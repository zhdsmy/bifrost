# shellcheck shell=sh
# Login, relogin, connect, and logout flows.
# Contract: docs/dev/contract.md, sections 2, 4, 5, 6.2.
# PLAN: sections 7.2-7.6.
# Load order: env.sh, validate.sh, common.sh, daemon.sh, ..., login.sh.

: "${BIFROST_LOGIN_TIMEOUT:=10m}"
: "${BIFROST_LOGIN_CLI_TIMEOUT:=630}"
: "${BIFROST_CONNECT_TIMEOUT:=30}"
: "${BIFROST_LOGOUT_TIMEOUT:=15}"

# login_same_server <cur_url> <target_url>: 0 when both refer to the same server.
login_same_server() {
    if daemon_is_official_url "${1:-}" && daemon_is_official_url "${2:-}"; then
        return 0
    fi
    _lss_a=${1%/}
    _lss_b=${2%/}
    [ "$_lss_a" = "$_lss_b" ]
}

# Keep diagnostic output (which may contain an AuthURL) in memory only.
# Tailscale handles TERM and can return 1 instead of run_timeout's 124.
login_cli() {
    _lc_start=$(now)
    _lc_err=$(ts_cli_t "$@" 2>&1 >/dev/null)
    _lc_rc=$?
    [ "$_lc_rc" -eq 0 ] && return 0
    _lc_code=cli_failed
    case "$_lc_err" in *"timeout waiting for Tailscale"*) _lc_code=timeout ;; esac
    if [ "$_lc_rc" -eq 124 ] || [ "$(($(now) - _lc_start))" -ge "$1" ]; then
        _lc_code=timeout
    fi
    fail "$_lc_code"
}

# login_read_prefs: populate _lrp_ctrl, _lrp_acc_routes, _lrp_adv_routes,
# _lrp_adv_exit, _lrp_hostname from "debug prefs". Returns 1 on read error
# (preserving BIFROST_ERR in-shell) with defaults populated.
login_read_prefs() {
    _lrp_ctrl=""
    _lrp_acc_routes="false"
    _lrp_adv_routes=""
    _lrp_adv_exit="false"
    _lrp_hostname=""

    daemon_read_prefs || return 1

    _lrp_raw_ctrl=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r '.ControlURL // ""' 2>/dev/null)
    if [ -n "$_lrp_raw_ctrl" ] && valid_login_server "$_lrp_raw_ctrl"; then
        _lrp_ctrl=$_lrp_raw_ctrl
    fi

    _lrp_raw_acc=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r 'if .RouteAll == true then "true" else "false" end' 2>/dev/null)
    [ "$_lrp_raw_acc" = true ] && _lrp_acc_routes="true"

    _lrp_raw_exit=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r '
        if ((.AdvertiseRoutes // []) | (index("0.0.0.0/0") != null and index("::/0") != null))
        then "true" else "false" end
    ' 2>/dev/null)
    [ "$_lrp_raw_exit" = true ] && _lrp_adv_exit="true"

    _lrp_raw_routes=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r '
        [(.AdvertiseRoutes // [])[] | select(. != "0.0.0.0/0" and . != "::/0")] | join(",")
    ' 2>/dev/null)
    if [ -n "$_lrp_raw_routes" ] && valid_cidr4_list "$_lrp_raw_routes"; then
        _lrp_adv_routes=$_lrp_raw_routes
    fi

    _lrp_raw_host=$(printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -r '.Hostname // ""' 2>/dev/null)
    if [ -n "$_lrp_raw_host" ] && valid_hostname "$_lrp_raw_host"; then
        _lrp_hostname=$_lrp_raw_host
    fi
    return 0
}

# PLAN 7.6. The bare reconnect fallback shares the same prefs as login.
login_run_ts() {
    _lrt_limit=$1
    _lrt_mode=$2
    _lrt_server=$3
    _lrt_keyfile=$4

    case "$_lrt_mode" in
        switch) set -- login ;;
        connect | recorded) set -- up ;;
        *) set -- up --reset ;;
    esac
    set -- "$@" --accept-dns=false --netfilter-mode=off
    # With only the recorded server we do not know the profile values. Omit
    # them and --reset so Tailscale's accidental-revert check protects them.
    if [ "$_lrt_mode" != recorded ]; then
        set -- "$@" "--accept-routes=$_lrp_acc_routes" "--advertise-routes=$_lrp_adv_routes" \
            "--advertise-exit-node=$_lrp_adv_exit" "--hostname=$_lrp_hostname"
    fi
    [ -n "$_lrt_server" ] && set -- "$@" "--login-server=$_lrt_server"
    [ -n "$_lrt_keyfile" ] && set -- "$@" "--auth-key=file:$_lrt_keyfile"
    case "$_lrt_mode" in recorded | relogin) set -- "$@" --force-reauth ;; esac
    [ "$_lrt_mode" = connect ] || set -- "$@" "--timeout=$BIFROST_LOGIN_TIMEOUT"
    login_cli "$_lrt_limit" "$@"
}

# Only the read descriptor crosses the detached job boundary. Unlink the
# empty mode-600 file before the first secret byte is written. A failed exec
# or SIGKILL cannot leave a credential in the run directory.
login_queue_key() {
    if ! rm -f "$BIFROST_RUN/authkey" || ! printf '%s\n' "$2" >&4; then
        fail internal
        return 1
    fi
    job_start login login "$1" 1 4>&-
}

login_queue_locked() {
    if job_running login; then
        fail busy
        return 1
    fi
    # Also remove files left by older releases.
    rm -f "$BIFROST_RUN/authkey" "$BIFROST_RUN"/authkey.tmp.* || return 1
    daemon_running || { fail not_running; return 1; }
    if [ "$1" = relogin ]; then
        job_start login relogin - 0
        return $?
    fi
    [ -z "$2" ] || valid_login_server "$2" || { fail bad_server; return 1; }
    if [ -z "$3" ]; then
        job_start login login "${2:--}" 0
        return $?
    fi
    valid_authkey "$3" || { fail bad_authkey; return 1; }
    (umask 077 && : >"$BIFROST_RUN/authkey") || { fail internal; return 1; }
    # Independent file descriptions keep the worker's read offset at zero.
    # shellcheck disable=SC2094
    login_queue_key "${2:--}" "$3" 3<"$BIFROST_RUN/authkey" 4>"$BIFROST_RUN/authkey"
}

act_login() {
    with_lock state "$BIFROST_LOCK_WAIT" login_queue_locked login "${1:-}" "${2:-}"
}

act_relogin() {
    with_lock state "$BIFROST_LOCK_WAIT" login_queue_locked relogin
}

# Locked preparation step for job_login (populates _ljb_* variables).
login_prepare_locked() {
    _ljb_mode=$_ljb_act
    _ljb_target=""

    if ! daemon_running; then
        fail not_running
        return 1
    fi

    _lpl_prefs_ok=1
    _lpl_perr=""
    if ! login_read_prefs; then
        _lpl_prefs_ok=0
        _lpl_perr=${BIFROST_ERR:-cli_failed}
        BIFROST_ERR=""
    fi

    if [ "$_ljb_act" = relogin ]; then
        if [ "$_lpl_prefs_ok" = 0 ] || [ -z "$_lrp_ctrl" ]; then
            _lrp_ctrl=$(daemon_control_server)
            if [ -z "$_lrp_ctrl" ]; then
                if [ "$_lpl_prefs_ok" = 0 ]; then
                    fail "$_lpl_perr"
                else
                    fail not_logged_in
                fi
                return 1
            fi
        fi
        if ! daemon_is_official_url "$_lrp_ctrl"; then
            _ljb_target=$_lrp_ctrl
        fi
        [ "$_lpl_prefs_ok" = 1 ] || _ljb_mode=recorded
    else
        [ -z "$_lrp_ctrl" ] && _lrp_ctrl=$(daemon_control_server)
        if ! daemon_is_official_url "$_ljb_srv"; then
            _ljb_target=$_ljb_srv
        fi
        # Switch to a new profile via "tailscale login" when changing server
        # from an existing profile (PLAN 7.4).
        if [ -n "$_lrp_ctrl" ] && ! login_same_server "$_lrp_ctrl" "$_ljb_target"; then
            _ljb_mode=switch
        fi
    fi

    _ljb_official="true"
    daemon_is_official_url "$_ljb_target" || _ljb_official="false"
    return 0
}

# Locked post-login step: record server, enforce --no-logs-no-support, apply fw/dns.
login_post_locked() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    daemon_set_control_server "$_ljb_target" || return 1
    # PLAN 7.4: non-official server requires --no-logs-no-support immediately.
    if daemon_should_disable_logs && ! daemon_running_has_nologs; then
        log login "restarting daemon to enforce --no-logs-no-support"
        daemon_restart || return 1
    else
        fw_apply || log login "fw_apply after login failed"
        dns_apply || true
        status_refresh || true
    fi
    return 0
}

# Keep the state lock around preparation and finalization only.
job_login() {
    _ljb_act=${1:-login}
    _ljb_srv=${2:--}
    [ "$_ljb_srv" = - ] && _ljb_srv=""
    case "$_ljb_act" in login | relogin) ;; *) fail invalid_param; return 1 ;; esac
    [ -z "$_ljb_srv" ] || valid_login_server "$_ljb_srv" || { fail bad_server; return 1; }
    with_lock state 60 login_prepare_locked || return 1

    _ljb_kf=""
    if [ "${3:-0}" = 1 ]; then
        _ljb_kf=/proc/self/fd/3
        if [ "$(readlink "$_ljb_kf")" != "$BIFROST_RUN/authkey (deleted)" ] || [ ! -s "$_ljb_kf" ]; then
            fail bad_authkey
            return 1
        fi
    fi
    job_data login "{\"action\":\"$_ljb_act\",\"official\":$_ljb_official}"
    job_phase login running 20
    log login "running $_ljb_act (official=$_ljb_official)"
    if ! login_run_ts "$BIFROST_LOGIN_CLI_TIMEOUT" "$_ljb_mode" "$_ljb_target" "$_ljb_kf"; then
        [ "$BIFROST_ERR" = timeout ] && fail login_expired
        return 1
    fi
    # A post-login daemon restart must not inherit the credential.
    with_lock state 60 login_post_locked 3<&- || return 1
    log login "$_ljb_act succeeded"
}

# Reconnect from Stopped state (PLAN 7.1). Bare "tailscale up" enters simpleUp
# when the profile has a LoginName (verified in Tailscale 1.104.7 up.go:1024),
# preserving all prefs; falls back to PLAN 7.6 args without --reset if needed.
login_connect_locked() {
    daemon_read_state || return 1
    case "$_BIFROST_BACKEND_STATE" in
        NeedsLogin | NoState)
            fail not_logged_in
            return 1
            ;;
        Running)
            status_refresh || true
            return 0
            ;;
    esac

    if ! login_cli "$BIFROST_CONNECT_TIMEOUT" up; then
        [ "$BIFROST_ERR" = cli_failed ] || return 1
        case "$_lc_err" in *"requires mentioning all"*) ;; *) return 1 ;; esac
        login_read_prefs || return 1
        login_run_ts "$BIFROST_CONNECT_TIMEOUT" connect "$_lrp_ctrl" "" || return 1
    fi

    daemon_fix_prefs || true
    fw_apply || true
    dns_apply || true
    status_refresh || true
    log login "reconnected"
    return 0
}

act_connect() {
    with_lock state "$BIFROST_LOCK_WAIT" login_connect_locked
}

login_logout_locked() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    login_cli "$BIFROST_LOGOUT_TIMEOUT" logout || return 1
    daemon_clean_stale_authkey
    dns_clear || true
    status_refresh || true
    log login "logged out"
    return 0
}

act_logout() {
    with_lock state "$BIFROST_LOCK_WAIT" login_logout_locked
}
