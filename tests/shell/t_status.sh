#!/bin/sh
# Tests for plugin/bifrost/lib/status.sh (contract 6.1).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIXDIR="$T_SRC/tests/shell/fixtures/net"
ST_OUT=""

start_fake_daemon() {
    "$BIFROST_CORE" --statedir="$BIFROST_STATE" --socket="$BIFROST_SOCK" &
    FAKE_DPID=$!
    echo "$FAKE_DPID" >"$BIFROST_PIDFILE"
    _i=0
    while [ ! -e "$BIFROST_SOCK" ] && [ "$_i" -lt 20 ]; do
        sleep 1
        _i=$((_i + 1))
    done
}

stop_fake_daemon() {
    if [ -n "${FAKE_DPID:-}" ]; then
        kill "$FAKE_DPID" 2>/dev/null
        wait "$FAKE_DPID" 2>/dev/null
        FAKE_DPID=""
    fi
    rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
}

seed_manifest() {
    cat >"$BIFROST_MANIFEST" <<'EOF'
{"schema":1,"serial":7,"tailscale":"1.104.7","revision":1,"tag":"core-1.104.7-1","min_plugin":"0.1.0","assets":{"arm":{"file":"bifrost-core-1.104.7-1-linux-arm.gz","size":9590179,"sha256":"aa","raw_size":25100448,"raw_sha256":"bb"}}}
EOF
}

t_setup
t_load
BIFROST_FW_RETRY_SLEEP=0
ST_OUT="$BIFROST_UPLOAD/bifrost_status.json"
export BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 ntp_ready=1 http_enable=0 http_lanport=80
echo aarch64 >"$MOCK_STATE/uname_m"
seed_manifest

# --- 1. core_missing (highest precedence, even when disabled) ---
mv "$BIFROST_CORE" "$T/bifrostd.bak"
dbus_seed bifrost_enable=0
ok refresh-core-missing status_refresh
eq state-core-missing "core_missing null null null 0" \
    "$(jq -r '"\(.state) \(.error) \(.self) \(.prefs) \(.peers | length)"' "$ST_OUT")"
eq core-missing-size-inst "0 null" "$(jq -r '"\(.core.size) \(.core.installed)"' "$ST_OUT")"
mv "$T/bifrostd.bak" "$BIFROST_CORE"

# --- 2. disabled (precedes conflict, 0 CLI calls) ---
: >"$MOCK_STATE/ts.log"
dbus_seed bifrost_enable=0
pidof_set tailscaled 9999
mkdir -p "$BIFROST_ORIG_STATE"
: >"$BIFROST_ORIG_STATE/tailscaled.state"
ok refresh-disabled status_refresh
eq state-disabled "disabled null false true true" \
    "$(jq -r '"\(.state) \(.error) \(.plugin.enabled) \(.conflict.original_installed) \(.conflict.original_running)"' "$ST_OUT")"
eq disabled-no-cli 0 "$(wc -l <"$MOCK_STATE/ts.log" | tr -d ' ')"
eq disabled-self-null "null null 0" "$(jq -r '"\(.self) \(.prefs) \(.peers | length)"' "$ST_OUT")"

# --- 3. conflict (enabled=1, another tailscaled running) ---
dbus_seed bifrost_enable=1
ok refresh-conflict status_refresh
eq state-conflict "conflict null" "$(jq -r '"\(.state) \(.error)"' "$ST_OUT")"
rm -f "$MOCK_STATE/pidof/tailscaled"

# --- 4. error from $BIFROST_DAEMON_ERR (including watchdog_gave_up check) ---
echo watchdog_gave_up >"$BIFROST_DAEMON_ERR"
ok refresh-daemon-err status_refresh
eq state-daemon-err "error watchdog_gave_up" "$(jq -r '"\(.state) \(.error)"' "$ST_OUT")"
eq check-watchdog '["watchdog_gave_up"]' "$(jq -c '.checks' "$ST_OUT")"
rm -f "$BIFROST_DAEMON_ERR"

# --- 5. error start_failed (enabled=1, daemon not running) ---
ok refresh-not-running status_refresh
eq state-start-failed "error start_failed false null" \
    "$(jq -r '"\(.state) \(.error) \(.daemon.running) \(.daemon.pid)"' "$ST_OUT")"

# Start fake daemon for all live-daemon states
start_fake_daemon

# --- 6. starting: NoState and Starting ---
ts_out_file status "$FIXDIR/status_nostate.json"
ts_out_file debug-prefs "$FIXDIR/prefs_default.json"
ok refresh-nostate status_refresh
eq state-nostate "starting null" "$(jq -r '"\(.state) \(.error)"' "$ST_OUT")"

ts_out_file status "$FIXDIR/status_starting.json"
ok refresh-starting status_refresh
eq state-starting "starting null" "$(jq -r '"\(.state) \(.error)"' "$ST_OUT")"

# --- 7. needs_login (auth_url populated ONLY here) ---
ts_out_file status "$FIXDIR/status_needs_login.json"
ok refresh-needs-login status_refresh
eq state-needs-login "needs_login null https://login.example.org/a/fake1234567890" \
    "$(jq -r '"\(.state) \(.error) \(.auth_url)"' "$ST_OUT")"

# --- 8. needs_approval (auth_url cleared even if status has stale AuthURL) ---
ts_out_file status "$FIXDIR/status_needs_approval.json"
ok refresh-needs-approval status_refresh
eq state-needs-approval "needs_approval null " \
    "$(jq -r '"\(.state) \(.error) \(.auth_url)"' "$ST_OUT")"

# --- 9. stopped (auth_url cleared) ---
ts_out_file status "$FIXDIR/status_stopped.json"
ok refresh-stopped status_refresh
eq state-stopped "stopped null " \
    "$(jq -r '"\(.state) \(.error) \(.auth_url)"' "$ST_OUT")"

# --- 10. running: full schema, fields, routes, peers, core, restarts, update ---
ts_out_file status "$FIXDIR/status_running.json"
ts_out_file debug-prefs "$FIXDIR/prefs_default.json"
ok setup-fw-for-running fw_apply
# shellcheck disable=SC2153
: >"$BIFROST_BIN/bifrostd.prev.gz"
_now=$(now)
printf '%s\n%s\n%s\nbadline\n' "$((_now - 3600))" "$((_now - 600))" "$((_now - 60))" >"$BIFROST_RUN/watchdog.restarts"
cat >"$BIFROST_RUN/core_latest.json" <<'EOF'
{"schema":1,"serial":8,"tailscale":"1.105.0","revision":1,"tag":"core-1.105.0-1","min_plugin":"0.1.0","extra":"ignored"}
EOF

: >"$MOCK_STATE/ts.log"
ok refresh-running status_refresh
eq cli-at-most-2 2 "$(wc -l <"$MOCK_STATE/ts.log" | tr -d ' ')"

# Exact top-level keys match contract 6.1
eq top-keys '["auth_url","checks","conflict","core","daemon","dns","error","exit_node","health","lan","peers","plugin","prefs","routes","schema","self","settings","state","time"]' \
    "$(jq -c 'keys' "$ST_OUT")"

eq run-basic "1 running null 0.1.0 true" \
    "$(jq -r '"\(.schema) \(.state) \(.error) \(.plugin.version) \(.plugin.enabled)"' "$ST_OUT")"
eq run-core "1.104.7 1 7 arm aarch64 true 8 1.105.0" \
    "$(jq -r '"\(.core.tailscale) \(.core.revision) \(.core.serial) \(.core.arch) \(.core.kernel_arch) \(.core.prev) \(.core.update.serial) \(.core.update.tailscale)"' "$ST_OUT")"
eq run-core-update-keys '["revision","serial","tag","tailscale"]' \
    "$(jq -c '.core.update | keys' "$ST_OUT")"
ok run-core-size-pos [ "$(jq -r '.core.size' "$ST_OUT")" -gt 0 ]
ok run-core-inst-pos [ "$(jq -r '.core.installed' "$ST_OUT")" -gt 0 ]

eq run-daemon "true $FAKE_DPID 2" \
    "$(jq -r '"\(.daemon.running) \(.daemon.pid) \(.daemon.restarts)"' "$ST_OUT")"

eq run-self "router router.example.ts.net example.ts.net example.ts.net  true 2027-05-01T00:00:00Z tok true" \
    "$(jq -r '"\(.self.hostname) \(.self.dns_name) \(.self.tailnet) \(.self.magicdns_suffix) \(.self.control) \(.self.official) \(.self.key_expiry) \(.self.relay) \(.self.online)"' "$ST_OUT")"
eq run-self-ips '["100.64.0.1","fd7a:115c:a1e0::1"]' "$(jq -c '.self.ips' "$ST_OUT")"

eq run-prefs '{"accept_routes":false,"advertise_exit_node":false,"advertise_routes":["192.168.1.0/24","10.99.0.0/24"],"hostname":""}' \
    "$(jq -c '.prefs | {accept_routes,advertise_exit_node,advertise_routes,hostname}' "$ST_OUT")"
eq run-routes '[{"cidr":"192.168.1.0/24","approved":true},{"cidr":"10.99.0.0/24","approved":false}]' \
    "$(jq -c '.routes' "$ST_OUT")"
eq run-exit '{"advertised":false,"approved":false}' "$(jq -c '.exit_node' "$ST_OUT")"

eq run-settings '{"lan_masq":true,"local_access":true,"magicdns":false,"mirror":"","no_logs":true,"no_logs_forced":false,"port":41641,"snat":"auto","snat_effective":false}' \
    "$(jq -c '.settings | {lan_masq,local_access,magicdns,mirror,no_logs,no_logs_forced,port,snat,snat_effective}' "$ST_OUT")"
eq run-lan '{"cidr":"192.168.1.0/24","ip":"192.168.1.1","sw_mode":1}' \
    "$(jq -c '.lan | {cidr,ip,sw_mode}' "$ST_OUT")"
eq run-dns '{"active":false,"conf_dir":true}' "$(jq -c '.dns | {active,conf_dir}' "$ST_OUT")"
eq run-auth-empty "" "$(jq -r '.auth_url' "$ST_OUT")"
eq run-health '["some upstream health warning"]' "$(jq -c '.health' "$ST_OUT")"
eq run-checks '[]' "$(jq -c '.checks' "$ST_OUT")"

# Peers: ShareeNode excluded (3 peers left), online first then by name: alpha, zulu, beta
eq run-peers-order '["alpha","zulu","beta"]' "$(jq -c '[.peers[].name]' "$ST_OUT")"
eq run-peer-alpha "alpha.example.ts.net 100.64.0.2 macOS true direct  1795435200 1024 2048 false" \
    "$(jq -r '.peers[0] | "\(.dns_name) \(.ip) \(.os) \(.online) \(.path) \(.relay) \(.last_handshake) \(.rx) \(.tx) \(.exit_node_option)"' "$ST_OUT")"
eq run-peer-zulu "zulu.example.ts.net 100.64.0.10 linux true peer-relay  1795435200 500 600 true" \
    "$(jq -r '.peers[1] | "\(.dns_name) \(.ip) \(.os) \(.online) \(.path) \(.relay) \(.last_handshake) \(.rx) \(.tx) \(.exit_node_option)"' "$ST_OUT")"
eq run-peer-zulu-routes '["10.10.0.0/24"]' "$(jq -c '.peers[1].routes' "$ST_OUT")"
eq run-peer-beta "beta.example.ts.net 100.64.0.3 iOS false derp hkg 0 10 20 false" \
    "$(jq -r '.peers[2] | "\(.dns_name) \(.ip) \(.os) \(.online) \(.path) \(.relay) \(.last_handshake) \(.rx) \(.tx) \(.exit_node_option)"' "$ST_OUT")"
eq run-peer-beta-routes '["172.16.0.0/24"]' "$(jq -c '.peers[2].routes' "$ST_OUT")"

# Security: no private keys, node keys, Config, or user emails in status JSON
for secret in PrivateKey PrivateNodeKey NodeKey PublicKey privkey: nodekey: alice@example.org; do
    no "no-secret-$secret" grep -Fq "$secret" "$ST_OUT"
done
# Verify core_latest.json with equal/smaller serial yields update=null
cat >"$BIFROST_RUN/core_latest.json" <<'EOF'
{"schema":1,"serial":7,"tailscale":"1.104.7","revision":1,"tag":"core-1.104.7-1"}
EOF
ok refresh-no-update status_refresh
eq update-same-serial null "$(jq -r '.core.update' "$ST_OUT")"

# --- 11. Headscale control server + advertised/approved exit node + AP snat ---
ts_out_file debug-prefs "$FIXDIR/prefs_headscale_exit.json"
jq '.Self.ExitNodeOption = true | .Self.AllowedIPs += ["0.0.0.0/0", "::/0"]' "$FIXDIR/status_running.json" >"$MOCK_STATE/ts/status.out"
nvram_seed sw_mode=3
ok refresh-headscale status_refresh
eq hs-official "false https://hs.example.org true true" \
    "$(jq -r '"\(.self.official) \(.self.control) \(.settings.no_logs_forced) \(.settings.snat_effective)"' "$ST_OUT")"
eq hs-prefs-routes '["192.168.1.0/24"]' "$(jq -c '.prefs.advertise_routes' "$ST_OUT")"
eq hs-exit '{"advertised":true,"approved":true,"pref":true}' \
    "$(jq -c '{advertised:.exit_node.advertised, approved:.exit_node.approved, pref:.prefs.advertise_exit_node}' "$ST_OUT")"
eq hs-hostname "gw-home" "$(jq -r '.prefs.hostname' "$ST_OUT")"

# --- 12. All remaining checks: fw_incomplete, prefs_drift, dns_stale, clock_unsynced ---
ts_out_file status "$FIXDIR/status_running.json"
ts_out_file debug-prefs "$FIXDIR/prefs_drift.json"
fw_clear
dbus_seed bifrost_magicdns=1
nvram_seed ntp_ready=0
ok refresh-all-checks status_refresh
eq checks-four '["fw_incomplete","prefs_drift","dns_stale","clock_unsynced"]' \
    "$(jq -c '.checks' "$ST_OUT")"
# login.tailscale.com is also official
eq login-ts-official "true  false" \
    "$(jq -r '"\(.self.official) \(.self.control) \(.settings.no_logs_forced)"' "$ST_OUT")"
nvram_seed ntp_ready=1
dbus_seed bifrost_magicdns=0

# --- 13. Daemon does not answer: cli_failed, timeout, missing socket ---
ts_rc status 1
ok refresh-cli-fail status_refresh
eq cli-fail-state "error cli_failed null null 0" \
    "$(jq -r '"\(.state) \(.error) \(.self) \(.prefs) \(.peers | length)"' "$ST_OUT")"
ts_rc status 124
ok refresh-cli-timeout status_refresh
eq cli-timeout-state "error timeout null null" \
    "$(jq -r '"\(.state) \(.error) \(.self) \(.prefs)"' "$ST_OUT")"
rm -f "$BIFROST_SOCK"
ts_rc status 1
ok refresh-no-sock status_refresh
eq no-sock-starting "starting null null null" \
    "$(jq -r '"\(.state) \(.error) \(.self) \(.prefs)"' "$ST_OUT")"
sock_up
ts_rc status 0

# --- 14. Peers 500-entry cap with online-first priority ---
jq -n '
{
  BackendState: "Running",
  TailscaleIPs: ["100.64.0.1"],
  Self: {HostName: "router", DNSName: "router.example.ts.net.", TailscaleIPs: ["100.64.0.1"], Online: true},
  Peer: (
    reduce range(0; 520) as $i ({};
      .["nodekey:\($i)"] = {
        HostName: (if $i < 300 then "off-\($i)" else "on-\($i)" end),
        DNSName: "p\($i).example.ts.net.",
        OS: "linux",
        TailscaleIPs: ["100.64.\(($i / 256) | floor).\($i % 256)"],
        Online: ($i >= 300)
      }
    )
  )
}' >"$MOCK_STATE/ts/status.out"
ts_out_file debug-prefs "$FIXDIR/prefs_default.json"
ok refresh-520-peers status_refresh
eq peers-capped-500 500 "$(jq '.peers | length' "$ST_OUT")"
eq peers-online-first-220 220 "$(jq '[.peers[] | select(.online)] | length' "$ST_OUT")"
eq peers-first-is-online true "$(jq -r '.peers[0].online' "$ST_OUT")"
eq peers-220th-is-offline false "$(jq -r '.peers[220].online' "$ST_OUT")"

# --- 15. End-to-end bifrost_status.sh script & no leftover temp files ---
: >"$MOCK_STATE/resp.log"
ok status-script sh "$BIFROST_KSROOT/scripts/bifrost_status.sh" 42
eq status-script-resp '{"ok":true}' "$(t_resp)"
eq status-no-upload-tmp "" "$(find "$BIFROST_UPLOAD" -name '*tmp*')"
eq status-no-run-tmp "" "$(find "$BIFROST_RUN" -name 'status_*.json')"

stop_fake_daemon
t_done
