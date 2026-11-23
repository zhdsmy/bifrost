# shellcheck shell=sh
# Settings action (act_set).
# Contract: docs/dev/contract.md, sections 4, 5.
# PLAN: section 8.
# Load order: env.sh, validate.sh, common.sh, daemon.sh, ..., settings.sh.

: "${BIFROST_LOCK_WAIT:=30}"

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
    if daemon_running; then
        _snf_json=$(prefs_json 2>/dev/null) || return 1
        _snf_url=$(printf '%s\n' "$_snf_json" | jq -r '.ControlURL // ""' 2>/dev/null)
        if [ -n "$_snf_url" ] && ! daemon_is_official_url "$_snf_url"; then
            return 0
        fi
    fi
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

settings_set_locked() {
    _ssl_key=${1:-}
    _ssl_val=${2:-}

    case "$_ssl_key" in
        advertise_routes)
            if [ -n "$_ssl_val" ] && ! valid_cidr4_list "$_ssl_val"; then
                fail invalid_param
                return 1
            fi
            daemon_running || { fail not_running; return 1; }
            settings_ts_set "--advertise-routes=$_ssl_val" || return 1
            _ssl_p=$(prefs_json) || return 1
            _ssl_rb=$(printf '%s\n' "$_ssl_p" | jq -c '
                {value: [(.AdvertiseRoutes // [])[] | select(. != "0.0.0.0/0" and . != "::/0")]}
            ' 2>/dev/null) || { fail cli_failed; return 1; }
            BIFROST_RESULT=$_ssl_rb
            status_refresh || true
            ;;

        advertise_exit_node)
            valid_bool01 "$_ssl_val" || { fail invalid_param; return 1; }
            daemon_running || { fail not_running; return 1; }
            _ssl_b=false
            [ "$_ssl_val" = 1 ] && _ssl_b=true
            settings_ts_set "--advertise-exit-node=$_ssl_b" || return 1
            fw_apply || log settings "fw_apply after advertise_exit_node failed"
            _ssl_p=$(prefs_json) || return 1
            _ssl_rb=$(printf '%s\n' "$_ssl_p" | jq -c '
                {value: ((.AdvertiseRoutes // []) | (index("0.0.0.0/0") != null and index("::/0") != null))}
            ' 2>/dev/null) || { fail cli_failed; return 1; }
            BIFROST_RESULT=$_ssl_rb
            status_refresh || true
            ;;

        accept_routes)
            valid_bool01 "$_ssl_val" || { fail invalid_param; return 1; }
            daemon_running || { fail not_running; return 1; }
            _ssl_b=false
            [ "$_ssl_val" = 1 ] && _ssl_b=true
            settings_ts_set "--accept-routes=$_ssl_b" || return 1
            _ssl_p=$(prefs_json) || return 1
            _ssl_rb=$(printf '%s\n' "$_ssl_p" | jq -c '{value: (.RouteAll == true)}' 2>/dev/null) || {
                fail cli_failed
                return 1
            }
            BIFROST_RESULT=$_ssl_rb
            status_refresh || true
            ;;

        hostname)
            if [ -n "$_ssl_val" ] && ! valid_hostname "$_ssl_val"; then
                fail invalid_param
                return 1
            fi
            daemon_running || { fail not_running; return 1; }
            settings_ts_set "--hostname=$_ssl_val" || return 1
            _ssl_p=$(prefs_json) || return 1
            _ssl_rb=$(printf '%s\n' "$_ssl_p" | jq -c '{value: (.Hostname // "")}' 2>/dev/null) || {
                fail cli_failed
                return 1
            }
            BIFROST_RESULT=$_ssl_rb
            status_refresh || true
            ;;

        port)
            valid_port "$_ssl_val" || { fail invalid_param; return 1; }
            if daemon_running && job_running daemon; then
                fail busy
                return 1
            fi
            cfg_set bifrost_port "$_ssl_val" || return 1
            if daemon_running; then
                job_start daemon restart || return 1
            else
                _ssl_cur=$(cfg bifrost_port)
                BIFROST_RESULT="{\"value\":$_ssl_cur}"
                status_refresh || true
            fi
            ;;

        no_logs)
            valid_bool01 "$_ssl_val" || { fail invalid_param; return 1; }
            if [ "$_ssl_val" = 0 ] && settings_is_nologs_forced; then
                fail invalid_param
                return 1
            fi
            if daemon_running && job_running daemon; then
                fail busy
                return 1
            fi
            cfg_set bifrost_no_logs "$_ssl_val" || return 1
            if daemon_running; then
                job_start daemon restart || return 1
            else
                _ssl_cur=$(cfg bifrost_no_logs)
                BIFROST_RESULT="{\"value\":$(settings_bool_json "$_ssl_cur")}"
                status_refresh || true
            fi
            ;;

        local_access | lan_masq)
            valid_bool01 "$_ssl_val" || { fail invalid_param; return 1; }
            _ssl_dkey="bifrost_$_ssl_key"
            _ssl_old=$(cfg "$_ssl_dkey")
            cfg_set "$_ssl_dkey" "$_ssl_val" || return 1
            if daemon_running; then
                if ! fw_apply; then
                    _ssl_err=${BIFROST_ERR:-fw_failed}
                    cfg_set "$_ssl_dkey" "$_ssl_old"
                    fail "$_ssl_err"
                    return 1
                fi
            fi
            _ssl_cur=$(cfg "$_ssl_dkey")
            BIFROST_RESULT="{\"value\":$(settings_bool_json "$_ssl_cur")}"
            status_refresh || true
            ;;

        snat)
            valid_snat "$_ssl_val" || { fail invalid_param; return 1; }
            _ssl_old=$(cfg bifrost_snat)
            cfg_set bifrost_snat "$_ssl_val" || return 1
            if daemon_running; then
                if ! fw_apply; then
                    _ssl_err=${BIFROST_ERR:-fw_failed}
                    cfg_set bifrost_snat "$_ssl_old"
                    fail "$_ssl_err"
                    return 1
                fi
            fi
            _ssl_cur=$(cfg bifrost_snat)
            BIFROST_RESULT=$(jq -cn --arg v "$_ssl_cur" '{value:$v}')
            status_refresh || true
            ;;

        magicdns)
            valid_bool01 "$_ssl_val" || { fail invalid_param; return 1; }
            _ssl_old=$(cfg bifrost_magicdns)
            cfg_set bifrost_magicdns "$_ssl_val" || return 1
            if ! dns_apply; then
                _ssl_err=${BIFROST_ERR:-internal}
                cfg_set bifrost_magicdns "$_ssl_old"
                fail "$_ssl_err"
                return 1
            fi
            _ssl_cur=$(cfg bifrost_magicdns)
            BIFROST_RESULT="{\"value\":$(settings_bool_json "$_ssl_cur")}"
            status_refresh || true
            ;;

        mirror)
            if [ -n "$_ssl_val" ] && ! valid_mirror "$_ssl_val"; then
                fail invalid_param
                return 1
            fi
            cfg_set bifrost_mirror "$_ssl_val" || return 1
            _ssl_cur=$(cfg bifrost_mirror)
            BIFROST_RESULT=$(jq -cn --arg v "$_ssl_cur" '{value:$v}')
            status_refresh || true
            ;;

        *)
            fail invalid_param
            return 1
            ;;
    esac
    return 0
}

act_set() {
    with_lock state "$BIFROST_LOCK_WAIT" settings_set_locked "${1:-}" "${2:-}"
}
