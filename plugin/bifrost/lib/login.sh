# shellcheck shell=sh
# Login, relogin, connect, and logout flows.
# Contract: docs/dev/contract.md, sections 4, 5, 6.2.
# PLAN: sections 7.2-7.6.
# Load order: env.sh, validate.sh, common.sh, daemon.sh, ..., login.sh.

: "${BIFROST_LOGIN_TIMEOUT:=10m}"
: "${BIFROST_LOGIN_CLI_TIMEOUT:=630}"
: "${BIFROST_CONNECT_TIMEOUT:=30}"
: "${BIFROST_LOGOUT_TIMEOUT:=15}"
: "${BIFROST_LOCK_WAIT:=30}"

# login_same_server <cur_url> <target_url>: 0 when both refer to the same server.
login_same_server() {
    if daemon_is_official_url "${1:-}" && daemon_is_official_url "${2:-}"; then
        return 0
    fi
    _lss_a=${1%/}
    _lss_b=${2%/}
    [ "$_lss_a" = "$_lss_b" ]
}

# login_read_prefs: populate _lrp_ctrl, _lrp_acc_routes, _lrp_adv_routes,
# _lrp_adv_exit, _lrp_hostname from "debug prefs" (or PLAN 4.3 defaults).
login_read_prefs() {
    _lrp_ctrl=""
    _lrp_acc_routes="false"
    _lrp_adv_routes=""
    _lrp_adv_exit="false"
    _lrp_hostname=""

    _lrp_json=$(prefs_json 2>/dev/null) || return 0

    _lrp_raw_ctrl=$(printf '%s\n' "$_lrp_json" | jq -r '.ControlURL // ""' 2>/dev/null)
    if [ -n "$_lrp_raw_ctrl" ] && valid_login_server "$_lrp_raw_ctrl"; then
        _lrp_ctrl=$_lrp_raw_ctrl
    fi

    _lrp_raw_acc=$(printf '%s\n' "$_lrp_json" | jq -r 'if .RouteAll == true then "true" else "false" end' 2>/dev/null)
    [ "$_lrp_raw_acc" = true ] && _lrp_acc_routes="true"

    _lrp_raw_exit=$(printf '%s\n' "$_lrp_json" | jq -r '
        if ((.AdvertiseRoutes // []) | (index("0.0.0.0/0") != null and index("::/0") != null))
        then "true" else "false" end
    ' 2>/dev/null)
    [ "$_lrp_raw_exit" = true ] && _lrp_adv_exit="true"

    _lrp_raw_routes=$(printf '%s\n' "$_lrp_json" | jq -r '
        [(.AdvertiseRoutes // [])[] | select(. != "0.0.0.0/0" and . != "::/0")] | join(",")
    ' 2>/dev/null)
    if [ -n "$_lrp_raw_routes" ] && valid_cidr4_list "$_lrp_raw_routes"; then
        _lrp_adv_routes=$_lrp_raw_routes
    fi

    _lrp_raw_host=$(printf '%s\n' "$_lrp_json" | jq -r '.Hostname // ""' 2>/dev/null)
    if [ -n "$_lrp_raw_host" ] && valid_hostname "$_lrp_raw_host"; then
        _lrp_hostname=$_lrp_raw_host
    fi
    return 0
}

# act_login <server> <authkey>: validate, store authkey in 600 file, start job.
act_login() {
    _al_srv=${1:-}
    _al_key=${2:-}

    if ! daemon_running; then
        fail not_running
        return 1
    fi
    if [ -n "$_al_srv" ] && ! valid_login_server "$_al_srv"; then
        fail bad_server
        return 1
    fi
    if [ -n "$_al_key" ] && ! valid_authkey "$_al_key"; then
        fail bad_authkey
        return 1
    fi
    if job_running login; then
        fail busy
        return 1
    fi

    mkdir -p "$BIFROST_RUN" || {
        fail internal
        return 1
    }
    chmod 700 "$BIFROST_RUN" 2>/dev/null || true

    _al_keyfile="$BIFROST_RUN/authkey"
    _al_haskey=0
    if [ -n "$_al_key" ]; then
        if ! (
            umask 077
            printf '%s\n' "$_al_key" | atomic_write "$_al_keyfile" 600
        ); then
            rm -f "$_al_keyfile"
            fail internal
            return 1
        fi
        _al_haskey=1
    else
        rm -f "$_al_keyfile"
    fi

    _al_srv_arg=$_al_srv
    [ -z "$_al_srv_arg" ] && _al_srv_arg="-"
    if ! job_start login login "$_al_srv_arg" "$_al_haskey"; then
        rm -f "$_al_keyfile"
        return 1
    fi
    return 0
}

act_relogin() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    job_start login relogin - 0
}

# Internal body of job_login; caller always removes the authkey file.
login_job_body() {
    _ljb_act=${1:-login}
    _ljb_srv=${2:--}
    _ljb_haskey=${3:-0}
    [ "$_ljb_srv" = - ] && _ljb_srv=""
    _ljb_keyfile="$BIFROST_RUN/authkey"

    case "$_ljb_act" in
        login | relogin) ;;
        *)
            fail invalid_param
            return 1
            ;;
    esac
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    if [ -n "$_ljb_srv" ] && ! valid_login_server "$_ljb_srv"; then
        fail bad_server
        return 1
    fi

    login_read_prefs

    _ljb_cmd="up"
    _ljb_target=""
    if [ "$_ljb_act" = relogin ]; then
        if ! daemon_is_official_url "$_lrp_ctrl"; then
            _ljb_target=$_lrp_ctrl
        fi
    else
        if ! daemon_is_official_url "$_ljb_srv"; then
            _ljb_target=$_ljb_srv
        fi
        # Switch to a new profile via "tailscale login" when changing server
        # from an existing profile (PLAN 7.4).
        if [ -n "$_lrp_ctrl" ] && ! login_same_server "$_lrp_ctrl" "$_ljb_target"; then
            _ljb_cmd="login"
        fi
    fi

    _ljb_official="true"
    daemon_is_official_url "$_ljb_target" || _ljb_official="false"
    job_data login "{\"action\":\"$_ljb_act\",\"official\":$_ljb_official}"
    job_phase login running 20

    set -- "$_ljb_cmd"
    if [ "$_ljb_cmd" = up ]; then
        set -- "$@" --reset
    fi
    set -- "$@" \
        --accept-dns=false \
        --netfilter-mode=off \
        "--accept-routes=$_lrp_acc_routes" \
        "--advertise-routes=$_lrp_adv_routes" \
        "--advertise-exit-node=$_lrp_adv_exit" \
        "--hostname=$_lrp_hostname"

    if [ -n "$_ljb_target" ]; then
        set -- "$@" "--login-server=$_ljb_target"
    fi
    if [ "$_ljb_haskey" = 1 ]; then
        if [ ! -f "$_ljb_keyfile" ]; then
            fail bad_authkey
            return 1
        fi
        set -- "$@" "--auth-key=file:$_ljb_keyfile"
    fi
    if [ "$_ljb_act" = relogin ] && [ "$_ljb_cmd" = up ]; then
        set -- "$@" --force-reauth
    fi
    set -- "$@" "--timeout=$BIFROST_LOGIN_TIMEOUT"

    log login "running $_ljb_act via $_ljb_cmd (official=$_ljb_official)"
    # Discard stdout/stderr from logs: interactive login prints AuthURL to stderr.
    _ljb_errf="$BIFROST_RUN/login.err.$$"
    (
        umask 077
        ts_cli_t "$BIFROST_LOGIN_CLI_TIMEOUT" "$@" >/dev/null 2>"$_ljb_errf"
    )
    _ljb_rc=$?
    _ljb_expired=0
    if [ "$_ljb_rc" -eq 124 ]; then
        _ljb_expired=1
    elif [ "$_ljb_rc" -ne 0 ] && [ -f "$_ljb_errf" ] &&
        grep -qi 'timeout waiting for Tailscale' "$_ljb_errf" 2>/dev/null; then
        _ljb_expired=1
    fi
    rm -f "$_ljb_errf"

    if [ "$_ljb_expired" = 1 ]; then
        log login "login expired"
        fail login_expired
        return 1
    fi
    if [ "$_ljb_rc" -ne 0 ]; then
        log login "login failed (rc=$_ljb_rc)"
        fail cli_failed
        return 1
    fi

    daemon_set_control_server "$_ljb_target" || true
    fw_apply || log login "fw_apply after login failed"
    dns_apply || true
    status_refresh || true
    log login "$_ljb_act succeeded"
    return 0
}

job_login() {
    login_job_body "$@"
    _jl_rc=$?
    rm -f "$BIFROST_RUN/authkey"
    return "$_jl_rc"
}

# Reconnect from Stopped state (PLAN 7.1). Bare "tailscale up" enters simpleUp
# when the profile has a LoginName (verified in Tailscale 1.104.7 up.go:1024),
# preserving all prefs; falls back to full prefs args without --reset if needed.
login_connect_locked() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    _lc_st=$(backend_state) || return 1
    case "$_lc_st" in
        NeedsLogin | NoState)
            fail not_logged_in
            return 1
            ;;
        Running)
            status_refresh || true
            return 0
            ;;
    esac

    _lc_errf="$BIFROST_RUN/connect.err.$$"
    (
        umask 077
        ts_cli_t "$BIFROST_CONNECT_TIMEOUT" up >/dev/null 2>"$_lc_errf"
    )
    _lc_rc=$?
    _lc_need_flags=0
    if [ "$_lc_rc" -ne 0 ] && [ "$_lc_rc" -ne 124 ] && [ -f "$_lc_errf" ] &&
        grep -q 'requires mentioning all' "$_lc_errf" 2>/dev/null; then
        _lc_need_flags=1
    fi
    rm -f "$_lc_errf"

    if [ "$_lc_need_flags" = 1 ]; then
        log login "bare up rejected; retrying with current prefs (no --reset)"
        login_read_prefs
        set -- up \
            --accept-dns=false \
            --netfilter-mode=off \
            "--accept-routes=$_lrp_acc_routes" \
            "--advertise-routes=$_lrp_adv_routes" \
            "--advertise-exit-node=$_lrp_adv_exit" \
            "--hostname=$_lrp_hostname"
        if [ -n "$_lrp_ctrl" ] && ! daemon_is_official_url "$_lrp_ctrl"; then
            set -- "$@" "--login-server=$_lrp_ctrl"
        fi
        ts_cli_t "$BIFROST_CONNECT_TIMEOUT" "$@" >/dev/null 2>&1
        _lc_rc=$?
    fi

    if [ "$_lc_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_lc_rc" -ne 0 ]; then
        fail cli_failed
        return 1
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
    ts_cli_t "$BIFROST_LOGOUT_TIMEOUT" logout >/dev/null 2>&1
    _lo_rc=$?
    if [ "$_lo_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_lo_rc" -ne 0 ]; then
        fail cli_failed
        return 1
    fi
    dns_clear || true
    status_refresh || true
    log login "logged out"
    return 0
}

act_logout() {
    with_lock state "$BIFROST_LOCK_WAIT" login_logout_locked
}
