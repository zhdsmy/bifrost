# shellcheck shell=sh
# Settings action (act_set).
# Contract: docs/dev/contract.md, sections 4, 5.
# PLAN: section 8.
# Load order: env.sh, validate.sh, common.sh, daemon.sh, ..., settings.sh.

settings_bool_json() {
    if [ "$1" = 1 ]; then
        echo true
    else
        echo false
    fi
}

settings_is_nologs_forced() {
    if ! daemon_is_official_url "$(daemon_control_server)"; then
        return 0
    fi
    if daemon_running && daemon_read_prefs; then
        _snf_url=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r '.ControlURL // ""' 2>/dev/null)
        if [ -n "$_snf_url" ] && ! daemon_is_official_url "$_snf_url"; then
            return 0
        fi
    fi
    BIFROST_ERR=""
    return 1
}

settings_ts_set() {
    ts_cli set "$@" >/dev/null 2>&1
    _sts_rc=$?
    if [ "$_sts_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_sts_rc" -ne 0 ]; then
        fail cli_failed
        return 1
    fi
    return 0
}

# The caller has validated the key and value and holds the state lock.
settings_set_pref() {
    daemon_running || { fail not_running; return 1; }
    case "$1" in
        advertise_routes)
            _ssp_arg="--advertise-routes=$2"
            _ssp_field='[(.AdvertiseRoutes // [])[] | select(. != "0.0.0.0/0" and . != "::/0")]'
            ;;
        advertise_exit_node)
            _ssp_arg="--advertise-exit-node=$(settings_bool_json "$2")"
            _ssp_field='((.AdvertiseRoutes // []) | (index("0.0.0.0/0") != null and index("::/0") != null))'
            daemon_read_prefs || return 1
            _ssp_old=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r "$_ssp_field") || { fail cli_failed; return 1; }
            ;;
        accept_routes)
            _ssp_arg="--accept-routes=$(settings_bool_json "$2")"
            _ssp_field='(.RouteAll == true)'
            ;;
        hostname)
            _ssp_arg="--hostname=$2"
            _ssp_field='(.Hostname // "")'
            ;;
    esac
    settings_ts_set "$_ssp_arg" || return 1
    if [ "$1" = advertise_exit_node ] && ! fw_apply; then
        _ssp_err=${BIFROST_ERR:-fw_failed}
        if ! settings_ts_set "--advertise-exit-node=$_ssp_old" || ! fw_apply; then
            log settings "could not restore exit-node firewall settings"
            daemon_err_set fw_failed
        fi
        fail "$_ssp_err"
        return 1
    fi
    daemon_read_prefs || return 1
    BIFROST_RESULT=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -c "{value: $_ssp_field}") || {
        fail cli_failed
        return 1
    }
}

settings_restore() {
    if [ "$_ssl_present" = 1 ]; then
        cfg_set "$_ssl_db" "$_ssl_old"
    else
        dbus remove "$_ssl_db" >/dev/null 2>&1
    fi
}

settings_set_locked() {
    _ssl_key=$1
    _ssl_val=$2
    case "$1" in
        advertise_routes) [ -z "$2" ] || valid_cidr4_list "$2" ;;
        hostname) [ -z "$2" ] || valid_hostname "$2" ;;
        advertise_exit_node | accept_routes) valid_bool01 "$2" ;;
        port | no_logs | snat | local_access | lan_masq | magicdns | mirror)
            valid_setting "bifrost_$1" "$2" ;;
        *) fail invalid_param; return 1 ;;
    esac || { fail invalid_param; return 1; }

    case "$1" in
        advertise_routes | hostname | advertise_exit_node | accept_routes)
            settings_set_pref "$@" || return 1
            status_refresh || true
            return 0
            ;;
        no_logs)
            if [ "$2" = 0 ] && settings_is_nologs_forced; then
                fail invalid_param
                return 1
            fi
            ;;
    esac
    _ssl_db="bifrost_$_ssl_key"
    _ssl_present=0
    if dbus list "$_ssl_db" | grep -q "^$_ssl_db="; then _ssl_present=1; fi
    _ssl_old=$(cfg "$_ssl_db")
    _ssl_apply=""
    if daemon_running; then
        case "$1" in
            port | no_logs)
                if [ "$2" != "$_ssl_old" ]; then
                    job_running daemon && { fail busy; return 1; }
                    _ssl_apply=restart
                fi
                ;;
            local_access | lan_masq | snat) _ssl_apply=fw_apply ;;
            magicdns) _ssl_apply=dns_apply ;;
        esac
    fi
    if [ "$_ssl_val" != "$_ssl_old" ]; then
        cfg_set "$_ssl_db" "$_ssl_val" || return 1
    fi
    case "$_ssl_apply" in
        restart)
            if job_start daemon restart; then return 0; fi
            _ssl_err=${BIFROST_ERR:-internal}
            settings_restore || log settings "could not restore $_ssl_key"
            fail "$_ssl_err"
            return 1
            ;;
        fw_apply | dns_apply)
            if ! "$_ssl_apply"; then
                _ssl_err=${BIFROST_ERR:-internal}
                if ! settings_restore || ! "$_ssl_apply"; then
                    log settings "could not restore $_ssl_key after apply failed"
                    [ "$_ssl_apply" = fw_apply ] && daemon_err_set fw_failed
                fi
                fail "$_ssl_err"
                return 1
            fi
            ;;
    esac
    _ssl_cur=$(cfg "$_ssl_db")
    case "$_ssl_key" in
        port) BIFROST_RESULT="{\"value\":$_ssl_cur}" ;;
        snat | mirror) BIFROST_RESULT=$(jq -cn --arg v "$_ssl_cur" '{value:$v}') ;;
        *) BIFROST_RESULT="{\"value\":$(settings_bool_json "$_ssl_cur")}" ;;
    esac
    status_refresh || true
    return 0
}

act_set() {
    with_lock state "$BIFROST_LOCK_WAIT" settings_set_locked "${1:-}" "${2:-}"
}
