#!/bin/sh
# Tests for plugin/bifrost/lib/daemon.sh (integrated with real P1/P3 libs).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

fresh() {
    t_setup
    t_load
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=2
    BIFROST_FW_RETRY_SLEEP=0
    BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
    printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
    nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 http_enable=0 http_lanport=80
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

wait_until_dead() {
    _wud_deadline=$(($(now) + 10))
    while daemon_pid_alive "$1"; do
        [ "$(now)" -lt "$_wud_deadline" ] || return 1
        sleep 1
    done
}

# --- 1. Pre-check failures & modprobe tun retry ---

fresh
rm -f "$BIFROST_CORE"
no precheck-core-missing daemon_start
eq precheck-core-err core_missing "$BIFROST_ERR"
eq precheck-core-file core_missing "$(cat "$BIFROST_DAEMON_ERR")"

# Core exists but --version fails (real core_version check)
fresh
printf '#!/bin/sh\nexit 1\n' >"$BIFROST_CORE"
chmod 755 "$BIFROST_CORE"
no precheck-core-badver daemon_start
eq precheck-core-badver-err core_missing "$BIFROST_ERR"
eq precheck-core-badver-file core_missing "$(cat "$BIFROST_DAEMON_ERR")"

# No tun + modprobe fails -> no_tun
fresh
rm -f "$BIFROST_TUN_DEV"
no precheck-no-tun daemon_start
eq precheck-tun-err no_tun "$BIFROST_ERR"
eq precheck-tun-file no_tun "$(cat "$BIFROST_DAEMON_ERR")"

# No tun -> modprobe tun creates device -> start succeeds
fresh
rm -f "$BIFROST_TUN_DEV"
mkdir -p "$T/mockbin"
cat >"$T/mockbin/modprobe" <<EOF
#!/bin/sh
echo "\$*" >>"$MOCK_STATE/modprobe.log"
[ "\$1" = tun ] && : >"$BIFROST_TUN_DEV"
exit 0
EOF
chmod 755 "$T/mockbin/modprobe"
OLD_PATH=$PATH
PATH="$T/mockbin:$PATH"
ok precheck-modprobe-ok daemon_start
has precheck-modprobe-called "tun" "$(cat "$MOCK_STATE/modprobe.log")"
PATH=$OLD_PATH
daemon_stop

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

# --- 2. Immediate startup failure & live process wait_ready timeout ---

fresh
: >"$MOCK_STATE/daemon.fail"
no start-immediate-fail daemon_start
eq start-fail-err start_failed "$BIFROST_ERR"
eq start-fail-file start_failed "$(cat "$BIFROST_DAEMON_ERR")"
no start-fail-not-running daemon_running

# Live process but status --json never answers -> daemon_wait_ready times out
fresh
BIFROST_WAIT_READY=1
ts_rc status 1
no start-wait-timeout daemon_start
eq start-wait-timeout-err start_failed "$BIFROST_ERR"
eq start-wait-timeout-file start_failed "$(cat "$BIFROST_DAEMON_ERR")"
no start-wait-timeout-dead daemon_running

# --- 3. Normal startup with REAL fw_apply, dns_apply, status_refresh ---

fresh
mkdir -p "$BIFROST_RUN"
echo core_missing >"$BIFROST_DAEMON_ERR"
dbus_seed bifrost_enable=1 bifrost_port=51820 bifrost_no_logs=1 bifrost_magicdns=1
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
# Real firewall, DNS, status, and watchdog cron
ok start-real-fw fw_check
has start-real-fw-port "--dport 51820" "$(iptables -t filter -S BIFROST_INPUT)"
ok start-real-dns dns_check
eq start-real-dns-line "server=/example.ts.net/100.100.100.100" "$(cat "$BIFROST_DNSMASQ_CONF")"
eq start-real-status running "$(jq -r .state "$BIFROST_UPLOAD/bifrost_status.json")"
has start-cru-a "CRU a $BIFROST_WATCHDOG_NAME" "$(cat "$MOCK_STATE/cru.log")"
has start-cru-entry "local watchdog #$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
dbus_seed bifrost_enable=0
daemon_stop

# no_logs=0 with official server omits --no-logs-no-support
fresh
dbus_seed bifrost_no_logs=0
ok start-logs-on daemon_start
no start-no-nologs-cmdline daemon_running_has_nologs
daemon_stop

# no_logs=0 with non-official server STILL forces --no-logs-no-support
fresh
dbus_seed bifrost_no_logs=0
ok set-custom-srv daemon_set_control_server "https://headscale.example.com"
ok start-custom-nologs daemon_start
ok start-custom-has-nologs daemon_running_has_nologs
daemon_stop

# Partial failure (fw_apply fails): daemon runs, watchdog IS registered,
# then watchdog repairs firewall and clears $BIFROST_DAEMON_ERR!
fresh
dbus_seed bifrost_enable=1
echo 50 >"$MOCK_STATE/iptables.fail_count"
no start-fw-fail daemon_start
eq start-fw-err fw_failed "$BIFROST_ERR"
eq start-fw-errfile fw_failed "$(cat "$BIFROST_DAEMON_ERR")"
ok start-fw-still-running daemon_running
has start-fw-has-watchdog "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
rm -f "$MOCK_STATE/iptables.fail_count"
ok wd-recovers-fw watchdog_run
ok wd-fw-repaired fw_check
no wd-clears-fw-err [ -f "$BIFROST_DAEMON_ERR" ]
eq wd-status-recovered running "$(jq -r .state "$BIFROST_UPLOAD/bifrost_status.json")"
# A partial apply can leave every jump intact and a single rule missing.
iptables -t filter -D BIFROST_INPUT -p udp --dport 41641 -j ACCEPT
ok wd-partial-jump-intact iptables -t filter -C INPUT -j BIFROST_INPUT
no wd-partial-rule-detected fw_check
daemon_err_set fw_failed
ok wd-partial-recovered watchdog_run
ok wd-partial-rule-restored iptables -t filter -C BIFROST_INPUT -p udp --dport 41641 -j ACCEPT
no wd-partial-error-cleared [ -e "$BIFROST_DAEMON_ERR" ]
dbus_seed bifrost_enable=0
daemon_stop

# Partial failure (prefs fix fails): preserves real error code and registers watchdog
fresh
dbus_seed bifrost_enable=1
ts_rc debug-prefs 1
no start-prefs-fail daemon_start
eq start-prefs-err cli_failed "$BIFROST_ERR"
eq start-prefs-errfile cli_failed "$(cat "$BIFROST_DAEMON_ERR")"
has start-prefs-has-watchdog "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
rm -f "$MOCK_STATE/ts/debug-prefs.rc"
dbus_seed bifrost_enable=0
daemon_stop

# --- 4. Stop: normal, pidfile missing, TERM ignored, keep watchdog when enabled ---

fresh
ok stop-when-stopped daemon_stop
dbus_seed bifrost_enable=0 bifrost_magicdns=1
ok start-for-stop daemon_start
: >"$MOCK_STATE/cru.log"
: >"$MOCK_STATE/daemon.log"
ok stop-running daemon_stop
no stop-not-running daemon_running
eq stop-no-cron-mutation "" "$(cat "$MOCK_STATE/cru.log")"
has stop-cleanup "cleanup" "$(cat "$MOCK_STATE/daemon.log")"
no stop-fw-cleared fw_check
no stop-dns-cleared [ -e "$BIFROST_DNSMASQ_CONF" ]

# Pidfile missing while daemon is still alive: daemon_stop finds it by cmdline,
# kills it, and only then runs --cleanup!
fresh
ok start-lost-pid daemon_start
orphan_pid=$(daemon_pid)
rm -f "$BIFROST_PIDFILE"
: >"$MOCK_STATE/daemon.log"
ok stop-lost-pid daemon_stop
no stop-lost-pid-dead kill -0 "$orphan_pid" 2>/dev/null
has stop-lost-pid-cleanup "cleanup" "$(cat "$MOCK_STATE/daemon.log")"

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

# Failed restart while bifrost_enable=1 MUST keep watchdog cron registered!
fresh
dbus_seed bifrost_enable=1
ok start-for-wd-keep daemon_start
: >"$MOCK_STATE/daemon.fail"
no restart-fails-keeps-wd daemon_restart
has restart-fail-wd-present "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
rm -f "$MOCK_STATE/daemon.fail"

# --- 5. daemon_restart, prefs_json, backend_state (ok, fail, bad JSON, timeout) ---

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

# CLI failure -> cli_failed
ts_rc debug-prefs 1
no prefs-cli-fail prefs_json >/dev/null
eq prefs-cli-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/debug-prefs.rc"

ts_rc status 1
no state-cli-fail backend_state >/dev/null
eq state-cli-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/status.rc"

# Non-JSON output -> cli_failed
ts_out debug-prefs "not-json"
no prefs-bad-json prefs_json >/dev/null
eq prefs-bad-json-err cli_failed "$BIFROST_ERR"
ts_out_file debug-prefs "$FIX/prefs_ok.json"

ts_out status "not-json"
no state-bad-json backend_state >/dev/null
eq state-bad-json-err cli_failed "$BIFROST_ERR"
ts_out_file status "$FIX/status_running.json"

# Timeout (fault stub for ts_cli returning 124) -> timeout
ts_cli() { return 124; }
no prefs-timeout prefs_json >/dev/null
eq prefs-timeout-err timeout "$BIFROST_ERR"
no state-timeout backend_state >/dev/null
eq state-timeout-err timeout "$BIFROST_ERR"
# Restore real ts_cli
t_load
BIFROST_FW_RETRY_SLEEP=0

ok restart-ok daemon_restart
p2=$(daemon_pid)
ok restart-new-pid [ "$p1" != "$p2" ]
daemon_stop

# --- 6. Hooks: hook_start (ok/fail), hook_stop (removes wd), hook_start_nat (ok/fail) ---

fresh
dbus_seed bifrost_enable=0
ok hook-start-disabled hook_start
no hook-start-disabled-not-running daemon_running

dbus_seed bifrost_enable=1
: >"$MOCK_STATE/daemon.fail"
no hook-start-fail hook_start
eq hook-start-fail-err start_failed "$BIFROST_ERR"
has hook-first-failure-registered "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
rm -f "$MOCK_STATE/daemon.fail"

ok hook-start-enabled hook_start
ok hook-start-enabled-running daemon_running
p1=$(daemon_pid)
ok hook-start-idempotent hook_start
eq hook-start-same-pid "$p1" "$(daemon_pid)"

# hook_start_nat repairs deleted jump and fails on fw_apply error
iptables -t filter -D INPUT -j BIFROST_INPUT
no hook-nat-broken fw_check
ok hook-nat-running hook_start_nat
ok hook-nat-fixed fw_check

echo 50 >"$MOCK_STATE/iptables.fail_count"
no hook-nat-fw-fail hook_start_nat
eq hook-nat-fw-fail-err fw_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/iptables.fail_count"

# hook_stop removes watchdog even while bifrost_enable=1
ok hook-stop-ok hook_stop
no hook-stop-stopped daemon_running
no hook-stop-wd-removed grep -q "#$BIFROST_WATCHDOG_NAME#" "$MOCK_STATE/cru.txt"

: >"$MOCK_STATE/iptables.log"
ok hook-nat-stopped hook_start_nat
eq hook-nat-noop "" "$(cat "$MOCK_STATE/iptables.log")"

# --- 7. Watchdog ---

fresh
# Disabled -> no-op, no CLI calls
dbus_seed bifrost_enable=0
: >"$MOCK_STATE/ts.log"
ok wd-disabled watchdog_run
no wd-disabled-no-daemon daemon_running
eq wd-disabled-no-cli "" "$(ts_log)"

dbus_seed bifrost_enable=1 bifrost_magicdns=1
ok wd-start daemon_start
# Healthy: fixes drifted prefs, real broken fw_check, real stale dns_check, stale authkey
ts_out_file debug-prefs "$FIX/prefs_drifted.json"
iptables -t filter -D INPUT -j BIFROST_INPUT
printf 'server=/stale.example.ts.net/100.100.100.100\n' >"$BIFROST_DNSMASQ_CONF"
: >"$BIFROST_RUN/authkey"
: >"$MOCK_STATE/ts.log"
ok wd-repair watchdog_run
has wd-fixed-prefs "--netfilter-mode=off" "$(ts_log)"
ok wd-fw-reapplied fw_check
ok wd-dns-reapplied dns_check
no wd-cleaned-authkey [ -f "$BIFROST_RUN/authkey" ]
ts_out_file debug-prefs "$FIX/prefs_ok.json"

# Process disappears -> watchdog restarts (1st, 2nd, 3rd), 4th gives up
for i in 1 2 3; do
    wd_pid=$(daemon_pid)
    kill -KILL "$wd_pid"
    ok "wd-exited-$i" wait_until_dead "$wd_pid"
    ok "wd-restart-$i" watchdog_run
    ok "wd-alive-$i" daemon_running
    has "wd-still-registered-$i" "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
done
eq wd-restarts-3 3 "$(wc -l <"$BIFROST_RUN/watchdog.restarts" | tr -d ' ')"

# 4th time within 30 min: refuses to restart, writes watchdog_gave_up
wd_pid=$(daemon_pid)
kill -KILL "$wd_pid"
ok wd-fourth-exited wait_until_dead "$wd_pid"
no wd-give-up watchdog_run
eq wd-give-up-err watchdog_gave_up "$BIFROST_ERR"
eq wd-give-up-file watchdog_gave_up "$(cat "$BIFROST_DAEMON_ERR")"
no wd-give-up-stays-down daemon_running

# Already watchdog_gave_up -> returns early without calling CLI or restarting
: >"$MOCK_STATE/ts.log"
no wd-already-gave-up watchdog_run
eq wd-already-gave-up-err watchdog_gave_up "$BIFROST_ERR"
no wd-already-gave-up-down daemon_running
eq wd-already-gave-up-no-cli "" "$(ts_log)"

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
has wd-unresponsive-wd-kept "#$BIFROST_WATCHDOG_NAME#" "$(cat "$MOCK_STATE/cru.txt")"
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

# Lock held -> local watchdog exits immediately without CLI calls or restart
p_locked=$(daemon_pid)
: >"$MOCK_STATE/ts.log"
lock_acquire state 0
t_call local watchdog
no wd-lock-busy [ "$?" -eq 0 ]
eq wd-lock-no-cli "" "$(ts_log)"
eq wd-lock-same-pid "$p_locked" "$(daemon_pid)"
lock_release state
dbus_seed bifrost_enable=0
daemon_stop

# --- 8. Page actions & job_daemon (enable, disable, purge, busy, invalid) ---

fresh
ok act-enable act_enable
eq act-enable-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
jf=$(job_file daemon)
eq job-enable-ok "false true done start" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
eq job-enable-dbus 1 "$(cfg bifrost_enable)"
ok job-enable-running daemon_running

# busy check for enable, disable, purge
job_begin daemon
no act-enable-busy act_enable
eq act-enable-busy-err busy "$BIFROST_ERR"
no act-disable-busy act_disable
eq act-disable-busy-err busy "$BIFROST_ERR"
no act-purge-busy act_purge
eq act-purge-busy-err busy "$BIFROST_ERR"
job_end daemon ok

# job_daemon with invalid action
job_begin daemon
no job-daemon-invalid job_daemon bogus_action
eq job-daemon-invalid-err invalid_param "$BIFROST_ERR"
job_end daemon fail invalid_param

# disable removes watchdog cron and stops daemon
ok act-disable act_disable
bg_drain
eq job-disable-ok "false true done stop" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
eq job-disable-dbus 0 "$(cfg bifrost_enable)"
no job-disable-stopped daemon_running
no job-disable-wd-gone grep -q "#$BIFROST_WATCHDOG_NAME#" "$MOCK_STATE/cru.txt"

# enable failure when conflict
pidof_set tailscaled 8888
ok act-enable-conflict-start act_enable
bg_drain
eq job-enable-conflict "false false conflict" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$jf")"
rm -f "$MOCK_STATE/pidof/tailscaled"

# purge while running: logout, stop, wipe state dir + migration backups, remove wd, bifrost_enable=0
dbus_seed bifrost_enable=1
ok start-for-purge daemon_start
echo "state" >"$BIFROST_STATE/tailscaled.state"
echo "hidden" >"$BIFROST_STATE/.hidden"
mkdir -p "${BIFROST_STATE}.bak.12345"
echo "privkey" >"${BIFROST_STATE}.bak.12345/tailscaled.state"
: >"$MOCK_STATE/ts.log"
ok act-purge act_purge
bg_drain
eq job-purge-ok "false true done purge" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action)"' "$jf")"
has job-purge-logout "logout" "$(ts_log)"
no job-purge-stopped daemon_running
eq job-purge-state-empty "" "$(ls -A "$BIFROST_STATE")"
no job-purge-bak-removed [ -e "${BIFROST_STATE}.bak.12345" ]
no job-purge-wd-removed grep -q "#$BIFROST_WATCHDOG_NAME#" "$MOCK_STATE/cru.txt"
eq job-purge-disabled 0 "$(cfg bifrost_enable)"

# purge while already stopped
echo "leftover" >"$BIFROST_STATE/tailscaled.state"
: >"$MOCK_STATE/ts.log"
ok act-purge-stopped act_purge
bg_drain
eq job-purge-stopped-ok true "$(jq -r .ok "$jf")"
eq job-purge-stopped-empty "" "$(ls -A "$BIFROST_STATE")"
eq job-purge-stopped-no-logout "" "$(ts_log)"

fresh
sock_up
sleep 60 &
other=$!
echo 60 >"$MOCK_STATE/ts/status.sleep"
TS_BE_CLI=1 "$BIFROST_CORE" "--socket=$BIFROST_SOCK" status >/dev/null &
cli_pid=$!
cp "$BIFROST_CORE" "$T/tailscaled"
"$T/tailscaled" "--statedir=$BIFROST_ORIG_STATE" "--socket=$T/original.sock" >/dev/null &
orig_pid=$!
pidof_set tailscaled "$orig_pid"
mkdir -p "$BIFROST_RUN"
for foreign in "$other" "$cli_pid" "$orig_pid"; do
    echo "$foreign" >"$BIFROST_PIDFILE"
    no "owns-excludes-$foreign" daemon_owns_pid "$foreign"
    no "find-excludes-$foreign" daemon_find_pid
done
rm "$BIFROST_PIDFILE"
ok stop-with-original-only daemon_stop
ok original-not-signalled kill -0 "$orig_pid"
ok cli-not-signalled kill -0 "$cli_pid"
ok other-not-signalled kill -0 "$other"
kill "$other" "$cli_pid" "$orig_pid"
wait "$other" "$cli_pid" "$orig_pid" 2>/dev/null || true

# Discover the custom server from live prefs. A failed write must keep the
# error until the same write succeeds; exactly one restart then applies it.
fresh
dbus_seed bifrost_enable=1 bifrost_no_logs=0
ts_out_file debug-prefs "$FIX/prefs_custom.json"
mkdir "$BIFROST_STATE/control_url"
no boot-custom-record-blocked t_call start
eq boot-custom-record-code state_not_writable "$(cat "$BIFROST_DAEMON_ERR")"
ok watchdog-still-unwritable watchdog_run
eq watchdog-keeps-write-code state_not_writable "$(cat "$BIFROST_DAEMON_ERR")"
rmdir "$BIFROST_STATE/control_url"
ok watchdog-retries-control-write watchdog_run
eq watchdog-recorded-control https://headscale.example.com "$(daemon_control_server)"
ok watchdog-enforces-nologs daemon_running_has_nologs
no watchdog-clears-write-error [ -f "$BIFROST_DAEMON_ERR" ]
ok watchdog-settled watchdog_run
eq custom-exactly-one-restart 2 "$(grep -c '^started ' "$MOCK_STATE/daemon.log")"
daemon_stop

fresh
dbus_seed bifrost_enable=1 bifrost_no_logs=0
ts_out_file debug-prefs "$FIX/prefs_custom.json"
ok boot-custom-first t_call start
ok boot-custom-immediate-flag daemon_running_has_nologs
eq boot-custom-one-restart 2 "$(grep -c '^started ' "$MOCK_STATE/daemon.log")"
daemon_stop
t_done
