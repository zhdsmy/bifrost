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

# Shared jq expression for both the live CLI and the status page.
dns_suffix_jq() {
    printf '%s' 'if (.CurrentTailnet.MagicDNSSuffix // "") != "" then .CurrentTailnet.MagicDNSSuffix else (.MagicDNSSuffix // "") end'
}

# Set _dns_suf in the calling shell so the specific error survives.
_dns_suffix() {
    if [ "$#" -eq 0 ]; then
        daemon_running || { fail not_running; return 1; }
        _ds_st=$(ts_cli status --json --peers=false 2>/dev/null) || {
            _ds_rc=$?
            if [ "$_ds_rc" -eq 124 ]; then fail timeout; else fail cli_failed; fi
            return 1
        }
    else
        _ds_st=$1
    fi
    _ds_result=$(printf '%s\n' "$_ds_st" | jq -er '
        if type != "object" then error("invalid status")
        elif .BackendState != null and .BackendState != "Running" then "inactive"
        else ('"$(dns_suffix_jq)"' | strings | "suffix:" + .) end' 2>/dev/null) || { fail cli_failed; return 1; }
    [ "$_ds_result" != inactive ] || { fail not_running; return 1; }
    _dns_suf=${_ds_result#suffix:}
    [ -n "$_dns_suf" ] || { fail no_magicdns; return 1; }
    valid_dns_name "$_dns_suf" || { fail cli_failed; return 1; }
}

# _dns_file_matches <expected-line>: 0 when $BIFROST_DNSMASQ_CONF has exactly that one line.
_dns_file_matches() {
    [ -f "$BIFROST_DNSMASQ_CONF" ] || return 1
    printf '%s\n' "$1" | cmp -s - "$BIFROST_DNSMASQ_CONF"
}

# Retire legacy temp files that dnsmasq could load. Reload once if a
# watched file was removed, including on a partially successful cleanup.
_dns_remove_files() {
    _dr_changed=0
    _dr_failed=0
    for _dr_path in "$@"; do
        [ -e "$_dr_path" ] || [ -L "$_dr_path" ] || continue
        if rm -f "$_dr_path"; then _dr_changed=1; else _dr_failed=1; fi
    done
    if [ "$_dr_changed" = 1 ]; then
        service restart_dnsmasq >/dev/null 2>&1 || _dr_failed=1
    fi
    [ "$_dr_failed" = 0 ] || fail internal
}

dns_clear() {
    # Staging files are outside the watched directory and require no reload.
    rm -f "$BIFROST_DNSMASQ_DIR"/../.bifrost-dns-stage.* || { fail internal; return 1; }
    _dns_remove_files "$BIFROST_DNSMASQ_CONF" "$BIFROST_DNSMASQ_CONF".tmp.*
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
    if [ "$(cfg bifrost_magicdns)" != 1 ]; then dns_clear; return $?; fi
    dns_has_conf_dir || { fail no_conf_dir; return 1; }
    if ! _dns_suffix; then
        # A stopped backend or an absent suffix makes an old rule unusable.
        # Keep the known-good file on transient CLI failures and timeouts.
        case "$BIFROST_ERR" in
            not_running | no_magicdns) dns_clear || return 1 ;;
        esac
        return 1
    fi
    _da_line="server=/$_dns_suf/100.100.100.100"
    if _dns_file_matches "$_da_line"; then
        _dns_remove_files "$BIFROST_DNSMASQ_CONF".tmp.*
        return $?
    fi
    _dns_install_line "$_da_line" || { fail internal; return 1; }
    # Remove legacy leftovers before activating the new rule.
    rm -f "$BIFROST_DNSMASQ_CONF".tmp.* || { fail internal; return 1; }
    service restart_dnsmasq >/dev/null 2>&1 || { fail internal; return 1; }
    log dns "updated MagicDNS forwarding"
}

# Optional status JSON avoids a CLI call for callers with a current snapshot.
dns_check() {
    for _dk_path in "$BIFROST_DNSMASQ_CONF".tmp.*; do
        [ ! -e "$_dk_path" ] && [ ! -L "$_dk_path" ] || return 1
    done
    if [ "$(cfg bifrost_magicdns)" != 1 ]; then
        [ ! -e "$BIFROST_DNSMASQ_CONF" ]
        return $?
    fi
    dns_has_conf_dir || { fail no_conf_dir; return 1; }
    if _dns_suffix "$@"; then
        _dns_file_matches "server=/$_dns_suf/100.100.100.100"
    else
        case "$BIFROST_ERR" in
            not_running | no_magicdns) [ ! -e "$BIFROST_DNSMASQ_CONF" ] ;;
            *) return 1 ;;
        esac
    fi
}
