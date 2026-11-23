# shellcheck shell=sh
# Daemon lifecycle, hooks, watchdog, and daemon job.
# Contract: docs/dev/contract.md, sections 4, 5, 6.1, 6.2, 7.
# Load order: env.sh, validate.sh, common.sh, daemon.sh.

: "${BIFROST_WAIT_READY:=15}"
: "${BIFROST_STOP_TIMEOUT:=10}"
: "${BIFROST_CLEANUP_TIMEOUT:=15}"
: "${BIFROST_WATCHDOG_CRON:=*/2 * * * *}"
: "${BIFROST_WATCHDOG_WINDOW:=1800}"
: "${BIFROST_WATCHDOG_MAX:=3}"
: "${BIFROST_LOG_MAX_BYTES:=1048576}"
: "${BIFROST_LOG_KEEP_BYTES:=204800}"

# Internal phase hook set only while job_daemon runs daemon_start/daemon_stop.
_BIFROST_DAEMON_JOB=""

daemon_phase() {
    [ -n "${_BIFROST_DAEMON_JOB:-}" ] || return 0
    job_phase "$_BIFROST_DAEMON_JOB" "$1" "${2:-}"
}

daemon_err_set() {
    mkdir -p "$BIFROST_RUN" 2>/dev/null
    printf '%s\n' "$1" | atomic_write "$BIFROST_DAEMON_ERR" 644
    fail "$1"
}

daemon_err_clear() {
    rm -f "$BIFROST_DAEMON_ERR"
}

# daemon_is_official_url <url>: 0 when empty or a Tailscale official control URL.
daemon_is_official_url() {
    case "${1:-}" in
        "" | "https://controlplane.tailscale.com" | "https://controlplane.tailscale.com/" | \
            "https://login.tailscale.com" | "https://login.tailscale.com/")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Last control server URL recorded in state dir (empty means official).
daemon_control_server() {
    _dcs_f="$BIFROST_STATE/control_url"
    [ -f "$_dcs_f" ] || return 0
    _dcs_u=$(head -n 1 "$_dcs_f" 2>/dev/null)
    if [ -n "$_dcs_u" ] && valid_login_server "$_dcs_u"; then
        printf '%s\n' "$_dcs_u"
    fi
}

# daemon_set_control_server <url>: store custom control server or clear for official.
daemon_set_control_server() {
    _dsc_f="$BIFROST_STATE/control_url"
    if daemon_is_official_url "${1:-}"; then
        rm -f "$_dsc_f"
        return 0
    fi
    valid_login_server "$1" || {
        fail bad_server
        return 1
    }
    mkdir -p "$BIFROST_STATE" 2>/dev/null || return 1
    printf '%s\n' "$1" | atomic_write "$_dsc_f" 644
}

# daemon_should_disable_logs: 0 when --no-logs-no-support must be passed.
daemon_should_disable_logs() {
    [ "$(cfg bifrost_no_logs)" = 1 ] && return 0
    ! daemon_is_official_url "$(daemon_control_server)"
}

# daemon_pid_alive <pid>: 0 when pid exists and is not a zombie.
daemon_pid_alive() {
    valid_uint "${1:-}" || return 1
    kill -0 "$1" 2>/dev/null || return 1
    if [ -r "/proc/$1/status" ] &&
        awk 'BEGIN { z=1 } /^State:/ { if ($2 == "Z") z=0; exit } END { exit z }' "/proc/$1/status" 2>/dev/null; then
        return 1
    fi
    return 0
}

# prefs_json: print "tailscale debug prefs" JSON, or fail not_running/timeout/cli_failed.
prefs_json() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    _pj_out=$(ts_cli debug prefs 2>/dev/null)
    _pj_rc=$?
    if [ "$_pj_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_pj_rc" -ne 0 ] || ! printf '%s\n' "$_pj_out" | jq -e 'type == "object"' >/dev/null 2>&1; then
        fail cli_failed
        return 1
    fi
    printf '%s\n' "$_pj_out"
}

# backend_state: print BackendState from "tailscale status --json", or fail.
backend_state() {
    if ! daemon_running; then
        fail not_running
        return 1
    fi
    _bs_out=$(ts_cli status --json 2>/dev/null)
    _bs_rc=$?
    if [ "$_bs_rc" -eq 124 ]; then
        fail timeout
        return 1
    fi
    if [ "$_bs_rc" -ne 0 ]; then
        fail cli_failed
        return 1
    fi
    _bs_st=$(printf '%s\n' "$_bs_out" | jq -r '.BackendState // empty' 2>/dev/null)
    if [ -z "$_bs_st" ]; then
        fail cli_failed
        return 1
    fi
    printf '%s\n' "$_bs_st"
}

# daemon_wait_ready <secs>: 0 when status --json answers within <secs>.
daemon_wait_ready() {
    _dw_limit=${1:-$BIFROST_WAIT_READY}
    _dw_deadline=$(($(now) + _dw_limit))
    while :; do
        _dw_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null)
        if ! daemon_pid_alive "$_dw_pid"; then
            fail start_failed
            return 1
        fi
        if [ -e "$BIFROST_SOCK" ] && daemon_running; then
            _dw_rem=$((_dw_deadline - $(now)))
            [ "$_dw_rem" -lt 1 ] && _dw_rem=1
            if ts_cli_t "$_dw_rem" status --json >/dev/null 2>&1; then
                return 0
            fi
        fi
        if [ "$(now)" -ge "$_dw_deadline" ]; then
            fail start_failed
            return 1
        fi
        sleep 1
    done
}

# daemon_precheck: verify core, tun device, no conflict, writable state dir.
daemon_precheck() {
    if [ ! -x "$BIFROST_CORE" ]; then
        log daemon "precheck failed: core missing"
        daemon_err_set core_missing
        return 1
    fi
    _dpc_ver=$(run_timeout 5 "$BIFROST_CORE" --version 2>/dev/null | head -n 1)
    if [ -z "$_dpc_ver" ]; then
        log daemon "precheck failed: core --version failed"
        daemon_err_set core_missing
        return 1
    fi

    if [ ! -e "$BIFROST_TUN_DEV" ]; then
        has_cmd modprobe && modprobe tun >/dev/null 2>&1
    fi
    if [ ! -e "$BIFROST_TUN_DEV" ]; then
        log daemon "precheck failed: no tun device"
        daemon_err_set no_tun
        return 1
    fi

    if orig_running; then
        log daemon "precheck failed: another tailscaled is running"
        daemon_err_set conflict
        return 1
    fi
    if ! daemon_running && tun_exists; then
        log daemon "precheck failed: $BIFROST_TUN exists without bifrostd"
        daemon_err_set conflict
        return 1
    fi

    if ! mkdir -p "$BIFROST_STATE" 2>/dev/null || [ ! -d "$BIFROST_STATE" ] || [ ! -w "$BIFROST_STATE" ]; then
        log daemon "precheck failed: state directory not writable"
        daemon_err_set state_not_writable
        return 1
    fi
    _dpc_probe="$BIFROST_STATE/.write_test.$$"
    if ! (: >"$_dpc_probe") 2>/dev/null; then
        log daemon "precheck failed: cannot write in state directory"
        daemon_err_set state_not_writable
        return 1
    fi
    rm -f "$_dpc_probe"
    return 0
}

# daemon_prefs_drifted <prefs json>: print space-separated set flags for any
# drifted fixed prefs (PLAN 4.3): CorpDNS, NetfilterMode, NoSNAT, ShieldsUp.
daemon_prefs_drifted() {
    printf '%s\n' "$1" | jq -r '
        [
            (if .CorpDNS == true then "--accept-dns=false" else empty end),
            (if (.NetfilterMode != null and .NetfilterMode != 0 and .NetfilterMode != "off") then "--netfilter-mode=off" else empty end),
            (if .NoSNAT == true then "--snat-subnet-routes=true" else empty end),
            (if .ShieldsUp == true then "--shields-up=false" else empty end)
        ] | join(" ")
    ' 2>/dev/null
}

# Sync ControlURL from prefs JSON to state dir if not yet recorded.
daemon_sync_control_from_prefs() {
    [ -f "$BIFROST_STATE/control_url" ] && return 0
    _sp_url=$(printf '%s\n' "$1" | jq -r '.ControlURL // empty' 2>/dev/null)
    if [ -n "$_sp_url" ] && ! daemon_is_official_url "$_sp_url" && valid_login_server "$_sp_url"; then
        daemon_set_control_server "$_sp_url" || true
    fi
}

# daemon_fix_prefs: check fixed prefs (PLAN 4.3) and repair any drift via set.
daemon_fix_prefs() {
    _df_json=$(prefs_json) || return 1
    daemon_sync_control_from_prefs "$_df_json"
    _df_flags=$(daemon_prefs_drifted "$_df_json") || {
        fail cli_failed
        return 1
    }
    if [ -n "$_df_flags" ]; then
        log daemon "fixing drifted prefs: $_df_flags"
        # shellcheck disable=SC2086
        ts_cli set $_df_flags >/dev/null 2>&1
        _df_rc=$?
        if [ "$_df_rc" -eq 124 ]; then
            fail timeout
            return 1
        fi
        if [ "$_df_rc" -ne 0 ]; then
            fail cli_failed
            return 1
        fi
    fi
    return 0
}

daemon_watchdog_register() {
    cru a bifrost_watchdog "$BIFROST_WATCHDOG_CRON sh $BIFROST_SCRIPTS/bifrost_config.sh local watchdog" >/dev/null 2>&1
}

daemon_watchdog_remove() {
    cru d bifrost_watchdog >/dev/null 2>&1
}

daemon_trim_file() {
    _dt_f=$1
    [ -f "$_dt_f" ] || return 0
    _dt_sz=$(file_size "$_dt_f" 2>/dev/null) || return 0
    if [ "$_dt_sz" -gt "$BIFROST_LOG_MAX_BYTES" ]; then
        _dt_tmp="$_dt_f.trim.$$"
        if tail -c "$BIFROST_LOG_KEEP_BYTES" "$_dt_f" >"$_dt_tmp" 2>/dev/null; then
            cat "$_dt_tmp" >"$_dt_f" 2>/dev/null || true
        fi
        rm -f "$_dt_tmp"
    fi
}

daemon_trim_logs() {
    daemon_trim_file "$BIFROST_DLOG"
    daemon_trim_file "$BIFROST_LOG"
}

# daemon_start: full startup sequence (PLAN 6.2). Caller holds state lock.
daemon_start() {
    daemon_phase precheck 15
    daemon_precheck || return 1

    mkdir -p "$BIFROST_RUN" "$BIFROST_TS_LOGS" "$BIFROST_SOCK_DIR" "$BIFROST_UPLOAD" || {
        daemon_err_set internal
        return 1
    }
    chmod 700 "$BIFROST_RUN" "$BIFROST_TS_LOGS" "$BIFROST_SOCK_DIR" 2>/dev/null || true
    chmod 700 "$BIFROST_STATE" 2>/dev/null || true

    if ! daemon_running; then
        daemon_phase starting 35
        rm -f "$BIFROST_SOCK"
        _da_port=$(cfg bifrost_port)
        set -- \
            "--statedir=$BIFROST_STATE" \
            "--socket=$BIFROST_SOCK" \
            "--tun=$BIFROST_TUN" \
            "--port=$_da_port"
        if daemon_should_disable_logs; then
            set -- "$@" --no-logs-no-support
        fi
        log daemon "starting bifrostd on port $_da_port"
        TS_LOGS_DIR="$BIFROST_TS_LOGS" \
            nohup "$BIFROST_CORE" "$@" </dev/null >>"$BIFROST_DLOG" 2>&1 &
        _da_pid=$!
        printf '%s\n' "$_da_pid" | atomic_write "$BIFROST_PIDFILE" 644

        daemon_phase waiting 55
        if ! daemon_wait_ready "$BIFROST_WAIT_READY"; then
            log daemon "bifrostd failed to become ready"
            kill -KILL "$_da_pid" 2>/dev/null || true
            wait "$_da_pid" 2>/dev/null || true
            rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
            daemon_err_set start_failed
            return 1
        fi
    fi

    daemon_phase prefs 70
    if ! daemon_fix_prefs; then
        _da_err=${BIFROST_ERR:-cli_failed}
        log daemon "failed to enforce fixed prefs: $_da_err"
        daemon_err_set "$_da_err"
        return 1
    fi

    daemon_phase firewall 85
    if ! fw_apply; then
        _da_err=${BIFROST_ERR:-fw_failed}
        log daemon "fw_apply failed: $_da_err"
        daemon_err_set "$_da_err"
        return 1
    fi

    daemon_phase dns 95
    if ! dns_apply; then
        log daemon "dns_apply skipped during start: ${BIFROST_ERR:-unknown}"
        BIFROST_ERR=""
    fi

    daemon_watchdog_register || log daemon "cru register failed"
    daemon_err_clear
    status_refresh || true
    log daemon "bifrostd started"
    return 0
}

# daemon_stop: full stop sequence (PLAN 6.3). Succeeds when nothing runs.
daemon_stop() {
    daemon_watchdog_remove || true
    fw_clear || log daemon "fw_clear failed during stop"
    dns_clear || log daemon "dns_clear failed during stop"

    daemon_phase stopping 40
    _ds_pid=$(daemon_pid 2>/dev/null)
    if [ -n "$_ds_pid" ]; then
        log daemon "stopping bifrostd (pid $_ds_pid)"
        kill -TERM "$_ds_pid" 2>/dev/null || true
        _ds_i=0
        while [ "$_ds_i" -lt "$BIFROST_STOP_TIMEOUT" ]; do
            daemon_pid_alive "$_ds_pid" || break
            sleep 1
            _ds_i=$((_ds_i + 1))
        done
        if daemon_pid_alive "$_ds_pid"; then
            log daemon "bifrostd ignored TERM; sending KILL"
            kill -KILL "$_ds_pid" 2>/dev/null || true
            _ds_k=0
            while [ "$_ds_k" -lt 2 ]; do
                daemon_pid_alive "$_ds_pid" || break
                sleep 1
                _ds_k=$((_ds_k + 1))
            done
        fi
        wait "$_ds_pid" 2>/dev/null || true
    fi
    rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"

    daemon_phase cleanup 80
    if [ -x "$BIFROST_CORE" ] && ! orig_running; then
        run_timeout "$BIFROST_CLEANUP_TIMEOUT" "$BIFROST_CORE" --cleanup >/dev/null 2>&1 || \
            log daemon "bifrostd --cleanup exited non-zero"
    fi

    BIFROST_ERR=""
    status_refresh || true
    log daemon "bifrostd stopped"
    return 0
}

daemon_restart() {
    daemon_stop && daemon_start
}

# Init.d hooks (called under state lock by bifrost_config.sh).
hook_start() {
    [ "$(cfg bifrost_enable)" = 1 ] || return 0
    daemon_running && return 0
    daemon_start
}

hook_stop() {
    daemon_stop
}

hook_start_nat() {
    daemon_running || return 0
    fw_apply
}

# watchdog_run: 6-point health check (PLAN 6.5). Called under state lock (wait 0).
watchdog_run() {
    daemon_trim_logs
    [ "$(cfg bifrost_enable)" = 1 ] || return 0

    if [ -f "$BIFROST_DAEMON_ERR" ] && [ "$(cat "$BIFROST_DAEMON_ERR" 2>/dev/null)" = watchdog_gave_up ]; then
        fail watchdog_gave_up
        return 1
    fi

    _wd_healthy=1
    if ! daemon_running; then
        log watchdog "daemon process missing"
        _wd_healthy=0
    elif ! ts_cli status --json >/dev/null 2>&1; then
        log watchdog "daemon status unresponsive"
        _wd_healthy=0
    fi

    if [ "$_wd_healthy" = 0 ]; then
        _wd_rf="$BIFROST_RUN/watchdog.restarts"
        _wd_now=$(now)
        _wd_cut=$((_wd_now - BIFROST_WATCHDOG_WINDOW))
        _wd_kept=""
        _wd_cnt=0
        if [ -f "$_wd_rf" ]; then
            while IFS= read -r _wd_ts; do
                valid_uint "$_wd_ts" || continue
                if [ "$_wd_ts" -ge "$_wd_cut" ]; then
                    _wd_cnt=$((_wd_cnt + 1))
                    if [ -n "$_wd_kept" ]; then
                        _wd_kept="$_wd_kept
$_wd_ts"
                    else
                        _wd_kept="$_wd_ts"
                    fi
                fi
            done <"$_wd_rf"
        fi

        if [ "$_wd_cnt" -ge "$BIFROST_WATCHDOG_MAX" ]; then
            mkdir -p "$BIFROST_RUN" 2>/dev/null
            if [ -n "$_wd_kept" ]; then
                printf '%s\n' "$_wd_kept" | atomic_write "$_wd_rf" 644
            fi
            log watchdog "restart limit reached ($_wd_cnt/$BIFROST_WATCHDOG_MAX); giving up"
            daemon_err_set watchdog_gave_up
            status_refresh || true
            return 1
        fi

        mkdir -p "$BIFROST_RUN" 2>/dev/null
        if [ -n "$_wd_kept" ]; then
            printf '%s\n%s\n' "$_wd_kept" "$_wd_now" | atomic_write "$_wd_rf" 644
        else
            printf '%s\n' "$_wd_now" | atomic_write "$_wd_rf" 644
        fi
        log watchdog "restarting daemon ($((_wd_cnt + 1))/$BIFROST_WATCHDOG_MAX)"
        daemon_restart
        return $?
    fi

    _wd_changed=0
    _wd_pjson=$(prefs_json) && {
        _wd_drift=$(daemon_prefs_drifted "$_wd_pjson")
        if [ -n "$_wd_drift" ]; then
            daemon_fix_prefs && _wd_changed=1
        fi
    }

    if ! fw_check; then
        log watchdog "fw_check failed; reapplying firewall"
        fw_apply && _wd_changed=1
    fi

    if ! dns_check; then
        log watchdog "dns_check failed; reapplying dns"
        dns_apply && _wd_changed=1
    fi

    [ "$_wd_changed" = 1 ] && { status_refresh || true; }
    return 0
}

# Page actions for daemon control.
act_enable() { job_start daemon start; }
act_disable() { job_start daemon stop; }
act_purge() { job_start daemon purge; }

# job_daemon <start|stop|restart|purge>: background job body (contract 6.2).
job_daemon() {
    _jdm_act=${1:-}
    case "$_jdm_act" in
        start)
            job_data daemon '{"action":"start"}'
            cfg_set bifrost_enable 1 || return 1
            rm -f "$BIFROST_RUN/watchdog.restarts"
            _BIFROST_DAEMON_JOB=daemon
            daemon_start
            _jdm_rc=$?
            _BIFROST_DAEMON_JOB=""
            return "$_jdm_rc"
            ;;
        stop)
            job_data daemon '{"action":"stop"}'
            cfg_set bifrost_enable 0 || return 1
            _BIFROST_DAEMON_JOB=daemon
            daemon_stop
            _jdm_rc=$?
            _BIFROST_DAEMON_JOB=""
            daemon_err_clear
            rm -f "$BIFROST_RUN/watchdog.restarts"
            status_refresh || true
            return "$_jdm_rc"
            ;;
        restart)
            job_data daemon '{"action":"restart"}'
            rm -f "$BIFROST_RUN/watchdog.restarts"
            _BIFROST_DAEMON_JOB=daemon
            daemon_restart
            _jdm_rc=$?
            _BIFROST_DAEMON_JOB=""
            return "$_jdm_rc"
            ;;
        purge)
            job_data daemon '{"action":"purge"}'
            job_phase daemon purge 10
            if daemon_running; then
                log daemon "purge: logging out"
                ts_cli logout >/dev/null 2>&1 || log daemon "purge: logout failed; continuing"
            fi
            _BIFROST_DAEMON_JOB=daemon
            daemon_stop
            _BIFROST_DAEMON_JOB=""
            job_phase daemon purge 85
            if [ -n "$BIFROST_STATE" ] && [ -d "$BIFROST_STATE" ]; then
                rm -rf "${BIFROST_STATE:?}"/* "${BIFROST_STATE:?}"/.[!.]* "${BIFROST_STATE:?}"/..?* 2>/dev/null || true
            fi
            cfg_set bifrost_enable 0 || return 1
            daemon_err_clear
            rm -f "$BIFROST_RUN/watchdog.restarts"
            status_refresh || true
            log daemon "purge complete"
            return 0
            ;;
        *)
            fail invalid_param
            return 1
            ;;
    esac
}
