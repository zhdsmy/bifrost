# shellcheck shell=sh
# MagicDNS forwarding via dnsmasq (PLAN section 10).
# Contract file: see docs/dev/contract.md.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.

: "${BIFROST_DNSMASQ_MAIN:=/etc/dnsmasq.conf}"

# dns_has_conf_dir: 0 when $BIFROST_DNSMASQ_MAIN has conf-dir pointing to $BIFROST_DNSMASQ_DIR.
dns_has_conf_dir() {
    [ -r "$BIFROST_DNSMASQ_MAIN" ] || return 1
    _dh_want=${BIFROST_DNSMASQ_DIR%/}
    awk -v want="$_dh_want" '
        {
            sub(/^[ \t]+/, "")
            sub(/[ \t\r]+$/, "")
            if (index($0, "conf-dir=") == 1) {
                v = substr($0, 10)
                sub(/,.*/, "", v)
                sub(/\/+$/, "", v)
                if (v == want) { found = 1; exit 0 }
            }
        }
        END { exit (found ? 0 : 1) }
    ' "$BIFROST_DNSMASQ_MAIN"
}

# Both the watchdog and the page evaluate this policy with their own status
# sample. "keep" means the current file cannot usefully be repaired.
dns_policy_jq() {
    cat <<'JQ'
def dns_suffix:
    if (.CurrentTailnet.MagicDNSSuffix // "") != "" then .CurrentTailnet.MagicDNSSuffix
    else (.MagicDNSSuffix // "") end;
def dns_plan($offline; $query_error):
    (if ($mdns | not) then {action:"clear"}
     elif ($conf_dir | not) then {action:"keep", code:"no_conf_dir"}
     elif $offline then {action:"clear", code:"not_running"}
     elif $query_error != "" then {action:"keep", code:$query_error}
     elif type != "object" then {action:"keep", code:"cli_failed"}
     elif .BackendState == "Starting" or .BackendState == "NoState" then {action:"keep", code:"not_running"}
     elif .BackendState == "Stopped" or .BackendState == "NeedsLogin" or .BackendState == "NeedsMachineAuth" then
        {action:"clear", code:"not_running"}
     elif .BackendState != "Running" then {action:"keep", code:"cli_failed"}
     else dns_suffix as $s |
        if $s == "" then {action:"clear", code:"no_magicdns"}
        elif ($s | type) == "string" and ($s | length) <= 253 and
             ($s | test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\\z")) then
            {action:"forward", suffix:$s}
        else {action:"keep", code:"cli_failed"} end
     end) |
    .matches = (if .action == "forward" then $dns_contents == ("server=/" + .suffix + "/100.100.100.100\n")
                else ($dns_conf_exists | not) end) |
    .stale = (.action != "keep" and ((.matches | not) or $dns_legacy or $dns_reload));
JQ
}

_dns_observe() {
    if dns_has_conf_dir; then _dns_conf_dir=true; else _dns_conf_dir=false; fi
    _dns_conf_exists=false
    _dns_file=/dev/null
    if [ -e "$BIFROST_DNSMASQ_CONF" ] || [ -L "$BIFROST_DNSMASQ_CONF" ]; then
        _dns_conf_exists=true
        [ -f "$BIFROST_DNSMASQ_CONF" ] && _dns_file=$BIFROST_DNSMASQ_CONF
    fi
    _dns_legacy=false
    for _do_path in "$BIFROST_DNSMASQ_CONF".tmp.*; do
        if [ -e "$_do_path" ] || [ -L "$_do_path" ]; then _dns_legacy=true; break; fi
    done
    if [ -f "$BIFROST_RUN/dns.reload" ]; then _dns_reload=true; else _dns_reload=false; fi
}

_dns_jq() {
    jq --rawfile dns_contents "$_dns_file" --argjson dns_conf_exists "$_dns_conf_exists" \
        --argjson dns_legacy "$_dns_legacy" --argjson dns_reload "$_dns_reload" \
        --argjson conf_dir "$_dns_conf_dir" "$@"
}

_dns_live_plan() {
    _dns_observe
    if [ "$(cfg bifrost_magicdns)" = 1 ]; then _dl_on=true; else _dl_on=false; fi
    _dl_offline=false _dl_error="" _dl_st=""
    if [ "$_dl_on" = true ] && [ "$_dns_conf_dir" = true ]; then
        if daemon_running; then
            _dl_st=$(ts_cli status --json --peers=false 2>/dev/null) || {
                if [ "$?" -eq 124 ]; then _dl_error=timeout; else _dl_error=cli_failed; fi
            }
        else
            _dl_offline=true
        fi
    fi
    # shellcheck disable=SC2016 # dollar-prefixed variables belong to jq.
    _dl_plan=$(printf '%s' "$_dl_st" | _dns_jq -Rrs --argjson mdns "$_dl_on" \
        --argjson offline "$_dl_offline" --arg err "$_dl_error" "$(dns_policy_jq)"'
        (try fromjson catch null) | dns_plan($offline; $err)
        | [.action, (.suffix // "-"), (.code // "-"), .matches, .stale] | @tsv') || { fail internal; return 1; }
    read -r _dns_action _dns_suffix _dns_code _dns_matches _dns_stale <<EOF
$_dl_plan
EOF
}

_dns_restart() {
    mkdir -p "$BIFROST_RUN" || return 1
    : >"$BIFROST_RUN/dns.reload" || return 1
    service restart_dnsmasq >/dev/null 2>&1 && rm -f "$BIFROST_RUN/dns.reload"
}

# Retire legacy temp files that dnsmasq could load. Reload once if a
# watched file was removed, including on a partially successful cleanup.
_dns_remove_files() {
    _dr_changed=$1
    shift
    _dr_failed=0
    for _dr_path in "$@"; do
        [ -e "$_dr_path" ] || [ -L "$_dr_path" ] || continue
        if rm -f "$_dr_path"; then _dr_changed=1; else _dr_failed=1; fi
    done
    if [ "$_dr_changed" = 1 ] || [ -f "$BIFROST_RUN/dns.reload" ]; then
        _dns_restart || _dr_failed=1
    fi
    [ "$_dr_failed" = 0 ] || fail internal
}

dns_clear() {
    # Staging files are outside the watched directory and require no reload.
    _dc_failed=0
    rm -f "$BIFROST_DNSMASQ_DIR"/../.bifrost-dns-stage.* || _dc_failed=1
    _dns_remove_files 0 "$BIFROST_DNSMASQ_CONF" "$BIFROST_DNSMASQ_CONF".tmp.* || _dc_failed=1
    [ "$_dc_failed" = 0 ] || fail internal
}

_dns_install_line() {
    mkdir -p "$BIFROST_DNSMASQ_DIR" || return 1
    [ ! -d "$BIFROST_DNSMASQ_CONF" ] || return 1
    # On the router both directories live on JFFS. Refuse a separately
    # mounted conf-dir: mv would copy across devices and expose a partial file.
    _di_parent="$BIFROST_DNSMASQ_DIR/.."
    df -P "$_di_parent" "$BIFROST_DNSMASQ_DIR" | awk '
        NR == 2 { dev = $1; mount = $NF }
        END { exit !(NR == 3 && $1 == dev && $NF == mount) }
    ' || return 1
    _di_stage="$_di_parent/.bifrost-dns-stage.$$"
    if printf '%s\n' "$1" | atomic_write "$_di_stage" 644 &&
        mv -f "$_di_stage" "$BIFROST_DNSMASQ_CONF"; then
        return 0
    fi
    rm -f "$_di_stage" "$_di_stage.tmp.$$"
    return 1
}

dns_apply() {
    _dns_live_plan || return 1
    case "$_dns_action" in
        clear) dns_clear || return 1 ;;
        forward)
            if [ "$_dns_matches" = true ]; then
                _dns_remove_files 0 "$BIFROST_DNSMASQ_CONF".tmp.* || return 1
            else
                valid_dns_name "$_dns_suffix" || { fail cli_failed; return 1; }
                _dns_install_line "server=/$_dns_suffix/100.100.100.100" || { fail internal; return 1; }
                _dns_remove_files 1 "$BIFROST_DNSMASQ_CONF".tmp.* || return 1
                log dns "updated MagicDNS forwarding"
            fi
            ;;
    esac
    [ "$_dns_code" = - ] || fail "$_dns_code"
}

dns_check() {
    _dns_live_plan && [ "$_dns_stale" = false ]
}
