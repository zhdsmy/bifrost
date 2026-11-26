# shellcheck shell=sh
# Daemon lifecycle, hooks, watchdog, and daemon job.
# Contract: docs/dev/contract.md, sections 4, 5, 6.1, 6.2, 7.
# Load order: env.sh, validate.sh, common.sh, daemon.sh.

: "${BIFROST_WAIT_READY:=15}"
: "${BIFROST_WAIT_NETMAP:=10}"
: "${BIFROST_STOP_TIMEOUT:=10}"
: "${BIFROST_CLEANUP_TIMEOUT:=15}"
: "${BIFROST_LOCK_WAIT:=30}"
: "${BIFROST_WATCHDOG_NAME:=bifrost_watchdog}"
: "${BIFROST_WATCHDOG_CRON:=*/2 * * * *}"
: "${BIFROST_WATCHDOG_WINDOW:=1800}"
: "${BIFROST_WATCHDOG_MAX:=3}"
: "${BIFROST_LOG_MAX_BYTES:=1048576}"
: "${BIFROST_LOG_KEEP_BYTES:=204800}"
: "${BIFROST_CRASH_KEEP:=3}"
: "${BIFROST_CRASH_LINES:=50}"

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

# Remove an orphaned authkey file whenever no login job is active.
daemon_clean_stale_authkey() {
    [ -f "$BIFROST_RUN/authkey" ] || return 0
    job_running login || rm -f "$BIFROST_RUN/authkey"
}

# daemon_clear_state_dir: remove all contents inside $BIFROST_STATE.
daemon_clear_state_dir() {
    [ -n "$BIFROST_STATE" ] && [ -d "$BIFROST_STATE" ] || return 0
    for _dcl_item in "$BIFROST_STATE"/* "$BIFROST_STATE"/.[!.]* "$BIFROST_STATE"/..?*; do
        [ -e "$_dcl_item" ] || [ -L "$_dcl_item" ] || continue
        rm -rf "$_dcl_item" || return 1
    done
    return 0
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
        return $?
    fi
    valid_login_server "$1" || {
        fail bad_server
        return 1
    }
    mkdir -p "$BIFROST_STATE" 2>/dev/null || return 1
    [ ! -d "$_dsc_f" ] || { fail state_not_writable; return 1; }
    printf '%s\n' "$1" | atomic_write "$_dsc_f" 644
}

# daemon_should_disable_logs: 0 when --no-logs-no-support must be passed.
daemon_should_disable_logs() {
    [ "$(cfg bifrost_no_logs)" = 1 ] && return 0
    ! daemon_is_official_url "$(daemon_control_server)"
}

# daemon_running_has_nologs: 0 when the live bifrostd cmdline includes --no-logs-no-support.
daemon_running_has_nologs() {
    _drn_pid=$(daemon_pid 2>/dev/null) || return 1
    [ -r "/proc/$_drn_pid/cmdline" ] || return 1
    tr '\000' '\n' <"/proc/$_drn_pid/cmdline" 2>/dev/null | grep -Fqx -- '--no-logs-no-support'
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

# Match the daemon's exact core and socket arguments. Other users of the
# binary (CLI helpers, version probes and cleanup) must never receive signals.
daemon_owns_pid() {
    [ -r "/proc/$1/cmdline" ] || return 1
    _dop_args=$(tr '\000' '\n' <"/proc/$1/cmdline" 2>/dev/null) || return 1
    printf '%s\n' "$_dop_args" | awk -v core="$BIFROST_CORE" -v state="--statedir=$BIFROST_STATE" -v sock="--socket=$BIFROST_SOCK" '
        NR == 1 { binary = ($0 == core); shell = ($0 ~ /(^|\/)sh$/) }
        NR == 2 && shell && $0 == core { binary = 1 }
        $0 == state { has_state = 1 }
        $0 == sock { has_sock = 1 }
        END { exit !(binary && has_state && has_sock) }
    '
}

daemon_find_pid() {
    _dfp_pid=$(daemon_pid) && daemon_owns_pid "$_dfp_pid" && {
        echo "$_dfp_pid"
        return 0
    }
    for _dfp_file in /proc/[0-9]*/stat; do
        # Kernel threads and zombies have no command line. Skip zombies with
        # shell builtins before spawning anything in a potentially large /proc.
        IFS= read -r _dfp_stat <"$_dfp_file" || continue
        case ${_dfp_stat##*) } in Z*) continue ;; esac
        _dfp_pid=${_dfp_stat%% *}
        if daemon_owns_pid "$_dfp_pid"; then
            echo "$_dfp_pid"
            return 0
        fi
    done
    return 1
}

# daemon_read_prefs: read "tailscale debug prefs" into _BIFROST_PREFS_JSON
# without a subshell so BIFROST_ERR is preserved for in-shell callers.
daemon_read_prefs() {
    _BIFROST_PREFS_JSON=""
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
    _BIFROST_PREFS_JSON=$_pj_out
    return 0
}

# prefs_json: print "tailscale debug prefs" JSON, or fail not_running/timeout/cli_failed.
prefs_json() {
    daemon_read_prefs || return 1
    printf '%s\n' "$_BIFROST_PREFS_JSON"
}

# daemon_read_state: read BackendState into _BIFROST_BACKEND_STATE in-shell.
daemon_read_state() {
    _BIFROST_BACKEND_STATE=""
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
    _bs_st=$(printf '%s\n' "$_bs_out" | jq -er '.BackendState | strings | select(length > 0)' 2>/dev/null) || _bs_st=""
    if [ -z "$_bs_st" ]; then
        fail cli_failed
        return 1
    fi
    _BIFROST_BACKEND_STATE=$_bs_st
    return 0
}

# backend_state: print BackendState from "tailscale status --json", or fail.
backend_state() {
    daemon_read_state || return 1
    printf '%s\n' "$_BIFROST_BACKEND_STATE"
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

# daemon_wait_netmap: until its first network map, from control or the disk
# cache, the core reports NoState and status has no tailnet address, so
# fw_apply would leave out the rules that use it until the next watchdog run.
# Wait up to BIFROST_WAIT_NETMAP seconds, then go on without it.
daemon_wait_netmap() {
    _dwn_deadline=$(($(now) + BIFROST_WAIT_NETMAP))
    while :; do
        _dwn_rem=$((_dwn_deadline - $(now)))
        [ "$_dwn_rem" -lt 1 ] && _dwn_rem=1
        _dwn_state=$(ts_cli_t "$_dwn_rem" status --json --peers=false 2>/dev/null |
            jq -r '.BackendState // empty' 2>/dev/null)
        [ "$_dwn_state" = NoState ] || return 0
        if [ "$(now)" -ge "$_dwn_deadline" ]; then
            log daemon "no network map after $BIFROST_WAIT_NETMAP s; applying the firewall without the tailnet address"
            return 0
        fi
        sleep 1
    done
}

# daemon_precheck: verify core, tun device, no conflict, writable state dir.
daemon_precheck() {
    if ! core_version >/dev/null; then
        log daemon "precheck failed: core missing"
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
        daemon_set_control_server "$_sp_url" || { fail state_not_writable; return 1; }
    fi
}

# daemon_fix_prefs: check fixed prefs (PLAN 4.3) and repair any drift via set.
daemon_fix_prefs() {
    daemon_read_prefs || return 1
    daemon_sync_control_from_prefs "$_BIFROST_PREFS_JSON" || return 1
    _df_flags=$(daemon_prefs_drifted "$_BIFROST_PREFS_JSON") || {
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
    cru a "$BIFROST_WATCHDOG_NAME" "$BIFROST_WATCHDOG_CRON sh $BIFROST_SCRIPTS/bifrost_config.sh local watchdog" >/dev/null 2>&1
}

daemon_watchdog_remove() {
    cru d "$BIFROST_WATCHDOG_NAME" >/dev/null 2>&1
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

# Seconds since boot. Event lines use it to tell a boot from a WAN reconnect.
daemon_sys_up() {
    if read -r _dsu_up _ 2>/dev/null </proc/uptime; then
        echo "${_dsu_up%%.*}"
    else
        echo "?"
    fi
}

daemon_nat_age() {
    _dna_t=$(cat "$BIFROST_RUN/nat_start.last" 2>/dev/null)
    if valid_uint "$_dna_t"; then
        echo "last nat-start $(($(now) - _dna_t)) s ago"
    else
        echo "no nat-start since boot"
    fi
}

# Read bifrostd output on stdin. From the last start marker on, print whether
# Go panicked, the first panic or fatal error with the lines after it, and
# the last lines.
_daemon_crash_out() {
    awk -v n="$BIFROST_CRASH_LINES" '
        /^==== .* bifrost: starting bifrostd ====$/ { c = 0; pn = 0; next }
        {
            buf[c % n] = $0
            c++
            if (pn == 0 && $0 ~ /^(panic: |fatal error: )/) pn = 1
            if (pn > 0 && pn <= 40) { pbuf[pn] = $0; pn++ }
        }
        END {
            print "go_panic: " (pn > 0 ? "yes" : "no")
            print "== first panic or fatal error =="
            if (pn == 0) print "(none)"
            for (i = 1; i < pn; i++) print pbuf[i]
            print "== last " n " lines of bifrostd output =="
            for (i = (c > n ? c - n : 0); i < c; i++) print buf[i % n]
        }'
}

# daemon_crash_note: bifrostd is gone without a stop. Keep a redacted record
# in $BIFROST_CRASH_DIR (the newest $BIFROST_CRASH_KEEP) and report the exit
# in the system log. Never fails.
daemon_crash_note() {
    _dcn_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null)
    valid_uint "$_dcn_pid" || _dcn_pid=""
    _dcn_ran=unknown
    _dcn_t0=$(cat "$BIFROST_RUN/bifrostd.started" 2>/dev/null)
    if valid_uint "$_dcn_t0" && [ "$(now)" -ge "$_dcn_t0" ]; then
        _dcn_ran="$(($(now) - _dcn_t0)) s"
    fi
    _dcn_kern=$(dmesg 2>/dev/null | grep -E 'bifrostd|Out of memory' | tail -n 10)
    _dcn_oom=no
    if printf '%s\n' "$_dcn_kern" | grep -Eq "Kill(ed)? process ${_dcn_pid:-[0-9]+} \\(bifrostd\\)"; then
        _dcn_oom=yes
    fi
    _dcn_out=$(cat "$BIFROST_DLOG" 2>/dev/null | _daemon_crash_out)
    case "$_dcn_out" in "go_panic: yes"*) _dcn_panic=yes ;; *) _dcn_panic=no ;; esac

    _dcn_name=""
    if has_cmd redact && has_cmd _diag_collect_redact_hints && mkdir -p "$BIFROST_CRASH_DIR" 2>/dev/null; then
        chmod 700 "$BIFROST_CRASH_DIR" 2>/dev/null
        _dcn_name="crash-$(date '+%Y%m%d-%H%M%S').txt"
        {
            printf 'time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf 'pid: %s\n' "${_dcn_pid:-unknown}"
            printf 'run_time: %s\n' "$_dcn_ran"
            printf 'system_uptime: %s s\n' "$(daemon_sys_up)"
            printf 'oom_killed: %s\n' "$_dcn_oom"
            printf '== kernel log (bifrostd, out of memory) ==\n'
            printf '%s\n' "${_dcn_kern:-(none)}"
            printf '%s\n' "$_dcn_out"
        } | redact "$(_diag_collect_redact_hints "")" |
            atomic_write "$BIFROST_CRASH_DIR/$_dcn_name" 600 || _dcn_name=""
        # Names sort by time; drop the oldest.
        set -- "$BIFROST_CRASH_DIR"/crash-*.txt
        [ -e "$1" ] || set --
        while [ "$#" -gt "$BIFROST_CRASH_KEEP" ]; do
            rm -f "$1"
            shift
        done
    fi
    event watchdog "bifrostd exited (pid ${_dcn_pid:-unknown}, ran $_dcn_ran, oom killed: $_dcn_oom, go panic: $_dcn_panic); record: ${_dcn_name:-none}"
}

# Launch and read the active profile under the caller's state lock.
daemon_start_ready() {
    daemon_phase precheck 15
    daemon_watchdog_register || {
        daemon_err_set internal
        return 1
    }
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
        _dst_port=$(cfg bifrost_port)
        set -- \
            "--statedir=$BIFROST_STATE" \
            "--socket=$BIFROST_SOCK" \
            "--tun=$BIFROST_TUN" \
            "--port=$_dst_port"
        if daemon_should_disable_logs; then
            set -- "$@" --no-logs-no-support
        fi
        log daemon "starting bifrostd on port $_dst_port"
        # A crash record reads the output after the last marker only.
        printf '==== %s bifrost: starting bifrostd ====\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$BIFROST_DLOG" 2>/dev/null
        now >"$BIFROST_RUN/bifrostd.started" 2>/dev/null
        TS_LOGS_DIR="$BIFROST_TS_LOGS" \
            nohup "$BIFROST_CORE" "$@" </dev/null >>"$BIFROST_DLOG" 2>&1 &
        _dst_pid=$!
        printf '%s\n' "$_dst_pid" | atomic_write "$BIFROST_PIDFILE" 644

        daemon_phase waiting 55
        if ! daemon_wait_ready "$BIFROST_WAIT_READY"; then
            log daemon "bifrostd failed to become ready"
            kill -KILL "$_dst_pid" 2>/dev/null || true
            wait "$_dst_pid" 2>/dev/null || true
            rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
            daemon_err_set start_failed
            return 1
        fi
    fi

    daemon_phase prefs 70
    if ! daemon_fix_prefs; then
        _dst_err=${BIFROST_ERR:-cli_failed}
        log daemon "failed to enforce fixed prefs: $_dst_err"
        daemon_err_set "$_dst_err"
        status_refresh || true
        return 1
    fi
    login_restore_prefs || log daemon "could not restore saved prefs: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
}

daemon_start() {
    daemon_start_ready || return 1
    # An imported profile may reveal its control server only after startup.
    if daemon_should_disable_logs && ! daemon_running_has_nologs; then
        log daemon "restarting to disable logging for the active profile"
        daemon_stop_for_restart && daemon_start_ready || return 1
        daemon_running_has_nologs || { daemon_err_set start_failed; return 1; }
    fi
    daemon_phase firewall 85
    daemon_wait_netmap
    if ! fw_apply; then
        _dst_err=${BIFROST_ERR:-fw_failed}
        log daemon "fw_apply failed: $_dst_err"
        daemon_err_set "$_dst_err"
        status_refresh || true
        return 1
    fi

    daemon_phase dns 95
    if ! dns_apply; then
        log daemon "dns_apply during start failed: ${BIFROST_ERR:-internal}"
        daemon_err_set "${BIFROST_ERR:-internal}"
    else
        daemon_err_clear
    fi
    status_refresh || true
    log daemon "bifrostd started"
    return 0
}

# Stop under the state lock. Attempt both network clears and finish stopping
# even if one fails. The first clear error survives later status refreshes.
daemon_stop() {
    _dsp_clear_err=""
    BIFROST_ERR=""
    if ! fw_clear; then
        _dsp_clear_err=${BIFROST_ERR:-fw_failed}
        log daemon "fw_clear failed during stop: $_dsp_clear_err"
    fi
    BIFROST_ERR=""
    if ! dns_clear; then
        log daemon "dns_clear failed during stop: ${BIFROST_ERR:-internal}"
        [ -n "$_dsp_clear_err" ] || _dsp_clear_err=${BIFROST_ERR:-internal}
    fi

    daemon_phase stopping 40
    _dsp_pid=$(daemon_find_pid 2>/dev/null)
    if [ -n "$_dsp_pid" ]; then
        log daemon "stopping bifrostd (pid $_dsp_pid)"
        kill -TERM "$_dsp_pid" 2>/dev/null || true
        _dsp_i=0
        while daemon_owns_pid "$_dsp_pid" && [ "$_dsp_i" -lt "$BIFROST_STOP_TIMEOUT" ]; do
            sleep 1
            _dsp_i=$((_dsp_i + 1))
        done
        if daemon_owns_pid "$_dsp_pid"; then
            log daemon "bifrostd ignored TERM; sending KILL"
            kill -KILL "$_dsp_pid" 2>/dev/null || true
            _dsp_i=0
            while daemon_owns_pid "$_dsp_pid" && [ "$_dsp_i" -lt "$BIFROST_STOP_TIMEOUT" ]; do
                sleep 1
                _dsp_i=$((_dsp_i + 1))
            done
        fi
        if _dsp_live=$(daemon_find_pid 2>/dev/null); then
            log daemon "bifrostd still running; restoring network settings"
            printf '%s\n' "$_dsp_live" | atomic_write "$BIFROST_PIDFILE" 644 || log daemon "could not restore pidfile"
            fw_apply || log daemon "could not restore firewall after failed stop"
            dns_apply || log daemon "could not restore DNS after failed stop"
            fail internal
            return 1
        fi
        wait "$_dsp_pid" 2>/dev/null || true
    fi

    rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
    daemon_clean_stale_authkey

    daemon_phase cleanup 80
    if [ -x "$BIFROST_CORE" ] && ! orig_running; then
        run_timeout "$BIFROST_CLEANUP_TIMEOUT" "$BIFROST_CORE" --cleanup >/dev/null 2>&1 ||
            log daemon "bifrostd --cleanup exited non-zero"
    fi

    BIFROST_ERR=""
    status_refresh || true
    log daemon "bifrostd stopped"
    [ -z "$_dsp_clear_err" ] || { fail "$_dsp_clear_err"; return 1; }
    return 0
}

daemon_stop_for_restart() {
    daemon_stop && return 0
    if daemon_find_pid >/dev/null; then return 1; fi
    log daemon "restarting after network cleanup error: ${BIFROST_ERR:-internal}"
    BIFROST_ERR=""
    return 0
}

daemon_restart() {
    daemon_stop_for_restart && daemon_start
}

# Init.d hooks (called under state lock by bifrost_config.sh).
hook_start() {
    # Restore the core first. The current enable setting controls startup
    # even if the daemon was running when the update was interrupted.
    if has_cmd core_recover && ! core_recover stopped; then
        log daemon "core recovery failed: ${BIFROST_ERR:-internal}"
        BIFROST_ERR=""
    fi
    if has_cmd migrate_recover; then migrate_recover || return 1; fi
    [ "$(cfg bifrost_enable)" = 1 ] || return 0
    if daemon_running; then
        event hook "start: bifrostd already running (pid $(daemon_pid)); not restarted"
        daemon_watchdog_register
        return $?
    fi
    if daemon_start; then
        event hook "start: bifrostd started (system up $(daemon_sys_up) s)"
        return 0
    fi
    event hook "start: bifrostd failed to start (${BIFROST_ERR:-internal})"
    return 1
}

# Remove supervision only once the daemon has stopped. A network-clear
# failure still stops the service, but remains visible to the calling job.
daemon_deactivate() {
    _dda_err=""
    if ! daemon_stop; then
        _dda_err=${BIFROST_ERR:-internal}
        daemon_find_pid >/dev/null 2>&1 && { fail "$_dda_err"; return 1; }
    fi
    daemon_unschedule "$1" || { fail "${_dda_err:-internal}"; return 1; }
    if [ -n "$_dda_err" ]; then
        status_refresh || true
        fail "$_dda_err"
        return 1
    fi
    return 0
}

daemon_unschedule() {
    if [ "$1" = disable ]; then cfg_set bifrost_enable 0 || return 1; fi
    daemon_watchdog_remove
}

hook_stop() {
    _hs_pid=$(daemon_pid)
    if daemon_deactivate hook; then
        [ -z "$_hs_pid" ] || event hook "stop: bifrostd stopped (pid $_hs_pid)"
        return 0
    fi
    event hook "stop: failed (${BIFROST_ERR:-internal})"
    return 1
}

# The dispatcher records the time of every nat-start before it takes the lock.
hook_start_nat() {
    if ! daemon_running; then
        [ "$(cfg bifrost_enable)" != 1 ] || event hook "nat-start: bifrostd not running; no rules applied"
        return 0
    fi
    _hn_t0=$(now)
    if fw_apply; then
        event hook "nat-start: firewall re-applied in $(($(now) - _hn_t0)) s"
        return 0
    fi
    event hook "nat-start: firewall apply failed (${BIFROST_ERR:-fw_failed}) after $(($(now) - _hn_t0)) s"
    return 1
}

# watchdog_run: 6-point health check (PLAN 6.5). Called under state lock (wait 0).
watchdog_run() {
    daemon_trim_logs
    daemon_clean_stale_authkey
    [ "$(cfg bifrost_enable)" = 1 ] || return 0

    _wd_error=$(cat "$BIFROST_DAEMON_ERR" 2>/dev/null)
    if [ "$_wd_error" = watchdog_gave_up ]; then
        fail watchdog_gave_up
        return 1
    fi

    _wd_healthy=1
    if ! daemon_running; then
        daemon_crash_note
        _wd_healthy=0
    elif ! ts_cli status --json >/dev/null 2>&1; then
        event watchdog "bifrostd unresponsive (pid $(daemon_pid)): no status within 10 s"
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
            event watchdog "restart limit reached ($_wd_cnt in $((BIFROST_WATCHDOG_WINDOW / 60)) min); gave up until the user acts"
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
        _wd_n="$((_wd_cnt + 1))/$BIFROST_WATCHDOG_MAX"
        log watchdog "restarting daemon ($_wd_n)"
        if daemon_restart; then
            event watchdog "restart $_wd_n ok"
            return 0
        fi
        event watchdog "restart $_wd_n failed (${BIFROST_ERR:-internal})"
        return 1
    fi

    _wd_changed=0
    _wd_problem=""
    if ! daemon_fix_prefs; then
        _wd_problem=${BIFROST_ERR:-cli_failed}
    elif daemon_should_disable_logs && ! daemon_running_has_nologs; then
        log watchdog "restarting to enforce the active profile logging setting"
        daemon_restart
        return $?
    elif [ -n "$_df_flags" ]; then
        _wd_changed=1
    fi
    # One event when rules go missing and one when a failed apply recovers;
    # repeated retries of a failing apply only go to bifrost.log.
    if [ "$_wd_error" = fw_failed ]; then
        if fw_apply; then
            event fw "firewall re-applied after an earlier failure"
        else
            log fw "firewall re-apply still failing"
            _wd_problem=${_wd_problem:-fw_failed}
        fi
        _wd_changed=1
    elif ! fw_check; then
        _wd_fw="firewall rules missing ($(fw_why)); $(daemon_nat_age)"
        if fw_apply; then
            event fw "$_wd_fw; re-applied"
        else
            event fw "$_wd_fw; re-apply failed"
            _wd_problem=${_wd_problem:-fw_failed}
        fi
        _wd_changed=1
    fi
    # dns_check reports stale files. A policy error can still exist while
    # the file is correct, so replay dns_apply before clearing a prior error.
    if [ -n "$_wd_error" ] || ! dns_check; then
        dns_apply || _wd_problem=${_wd_problem:-${BIFROST_ERR:-internal}}
        _wd_changed=1
    fi
    if [ -n "$_wd_problem" ]; then
        daemon_err_set "$_wd_problem"
        _wd_changed=1
    else
        case "$_wd_error" in
            internal) daemon_watchdog_register && daemon_err_clear ;;
            state_not_writable) daemon_precheck && daemon_err_clear ;;
            fw_failed | cli_failed | "timeout" | not_running | no_conf_dir | no_magicdns)
                daemon_err_clear ;;
        esac
    fi

    [ "$_wd_changed" = 1 ] && { status_refresh || true; }
    return 0
}

# Page actions for daemon control.
act_enable() { job_start daemon start; }
act_disable() { job_start daemon stop; }
act_purge() { job_start daemon purge; }

# job_daemon <start|stop|restart|purge>: background job body (contract 6.2).
# Each action leaves one line in the system log.
job_daemon() {
    _job_daemon "$@"
    _jdm_rc=$?
    case "${1:-}" in
        start) _jdm_what=enable ;;
        stop) _jdm_what=disable ;;
        restart | purge) _jdm_what=$1 ;;
        *) return "$_jdm_rc" ;;
    esac
    if [ "$_jdm_rc" -eq 0 ]; then
        event page "$_jdm_what: done"
    else
        event page "$_jdm_what: failed (${BIFROST_ERR:-internal})"
    fi
    return "$_jdm_rc"
}

_job_daemon() {
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
            # Refused because another tailscaled owns the interface: do not
            # leave Bifrost enabled for the next boot or the watchdog.
            if [ "$_jdm_rc" -ne 0 ] && [ "${BIFROST_ERR:-}" = conflict ]; then
                daemon_unschedule disable || true
                daemon_err_clear
                fail conflict
            fi
            return "$_jdm_rc"
            ;;
        stop)
            job_data daemon '{"action":"stop"}'
            _BIFROST_DAEMON_JOB=daemon
            daemon_deactivate disable
            _jdm_rc=$?
            _BIFROST_DAEMON_JOB=""
            [ "$_jdm_rc" -eq 0 ] || return "$_jdm_rc"
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
            if has_cmd migrate_recover; then
                migrate_recover || return 1
                [ ! -d "$_BIFROST_MIGRATION" ] || { fail state_not_writable; return 1; }
            fi
            if daemon_running; then
                log daemon "purge: logging out"
                ts_cli logout >/dev/null 2>&1 || log daemon "purge: logout failed; continuing"
            fi
            _BIFROST_DAEMON_JOB=daemon
            daemon_deactivate disable
            _jdm_rc=$?
            _BIFROST_DAEMON_JOB=""
            [ "$_jdm_rc" -eq 0 ] || return "$_jdm_rc"
            job_phase daemon purge 85
            if ! daemon_clear_state_dir || ! rm -rf "${BIFROST_STATE}".bak.*; then
                fail state_not_writable
                return 1
            fi
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
