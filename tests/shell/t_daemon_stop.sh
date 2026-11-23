#!/bin/sh
# Stop contract: process, firewall, DNS and callers' persistent state.
# shellcheck disable=SC1091
. tests/shell/lib.sh
t_setup
t_load
FIX="$T_SRC/tests/shell/fixtures/runtime"
BIFROST_FW_RETRY=0
BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1
ts_out_file status "$FIX/status_running.json"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
dbus_seed bifrost_enable=1 bifrost_magicdns=1

ok start-for-survivor daemon_start
target_pid=$(daemon_pid)
BIFROST_STOP_TIMEOUT=0
# Inject a kernel that refuses both signals to this one process.
# shellcheck disable=SC2329
kill() {
    case "$1:$2" in
        "-TERM:$target_pid"|"-KILL:$target_pid") return 1 ;;
    esac
    command kill "$@"
}
rm -f "$BIFROST_PIDFILE"
: >"$MOCK_STATE/daemon.log"
no stop-survivor hook_stop
eq stop-survivor-internal internal "$BIFROST_ERR"
eq stop-survivor-pid "$target_pid" "$(daemon_pid)"
ok stop-survivor-fw-restored fw_check
ok stop-survivor-dns-restored dns_check
ok stop-survivor-socket [ -e "$BIFROST_SOCK" ]
no stop-survivor-skips-cleanup grep -q cleanup "$MOCK_STATE/daemon.log"
has hook-survivor-keeps-supervision "#$BIFROST_WATCHDOG_NAME#" "$(cru l)"

ok disable-survivor-queued act_disable
bg_drain
eq disable-survivor-code internal "$(jq -r .code "$(job_file daemon)")"
eq disable-survivor-still-enabled 1 "$(cfg bifrost_enable)"
has disable-survivor-supervised "#$BIFROST_WATCHDOG_NAME#" "$(cru l)"

echo live >"$BIFROST_STATE/test-state"
backup="$_BIFROST_MIGRATION/backup"
mkdir -p "$backup"
echo 'replacing 1 1 1 1' >"$_BIFROST_MIGRATION/record"
dbus_seed tailscale_enable=0
echo saved >"$backup/test-state"
job_begin migrate
no migration-survivor migrate_recover
eq migration-survivor-code migrate_rollback_failed "$BIFROST_ERR"
eq migration-survivor-original-disabled 0 "$(dbus get tailscale_enable)"
no migration-survivor-original-down orig_running
no restart-survivor daemon_restart
eq restart-survivor-same-pid "$target_pid" "$(daemon_pid)"
eq migration-survivor-keeps-live live "$(cat "$BIFROST_STATE/test-state")"
eq migration-survivor-keeps-backup saved "$(cat "$backup/test-state")"
ok migration-survivor-fw fw_check
ok migration-survivor-dns dns_check

rm "$_BIFROST_MIGRATION/record"
mv "$backup" "${BIFROST_STATE}.bak.123"
backup="${BIFROST_STATE}.bak.123"
rmdir "$_BIFROST_MIGRATION"
unset -f kill
BIFROST_STOP_TIMEOUT=2
# Make both clear operations fail. Check that the first error survives
# refresh and that cleanup still runs after a confirmed process exit.
echo 1 >"$MOCK_STATE/iptables.fail_count"
echo '-F BIFROST_INPUT' >"$MOCK_STATE/iptables.fail_match"
rm -f "$BIFROST_DNSMASQ_CONF"
mkdir "$BIFROST_DNSMASQ_CONF"
no stop-with-two-clear-failures daemon_stop 2>/dev/null
eq stop-first-clear-code fw_failed "$BIFROST_ERR"
no failed-stop-cleaned-pid [ -e "$BIFROST_PIDFILE" ]
no failed-stop-cleaned-socket [ -e "$BIFROST_SOCK" ]
ok restart-after-clear-error daemon_restart 2>/dev/null
ok restart-running daemon_running
ok restart-restored-fw fw_check
ok restart-new-pid [ "$(daemon_pid)" != "$target_pid" ]
has failed-stop-ran-cleanup cleanup "$(cat "$MOCK_STATE/daemon.log")"
has failed-stop-checked-dns "dns_clear failed during stop" "$(cat "$BIFROST_LOG")"
has restart-keeps-supervision "#$BIFROST_WATCHDOG_NAME#" "$(cru l)"

# DNS still cannot be cleared. A purge is retryable and
# must retain both copies of the state until network cleanup succeeds.
ok purge-failed-clear-queued act_purge
bg_drain 2>/dev/null
eq purge-dns-code internal "$(jq -r .code "$(job_file daemon)")"
eq purge-dns-disabled 0 "$(cfg bifrost_enable)"
no purge-dns-unscheduled grep -q "#$BIFROST_WATCHDOG_NAME#" "$MOCK_STATE/cru.txt"
eq purge-keeps-current live "$(cat "$BIFROST_STATE/test-state")"
eq purge-keeps-backup saved "$(cat "$backup/test-state")"
rmdir "$BIFROST_DNSMASQ_CONF"
ok purge-retry-queued act_purge
bg_drain
eq purge-retry-success true "$(jq -r .ok "$(job_file daemon)")"
no purge-retry-removes-state [ -e "$BIFROST_STATE/test-state" ]
no purge-retry-removes-backup [ -e "$backup" ]
t_done
