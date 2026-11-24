#!/bin/sh
# Tests for plugin/bifrost/lib/migrate.sh (integrated with real P1/P3 libs).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

fresh() {
    t_setup
    t_load
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=1
    BIFROST_FW_RETRY_SLEEP=0
    BIFROST_MIGRATE_AUTOSTOP=0
    BIFROST_MIGRATE_WAIT_POLL=1
    BIFROST_MIGRATE_WAIT_TIMEOUT=2
    BIFROST_MIGRATE_VERIFY_TIMEOUT=2
    BIFROST_MIGRATE_VERIFY_POLL=1
    BIFROST_MIGRATE_ORIG_STOP_TIMEOUT=2
    BIFROST_ORIG_CLI=""
    BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
    printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
    nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 http_enable=0 http_lanport=80
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

seed_orig_state() {
    mkdir -p "$BIFROST_ORIG_STATE/files"
    printf 'ORIG-STATE-DATA\n' >"$BIFROST_ORIG_STATE/tailscaled.state"
    printf '{"regions":{}}\n' >"$BIFROST_ORIG_STATE/derpmap.cached.json"
    printf 'should-not-copy\n' >"$BIFROST_ORIG_STATE/files/a.txt"
}

wait_original_phase() {
    _wo_until=$(($(now) + 30))
    until [ "$(jq -r .phase "$jf" 2>/dev/null)" = wait_original ]; do
        [ "$(now)" -lt "$_wo_until" ] || return 1
        sleep 1
    done
}

seed_orig_cli() {
    cat >"$BIFROST_KSBIN/tailscale" <<EOF
#!/bin/sh
cat "$1"
EOF
    chmod 755 "$BIFROST_KSBIN/tailscale"
}

seed_orig_config() {
    _soc_start_rc=${1:-0}
    _soc_stop_keeps=${2:-0}
    cat >"$BIFROST_ORIG_CONFIG" <<EOF
#!/bin/sh
echo "ORIG_CFG \$*" >>"$MOCK_STATE/orig_cfg.log"
case "\$1" in
    stop)
        [ "$_soc_stop_keeps" = 1 ] || rm -f "$MOCK_STATE/pidof/tailscaled"
        ;;
    start)
        [ "$_soc_start_rc" = 0 ] || exit "$_soc_start_rc"
        echo 7777 >"$MOCK_STATE/pidof/tailscaled"
        ;;
esac
exit 0
EOF
    chmod 755 "$BIFROST_ORIG_CONFIG"
}

# --- 0. Migration stops the original itself unless told otherwise ---

# shellcheck disable=SC2016
eq mig-autostop-default 1 "$(sh -c 'unset BIFROST_MIGRATE_AUTOSTOP; . "$1"; echo "$BIFROST_MIGRATE_AUTOSTOP"' \
    sh "$T_SRC/plugin/bifrost/lib/env.sh")"

# --- 1. Precheck failures ---

fresh
ok mig-pre-missing act_migrate
eq mig-pre-res '{"job":"migrate"}' "$BIFROST_RESULT"
bg_drain
jf=$(job_file migrate)
eq mig-pre-missing-code orig_missing "$(jq -r .code "$jf")"

fresh
seed_orig_state
rm -f "$BIFROST_CORE"
ok mig-pre-core act_migrate
bg_drain
eq mig-pre-core-code core_missing "$(jq -r .code "$jf")"

fresh
seed_orig_state
ok mig-start-first daemon_start
ok mig-pre-running act_migrate
bg_drain
eq mig-pre-running-code already_running "$(jq -r .code "$jf")"
daemon_stop

# --- 2. AUTOSTOP=0: timeout while original keeps running (nothing changed) ---

fresh
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
pidof_set tailscaled 7777
echo "KEEP_ME" >"$BIFROST_STATE/existing.txt"
BIFROST_MIGRATE_WAIT_TIMEOUT=1
ok mig-wait-timeout-start act_migrate
bg_drain
eq mig-wait-timeout-res "false orig_still_running true false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.manual_stop) \(.data.rolled_back)"' "$jf")"
eq mig-wait-timeout-untouched "KEEP_ME" "$(cat "$BIFROST_STATE/existing.txt")"
eq mig-wait-timeout-disabled 0 "$(cfg bifrost_enable)"
no mig-wait-timeout-no-daemon daemon_running

# --- 3. AUTOSTOP=0: wait_original phase + lock-free wait + record.json + backup cleanup ---

fresh
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
pidof_set tailscaled 7777
echo "OLD_PRIVATE_STATE" >"$BIFROST_STATE/old.state"
BIFROST_MIGRATE_WAIT_TIMEOUT=60
job_begin migrate
(export BIFROST_MIGRATE_WAIT_TIMEOUT BIFROST_MIGRATE_WAIT_POLL BIFROST_MIGRATE_AUTOSTOP; t_call local job migrate) &
mig_bg_pid=$!
ok mig-wait-phase wait_original_phase
no mig-wait-no-lock [ -d "$BIFROST_RUN/lock.state" ]
ok mig-wait-set-unblocked act_set mirror "https://mirror.example.com/"
rm -f "$MOCK_STATE/pidof/tailscaled"
wait "$mig_bg_pid"
eq mig-manual-rc 0 "$?"
eq mig-manual-job "false true done true false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.manual_stop) \(.data.rolled_back)"' "$jf")"
ok mig-manual-running daemon_running
ok mig-manual-fw fw_check
eq mig-manual-enabled 1 "$(cfg bifrost_enable)"
eq mig-manual-state-copied "ORIG-STATE-DATA" "$(cat "$BIFROST_STATE/tailscaled.state")"
# shellcheck disable=SC2012
eq mig-manual-state-mode "-rw-------" "$(ls -l "$BIFROST_STATE/tailscaled.state" | cut -c1-10)"
# shellcheck disable=SC2012
eq mig-manual-derp-mode "-rw-------" "$(ls -l "$BIFROST_STATE/derpmap.cached.json" | cut -c1-10)"
no mig-manual-no-files [ -e "$BIFROST_STATE/files" ]
# Backup containing old private state was deleted on success
no mig-manual-bak-deleted [ -e "$_BIFROST_MIGRATION" ]
# Original files untouched
eq mig-orig-state-intact "ORIG-STATE-DATA" "$(cat "$BIFROST_ORIG_STATE/tailscaled.state")"
eq mig-orig-derp-intact '{"regions":{}}' "$(cat "$BIFROST_ORIG_STATE/derpmap.cached.json")"
eq mig-orig-other-intact "should-not-copy" "$(cat "$BIFROST_ORIG_STATE/files/a.txt")"
# record.json contents verified
eq mig-record-content "Running n123456CNTRL nodekey:1111111111111111111111111111111111111111111111111111111111111111" \
    "$(jq -r '"\(.state) \(.id) \(.public_key)"' "$BIFROST_RUN/migrate/record.json")"
dbus_seed bifrost_enable=0
daemon_stop

# --- 4. Migrating custom headscale state when bifrost_no_logs=0 enforces --no-logs-no-support ---

fresh
seed_orig_state
dbus_seed bifrost_no_logs=0
ts_out_file debug-prefs "$FIX/prefs_custom.json"
ok mig-custom-nologs act_migrate
bg_drain
eq mig-custom-nologs-ok true "$(jq -r .ok "$jf")"
ok mig-custom-nologs-enforced daemon_running_has_nologs
eq mig-custom-server-saved "https://headscale.example.com" "$(daemon_control_server)"
dbus_seed bifrost_enable=0
daemon_stop

# --- 5. No original CLI: state-only verify (Running succeeds, NeedsLogin fails & rolls back) ---

fresh
seed_orig_state
ok mig-nocli-ok act_migrate
bg_drain
eq mig-nocli-ok-res true "$(jq -r .ok "$jf")"
dbus_seed bifrost_enable=0
daemon_stop

fresh
seed_orig_state
echo "KEEP_OLD" >"$BIFROST_STATE/old.txt"
ts_out_file status "$FIX/status_needs_login.json"
ok mig-nocli-fail act_migrate
bg_drain
eq mig-nocli-fail-res "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-nocli-fail-restored "KEEP_OLD" "$(cat "$BIFROST_STATE/old.txt")"

# --- 6. Identity mismatch -> rollback restores backup & returns migrate_verify_failed ---

fresh
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
pidof_set tailscaled 7777
echo "OLD_BIFROST" >"$BIFROST_STATE/old.txt"
ts_out status '{"BackendState":"Running","Self":{"ID":"nDIFFERENT","PublicKey":"nodekey:9999"}}'
BIFROST_MIGRATE_WAIT_TIMEOUT=60
(wait_original_phase && rm -f "$MOCK_STATE/pidof/tailscaled") &
wait_helper=$!
ok mig-verify-fail-start act_migrate
bg_drain
ok mig-verify-saw-wait-original wait "$wait_helper"
eq mig-verify-fail-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
no mig-verify-fail-stopped daemon_running
eq mig-verify-fail-disabled 0 "$(cfg bifrost_enable)"
eq mig-verify-fail-backup-restored "OLD_BIFROST" "$(cat "$BIFROST_STATE/old.txt")"
no mig-verify-fail-no-copied [ -f "$BIFROST_STATE/tailscaled.state" ]

# --- 7. Non-verify failures preserve original error code (start_failed, state_not_writable) ---

fresh
seed_orig_state
echo "BEFORE_MIG" >"$BIFROST_STATE/before.txt"
: >"$MOCK_STATE/daemon.fail"
ok mig-start-fail-go act_migrate
bg_drain
eq mig-start-fail-job "false start_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-start-fail-restored "BEFORE_MIG" "$(cat "$BIFROST_STATE/before.txt")"
eq mig-start-fail-disabled 0 "$(cfg bifrost_enable)"

# Copy failure -> rollback + state_not_writable (fault via unreadable source or broken cp stub)
fresh
seed_orig_state
echo "BEFORE_CP" >"$BIFROST_STATE/before.txt"
# shellcheck disable=SC2329
cp() {
    [ "$1" != "$BIFROST_ORIG_STATE/tailscaled.state" ] || return 1
    command cp "$@"
}
ok mig-cp-fail act_migrate
bg_drain
unset -f cp
eq mig-cp-fail-job "false state_not_writable true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-cp-fail-restored "BEFORE_CP" "$(cat "$BIFROST_STATE/before.txt")"

# Backup fails before disabling the original or changing live state.
fresh
seed_orig_state
echo "BEFORE_BAK" >"$BIFROST_STATE/before.txt"
# shellcheck disable=SC2329
cp() {
    [ "${3:-}" != "$_BIFROST_MIGRATION/backup" ] || return 1
    command cp "$@"
}
ok mig-bak-fail act_migrate
bg_drain
unset -f cp
eq mig-bak-fail-job "false state_not_writable false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-bak-fail-untouched "BEFORE_BAK" "$(cat "$BIFROST_STATE/before.txt")"

# AUTOSTOP=0 rollback failure -> migrate_rollback_failed (fault: backup vanishes before rollback)
fresh
seed_orig_state
echo "VANISH" >"$BIFROST_STATE/v.txt"
ts_out_file status "$FIX/status_needs_login.json"
daemon_stop() {
    _tmp_p=$(daemon_pid 2>/dev/null)
    [ -n "$_tmp_p" ] && kill -KILL "$_tmp_p" 2>/dev/null || true
    rm -rf "$_BIFROST_MIGRATION/backup"
    return 0
}
ok mig-autostop0-rbfail act_migrate
bg_drain
t_load
eq mig-autostop0-rbfail-job "false migrate_rollback_failed false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"

# --- 8. AUTOSTOP=1: success, stop failure, rollback preserves tailscale_enable, rollback fail ---

fresh
BIFROST_MIGRATE_AUTOSTOP=1
dbus_seed tailscale_enable=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 0 0
pidof_set tailscaled 7777
ok mig-auto-ok act_migrate
bg_drain
eq mig-auto-job "false true done false false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.manual_stop) \(.data.rolled_back)"' "$jf")"
has mig-auto-stopped-orig "ORIG_CFG stop" "$(cat "$MOCK_STATE/orig_cfg.log")"
eq mig-auto-orig-disabled 0 "$(dbus get tailscale_enable)"
# The original's leftover nat rules go away with a firewall rebuild.
has mig-auto-fw-rebuild restart_firewall "$(cat "$MOCK_STATE/service.log" 2>/dev/null)"
ok mig-auto-running daemon_running
dbus_seed bifrost_enable=0
daemon_stop

# AUTOSTOP=1: stopping original fails -> orig_still_running + restores tailscale_enable=1
fresh
BIFROST_MIGRATE_AUTOSTOP=1
dbus_seed tailscale_enable=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 0 1
pidof_set tailscaled 7777
ok mig-auto-stopfail act_migrate
bg_drain
eq mig-auto-stopfail-job "false orig_still_running false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-auto-stopfail-restored-en 1 "$(dbus get tailscale_enable)"

# An enabled but stopped original stays stopped and recovers its saved boot flag.
fresh
BIFROST_MIGRATE_AUTOSTOP=1
dbus_seed tailscale_enable=1
seed_orig_state
seed_orig_config 0 0
ts_out_file status "$FIX/status_needs_login.json"
ok mig-auto-orig0-rb act_migrate
bg_drain
eq mig-auto-orig0-rb-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-auto-orig0-rb-en 1 "$(dbus get tailscale_enable)"
no mig-auto-orig0-rb-not-started orig_running

# AUTOSTOP=1: original running with tailscale_enable=0; verify fails -> restarts original
fresh
BIFROST_MIGRATE_AUTOSTOP=1
dbus_seed tailscale_enable=0
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 0 0
pidof_set tailscaled 7777
echo "PREV_STATE" >"$BIFROST_STATE/prev.txt"
ts_out_file status "$FIX/status_needs_login.json"
ok mig-auto-rb-start act_migrate
bg_drain
eq mig-auto-rb-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
has mig-auto-rb-restarted "ORIG_CFG start" "$(cat "$MOCK_STATE/orig_cfg.log")"
no mig-auto-rb-no-fw-rebuild grep -q restart_firewall "$MOCK_STATE/service.log"
eq mig-auto-rb-orig-enabled 0 "$(dbus get tailscale_enable)"
ok mig-auto-rb-orig-running orig_running
eq mig-auto-rb-restored "PREV_STATE" "$(cat "$BIFROST_STATE/prev.txt")"

# AUTOSTOP=1: rollback itself fails -> migrate_rollback_failed
fresh
BIFROST_MIGRATE_AUTOSTOP=1
dbus_seed tailscale_enable=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 1 0
pidof_set tailscaled 7777
ts_out_file status "$FIX/status_needs_login.json"
ok mig-rb-fail-start act_migrate
bg_drain
eq mig-rb-fail-job "false migrate_rollback_failed false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"

# --- 9. Busy when migrate job already running ---

job_begin migrate
no mig-busy act_migrate
eq mig-busy-err busy "$BIFROST_ERR"
job_end migrate ok

# The stopped daemon can surrender the identity even if clearing its rules failed.
fresh
seed_orig_state
seed_orig_config
pidof_set tailscaled 7777
BIFROST_MIGRATE_AUTOSTOP=1
echo before >"$BIFROST_STATE/before"
ts_out_file status "$FIX/status_needs_login.json"
fw_clear() { fail fw_failed; }
ok cleanup-error-queued act_migrate
bg_drain
eq cleanup-error-result "migrate_verify_failed true fw_failed" \
    "$(jq -r '"\(.code) \(.data.rolled_back) \(.data.cleanup_error)"' "$jf")"
ok cleanup-error-original-running orig_running
no cleanup-error-original-key grep -q '^tailscale_enable=' "$MOCK_STATE/dbus.env"
eq cleanup-error-old-state before "$(cat "$BIFROST_STATE/before")"
no cleanup-error-copied-key [ -e "$BIFROST_STATE/tailscaled.state" ]
no cleanup-error-journal [ -d "$_BIFROST_MIGRATION" ]
t_load

fresh
seed_orig_state
echo before >"$BIFROST_STATE/before"
# shellcheck disable=SC2329
cp() {
    [ "$1" != "$BIFROST_ORIG_STATE/derpmap.cached.json" ] || return 1
    command cp "$@"
}
ok derp-copy-queued act_migrate
bg_drain
unset -f cp
eq derp-copy-result "state_not_writable true" "$(jq -r '[.code,.data.rolled_back]|@tsv' "$jf" | tr '\t' ' ')"
eq derp-copy-old-state before "$(cat "$BIFROST_STATE/before")"
no derp-copy-no-private-key [ -e "$BIFROST_STATE/tailscaled.state" ]

for sig in TERM HUP INT KILL; do
    fresh
    seed_orig_state
    seed_orig_config
    pidof_set tailscaled 7777
    dbus_seed tailscale_enable=1
    echo old >"$BIFROST_STATE/before"
    job_begin migrate
    no "$sig-worker" env BIFROST_MIGRATE_AUTOSTOP=1 sh "$FIX/interrupted-migration.sh" "$sig" copying
    ok "$sig-fired" [ -f "$MOCK_STATE/interrupted" ]
    if [ "$sig" = KILL ]; then
        no cold-original-still-down orig_running
        eq cold-boot-disabled 0 "$(dbus get tailscale_enable)"
        rm -rf "$BIFROST_RUN" "$BIFROST_UPLOAD"
        ok cold-boot t_call start
        ok cold-replay t_call start
    else
        eq "$sig-failed-job" "internal true false" "$(jq -r '[.code,.data.rolled_back,.running]|@tsv' "$jf" | tr '\t' ' ')"
    fi
    ok "$sig-original-running" orig_running
    eq "$sig-original-autostart" 1 "$(dbus get tailscale_enable)"
    eq "$sig-old-state" old "$(cat "$BIFROST_STATE/before")"
    no "$sig-no-copied-identity" [ -e "$BIFROST_STATE/tailscaled.state" ]
    no "$sig-no-journal" [ -e "$_BIFROST_MIGRATION" ]
    no "$sig-no-lock" [ -e "$BIFROST_RUN/lock.state" ]
done

# Losing power before commit must also be recoverable at the next migration
# entry. Remove its test source so that the new job stops just after recovery.
fresh
seed_orig_state
seed_orig_config
pidof_set tailscaled 7777
echo saved >"$BIFROST_STATE/saved"
job_begin migrate
no power-cut-while-running env BIFROST_MIGRATE_AUTOSTOP=1 sh "$FIX/interrupted-migration.sh" KILL verifying
ok interrupted-migrated-daemon daemon_running
ok interrupted-durable-record [ -s "$_BIFROST_MIGRATION/record" ]
rm -f "$BIFROST_ORIG_STATE/tailscaled.state"
job_reap
ok next-job-queued act_migrate
bg_drain
eq next-job-after-recovery orig_missing "$(jq -r .code "$jf")"
no next-job-stopped-bifrost daemon_running
ok next-job-restarted-original orig_running
eq next-job-restored-state saved "$(cat "$BIFROST_STATE/saved")"
no next-job-original-flag-absent grep -q '^tailscale_enable=' "$MOCK_STATE/dbus.env"

# A watchdog removal error keeps a retryable record, but a confirmed stop
# already makes it safe to restore the original identity and service.
fresh
seed_orig_state
seed_orig_config
pidof_set tailscaled 7777
dbus_seed tailscale_enable=1
BIFROST_MIGRATE_AUTOSTOP=1
ts_out_file status "$FIX/status_needs_login.json"
echo before >"$BIFROST_STATE/before"
daemon_watchdog_remove() { return 1; }
ok unschedule-fail-queued act_migrate
bg_drain
eq unschedule-fail-code migrate_rollback_failed "$(jq -r .code "$jf")"
ok unschedule-restored-original orig_running
eq unschedule-restored-autostart 1 "$(dbus get tailscale_enable)"
eq unschedule-restored-state before "$(cat "$BIFROST_STATE/before")"
ok unschedule-retains-retry [ -s "$_BIFROST_MIGRATION/record" ]
t_load
ok unschedule-boot-retries t_call start
no unschedule-journal-cleared [ -e "$_BIFROST_MIGRATION" ]

# Failure to dispose of an old key after commit is a warning. The next
# migration retries cleanup before checking that Bifrost is already running.
fresh
seed_orig_state
echo old >"$BIFROST_STATE/before"
# shellcheck disable=SC2329
rm() {
    [ "${2:-}" != "$_BIFROST_MIGRATION/backup" ] || return 1
    command rm "$@"
}
ok cleanup-pending-queued act_migrate
bg_drain
eq cleanup-pending-success "true true" "$(jq -r '[.ok,.data.backup_cleanup_pending]|@tsv' "$jf" | tr '\t' ' ')"
has cleanup-pending-warning "backup cleanup pending" "$(cat "$BIFROST_LOG")"
ok cleanup-pending-running daemon_running
eq cleanup-pending-key old "$(cat "$_BIFROST_MIGRATION/backup/before")"
unset -f rm
ok retry-cleanup-queued act_migrate
bg_drain
eq retry-cleanup-running already_running "$(jq -r .code "$jf")"
no retry-cleanup-no-key [ -e "$_BIFROST_MIGRATION" ]
eq retry-cleanup-active-state ORIG-STATE-DATA "$(cat "$BIFROST_STATE/tailscaled.state")"
daemon_stop

# After the commit marker, a power cut must never bring the original back.
fresh
seed_orig_state
seed_orig_config
pidof_set tailscaled 7777
job_begin migrate
no committed-worker-killed env BIFROST_MIGRATE_AUTOSTOP=1 sh "$FIX/interrupted-migration.sh" KILL committed
ok committed-signal-fired [ -e "$MOCK_STATE/interrupted" ]
ok committed-replay t_call start
no committed-original-remains-down orig_running
ok committed-bifrost-running daemon_running
eq committed-keeps-new-state ORIG-STATE-DATA "$(cat "$BIFROST_STATE/tailscaled.state")"
no committed-clears-journal [ -e "$_BIFROST_MIGRATION" ]
daemon_stop
t_done
