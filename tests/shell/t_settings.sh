#!/bin/sh
# Tests for plugin/bifrost/lib/settings.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

p3_stubs() {
    STUB_FW_RC=0
    STUB_DNS_RC=0
    STUB_DNS_ERR=no_magicdns
    fw_apply() {
        echo "fw_apply" >>"$MOCK_STATE/p3.log"
        [ "$STUB_FW_RC" = 0 ] || { fail fw_failed; return 1; }
    }
    fw_clear() { echo "fw_clear" >>"$MOCK_STATE/p3.log"; return 0; }
    fw_check() { return 0; }
    dns_apply() {
        echo "dns_apply" >>"$MOCK_STATE/p3.log"
        [ "$STUB_DNS_RC" = 0 ] || { fail "$STUB_DNS_ERR"; return 1; }
    }
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
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

# --- 1. Stopped daemon: prefs keys return not_running; invalid values rejected ---

fresh
no set-unknown act_set unknown_key 1
eq set-unknown-err invalid_param "$BIFROST_ERR"

no set-routes-stopped act_set advertise_routes "192.168.1.0/24"
eq set-routes-stopped-err not_running "$BIFROST_ERR"
no set-exit-stopped act_set advertise_exit_node 1
eq set-exit-stopped-err not_running "$BIFROST_ERR"
no set-acc-stopped act_set accept_routes 1
eq set-acc-stopped-err not_running "$BIFROST_ERR"
no set-host-stopped act_set hostname router1
eq set-host-stopped-err not_running "$BIFROST_ERR"

# Dbus keys work while daemon is stopped (no restart job, no fw_apply)
: >"$MOCK_STATE/p3.log"
ok set-port-stopped act_set port 51820
eq set-port-stopped-res '{"value":51820}' "$BIFROST_RESULT"
eq set-port-stopped-db 51820 "$(cfg bifrost_port)"
no set-port-stopped-bad act_set port 80
eq set-port-stopped-bad-err invalid_param "$BIFROST_ERR"
eq set-port-stopped-unchanged 51820 "$(cfg bifrost_port)"

ok set-nologs-stopped act_set no_logs 0
eq set-nologs-stopped-res '{"value":false}' "$BIFROST_RESULT"
eq set-nologs-stopped-db 0 "$(cfg bifrost_no_logs)"
no set-nologs-bad act_set no_logs 2
eq set-nologs-bad-err invalid_param "$BIFROST_ERR"
eq set-nologs-unchanged 0 "$(cfg bifrost_no_logs)"

# Non-official control server locks no_logs=1 (rejects 0)
daemon_set_control_server "https://headscale.example.com"
cfg_set bifrost_no_logs 1
no set-nologs-locked act_set no_logs 0
eq set-nologs-locked-err invalid_param "$BIFROST_ERR"
eq set-nologs-locked-unchanged 1 "$(cfg bifrost_no_logs)"
ok set-nologs-locked-1 act_set no_logs 1
eq set-nologs-locked-1-res '{"value":true}' "$BIFROST_RESULT"
daemon_set_control_server ""

: >"$MOCK_STATE/p3.log"
ok set-local-stopped act_set local_access 0
eq set-local-stopped-res '{"value":false}' "$BIFROST_RESULT"
no set-local-stopped-nofw grep -q fw_apply "$MOCK_STATE/p3.log"
no set-local-bad act_set local_access yes
eq set-local-bad-err invalid_param "$BIFROST_ERR"
eq set-local-unchanged 0 "$(cfg bifrost_local_access)"

ok set-lan-stopped act_set lan_masq 0
eq set-lan-stopped-res '{"value":false}' "$BIFROST_RESULT"
no set-lan-bad act_set lan_masq 2
eq set-lan-bad-err invalid_param "$BIFROST_ERR"
eq set-lan-unchanged 0 "$(cfg bifrost_lan_masq)"

ok set-snat-stopped act_set snat on
eq set-snat-stopped-res '{"value":"on"}' "$BIFROST_RESULT"
no set-snat-bad act_set snat always
eq set-snat-bad-err invalid_param "$BIFROST_ERR"
eq set-snat-unchanged on "$(cfg bifrost_snat)"

ok set-mirror-ok act_set mirror "https://mirror.example.com/gh/"
eq set-mirror-res '{"value":"https://mirror.example.com/gh/"}' "$BIFROST_RESULT"
no set-mirror-bad act_set mirror "http://mirror.example.com/"
eq set-mirror-bad-err invalid_param "$BIFROST_ERR"
eq set-mirror-unchanged "https://mirror.example.com/gh/" "$(cfg bifrost_mirror)"
ok set-mirror-clear act_set mirror ""
eq set-mirror-clear-res '{"value":""}' "$BIFROST_RESULT"
eq set-mirror-clear-db "" "$(cfg bifrost_mirror)"

# magicdns calls dns_apply; on failure rolls back and returns error code
STUB_DNS_RC=1
STUB_DNS_ERR=no_conf_dir
no set-dns-fail act_set magicdns 1
eq set-dns-fail-err no_conf_dir "$BIFROST_ERR"
eq set-dns-rollback 0 "$(cfg bifrost_magicdns)"

STUB_DNS_RC=0
ok set-dns-ok act_set magicdns 1
eq set-dns-ok-res '{"value":true}' "$BIFROST_RESULT"
eq set-dns-ok-db 1 "$(cfg bifrost_magicdns)"
no set-dns-bad act_set magicdns nope
eq set-dns-bad-err invalid_param "$BIFROST_ERR"
eq set-dns-unchanged 1 "$(cfg bifrost_magicdns)"

# --- 2. Running daemon: prefs keys, read-back, fw_apply, daemon restart ---

fresh
ok start-daemon daemon_start
: >"$MOCK_STATE/ts.log"
: >"$MOCK_STATE/p3.log"

# advertise_routes valid + read-back (actual prefs, excluding exit routes)
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":["192.168.1.0/24","198.51.100.0/24","0.0.0.0/0","::/0"]}'
ok set-routes-ok act_set advertise_routes "192.168.1.0/24,198.51.100.0/24"
eq set-routes-res '{"value":["192.168.1.0/24","198.51.100.0/24"]}' "$BIFROST_RESULT"
has set-routes-cli "set --advertise-routes=192.168.1.0/24,198.51.100.0/24" "$(ts_log)"

# advertise_routes clear
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":null}'
ok set-routes-clear act_set advertise_routes ""
eq set-routes-clear-res '{"value":[]}' "$BIFROST_RESULT"

# advertise_routes invalid (0.0.0.0/0, host bits, duplicate)
: >"$MOCK_STATE/ts.log"
no set-routes-zero act_set advertise_routes "0.0.0.0/0"
eq set-routes-zero-err invalid_param "$BIFROST_ERR"
no set-routes-hostbits act_set advertise_routes "192.168.1.1/24"
eq set-routes-hostbits-err invalid_param "$BIFROST_ERR"
eq set-routes-bad-no-cli "" "$(ts_log)"

# advertise_exit_node
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":["0.0.0.0/0","::/0"]}'
ok set-exit-on act_set advertise_exit_node 1
eq set-exit-on-res '{"value":true}' "$BIFROST_RESULT"
has set-exit-cli "set --advertise-exit-node=true" "$(ts_log)"
no set-exit-bad act_set advertise_exit_node true
eq set-exit-bad-err invalid_param "$BIFROST_ERR"

# accept_routes
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"RouteAll":true}'
ok set-acc-on act_set accept_routes 1
eq set-acc-on-res '{"value":true}' "$BIFROST_RESULT"
has set-acc-cli "set --accept-routes=true" "$(ts_log)"
no set-acc-bad act_set accept_routes 9
eq set-acc-bad-err invalid_param "$BIFROST_ERR"

# hostname: read-back returns actual prefs value, NOT blindly the submitted string
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"Hostname":"actual-from-prefs"}'
ok set-host-ok act_set hostname "submitted-name"
eq set-host-readback '{"value":"actual-from-prefs"}' "$BIFROST_RESULT"
has set-host-cli "set --hostname=submitted-name" "$(ts_log)"
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"Hostname":""}'
ok set-host-clear act_set hostname ""
eq set-host-clear-res '{"value":""}' "$BIFROST_RESULT"
no set-host-bad act_set hostname "-bad-"
eq set-host-bad-err invalid_param "$BIFROST_ERR"

# local_access, lan_masq, snat trigger fw_apply when running; rollback on fw_apply failure
: >"$MOCK_STATE/p3.log"
ok set-local-run act_set local_access 0
eq set-local-run-res '{"value":false}' "$BIFROST_RESULT"
has set-local-fw "fw_apply" "$(cat "$MOCK_STATE/p3.log")"

: >"$MOCK_STATE/p3.log"
ok set-lan-run act_set lan_masq 0
eq set-lan-run-res '{"value":false}' "$BIFROST_RESULT"
has set-lan-fw "fw_apply" "$(cat "$MOCK_STATE/p3.log")"

: >"$MOCK_STATE/p3.log"
ok set-snat-run act_set snat off
eq set-snat-run-res '{"value":"off"}' "$BIFROST_RESULT"
has set-snat-fw "fw_apply" "$(cat "$MOCK_STATE/p3.log")"

STUB_FW_RC=1
no set-local-fw-fail act_set local_access 1
eq set-local-fw-fail-err fw_failed "$BIFROST_ERR"
eq set-local-fw-rollback 0 "$(cfg bifrost_local_access)"
STUB_FW_RC=0

# port and no_logs while running start daemon restart job
ts_out_file debug-prefs "$FIX/prefs_ok.json"
ok set-port-run act_set port 49999
eq set-port-run-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
eq set-port-restarted 49999 "$(cfg bifrost_port)"
has set-port-daemon-arg "--port=49999" "$(cat "$MOCK_STATE/daemon.args")"
eq set-port-job-action restart "$(jq -r .data.action "$(job_file daemon)")"

ok set-nologs-run act_set no_logs 0
eq set-nologs-run-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
eq set-nologs-restarted 0 "$(cfg bifrost_no_logs)"
case "$(cat "$MOCK_STATE/daemon.args")" in
    *--no-logs-no-support*) no set-nologs-removed-flag true ;;
    *) ok set-nologs-removed-flag true ;;
esac

# Busy daemon job rejects port/no_logs without mutating dbus
job_begin daemon
no set-port-busy act_set port 48888
eq set-port-busy-err busy "$BIFROST_ERR"
eq set-port-busy-unchanged 49999 "$(cfg bifrost_port)"
job_end daemon ok

# Held state lock rejects act_set with busy
BIFROST_LOCK_WAIT=0
mkdir -p "$BIFROST_RUN/lock.state"
sleep 30 &
locker=$!
echo "$locker" >"$BIFROST_RUN/lock.state/pid"
no set-lock-busy act_set mirror "https://example.com/"
eq set-lock-busy-err busy "$BIFROST_ERR"
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null || true
rm -rf "$BIFROST_RUN/lock.state"
BIFROST_LOCK_WAIT=30

# Verify via dispatcher (t_page) with "-" as empty value
eq page-set-mirror '{"ok":true,"value":""}' "$(t_page set mirror - 2>/dev/null)"
eq page-set-bad '{"ok":false,"code":"invalid_param"}' "$(t_page set port 80 2>/dev/null)"

daemon_stop
t_done
