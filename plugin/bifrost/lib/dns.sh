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

# _dns_suffix_from_json <status-json>: print validated MagicDNS suffix or return 1.
_dns_suffix_from_json() {
    _ds_raw=$(printf '%s\n' "$1" | jq -r '
        if (.MagicDNSSuffix // "") != "" then .MagicDNSSuffix
        elif (.CurrentTailnet.MagicDNSSuffix // "") != "" then .CurrentTailnet.MagicDNSSuffix
        else "" end
    ' 2>/dev/null)
    if [ -z "$_ds_raw" ]; then
        return 1
    fi
    if ! valid_dns_name "$_ds_raw"; then
        log dns "invalid MagicDNSSuffix ignored"
        return 1
    fi
    printf '%s\n' "$_ds_raw"
}

# _dns_current_suffix: query tailscale status --json and print validated suffix.
_dns_current_suffix() {
    _dc_st=$(ts_cli status --json 2>/dev/null) || return 1
    _dns_suffix_from_json "$_dc_st"
}

# _dns_file_matches <expected-line>: 0 when $BIFROST_DNSMASQ_CONF has exactly that one line.
_dns_file_matches() {
    [ -f "$BIFROST_DNSMASQ_CONF" ] || return 1
    printf '%s\n' "$1" | cmp -s - "$BIFROST_DNSMASQ_CONF"
}

# dns_clear: remove dnsmasq config file and restart dnsmasq only if a file was removed.
dns_clear() {
    if [ -e "$BIFROST_DNSMASQ_CONF" ]; then
        rm -f "$BIFROST_DNSMASQ_CONF" || {
            fail internal
            return 1
        }
        service restart_dnsmasq >/dev/null 2>&1
        log dns "cleared MagicDNS forwarding"
    fi
    return 0
}

# dns_apply: write or clear MagicDNS forwarding config according to bifrost_magicdns (PLAN 10).
dns_apply() {
    if [ "$(cfg bifrost_magicdns)" != 1 ]; then
        dns_clear
        return $?
    fi
    if ! dns_has_conf_dir; then
        fail no_conf_dir
        return 1
    fi
    _da_suf=$(_dns_current_suffix) || {
        fail no_magicdns
        return 1
    }
    _da_line="server=/$_da_suf/100.100.100.100"
    if _dns_file_matches "$_da_line"; then
        return 0
    fi
    [ -d "$BIFROST_DNSMASQ_DIR" ] || mkdir -p "$BIFROST_DNSMASQ_DIR" || {
        fail internal
        return 1
    }
    if ! printf '%s\n' "$_da_line" | atomic_write "$BIFROST_DNSMASQ_CONF" 644; then
        fail internal
        return 1
    fi
    service restart_dnsmasq >/dev/null 2>&1
    log dns "updated MagicDNS forwarding"
    return 0
}

# dns_check: 0 when dnsmasq file matches current suffix (or is absent when disabled).
# Optional $1: already-fetched status JSON to avoid an extra CLI call.
dns_check() {
    if [ "$(cfg bifrost_magicdns)" != 1 ]; then
        [ ! -e "$BIFROST_DNSMASQ_CONF" ]
        return $?
    fi
    dns_has_conf_dir || return 1
    if [ $# -ge 1 ]; then
        _dk_suf=$(_dns_suffix_from_json "$1") || return 1
    else
        _dk_suf=$(_dns_current_suffix) || return 1
    fi
    _dns_file_matches "server=/$_dk_suf/100.100.100.100"
}
