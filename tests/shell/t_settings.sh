#!/bin/sh
# Tests for plugin/bifrost/lib/settings.sh (integrated with real P1/P3 libs).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

fresh() {
    t_setup
    t_load
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=1
    BIFROST_FW_RETRY_SLEEP=0
    BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
    printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
    nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 http_enable=0 http_lanport=80
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

# --- 1. Stopped daemon: prefs keys -> not_running; dbus keys (incl. magicdns) save cleanly ---

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

# Dbus keys work while daemon is stopped (no restart job, no fw_apply, no dns_apply)
: >"$MOCK_STATE/iptables.log"
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

ok set-local-stopped act_set local_access 0
eq set-local-stopped-res '{"value":false}' "$BIFROST_RESULT"
eq set-local-stopped-no-ipt "" "$(cat "$MOCK_STATE/iptables.log")"
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

# magicdns while stopped ONLY saves to dbus (real dns_apply is NOT called!)
ok set-dns-stopped act_set magicdns 1
eq set-dns-stopped-res '{"value":true}' "$BIFROST_RESULT"
eq set-dns-stopped-db 1 "$(cfg bifrost_magicdns)"
no set-dns-stopped-no-file [ -f "$BIFROST_DNSMASQ_CONF" ]
no set-dns-bad act_set magicdns nope
eq set-dns-bad-err invalid_param "$BIFROST_ERR"
eq set-dns-unchanged 1 "$(cfg bifrost_magicdns)"

ok set-mirror-ok act_set mirror "https://mirror.example.com/gh/"
eq set-mirror-res '{"value":"https://mirror.example.com/gh/"}' "$BIFROST_RESULT"
no set-mirror-bad act_set mirror "http://mirror.example.com/"
eq set-mirror-bad-err invalid_param "$BIFROST_ERR"
eq set-mirror-unchanged "https://mirror.example.com/gh/" "$(cfg bifrost_mirror)"
ok set-mirror-clear act_set mirror ""
eq set-mirror-clear-res '{"value":""}' "$BIFROST_RESULT"
eq set-mirror-clear-db "" "$(cfg bifrost_mirror)"

# --- 2. Running daemon: all 4 prefs keys (ok, invalid, cli_failed, timeout, read-back fail) ---

fresh
ok start-daemon daemon_start
: >"$MOCK_STATE/ts.log"

# advertise_routes valid + read-back (excluding exit routes)
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":["192.168.1.0/24","198.51.100.0/24","0.0.0.0/0","::/0"]}'
ok set-routes-ok act_set advertise_routes "192.168.1.0/24,198.51.100.0/24"
eq set-routes-res '{"value":["192.168.1.0/24","198.51.100.0/24"]}' "$BIFROST_RESULT"
has set-routes-cli "set --advertise-routes=192.168.1.0/24,198.51.100.0/24" "$(ts_log)"

# advertise_routes clear
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":null}'
ok set-routes-clear act_set advertise_routes ""
eq set-routes-clear-res '{"value":[]}' "$BIFROST_RESULT"

# advertise_routes invalid -> no CLI call
: >"$MOCK_STATE/ts.log"
no set-routes-zero act_set advertise_routes "0.0.0.0/0"
eq set-routes-zero-err invalid_param "$BIFROST_ERR"
no set-routes-hostbits act_set advertise_routes "192.168.1.1/24"
eq set-routes-hostbits-err invalid_param "$BIFROST_ERR"
eq set-routes-bad-no-cli "" "$(ts_log)"

# advertise_exit_node ok + invalid (no CLI call) + fw_apply fail rolls back
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":["0.0.0.0/0","::/0"]}'
ok set-exit-on act_set advertise_exit_node 1
eq set-exit-on-res '{"value":true}' "$BIFROST_RESULT"
has set-exit-cli "set --advertise-exit-node=true" "$(ts_log)"
: >"$MOCK_STATE/ts.log"
no set-exit-bad act_set advertise_exit_node true
eq set-exit-bad-err invalid_param "$BIFROST_ERR"
eq set-exit-bad-no-cli "" "$(ts_log)"

# advertise_exit_node fw_apply failure fails with fw_failed and rolls back pref
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"AdvertiseRoutes":null}'
: >"$MOCK_STATE/ts.log"
echo 4 >"$MOCK_STATE/iptables.fail_count"
printf '%s\n' '-A BIFROST_INPUT' >"$MOCK_STATE/iptables.fail_match"
no set-exit-fw-fail act_set advertise_exit_node 1
eq set-exit-fw-fail-err fw_failed "$BIFROST_ERR"
has set-exit-fw-rollback "set --advertise-exit-node=false" "$(ts_log)"
ok set-exit-fw-still-valid fw_check
rm -f "$MOCK_STATE/iptables.fail_match"

# accept_routes ok + invalid (no CLI call)
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"RouteAll":true}'
ok set-acc-on act_set accept_routes 1
eq set-acc-on-res '{"value":true}' "$BIFROST_RESULT"
has set-acc-cli "set --accept-routes=true" "$(ts_log)"
: >"$MOCK_STATE/ts.log"
no set-acc-bad act_set accept_routes 9
eq set-acc-bad-err invalid_param "$BIFROST_ERR"
eq set-acc-bad-no-cli "" "$(ts_log)"

# hostname read-back returns actual prefs value, invalid -> no CLI call
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"Hostname":"actual-from-prefs"}'
ok set-host-ok act_set hostname "submitted-name"
eq set-host-readback '{"value":"actual-from-prefs"}' "$BIFROST_RESULT"
has set-host-cli "set --hostname=submitted-name" "$(ts_log)"
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":0,"NoSNAT":false,"ShieldsUp":false,"Hostname":""}'
ok set-host-clear act_set hostname ""
eq set-host-clear-res '{"value":""}' "$BIFROST_RESULT"
: >"$MOCK_STATE/ts.log"
no set-host-bad act_set hostname "-bad-"
eq set-host-bad-err invalid_param "$BIFROST_ERR"
eq set-host-bad-no-cli "" "$(ts_log)"

# All 4 prefs keys: tailscale set failure -> cli_failed
ts_rc set 1
for kv in "advertise_routes:192.168.1.0/24" "advertise_exit_node:1" "accept_routes:1" "hostname:router1"; do
    k=${kv%%:*}
    v=${kv#*:}
    no "set-$k-clifail" act_set "$k" "$v"
    eq "set-$k-clifail-err" cli_failed "$BIFROST_ERR"
done
rm -f "$MOCK_STATE/ts/set.rc"

# All 4 prefs keys: read-back failure preserves real cli_failed (not internal!)
ts_rc debug-prefs 1
for kv in "advertise_routes:192.168.1.0/24" "advertise_exit_node:1" "accept_routes:1" "hostname:router1"; do
    k=${kv%%:*}
    v=${kv#*:}
    no "set-$k-rbfail" act_set "$k" "$v"
    eq "set-$k-rbfail-err" cli_failed "$BIFROST_ERR"
done
rm -f "$MOCK_STATE/ts/debug-prefs.rc"

# All 4 prefs keys: tailscale set timeout -> timeout (fault stub for ts_cli set)
# shellcheck disable=SC2329
ts_cli() {
    [ "$1" = set ] && return 124
    ts_cli_t 10 "$@"
}
for kv in "advertise_routes:192.168.1.0/24" "advertise_exit_node:1" "accept_routes:1" "hostname:router1"; do
    k=${kv%%:*}
    v=${kv#*:}
    no "set-$k-timeout" act_set "$k" "$v"
    eq "set-$k-timeout-err" timeout "$BIFROST_ERR"
done
# Read-back timeout preserves timeout (not internal!)
ts_cli() {
    [ "$1" = debug ] && return 124
    ts_cli_t 10 "$@"
}
no set-routes-rb-timeout act_set advertise_routes "192.168.1.0/24"
eq set-routes-rb-timeout-err timeout "$BIFROST_ERR"
t_load
BIFROST_FW_RETRY_SLEEP=0
BIFROST_WAIT_READY=5
BIFROST_STOP_TIMEOUT=1
BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"

# --- 3. Running daemon: real fw_apply / dns_apply + real rule rollback ---

# local_access: toggling updates real BIFROST_INPUT; failure rolls back BOTH dbus AND rules!
ok set-local-0 act_set local_access 0
eq set-local-0-res '{"value":false}' "$BIFROST_RESULT"
has set-local-0-drop "-j DROP" "$(iptables -t filter -S BIFROST_INPUT)"

# Inject 4 failures on the new rule so first fw_apply fails after flushing BIFROST_INPUT,
# then rollback fw_apply runs cleanly and restores DROP rule for local_access=0!
echo 4 >"$MOCK_STATE/iptables.fail_count"
printf '%s\n' "-A BIFROST_INPUT -i tailscale0 -j ACCEPT" >"$MOCK_STATE/iptables.fail_match"
no set-local-fw-fail act_set local_access 1
eq set-local-fw-fail-err fw_failed "$BIFROST_ERR"
eq set-local-fw-rollback-db 0 "$(cfg bifrost_local_access)"
has set-local-fw-rollback-rule "-j DROP" "$(iptables -t filter -S BIFROST_INPUT)"
ok set-local-fw-rollback-check fw_check
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"

# lan_masq: toggling updates real BIFROST_POSTROUTING; failure rolls back dbus AND rules
ok set-lan-0 act_set lan_masq 0
eq set-lan-0-res '{"value":false}' "$BIFROST_RESULT"
no set-lan-0-nomasq grep -q "MASQUERADE" "$MOCK_STATE/iptables/nat/chain.BIFROST_POSTROUTING"

echo 4 >"$MOCK_STATE/iptables.fail_count"
printf '%s\n' "-A BIFROST_POSTROUTING -o tailscale0 -j MASQUERADE" >"$MOCK_STATE/iptables.fail_match"
no set-lan-fw-fail act_set lan_masq 1
eq set-lan-fw-fail-err fw_failed "$BIFROST_ERR"
eq set-lan-fw-rollback-db 0 "$(cfg bifrost_lan_masq)"
ok set-lan-fw-rollback-check fw_check
no set-lan-fw-rollback-rule grep -q "MASQUERADE" "$MOCK_STATE/iptables/nat/chain.BIFROST_POSTROUTING"
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"

# snat: toggling updates real BIFROST_FORWARD MARK; failure rolls back dbus AND rules
ok set-snat-off act_set snat off
eq set-snat-off-res '{"value":"off"}' "$BIFROST_RESULT"
no set-snat-off-nomark grep -q "0x40000" "$MOCK_STATE/iptables/filter/chain.BIFROST_FORWARD"

echo 4 >"$MOCK_STATE/iptables.fail_count"
printf '%s\n' "0x40000/0xff0000" >"$MOCK_STATE/iptables.fail_match"
no set-snat-fw-fail act_set snat on
eq set-snat-fw-fail-err fw_failed "$BIFROST_ERR"
eq set-snat-fw-rollback-db off "$(cfg bifrost_snat)"
ok set-snat-fw-rollback-check fw_check
no set-snat-fw-rollback-rule grep -q "0x40000" "$MOCK_STATE/iptables/filter/chain.BIFROST_FORWARD"
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"

# magicdns while running: real dns_apply succeeds, failure (no_conf_dir / no_magicdns) rolls back
ok set-dns-on act_set magicdns 1
eq set-dns-on-res '{"value":true}' "$BIFROST_RESULT"
eq set-dns-on-file "server=/example.ts.net/100.100.100.100" "$(cat "$BIFROST_DNSMASQ_CONF")"
ok set-dns-off act_set magicdns 0
eq set-dns-off-res '{"value":false}' "$BIFROST_RESULT"
no set-dns-off-file [ -f "$BIFROST_DNSMASQ_CONF" ]

: >"$BIFROST_DNSMASQ_MAIN"
no set-dns-noconfdir act_set magicdns 1
eq set-dns-noconfdir-err no_conf_dir "$BIFROST_ERR"
eq set-dns-noconfdir-rollback 0 "$(cfg bifrost_magicdns)"
no set-dns-noconfdir-nofile [ -f "$BIFROST_DNSMASQ_CONF" ]
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"

# Inject a partial DNS clear; rollback must re-create the real file.
ok set-dns-before-partial act_set magicdns 1
dns_clear() { rm -f "$BIFROST_DNSMASQ_CONF"; fail internal; }
no set-dns-partial act_set magicdns 0
eq set-dns-partial-code internal "$BIFROST_ERR"
eq set-dns-restored-db 1 "$(cfg bifrost_magicdns)"
ok set-dns-restored-file dns_check
t_load

# --- 4. port & no_logs while running: unchanged = no restart; changed = restart; busy & job_start fail ---

ts_out_file debug-prefs "$FIX/prefs_ok.json"
: >"$BIFROST_RUN/bg_queue"
p_same=$(daemon_pid)
ok set-port-unchanged act_set port 41641
eq set-port-unchanged-res '{"value":41641}' "$BIFROST_RESULT"
eq set-port-unchanged-noqueue "" "$(cat "$BIFROST_RUN/bg_queue")"
eq set-port-unchanged-pid "$p_same" "$(daemon_pid)"

ok set-nologs-unchanged act_set no_logs 1
eq set-nologs-unchanged-res '{"value":true}' "$BIFROST_RESULT"
eq set-nologs-unchanged-noqueue "" "$(cat "$BIFROST_RUN/bg_queue")"

# Changed port triggers daemon restart
ok set-port-run act_set port 49999
eq set-port-run-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
eq set-port-restarted 49999 "$(cfg bifrost_port)"
has set-port-daemon-arg "--port=49999" "$(cat "$MOCK_STATE/daemon.args")"
eq set-port-job-action restart "$(jq -r .data.action "$(job_file daemon)")"

# Changed no_logs triggers daemon restart
ok set-nologs-run act_set no_logs 0
eq set-nologs-run-res '{"job":"daemon"}' "$BIFROST_RESULT"
bg_drain
eq set-nologs-restarted 0 "$(cfg bifrost_no_logs)"
no set-nologs-removed-flag daemon_running_has_nologs

# Busy daemon job rejects BOTH port and no_logs without mutating dbus
job_begin daemon
no set-port-busy act_set port 48888
eq set-port-busy-err busy "$BIFROST_ERR"
eq set-port-busy-unchanged 49999 "$(cfg bifrost_port)"
no set-nologs-busy act_set no_logs 1
eq set-nologs-busy-err busy "$BIFROST_ERR"
eq set-nologs-busy-unchanged 0 "$(cfg bifrost_no_logs)"
job_end daemon ok

# job_start failure rolls back port/no_logs in dbus
job_start() { fail internal; return 1; }
no set-port-jsfail act_set port 47777
eq set-port-jsfail-err internal "$BIFROST_ERR"
eq set-port-jsfail-rollback 49999 "$(cfg bifrost_port)"
no set-nologs-jsfail act_set no_logs 1
eq set-nologs-jsfail-err internal "$BIFROST_ERR"
eq set-nologs-jsfail-rollback 0 "$(cfg bifrost_no_logs)"
t_load
BIFROST_FW_RETRY_SLEEP=0
BIFROST_WAIT_READY=5
BIFROST_STOP_TIMEOUT=1
BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"

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

# End-to-end via real dispatcher (t_page) with real status_refresh (no stderr!)
eq page-set-mirror '{"ok":true,"value":""}' "$(t_page set mirror -)"
eq page-set-bad '{"ok":false,"code":"invalid_param"}' "$(t_page set port 80)"

daemon_stop
t_done
