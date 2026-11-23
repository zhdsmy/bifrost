#!/bin/sh
# Tests for plugin/bifrost/lib/migrate.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

p3_stubs() {
    fw_apply() { echo "fw_apply" >>"$MOCK_STATE/p3.log"; return 0; }
    fw_clear() { echo "fw_clear" >>"$MOCK_STATE/p3.log"; return 0; }
    fw_check() { return 0; }
    dns_apply() { echo "dns_apply" >>"$MOCK_STATE/p3.log"; return 0; }
    dns_clear() { echo "dns_clear" >>"$MOCK_STATE/p3.log"; return 0; }
    dns_check() { return 0; }
    status_refresh() { echo "status_refresh" >>"$MOCK_STATE/p3.log"; return 0; }
}

fresh() {
    t_setup
    t_load
    p3_stubs
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=1
    BIFROST_MIGRATE_AUTOSTOP=0
    BIFROST_MIGRATE_WAIT_POLL=1
    BIFROST_MIGRATE_WAIT_TIMEOUT=2
    BIFROST_MIGRATE_VERIFY_TIMEOUT=2
    BIFROST_MIGRATE_VERIFY_POLL=1
    BIFROST_MIGRATE_ORIG_STOP_TIMEOUT=2
    BIFROST_ORIG_CLI=""
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

seed_orig_state() {
    mkdir -p "$BIFROST_ORIG_STATE/files"
    printf 'ORIG-STATE-DATA\n' >"$BIFROST_ORIG_STATE/tailscaled.state"
    printf '{"regions":{}}\n' >"$BIFROST_ORIG_STATE/derpmap.cached.json"
    printf 'should-not-copy\n' >"$BIFROST_ORIG_STATE/files/a.txt"
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
    cat >"$BIFROST_ORIG_CONFIG" <<EOF
#!/bin/sh
echo "ORIG_CFG \$*" >>"$MOCK_STATE/orig_cfg.log"
case "\$1" in
    stop) rm -f "$MOCK_STATE/pidof/tailscaled" ;;
    start)
        [ "$_soc_start_rc" = 0 ] || exit "$_soc_start_rc"
        echo 7777 >"$MOCK_STATE/pidof/tailscaled"
        ;;
esac
exit 0
EOF
    chmod 755 "$BIFROST_ORIG_CONFIG"
}

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

# --- 3. AUTOSTOP=0: user stops original during wait_original -> success ---

fresh
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
pidof_set tailscaled 7777
BIFROST_MIGRATE_WAIT_TIMEOUT=5
(sleep 1; rm -f "$MOCK_STATE/pidof/tailscaled") &
wait_helper=$!
ok mig-manual-ok act_migrate
bg_drain
wait "$wait_helper" 2>/dev/null || true
eq mig-manual-job "false true done true false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.manual_stop) \(.data.rolled_back)"' "$jf")"
ok mig-manual-running daemon_running
eq mig-manual-enabled 1 "$(cfg bifrost_enable)"
eq mig-manual-state-copied "ORIG-STATE-DATA" "$(cat "$BIFROST_STATE/tailscaled.state")"
# shellcheck disable=SC2012
eq mig-manual-state-mode "-rw-------" "$(ls -l "$BIFROST_STATE/tailscaled.state" | cut -c1-10)"
# shellcheck disable=SC2012
eq mig-manual-derp-mode "-rw-------" "$(ls -l "$BIFROST_STATE/derpmap.cached.json" | cut -c1-10)"
no mig-manual-no-files [ -e "$BIFROST_STATE/files" ]
# Original untouched
eq mig-manual-orig-intact "ORIG-STATE-DATA" "$(cat "$BIFROST_ORIG_STATE/tailscaled.state")"
ok mig-manual-record-saved [ -f "$BIFROST_RUN/migrate/record.json" ]
daemon_stop

# --- 4. Success when original was already stopped (no record, state-only verify) ---

fresh
seed_orig_state
ok mig-stopped-orig act_migrate
bg_drain
eq mig-stopped-orig-ok true "$(jq -r .ok "$jf")"
ok mig-stopped-orig-running daemon_running
daemon_stop

# --- 5. Verification failure (ID/key mismatch) -> rollback restores backup ---

fresh
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
pidof_set tailscaled 7777
echo "OLD_BIFROST" >"$BIFROST_STATE/old.txt"
ts_out status '{"BackendState":"Running","Self":{"ID":"nDIFFERENT","PublicKey":"nodekey:9999"}}'
BIFROST_MIGRATE_WAIT_TIMEOUT=5
(sleep 1; rm -f "$MOCK_STATE/pidof/tailscaled") &
wait_helper=$!
ok mig-verify-fail-start act_migrate
bg_drain
wait "$wait_helper" 2>/dev/null || true
eq mig-verify-fail-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
no mig-verify-fail-stopped daemon_running
eq mig-verify-fail-disabled 0 "$(cfg bifrost_enable)"
eq mig-verify-fail-backup-restored "OLD_BIFROST" "$(cat "$BIFROST_STATE/old.txt")"
no mig-verify-fail-no-copied [ -f "$BIFROST_STATE/tailscaled.state" ]

# --- 6. AUTOSTOP=1: success ---

fresh
BIFROST_MIGRATE_AUTOSTOP=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 0
pidof_set tailscaled 7777
ok mig-auto-ok act_migrate
bg_drain
eq mig-auto-job "false true done false false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.manual_stop) \(.data.rolled_back)"' "$jf")"
has mig-auto-stopped-orig "ORIG_CFG stop" "$(cat "$MOCK_STATE/orig_cfg.log")"
eq mig-auto-orig-disabled 0 "$(dbus get tailscale_enable)"
ok mig-auto-running daemon_running
daemon_stop

# --- 7. AUTOSTOP=1: verify fails -> rollback restarts original ---

fresh
BIFROST_MIGRATE_AUTOSTOP=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 0
pidof_set tailscaled 7777
echo "PREV_STATE" >"$BIFROST_STATE/prev.txt"
ts_out_file status "$FIX/status_needs_login.json"
ok mig-auto-rb-start act_migrate
bg_drain
eq mig-auto-rb-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
has mig-auto-rb-restarted "ORIG_CFG start" "$(cat "$MOCK_STATE/orig_cfg.log")"
eq mig-auto-rb-orig-enabled 1 "$(dbus get tailscale_enable)"
ok mig-auto-rb-orig-running orig_running
eq mig-auto-rb-restored "PREV_STATE" "$(cat "$BIFROST_STATE/prev.txt")"

# --- 8. AUTOSTOP=1: rollback itself fails -> migrate_rollback_failed ---

fresh
BIFROST_MIGRATE_AUTOSTOP=1
seed_orig_state
seed_orig_cli "$FIX/status_running.json"
seed_orig_config 1
pidof_set tailscaled 7777
ts_out_file status "$FIX/status_needs_login.json"
ok mig-rb-fail-start act_migrate
bg_drain
eq mig-rb-fail-job "false migrate_rollback_failed false" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"

# --- 9. daemon_start failure during migration -> rollback restores backup ---

fresh
seed_orig_state
echo "BEFORE_MIG" >"$BIFROST_STATE/before.txt"
: >"$MOCK_STATE/daemon.fail"
ok mig-start-fail-go act_migrate
bg_drain
eq mig-start-fail-job "false migrate_verify_failed true" \
    "$(jq -r '"\(.ok) \(.code) \(.data.rolled_back)"' "$jf")"
eq mig-start-fail-restored "BEFORE_MIG" "$(cat "$BIFROST_STATE/before.txt")"
eq mig-start-fail-disabled 0 "$(cfg bifrost_enable)"

# --- 10. Busy when migrate job already running ---

job_begin migrate
no mig-busy act_migrate
eq mig-busy-err busy "$BIFROST_ERR"
job_end migrate ok

t_done
