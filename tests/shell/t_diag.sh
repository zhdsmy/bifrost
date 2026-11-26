#!/bin/sh
# Tests for plugin/bifrost/lib/diag.sh (netcheck, ping, logs, redact).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIXDIR="$T_SRC/tests/shell/fixtures/net"

t_setup
t_load
BIFROST_FW_RETRY_SLEEP=0
export BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"

# =========================================================================
# 1. redact: >= 2 positive AND >= 2 negative cases for EVERY ONE of 7 classes
# =========================================================================

# Class 1: Public IPv4 -> <ipv4> (incl. trailing period & end-of-line; keep private/tailnet/5-octet)
eq redact-ipv4-pos1 "peer <ipv4>:41641 -> <ipv4>" \
    "$(printf 'peer 203.0.113.42:41641 -> 198.51.100.7\n' | redact)"
eq redact-ipv4-pos2 "wan <ipv4> dns <ipv4>" \
    "$(printf 'wan 192.0.2.10 dns 8.8.8.8\n' | redact)"
eq redact-ipv4-pos3-period "connected to <ipv4>. next <ipv4>" \
    "$(printf 'connected to 203.0.113.5. next 198.51.100.9\n' | redact)"
eq redact-ipv4-pos4-eol "<ipv4>" \
    "$(printf '203.0.113.5\n' | redact)"
eq redact-ipv4-neg1 "lan 192.168.1.1 10.0.5.2 172.16.0.1 172.31.255.254" \
    "$(printf 'lan 192.168.1.1 10.0.5.2 172.16.0.1 172.31.255.254\n' | redact)"
eq redact-ipv4-neg2 "ts 100.64.0.1 100.100.100.100 100.127.255.254 lo 127.0.0.1 route 0.0.0.0/0 ver 1.104.7" \
    "$(printf 'ts 100.64.0.1 100.100.100.100 100.127.255.254 lo 127.0.0.1 route 0.0.0.0/0 ver 1.104.7\n' | redact)"
eq redact-ipv4-neg3 "invalid 999.1.2.3 mask 255.255.255.0 five 1.2.3.4.5" \
    "$(printf 'invalid 999.1.2.3 mask 255.255.255.0 five 1.2.3.4.5\n' | redact)"

# Class 2: IPv6 -> <ipv6> (keep fd7a:115c:a1e0::/48, ::, ::1, timestamps)
eq redact-ipv6-pos1 "ep [<ipv6>]:41641 full <ipv6>" \
    "$(printf 'ep [2001:db8::1]:41641 full 2001:0db8:85a3:0000:0000:8a2e:0370:7334\n' | redact)"
eq redact-ipv6-pos2 "ll <ipv6> mapped <ipv6> key:<ipv6>." \
    "$(printf 'll fe80::1234:56ff:fe78:9abc mapped ::ffff:203.0.113.5 key:2001:db8::2.\n' | redact)"
eq redact-ipv6-neg1 "ts fd7a:115c:a1e0::1 upper FD7A:115C:A1E0:ab12:4843:cd96:6258:b240" \
    "$(printf 'ts fd7a:115c:a1e0::1 upper FD7A:115C:A1E0:ab12:4843:cd96:6258:b240\n' | redact)"
eq redact-ipv6-neg2 "time 2026-11-23 12:34:56 default ::/0 lo ::1 short a:b:c" \
    "$(printf 'time 2026-11-23 12:34:56 default ::/0 lo ::1 short a:b:c\n' | redact)"

# Class 3: Email -> <email>
eq redact-email-pos1 "user <email> logged in" \
    "$(printf 'user alice@example.org logged in\n' | redact)"
eq redact-email-pos2 "owner=<email> cc <email>" \
    "$(printf 'owner=first.last+tag@sub.example.com cc bob_2@corp.example.net\n' | redact)"
eq redact-email-neg1 "local user@localhost num foo@123" \
    "$(printf 'local user@localhost num foo@123\n' | redact)"
eq redact-email-neg2 "host router.example.com device laptop-01" \
    "$(printf 'host router.example.com device laptop-01\n' | redact)"

# Class 4: MagicDNS suffix and tailnet name -> <tailnet> (keep device names!)
# Construct non-example *.ts.net at runtime so private-pattern check stays clean.
_fake_tn="tail1a2b""."ts.net
eq redact-tailnet-pos1 "fqdn router.<tailnet> suffix <tailnet>" \
    "$(printf 'fqdn router.%s suffix %s\n' "$_fake_tn" "$_fake_tn" | redact)"
eq redact-tailnet-pos2 "fqdn laptop.<tailnet> custom gw.<tailnet> org <tailnet>" \
    "$(printf 'fqdn laptop.example.ts.net custom gw.mesh.corp.internal org acme.github\n' | redact "mesh.corp.internal" "acme.github")"
eq redact-tailnet-neg1 "device router laptop-01 nas-home" \
    "$(printf 'device router laptop-01 nas-home\n' | redact "mesh.corp.internal" "acme.github")"
eq redact-tailnet-neg2 "site github.com tailscale.com file net.ts.bak" \
    "$(printf 'site github.com tailscale.com file net.ts.bak\n' | redact "mesh.corp.internal" "acme.github")"
eq short-hints-network 'tailnet=<tailnet> control: <tailnet> https://<tailnet>:8443 host.<tailnet>' \
    "$(printf 'tailnet=home control: hs https://hs:8443 host.home\n' | redact home hs)"
eq short-hints-prose 'go home with hs, then open /home/docs or household help' \
    "$(printf 'go home with hs, then open /home/docs or household help\n' | redact home hs)"
eq short-hints-fields '{"tailnet":"<tailnet>","ControlURL":"https://<tailnet>"}' \
    "$(printf '%s\n' '{"tailnet":"home","ControlURL":"https://hs"}' | redact home hs)"

# Class 5: Auth / login URLs -> <auth-url>
eq redact-authurl-pos1 "visit <auth-url> now" \
    "$(printf 'visit https://login.tailscale.com/a/0123456789abcdef now\n' | redact)"
eq redact-authurl-pos2 "hs <auth-url> prompt To authenticate, visit: <auth-url>" \
    "$(printf 'hs https://hs.example.org/register/mkey:abc123 prompt To authenticate, visit: https://auth.example.org/oidc?code=xyz\n' | redact)"
eq redact-authurl-neg1 "repo https://github.com/zhdsmy/bifrost/releases" \
    "$(printf 'repo https://github.com/zhdsmy/bifrost/releases\n' | redact)"
eq redact-authurl-neg2 "peerapi http://100.64.0.1:49152/v0/dns ctrl https://controlplane.tailscale.com" \
    "$(printf 'peerapi http://100.64.0.1:49152/v0/dns ctrl https://controlplane.tailscale.com\n' | redact)"

# Class 6: tskey- / hskey- -> <key> (split literal so check-private never matches)
_k1="tskey-auth-12345678""-abcdef90"
_k2="hskey-9876543210abcdef"
eq redact-key-pos1 "using <key> ok" \
    "$(printf 'using %s ok\n' "$_k1" | redact)"
eq redact-key-pos2 "headscale <key> client <key>" \
    "$(printf 'headscale %s client %s\n' "$_k2" "tskey-client-abc123" | redact)"
eq redact-key-neg1 "option key-value-pair word tskey" \
    "$(printf 'option key-value-pair word tskey\n' | redact)"
eq redact-key-neg2 "prefix mytskey-abc123 myhskey-def456" \
    "$(printf 'prefix mytskey-abc123 myhskey-def456\n' | redact)"

# Class 7: MAC addresses -> <mac> (do not touch IPv6 or timestamps)
eq redact-mac-pos1 "ether <mac> hw <mac>" \
    "$(printf 'ether aa:bb:cc:dd:ee:ff hw 00-1A-2B-3C-4D-5E\n' | redact)"
eq redact-mac-pos2 "br0=<mac>, eth0=<mac>" \
    "$(printf 'br0=DE:AD:BE:EF:01:23, eth0=11-22-33-44-55-66\n' | redact)"
eq redact-mac-neg1 "clock 12:34:56 invalid zz:bb:cc:dd:ee:ff" \
    "$(printf 'clock 12:34:56 invalid zz:bb:cc:dd:ee:ff\n' | redact)"
# 8-group IPv6 with hex pairs must become <ipv6>, NOT <mac>
eq redact-mac-neg2 "v6 <ipv6>" \
    "$(printf 'v6 2001:db8:aa:bb:cc:dd:ee:ff\n' | redact)"

# =========================================================================
# 2. act_ping: direct, derp, peer-relay, unknown_peer, cli_failed, timeout, not_running
# =========================================================================

# Stopped (no socket, no daemon) -> not_running for valid tailnet IP
BIFROST_ERR=""
no ping-not-running act_ping 100.64.0.2
eq ping-not-running-code not_running "$BIFROST_ERR"

# Invalid IP -> unknown_peer even before checking daemon
BIFROST_ERR=""
no ping-non-tailnet act_ping 192.168.1.1
eq ping-non-tailnet-code unknown_peer "$BIFROST_ERR"

sock_up
ts_out_file status "$FIXDIR/status_running.json"

# Valid tailnet IP not in peer list (and self IP, and ShareeNode IP) -> unknown_peer
BIFROST_ERR=""
no ping-unlisted act_ping 100.64.9.9
eq ping-unlisted-code unknown_peer "$BIFROST_ERR"
BIFROST_ERR=""
no ping-self-rejected act_ping 100.64.0.1
eq ping-self-code unknown_peer "$BIFROST_ERR"
BIFROST_ERR=""
no ping-sharee-rejected act_ping 100.64.0.99
eq ping-sharee-code unknown_peer "$BIFROST_ERR"

# Direct path (via endpoint)
ts_out ping 'pong from alpha (100.64.0.2) via 203.0.113.10:41641 in 12ms'
ts_rc ping 0
: >"$MOCK_STATE/ts.log"
BIFROST_RESULT=""
ok ping-direct act_ping 100.64.0.2
eq ping-direct-res '{"latency_ms":12,"path":"direct","relay":""}' "$BIFROST_RESULT"
has ping-flags "ping -c 1 --until-direct=false --timeout=5s 100.64.0.2" "$(ts_log)"

# DERP path (via DERP(hkg))
ts_out ping 'pong from beta (100.64.0.3, 49152) via DERP(hkg) in 35ms'
BIFROST_RESULT=""
ok ping-derp act_ping 100.64.0.3
eq ping-derp-res '{"latency_ms":35,"path":"derp","relay":"hkg"}' "$BIFROST_RESULT"

# Peer-relay path + seconds duration (1.25s -> 1250ms) + IPv6 peer IP
ts_out ping 'pong from alpha (fd7a:115c:a1e0::2) via peer-relay(198.51.100.5:41641:vni:1) in 1.25s'
BIFROST_RESULT=""
ok ping-peer-relay act_ping fd7a:115c:a1e0::2
eq ping-peer-relay-res '{"latency_ms":1250,"path":"peer-relay","relay":""}' "$BIFROST_RESULT"

# Ping non-zero exit with non-timeout error output -> cli_failed (item 18)
ts_out ping 'cannot ping peer: backend not ready'
ts_rc ping 1
BIFROST_ERR=""
no ping-cli-failed act_ping 100.64.0.2
eq ping-cli-failed-code cli_failed "$BIFROST_ERR"

# Ping timeout output -> timeout error
ts_out ping 'ping "100.64.0.2" timed out'
ts_rc ping 1
BIFROST_ERR=""
no ping-timeout act_ping 100.64.0.2
eq ping-timeout-code timeout "$BIFROST_ERR"

# Ping command hangs -> run_timeout -> timeout error
echo 5 >"$MOCK_STATE/ts/ping.sleep"
BIFROST_PING_CMD_TIMEOUT=1
BIFROST_ERR=""
no ping-cmd-timeout act_ping 100.64.0.2
eq ping-cmd-timeout-code timeout "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/ping.sleep"
BIFROST_PING_CMD_TIMEOUT=10
ts_rc ping 0

# Page dispatch end-to-end for ping
ts_out ping 'pong from alpha (100.64.0.2) via 203.0.113.10:41641 in 18ms'
eq ping-page '{"ok":true,"latency_ms":18,"path":"direct","relay":""}' "$(t_page ping 100.64.0.2)"

# =========================================================================
# 3. act_netcheck -> job_netcheck: success, outside state lock, fallback, timeout, error
# =========================================================================

ts_out_file netcheck "$FIXDIR/netcheck_ok.json"
ts_out_file debug-derp-map "$FIXDIR/derpmap.json"
ts_rc netcheck 0

# Verify job_netcheck runs cleanly even while state lock is held (item 1)
ok netcheck-hold-state-lock lock_acquire state 0
BIFROST_RESULT=""
ok netcheck-start act_netcheck
eq netcheck-start-res '{"job":"netcheck"}' "$BIFROST_RESULT"
ok netcheck-drain-while-locked bg_drain
lock_release state
NF=$(job_file netcheck)
eq netcheck-done "false true done 100" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress)"' "$NF")"
eq netcheck-fields "true true false false UPnP tok" \
    "$(jq -r '.data.report | "\(.udp) \(.ipv4) \(.ipv6) \(.mapping_varies) \(.portmap) \(.preferred_derp)"' "$NF")"
# Sorted by latency_ms ascending: derp901 (12ms), tok (30ms), hkg (55ms)
eq netcheck-derps '[{"code":"derp901","latency_ms":12},{"code":"tok","latency_ms":30},{"code":"hkg","latency_ms":55}]' \
    "$(jq -c '.data.report.derp' "$NF")"

# Netcheck with portmap all null -> "not checked" and cached derpmap fallback
ts_rc debug-derp-map 1
cp "$FIXDIR/derpmap.json" "$BIFROST_STATE/derpmap.cached.json"
ts_out netcheck '{"UDP":false,"IPv4":true,"IPv6":true,"MappingVariesByDestIP":null,"UPnP":null,"PMP":null,"PCP":null,"PreferredDERP":20,"RegionLatency":{"20":40000000}}'
ok netcheck-start2 act_netcheck
bg_drain
eq netcheck-fallback "false true true null not checked hkg" \
    "$(jq -r '.data.report | "\(.udp) \(.ipv4) \(.ipv6) \(.mapping_varies) \(.portmap) \(.preferred_derp)"' "$NF")"
ts_rc debug-derp-map 0

# Netcheck CLI failure -> cli_failed
ts_rc netcheck 1
ok netcheck-fail-start act_netcheck
no netcheck-fail-drain bg_drain
eq netcheck-fail-code "false false cli_failed" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$NF")"
ts_rc netcheck 0

# Netcheck timeout -> timeout
echo 5 >"$MOCK_STATE/ts/netcheck.sleep"
BIFROST_NETCHECK_TIMEOUT=1
ok netcheck-to-start act_netcheck
no netcheck-to-drain bg_drain
eq netcheck-to-code "false false timeout" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$NF")"
rm -f "$MOCK_STATE/ts/netcheck.sleep"
BIFROST_NETCHECK_TIMEOUT=60

# Netcheck when job is already running -> busy
job_begin netcheck
BIFROST_ERR=""
no netcheck-busy act_netcheck
eq netcheck-busy-code busy "$BIFROST_ERR"
job_end netcheck ok

# Netcheck when stopped (no socket, no daemon) -> not_running
rm -f "$BIFROST_SOCK"
BIFROST_ERR=""
no netcheck-not-running act_netcheck
eq netcheck-not-running-code not_running "$BIFROST_ERR"
sock_up

# =========================================================================
# 4. act_logs: bifrost_diag.json & bifrost_logs.txt (200-line tail, offline redaction)
# =========================================================================

# Start fake daemon so fw_complete is checked
"$BIFROST_CORE" --statedir="$BIFROST_STATE" --socket="$BIFROST_SOCK" &
FAKE_DPID=$!
echo "$FAKE_DPID" >"$BIFROST_PIDFILE"
sleep 1

dbus_seed bifrost_enable=1 bifrost_port=41641
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 wan0_ipaddr=100.64.10.20 ntp_ready=1 http_enable=0 http_lanport=80
ts_out_file status "$FIXDIR/status_running.json"
ts_out_file debug-prefs "$FIXDIR/prefs_default.json"
ok logs-fw-apply fw_apply

# Write 250 lines to bifrost.log and 260 lines to bifrostd.log with sensitive data in the tail
mkdir -p "$BIFROST_RUN"
: >"$BIFROST_LOG"
: >"$BIFROST_DLOG"
_i=1
while [ "$_i" -le 250 ]; do
    printf 'script-line-%03d\n' "$_i" >>"$BIFROST_LOG"
    _i=$((_i + 1))
done
printf 'script-secret email=alice@example.org key=%s wan=203.0.113.99.\n' "$_k1" >>"$BIFROST_LOG"

_i=1
while [ "$_i" -le 260 ]; do
    printf 'daemon-line-%03d\n' "$_i" >>"$BIFROST_DLOG"
    _i=$((_i + 1))
done
printf 'daemon-secret fqdn=router.%s auth=https://login.tailscale.com/a/deadbeef1234 mac=aa:bb:cc:dd:ee:ff v6=2001:db8::99 keep=100.64.0.1\n' "$_fake_tn" >>"$BIFROST_DLOG"
mkdir -p "$BIFROST_CRASH_DIR"
printf 'crash-body-line peer 198.51.100.23\n' >"$BIFROST_CRASH_DIR/crash-20261124-160000.txt"

ok act-logs-ok act_logs

DF="$BIFROST_UPLOAD/bifrost_diag.json"
LF="$BIFROST_UPLOAD/bifrost_logs.txt"

# Verify bifrost_diag.json schema & values (contract 6.3)
eq diag-keys '["conflict","dnsmasq_conf_dir","fw_complete","jffs_free_kb","schema","time","time_synced","tun","wan_cgnat"]' \
    "$(jq -c 'keys' "$DF")"
eq diag-values "1 true true false true true true" \
    "$(jq -r '"\(.schema) \(.tun) \(.fw_complete) \(.conflict) \(.wan_cgnat) \(.time_synced) \(.dnsmasq_conf_dir)"' "$DF")"
ok diag-jffs-int [ "$(jq -r '.jffs_free_kb' "$DF")" -ge 0 ]

# Verify bifrost_logs.txt structure (contract 6.3)
has logs-header "Redacted:" "$(head -n 1 "$LF")"
ok logs-sec-summary grep -Fqx "== summary ==" "$LF"
# Local time with its offset first, then the epoch seconds the JSON uses.
ok logs-summary-time grep -Eqx "time: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4} \($(jq -r '.time' "$DF")\)" "$LF"
ok logs-sec-script grep -Fqx "== bifrost.log ==" "$LF"
ok logs-sec-daemon grep -Fqx "== bifrostd.log ==" "$LF"
ok logs-has-backend grep -Fq "backend_state: Running" "$LF"
ok logs-sec-crash grep -Fqx "== crash records ==" "$LF"
ok logs-crash-name grep -Fqx -- "-- crash-20261124-160000.txt --" "$LF"
ok logs-crash-body grep -Fqx "crash-body-line peer <ipv4>" "$LF"

# Only last 200 lines of each log are kept (early lines 001..050 must be absent, 250/260 present)
no logs-trimmed-script-early grep -Fq "script-line-001" "$LF"
ok logs-kept-script-late grep -Fq "script-line-250" "$LF"
no logs-trimmed-daemon-early grep -Fq "daemon-line-001" "$LF"
ok logs-kept-daemon-late grep -Fq "daemon-line-260" "$LF"

# Sensitive data must NOT appear in bifrost_logs.txt; placeholders and safe data MUST appear
for bad in alice@example.org "$_k1" 203.0.113.99 "$_fake_tn" example.ts.net deadbeef1234 aa:bb:cc:dd:ee:ff 2001:db8::99; do
    no "logs-no-$bad" grep -Fq "$bad" "$LF"
done
for good in "<email>" "<key>" "<ipv4>." "router.<tailnet>" "<auth-url>" "<mac>" "<ipv6>" "100.64.0.1"; do
    ok "logs-has-$good" grep -Fq "$good" "$LF"
done

# --- 4b. Offline redaction when daemon is STOPPED and suffix is non-ts.net (item 2 & 18) ---
# First observe a self-hosted headscale run so status_refresh persists redact_hints
jq '.MagicDNSSuffix = "mesh.private.arpa" | .CurrentTailnet.Name = "corp-mesh" | .CurrentTailnet.MagicDNSSuffix = "mesh.private.arpa"' \
    "$FIXDIR/status_running.json" >"$MOCK_STATE/ts/status.out"
ts_out_file debug-prefs "$FIXDIR/prefs_headscale_exit.json"
ok offline-prime-status status_refresh

# Now stop daemon completely and remove bifrost_status.json
kill "$FAKE_DPID" 2>/dev/null
wait "$FAKE_DPID" 2>/dev/null
rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK" "$BIFROST_UPLOAD/bifrost_status.json"
printf 'failed to reach https://hs.example.org/noise for router.mesh.private.arpa in corp-mesh\n' >"$BIFROST_DLOG"
ok offline-act-logs-hints act_logs
for bad in mesh.private.arpa corp-mesh hs.example.org; do
    no "offline-hints-no-$bad" grep -Fq "$bad" "$LF"
done
ok offline-hints-keeps-device grep -Fq "router.<tailnet>" "$LF"

# Even with NO redact_hints and NO prior status, recover custom domains from control_url + dnsmasq + tailscaled.state
rm -f "$BIFROST_STATE/redact_hints" "$BIFROST_RUN/redact_hints" "$BIFROST_UPLOAD/bifrost_status.json"
printf 'https://hs-alt.example.org:8443\n' >"$BIFROST_STATE/control_url"
printf 'server=/dns.private.arpa/100.100.100.100\n' >"$BIFROST_DNSMASQ_CONF"
_prof_b64=$(printf '%s' '{"p1":{"NetworkProfile":{"MagicDNSName":"state.private.arpa","DomainName":"state-tn"},"ControlURL":"https://hs-state.example.org"}}' | base64 | tr -d '\n')
printf '{"_profiles":"%s"}\n' "$_prof_b64" >"$BIFROST_STATE/tailscaled.state"
printf 'ctrl=hs-alt.example.org dns=nas.dns.private.arpa st=box.state.private.arpa tn=state-tn srv=hs-state.example.org\n' >"$BIFROST_DLOG"
ok offline-act-logs-state act_logs
for bad in hs-alt.example.org dns.private.arpa state.private.arpa state-tn hs-state.example.org; do
    no "offline-state-no-$bad" grep -Fq "$bad" "$LF"
done
ok offline-state-keeps-hosts grep -Fq "dns=nas.<tailnet> st=box.<tailnet>" "$LF"
rm -f "$BIFROST_STATE/control_url" "$BIFROST_DNSMASQ_CONF" "$BIFROST_STATE/tailscaled.state"

# When daemon is stopped, fw_complete is null; non-CGNAT WAN -> wan_cgnat=false; missing tun -> tun=false
rm -f "$BIFROST_TUN_DEV"
nvram_seed wan0_ipaddr=203.0.113.5 ntp_ready=0
ok act-logs-stopped act_logs
eq diag-stopped "false null false false false" \
    "$(jq -r '"\(.tun) \(.fw_complete) \(.conflict) \(.wan_cgnat) \(.time_synced)"' "$DF")"

# Missing WAN IP -> wan_cgnat=null; empty logs produce (empty)
nvram unset wan0_ipaddr
nvram unset wan_ipaddr
rm -f "$BIFROST_LOG" "$BIFROST_DLOG"
ok act-logs-no-wan act_logs
eq diag-wan-null null "$(jq -r '.wan_cgnat' "$DF")"
eq logs-empty-sections 2 "$(grep -c '^(empty)$' "$LF")"

# End-to-end page dispatch for logs
eq logs-page '{"ok":true}' "$(t_page logs)"

fail_redaction() (
    # shellcheck disable=SC2329 # simulate a redactor that writes before failing.
    redact() { cat >/dev/null; printf 'partial output\n'; return 1; }
    ! act_logs && [ "$BIFROST_ERR" = internal ]
)
cp "$LF" "$T/previous-logs"
ok failed-redaction-with-previous fail_redaction
ok previous-logs-intact cmp -s "$T/previous-logs" "$LF"
rm -f "$LF"
ok failed-first-redaction fail_redaction
no partial-logs-published [ -e "$LF" ]
eq no-redaction-stage "" "$(find "$BIFROST_RUN" -name 'diag.redacted.*')"

# act_logs failure path (unwritable upload path -> internal)
_saved_upload=$BIFROST_UPLOAD
: >"$T/not-a-dir"
BIFROST_UPLOAD="$T/not-a-dir"
BIFROST_ERR=""
no act-logs-fail act_logs
eq act-logs-fail-code internal "$BIFROST_ERR"
BIFROST_UPLOAD=$_saved_upload

t_done
