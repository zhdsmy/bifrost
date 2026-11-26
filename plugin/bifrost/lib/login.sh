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

# PLAN 7.5. "tailscale logout" deletes the profile. The new profile stays in
# memory until the next login, so a daemon restart drops prefs set on it. Keep
# the Settings-page prefs in the state dir from logout to the next login.
login_saved_prefs_file() {
    printf '%s\n' "$BIFROST_STATE/saved-prefs.json"
}

# login_logged_in_prefs: 0 when $_BIFROST_PREFS_JSON belongs to a logged-in profile.
login_logged_in_prefs() {
    printf '%s\n' "$_BIFROST_PREFS_JSON" |
        jq -e '((.Config.NodeID // "") != "") or ((.Config.UserProfile.LoginName // "") != "")' >/dev/null 2>&1
}

# login_save_prefs: record the prefs of the logged-in profile before logout.
# A logged-out profile already holds the saved values, so the file is kept.
login_save_prefs() {
    daemon_read_prefs || return 1
    login_logged_in_prefs || return 0
    mkdir -p "$BIFROST_STATE" 2>/dev/null || { fail state_not_writable; return 1; }
    printf '%s\n' "$_BIFROST_PREFS_JSON" | jq -c '{
        advertise_routes: [(.AdvertiseRoutes // [])[] | select(. != "0.0.0.0/0" and . != "::/0")],
        advertise_exit_node: ((.AdvertiseRoutes // []) | (index("0.0.0.0/0") != null and index("::/0") != null)),
        accept_routes: (.RouteAll == true),
        hostname: (.Hostname // "")
    }' 2>/dev/null | json_write "$(login_saved_prefs_file)"
}

# login_restore_prefs: set the saved prefs on a logged-out profile. A logged-in
# profile has its own prefs: the file is stale and is removed.
login_restore_prefs() {
    _lrs_f=$(login_saved_prefs_file)
    [ -f "$_lrs_f" ] || return 0
    daemon_read_prefs || return 1
    if login_logged_in_prefs; then
        rm -f "$_lrs_f"
        return 0
    fi
    # "-" stands for an empty list or name, so read keeps the field order.
    _lrs_line=$(jq -r '
        select((.advertise_routes | type) == "array" and (.advertise_exit_node | type) == "boolean" and
            (.accept_routes | type) == "boolean" and (.hostname | type) == "string") |
        "\(.advertise_routes | join(",") | if . == "" then "-" else . end) \(.advertise_exit_node) \(.accept_routes) \(if .hostname == "" then "-" else .hostname end)"
    ' "$_lrs_f" 2>/dev/null)
    read -r _lrs_routes _lrs_exit _lrs_acc _lrs_host <<EOF
$_lrs_line
EOF
    [ "$_lrs_routes" = - ] && _lrs_routes=""
    [ "$_lrs_host" = - ] && _lrs_host=""
    case "$_lrs_exit:$_lrs_acc" in true:true | true:false | false:true | false:false) ;; *) _lrs_line="" ;; esac
    if [ -z "$_lrs_line" ] || { [ -n "$_lrs_routes" ] && ! valid_cidr4_list "$_lrs_routes"; } ||
        { [ -n "$_lrs_host" ] && ! valid_hostname "$_lrs_host"; }; then
        log login "discarding invalid saved prefs"
        rm -f "$_lrs_f"
        return 0
    fi
    settings_ts_set "--advertise-routes=$_lrs_routes" "--advertise-exit-node=$_lrs_exit" \
        "--accept-routes=$_lrs_acc" "--hostname=$_lrs_host"
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

# Tailscale can create a machine key before the first login. Treat unknown
# store keys, unreadable state and an inconclusive live status conservatively.
login_new_profile() {
    [ ! -e "$BIFROST_STATE/control_url" ] || return 1
    if [ -e "$BIFROST_STATE/tailscaled.state" ]; then
        jq -e 'type == "object" and (keys - ["_machinekey"] == [])' \
            "$BIFROST_STATE/tailscaled.state" >/dev/null 2>&1 || return 1
    fi
    _lnp_status=$(ts_cli status --json 2>/dev/null) || return 1
    printf '%s\n' "$_lnp_status" | jq -e '.BackendState == "NeedsLogin" and .HaveNodeKey == false and
        ((.Self.ID // "") == "")' >/dev/null 2>&1
}

# Locked preparation step for job_login (populates _ljb_* variables).
login_prepare_locked() {
    _ljb_mode=$_ljb_act
    _ljb_target=""

    if ! daemon_running; then
        fail not_running
        return 1
    fi

    login_restore_prefs || log login "could not restore saved prefs: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
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
        if [ "$_lpl_prefs_ok" = 0 ] && ! login_new_profile; then
            fail "$_lpl_perr"
            return 1
        fi
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
    rm -f "$(login_saved_prefs_file)"
    # PLAN 7.4: non-official server requires --no-logs-no-support immediately.
    if daemon_should_disable_logs && ! daemon_running_has_nologs; then
        log login "restarting daemon to enforce --no-logs-no-support"
        daemon_restart || return 1
    else
        _lpost_err=""
        fw_apply || _lpost_err=${BIFROST_ERR:-fw_failed}
        dns_apply || _lpost_err=${_lpost_err:-${BIFROST_ERR:-internal}}
        if [ -n "$_lpost_err" ]; then
            log login "post-login network configuration failed: $_lpost_err"
            daemon_err_set "$_lpost_err"
        fi
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
    # Logging out must still work when the prefs cannot be saved.
    login_save_prefs || log login "could not save prefs before logout: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
    login_cli "$BIFROST_LOGOUT_TIMEOUT" logout || return 1
    daemon_clean_stale_authkey
    # The new profile starts from Tailscale's defaults.
    daemon_fix_prefs || log login "could not fix prefs after logout: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
    login_restore_prefs || log login "could not restore saved prefs: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
    dns_clear || true
    status_refresh || true
    log login "logged out"
    return 0
}

act_logout() {
    with_lock state "$BIFROST_LOCK_WAIT" login_logout_locked
}
