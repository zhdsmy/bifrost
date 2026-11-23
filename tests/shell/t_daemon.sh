#!/bin/sh
# Tests for plugin/bifrost/lib/daemon.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

# Stubs for P3 functions (not on this branch); record call order in $MOCK_STATE/p3.log.
p3_stubs() {
    STUB_FW_APPLY_RC=0
    STUB_FW_CHECK_RC=0
    STUB_DNS_APPLY_RC=0
    STUB_DNS_CHECK_RC=0
    fw_apply() {
        echo "fw_apply" >>"$MOCK_STATE/p3.log"
        [ "$STUB_FW_APPLY_RC" = 0 ] || { fail fw_failed; return 1; }
    }
    fw_clear() {
        echo "fw_clear" >>"$MOCK_STATE/p3.log"
        return 0
    }
    fw_check() {
        echo "fw_check" >>"$MOCK_STATE/p3.log"
        return "$STUB_FW_CHECK_RC"
    }
    dns_apply() {
        echo "dns_apply" >>"$MOCK_STATE/p3.log"
        [ "$STUB_DNS_APPLY_RC" = 0 ] || { fail no_magicdns; return 1; }
    }
    dns_clear() {
        echo "dns_clear" >>"$MOCK_STATE/p3.log"
        return 0
    }
    dns_check() {
        echo "dns_check" >>"$MOCK_STATE/p3.log"
        return "$STUB_DNS_CHECK_RC"
    }
    status_refresh() {
        echo "status_refresh" >>"$MOCK_STATE/p3.log"
        return 0
    }
}

fresh() {
    t_setup
    t_load
    p3_stubs
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=2
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

# --- 1. Pre-check failures ---

fresh
rm -f "$BIFROST_CORE"
no precheck-core-missing daemon_start
eq precheck-core-err core_missing "$BIFROST_ERR"
eq precheck-core-file core_missing "$(cat "$BIFROST_DAEMON_ERR")"

fresh
rm -f "$BIFROST_TUN_DEV"
no precheck-no-tun daemon_start
eq precheck-tun-err no_tun "$BIFROST_ERR"
eq precheck-tun-file no_tun "$(cat "$BIFROST_DAEMON_ERR")"

fresh
pidof_set tailscaled 9999
no precheck-orig-running daemon_start
eq precheck-orig-err conflict "$BIFROST_ERR"
eq precheck-orig-file conflict "$(cat "$BIFROST_DAEMON_ERR")"

fresh
ip_out "link show tailscale0" "5: tailscale0: <POINTOPOINT,UP> mtu 1280"
no precheck-tun-exists daemon_start
eq precheck-tun-exists-err conflict "$BIFROST_ERR"
eq precheck-tun-exists-file conflict "$(cat "$BIFROST_DAEMON_ERR")"

fresh
rm -rf "$BIFROST_STATE"
: >"$BIFROST_STATE"
no precheck-state-ro daemon_start
eq precheck-state-err state_not_writable "$BIFROST_ERR"
eq precheck-state-file state_not_writable "$(cat "$BIFROST_DAEMON_ERR")"

# --- 2. Immediate daemon startup failure ---

fresh
: >"$MOCK_STATE/daemon.fail"
no start-immediate-fail daemon_start
eq start-fail-err start_failed "$BIFROST_ERR"
eq start-fail-file start_failed "$(cat "$BIFROST_DAEMON_ERR")"
no start-fail-not-running daemon_running

# --- 3. Normal startup, args, order, prefs repair, no-logs ---

fresh
mkdir -p "$BIFROST_RUN"
echo core_missing >"$BIFROST_DAEMON_ERR"
dbus_seed bifrost_port=51820 bifrost_no_logs=1
ts_out_file debug-prefs "$FIX/prefs_drifted.json"
ok start-ok daemon_start
ok start-running daemon_running
no start-clears-err [ -f "$BIFROST_DAEMON_ERR" ]
# shellcheck disable=SC2012
eq start-run-mode "drwx------" "$(ls -ld "$BIFROST_RUN" | cut -c1-10)"
dargs=$(cat "$MOCK_STATE/daemon.args")
has start-arg-statedir "--statedir=$BIFROST_STATE" "$dargs"
has start-arg-sock "--socket=$BIFROST_SOCK" "$dargs"
# shellcheck disable=SC2153
has start-arg-tun "--tun=$BIFROST_TUN" "$dargs"
has start-arg-port "--port=51820" "$dargs"
has start-arg-nologs "--no-logs-no-support" "$dargs"
eq start-env-logs "TS_LOGS_DIR=$BIFROST_TS_LOGS" "$(cat "$MOCK_STATE/daemon.env")"
# Fixed prefs repaired via tailscale set
tlog=$(ts_log)
has start-fix-dns "--accept-dns=false" "$tlog"
has start-fix-nf "--netfilter-mode=off" "$tlog"
has start-fix-snat "--snat-subnet-routes=true" "$tlog"
has start-fix-shields "--shields-up=false" "$tlog"
# P3 calls in order: fw_apply -> dns_apply -> status_refresh
eq start-p3-order "fw_apply
dns_apply
status_refresh" "$(cat "$MOCK_STATE/p3.log")"
# Watchdog registered via cru a
has start-cru-a "CRU a bifrost_watchdog" "$(cat "$MOCK_STATE/cru.log")"
has start-cru-entry "local watchdog #bifrost_watchdog#" "$(cat "$MOCK_STATE/cru.txt")"
daemon_stop

# no_logs=0 with official server omits --no-logs-no-support
fresh
dbus_seed bifrost_no_logs=0
ok start-logs-on daemon_start
dargs=$(cat "$MOCK_STATE/daemon.args")
case "$dargs" in
    *--no-logs-no-support*) no start-no-nologs-flag true ;;
    *) ok start-no-nologs-flag true ;;
esac
daemon_stop

# no_logs=0 with non-official server STILL forces --no-logs-no-support
fresh
dbus_seed bifrost_no_logs=0
ok set-custom-srv daemon_set_control_server "https://headscale.example.com"
ok start-custom-nologs daemon_start
has start-custom-forces-nologs "--no-logs-no-support" "$(cat "$MOCK_STATE/daemon.args")"
daemon_stop

# fw_apply failure fails daemon_start and sets $BIFROST_DAEMON_ERR
fresh
STUB_FW_APPLY_RC=1
no start-fw-fail daemon_start
eq start-fw-err fw_failed "$BIFROST_ERR"
eq start-fw-errfile fw_failed "$(cat "$BIFROST_DAEMON_ERR")"
daemon_stop

# --- 4. Stop: normal, idempotent, TERM ignored -> KILL ---

fresh
ok stop-when-stopped daemon_stop
ok start-for-stop daemon_start
: >"$MOCK_STATE/p3.log"
: >"$MOCK_STATE/cru.log"
: >"$MOCK_STATE/daemon.log"
ok stop-running daemon_stop
no stop-not-running daemon_running
has stop-cru-d "CRU d bifrost_watchdog" "$(cat "$MOCK_STATE/cru.log")"
has stop-cleanup "cleanup" "$(cat "$MOCK_STATE/daemon.log")"
eq stop-p3-order "fw_clear
dns_clear
status_refresh" "$(cat "$MOCK_STATE/p3.log")"

# TERM ignored -> KILL after BIFROST_STOP_TIMEOUT
fresh
BIFROST_STOP_TIMEOUT=1
: >"$MOCK_STATE/daemon.ignore_term"
ok start-ignore-term daemon_start
pid_before=$(daemon_pid)
ok stop-ignore-term daemon_stop
no stop-kill-dead kill -0 "$pid_before" 2>/dev/null
has stop-kill-logged "sending KILL" "$(cat "$BIFROST_LOG")"
has stop-kill-cleanup "cleanup" "$(cat "$MOCK_STATE/daemon.log")"

# daemon_stop skips --cleanup when orig_running is true
fresh
pidof_set tailscaled 5555
: >"$MOCK_STATE/daemon.log"
ok stop-skip-cleanup-orig daemon_stop
no stop-no-cleanup-orig grep -q cleanup "$MOCK_STATE/daemon.log"

# --- 5. daemon_restart, prefs_json, backend_state, daemon_wait_ready ---

fresh
no prefs-when-stopped prefs_json >/dev/null
eq prefs-stopped-err not_running "$BIFROST_ERR"
no state-when-stopped backend_state >/dev/null
eq state-stopped-err not_running "$BIFROST_ERR"

ok start-for-helpers daemon_start
p1=$(daemon_pid)
eq helpers-state Running "$(backend_state)"
eq helpers-prefs-nf 0 "$(prefs_json | jq -r .NetfilterMode)"
ok helpers-wait-ready daemon_wait_ready 3

ok restart-ok daemon_restart
p2=$(daemon_pid)
ok restart-new-pid [ "$p1" != "$p2" ]
daemon_stop

# --- 6. Hooks: hook_start, hook_stop, hook_start_nat ---

fresh
dbus_seed bifrost_enable=0
ok hook-start-disabled hook_start
no hook-start-disabled-not-running daemon_running

dbus_seed bifrost_enable=1
ok hook-start-enabled hook_start
ok hook-start-enabled-running daemon_running
p1=$(daemon_pid)
ok hook-start-idempotent hook_start
eq hook-start-same-pid "$p1" "$(daemon_pid)"

: >"$MOCK_STATE/p3.log"
ok hook-nat-running hook_start_nat
eq hook-nat-calls "fw_apply" "$(cat "$MOCK_STATE/p3.log")"

ok hook-stop-ok hook_stop
no hook-stop-stopped daemon_running

: >"$MOCK_STATE/p3.log"
ok hook-nat-stopped hook_start_nat
eq hook-nat-noop "" "$(cat "$MOCK_STATE/p3.log")"

# --- 7. Watchdog ---

fresh
dbus_seed bifrost_enable=1
ok wd-start daemon_start
# Healthy: prefs drift fixed, fw_check fail -> fw_apply, dns_check fail -> dns_apply
ts_out_file debug-prefs "$FIX/prefs_drifted.json"
: >"$MOCK_STATE/ts.log"
: >"$MOCK_STATE/p3.log"
STUB_FW_CHECK_RC=1
STUB_DNS_CHECK_RC=1
ok wd-repair watchdog_run
has wd-fixed-prefs "--netfilter-mode=off" "$(ts_log)"
has wd-fw-reapplied "fw_apply" "$(cat "$MOCK_STATE/p3.log")"
has wd-dns-reapplied "dns_apply" "$(cat "$MOCK_STATE/p3.log")"
STUB_FW_CHECK_RC=0
STUB_DNS_CHECK_RC=0
ts_out_file debug-prefs "$FIX/prefs_ok.json"

# Process disappears -> watchdog restarts (1st, 2nd, 3rd), 4th gives up
for i in 1 2 3; do
    kill -KILL "$(daemon_pid)" 2>/dev/null
    sleep 1
    ok "wd-restart-$i" watchdog_run
    ok "wd-alive-$i" daemon_running
done
eq wd-restarts-3 3 "$(wc -l <"$BIFROST_RUN/watchdog.restarts" | tr -d ' ')"

# 4th time within 30 min: refuses to restart, writes watchdog_gave_up
kill -KILL "$(daemon_pid)" 2>/dev/null
sleep 1
no wd-give-up watchdog_run
eq wd-give-up-err watchdog_gave_up "$BIFROST_ERR"
eq wd-give-up-file watchdog_gave_up "$(cat "$BIFROST_DAEMON_ERR")"
no wd-give-up-stays-down daemon_running

# Old timestamps (>30 min) are pruned and allow restart again
daemon_err_clear
old_ts=$(($(now) - 3600))
printf '%s\n%s\n%s\n' "$old_ts" "$old_ts" "$old_ts" >"$BIFROST_RUN/watchdog.restarts"
ok wd-old-pruned watchdog_run
ok wd-restarted-after-prune daemon_running
eq wd-pruned-count 1 "$(wc -l <"$BIFROST_RUN/watchdog.restarts" | tr -d ' ')"

# Unresponsive status --json while process is alive triggers restart
p_before=$(daemon_pid)
ts_rc status 1
no wd-unresponsive-restarts watchdog_run
eq wd-unresponsive-counted 2 "$(wc -l <"$BIFROST_RUN/watchdog.restarts" | tr -d ' ')"
rm -f "$MOCK_STATE/ts/status.rc"
daemon_err_clear
ok wd-recover-after-unresponsive daemon_start
ok wd-new-pid [ "$p_before" != "$(daemon_pid)" ]

# Log truncation (> max -> keep last bytes)
BIFROST_LOG_MAX_BYTES=100
BIFROST_LOG_KEEP_BYTES=20
printf '%0120dTAIL_MARKER_12345678' 0 >"$BIFROST_DLOG"
ok wd-trim watchdog_run
eq wd-trim-size 20 "$(file_size "$BIFROST_DLOG")"
eq wd-trim-tail "TAIL_MARKER_12345678" "$(cat "$BIFROST_DLOG")"

# Lock held -> local watchdog exits immediately without running
lock_acquire state 0
t_call local watchdog
no wd-lock-busy [ "$?" -eq 0 ]
lock_release state
daemon_stop

# --- 8. Page actions & job_daemon (enable, disable, purge) ---

fresh
ok act-enable act_enable
eq act-enable-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
jf=$(job_file daemon)
eq job-enable-ok "false true done start" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
eq job-enable-dbus 1 "$(cfg bifrost_enable)"
ok job-enable-running daemon_running

# busy check when daemon job is running
job_begin daemon
no act-enable-busy act_enable
eq act-enable-busy-err busy "$BIFROST_ERR"
job_end daemon ok

# disable
ok act-disable act_disable
bg_drain
eq job-disable-ok "false true done stop" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
eq job-disable-dbus 0 "$(cfg bifrost_enable)"
no job-disable-stopped daemon_running

# enable failure when conflict
pidof_set tailscaled 8888
ok act-enable-conflict-start act_enable
bg_drain
eq job-enable-conflict "false false conflict" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$jf")"
rm -f "$MOCK_STATE/pidof/tailscaled"

# purge while running: logout, stop, wipe state dir, bifrost_enable=0
ok start-for-purge daemon_start
echo "state" >"$BIFROST_STATE/tailscaled.state"
echo "hidden" >"$BIFROST_STATE/.hidden"
: >"$MOCK_STATE/ts.log"
ok act-purge act_purge
bg_drain
eq job-purge-ok "false true done purge" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
has job-purge-logout "logout" "$(ts_log)"
no job-purge-stopped daemon_running
eq job-purge-state-empty "" "$(ls -A "$BIFROST_STATE")"
eq job-purge-disabled 0 "$(cfg bifrost_enable)"

# purge while already stopped
echo "leftover" >"$BIFROST_STATE/tailscaled.state"
: >"$MOCK_STATE/ts.log"
ok act-purge-stopped act_purge
bg_drain
eq job-purge-stopped-ok true "$(jq -r .ok "$jf")"
eq job-purge-stopped-empty "" "$(ls -A "$BIFROST_STATE")"
eq job-purge-stopped-no-logout "" "$(ts_log)"

t_done
