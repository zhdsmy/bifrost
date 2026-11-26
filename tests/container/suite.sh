#!/bin/sh
# Stage B of container integration tests: real test core + real Bifrost scripts
# against headscale v0.29.7, an official tailscale v1.104.7 peer, and a LAN host.
#
# Invoked by tests/container/run.sh when core/build.sh and P1-P3 libs are present.
# Expects env vars: HS_CTR, ROUTER_CTR, PEER_CTR, LAN_CTR, HS_URL, AUTHKEY, PKG_TAR.
set -eu

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    echo "PASS [container] $1"
}

fail_case() {
    FAIL=$((FAIL + 1))
    echo "FAIL [container] $1: ${2:-}" >&2
}

r_exec() { docker exec "$ROUTER_CTR" sh -c "$1"; }
r_exec_stdin() { docker exec -i "$ROUTER_CTR" sh -eu; }
p_exec() { docker exec "$PEER_CTR" sh -c "$1"; }
hs_exec() { docker exec "$HS_CTR" headscale "$@"; }

wait_for() {
    _wf_secs=$1
    shift
    _wf_i=0
    while [ "$_wf_i" -lt "$_wf_secs" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        _wf_i=$((_wf_i + 1))
    done
    return 1
}

r_job_done() {
    _rj_val=$(docker exec "$ROUTER_CTR" jq -r .running "$1" 2>/dev/null || true)
    [ "$_rj_val" = false ]
}

r_state_is() {
    docker exec "$ROUTER_CTR" /koolshare/scripts/bifrost_status.sh 3 >/dev/null 2>&1 || return 1
    _rs_val=$(docker exec "$ROUTER_CTR" jq -r .state /tmp/upload/bifrost_status.json 2>/dev/null || true)
    [ "$_rs_val" = "$1" ]
}

r_new_pid_alive() {
    _rp_pid=$(docker exec "$ROUTER_CTR" cat /tmp/bifrost-run/bifrostd.pid 2>/dev/null || true)
    [ -n "$_rp_pid" ] && [ "$_rp_pid" != "$1" ] && docker exec "$ROUTER_CTR" kill -0 "$_rp_pid" 2>/dev/null
}

# 1. Install the built Bifrost package using the real install.sh.
echo "==> [B1] Installing Bifrost package inside router container..."
docker cp "$PKG_TAR" "$ROUTER_CTR:/tmp/bifrost-pkg.tar.gz"
r_exec 'mkdir -p /tmp/bifrost && tar -xzf /tmp/bifrost-pkg.tar.gz -C /tmp && sh /tmp/bifrost/install.sh && rm -rf /tmp/bifrost /tmp/bifrost-pkg.tar.gz'
pass "install-package"

# 2. Enable Bifrost and log into headscale with the pre-auth key.
echo "==> [B2] Enabling Bifrost and logging in with headscale pre-auth key..."
r_exec "/koolshare/scripts/bifrost_config.sh 1 enable" >/dev/null
wait_for 30 r_job_done /tmp/upload/bifrost_daemon.json || {
    fail_case "enable-job" "daemon job did not finish"
    exit 1
}
if ! r_exec "/koolshare/scripts/bifrost_config.sh 2 login '$HS_URL' '$AUTHKEY' 0" >/dev/null ||
   ! wait_for 45 r_state_is running; then
    sh "$(dirname "$0")/diagnostics.sh" "$HS_CTR" "$ROUTER_CTR" >&2 || true
    fail_case "headscale-login" "router did not reach running state"
    exit 1
fi
pass "headscale-preauth-login-running"

# Verify key status JSON fields (contract section 6.1).
status_json=$(r_exec 'cat /tmp/upload/bifrost_status.json')
st_state=$(printf '%s' "$status_json" | jq -r '.state')
st_official=$(printf '%s' "$status_json" | jq -r '.self.official')
st_control=$(printf '%s' "$status_json" | jq -r '.self.control')
router_ts_ip=$(printf '%s' "$status_json" | jq -r '.self.ips[] | select(startswith("100."))' | head -n 1)
if [ "$st_state" = running ] && [ "$st_official" = false ] && [ "$st_control" = "$HS_URL" ] && [ -n "$router_ts_ip" ]; then
    pass "status-json-fields ($router_ts_ip)"
else
    fail_case "status-json-fields" "state=$st_state official=$st_official control=$st_control ip=$router_ts_ip"
fi

# 3. Advertise LAN subnet 192.0.2.0/24, approve in headscale, connect peer with --accept-routes.
echo "==> [B3] Advertising 192.0.2.0/24 and testing 3 SNAT modes..."
r_exec "/koolshare/scripts/bifrost_config.sh 4 set advertise_routes 192.0.2.0/24" >/dev/null
router_node_id=$(hs_exec nodes list -o json | jq -r --arg ip "$router_ts_ip" '.[] | select(.ip_addresses[]? == $ip) | .id' | head -n 1)
hs_exec nodes approve-routes -i "$router_node_id" -r "192.0.2.0/24" >/dev/null
p_exec "tailscale set --accept-routes=true" >/dev/null
peer_ts_ip=$(p_exec "tailscale ip -4" | head -n 1)

# Wait for route to propagate to peer and become reachable.
wait_for 30 p_exec "nc -w 2 192.0.2.10 18080 | grep -q ." || {
    fail_case "subnet-route-reachable" "peer cannot reach 192.0.2.10:18080"
    exit 1
}

# Mode 1: snat=on -> lan-host must see router LAN IP 192.0.2.1
r_exec "/koolshare/scripts/bifrost_config.sh 5 set snat on" >/dev/null
seen_on=$(p_exec "nc -w 3 192.0.2.10 18080" | tr -d '\r\n')
if [ "$seen_on" = "192.0.2.1" ]; then
    pass "snat-on-sees-router-lan-ip ($seen_on)"
else
    fail_case "snat-on" "want 192.0.2.1 got '$seen_on'"
fi

# Mode 2: snat=off -> lan-host must see peer tailnet IP ($peer_ts_ip)
r_exec "/koolshare/scripts/bifrost_config.sh 6 set snat off" >/dev/null
seen_off=$(p_exec "nc -w 3 192.0.2.10 18080" | tr -d '\r\n')
if [ "$seen_off" = "$peer_ts_ip" ]; then
    pass "snat-off-sees-peer-tailnet-ip ($seen_off)"
else
    fail_case "snat-off" "want $peer_ts_ip got '$seen_off'"
fi

# Mode 3a: snat=auto with sw_mode=1 (router mode) -> off -> peer tailnet IP
r_exec "nvram set sw_mode=1 && /koolshare/scripts/bifrost_config.sh 7 set snat auto" >/dev/null
seen_auto_router=$(p_exec "nc -w 3 192.0.2.10 18080" | tr -d '\r\n')
if [ "$seen_auto_router" = "$peer_ts_ip" ]; then
    pass "snat-auto-router-mode ($seen_auto_router)"
else
    fail_case "snat-auto-router-mode" "want $peer_ts_ip got '$seen_auto_router'"
fi

# Mode 3b: snat=auto with sw_mode=3 (AP mode) -> on -> router LAN IP
r_exec "nvram set sw_mode=3 && /koolshare/scripts/bifrost_config.sh 8 set snat auto" >/dev/null
seen_auto_ap=$(p_exec "nc -w 3 192.0.2.10 18080" | tr -d '\r\n')
if [ "$seen_auto_ap" = "192.0.2.1" ]; then
    pass "snat-auto-ap-mode ($seen_auto_ap)"
else
    fail_case "snat-auto-ap-mode" "want 192.0.2.1 got '$seen_auto_ap'"
fi
r_exec "nvram set sw_mode=1" >/dev/null

# 4. local_access=0 blocks router port while allowing ICMP and LAN subnet behind router.
echo "==> [B4] Testing local_access=0..."
r_exec 'socat TCP4-LISTEN:18081,reuseaddr,fork SYSTEM:"echo ROUTER_OK" >/dev/null 2>&1 &'
sleep 1
if p_exec "nc -w 3 $router_ts_ip 18081" | grep -Fq "ROUTER_OK"; then
    pass "local-access-on-allows-router-port"
else
    fail_case "local-access-on" "could not reach router TCP 18081 when local_access=1"
fi

r_exec "/koolshare/scripts/bifrost_config.sh 9 set local_access 0" >/dev/null
if p_exec "nc -w 3 $router_ts_ip 18081" 2>/dev/null | grep -Fq "ROUTER_OK"; then
    fail_case "local-access-off-blocks-router-port" "router port 18081 still reachable!"
else
    pass "local-access-off-blocks-router-port"
fi
if p_exec "ping -c 1 -W 3 $router_ts_ip" >/dev/null 2>&1; then
    pass "local-access-off-allows-icmp"
else
    fail_case "local-access-off-allows-icmp" "ping to router failed"
fi
if p_exec "nc -w 3 192.0.2.10 18080" | grep -q .; then
    pass "local-access-off-allows-lan-subnet"
else
    fail_case "local-access-off-allows-lan-subnet" "LAN host unreachable when local_access=0"
fi
r_exec "/koolshare/scripts/bifrost_config.sh 10 set local_access 1" >/dev/null

# 5. fw_clear removes every BIFROST_* chain and jump rule.
echo "==> [B5] Testing fw_clear..."
if ! r_exec 'iptables-save | grep -q BIFROST_'; then
    fail_case "fw-pre-present" "expected BIFROST_ chains before fw_clear"
fi
r_exec_stdin <<'EOF'
. /koolshare/bifrost/lib/env.sh
. /koolshare/bifrost/lib/validate.sh
. /koolshare/bifrost/lib/common.sh
. /koolshare/bifrost/lib/fw.sh
fw_clear
EOF
if r_exec 'iptables-save | grep -q BIFROST_ || ip6tables-save | grep -q BIFROST_'; then
    fail_case "fw-clear" "BIFROST_ chains still present after fw_clear"
else
    pass "fw-clear-empty"
fi
r_exec "/koolshare/scripts/bifrost_config.sh start_nat" >/dev/null

# 6. Watchdog resurrects a killed daemon.
echo "==> [B6] Testing watchdog resurrection..."
old_pid=$(r_exec 'cat /tmp/bifrost-run/bifrostd.pid')
r_exec "kill -9 $old_pid"
sleep 1
r_exec "/koolshare/scripts/bifrost_config.sh local watchdog" >/dev/null 2>&1 || true
if wait_for 30 r_new_pid_alive "$old_pid"; then
    pass "watchdog-restarted-daemon"
else
    fail_case "watchdog-restarted-daemon" "daemon was not revived by watchdog"
fi

# 7. Core update failure scenarios using a local ECDSA P-256 signed fake release.
echo "==> [B7] Testing core update failure and rollback scenarios..."
r_exec_stdin <<'EOF'
mkdir -p /tmp/fake-rel/channel-stable /tmp/fake-rel/core-1.104.7-99 /koolshare/bifrost/keys
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/fake-priv.pem 2>/dev/null
openssl ec -in /tmp/fake-priv.pem -pubout -out /koolshare/bifrost/keys/it-test.pub.pem 2>/dev/null
httpd -p 127.0.0.1:18082 -h /tmp/fake-rel
EOF

# 7a: tampered manifest -> bad_signature
r_exec_stdin <<'EOF'
jq '.serial = 99 | .tag = "core-1.104.7-99"' /koolshare/bifrost/core.json >/tmp/fake-rel/channel-stable/core.json
openssl dgst -sha256 -sign /tmp/fake-priv.pem -out /tmp/fake-rel/channel-stable/core.json.sig /tmp/fake-rel/channel-stable/core.json
jq '.serial = 100' /tmp/fake-rel/channel-stable/core.json >/tmp/fake-rel/channel-stable/core.json.t
mv /tmp/fake-rel/channel-stable/core.json.t /tmp/fake-rel/channel-stable/core.json
BIFROST_RELEASE_BASE="http://127.0.0.1:18082" BIFROST_CHANNEL_URL="http://127.0.0.1:18082/channel-stable/core.json" \
    /koolshare/scripts/bifrost_config.sh 11 core-update >/dev/null
EOF
wait_for 20 r_job_done /tmp/upload/bifrost_update.json
code_7a=$(r_exec 'jq -r .code /tmp/upload/bifrost_update.json')
if [ "$code_7a" = bad_signature ]; then
    pass "update-reject-tampered-manifest"
else
    fail_case "update-reject-tampered-manifest" "want bad_signature got $code_7a"
fi

# 7b: valid signature, tampered gz -> hash_mismatch
r_exec_stdin <<'EOF'
arch=$(jq -r '.assets | keys[0]' /koolshare/bifrost/core.json)
fname="bifrost-core-1.104.7-99-linux-${arch}.gz"
jq --arg a "$arch" --arg f "$fname" '.serial = 99 | .revision = 99 | .tag = "core-1.104.7-99" | .assets[$a].file = $f' /koolshare/bifrost/core.json >/tmp/fake-rel/channel-stable/core.json
openssl dgst -sha256 -sign /tmp/fake-priv.pem -out /tmp/fake-rel/channel-stable/core.json.sig /tmp/fake-rel/channel-stable/core.json
printf 'corrupted-core-archive\n' >/tmp/fake-rel/core-1.104.7-99/"$fname"
BIFROST_RELEASE_BASE="http://127.0.0.1:18082" BIFROST_CHANNEL_URL="http://127.0.0.1:18082/channel-stable/core.json" \
    /koolshare/scripts/bifrost_config.sh 12 core-update >/dev/null
EOF
wait_for 20 r_job_done /tmp/upload/bifrost_update.json
code_7b=$(r_exec 'jq -r .code /tmp/upload/bifrost_update.json')
if [ "$code_7b" = hash_mismatch ]; then
    pass "update-reject-tampered-core"
else
    fail_case "update-reject-tampered-core" "want hash_mismatch got $code_7b"
fi

# 7c: new core passes --version but fails to stay up -> automatic rollback to Running
r_exec_stdin <<'EOF'
arch=$(jq -r '.assets | keys[0]' /koolshare/bifrost/core.json)
tsver=$(jq -r '.tailscale' /koolshare/bifrost/core.json)
fname="bifrost-core-${tsver}-99-linux-${arch}.gz"
cat >/tmp/bad-core <<INNER
#!/bin/sh
[ "\${1:-}" = "--version" ] && { echo "$tsver"; exit 0; }
exit 1
INNER
chmod 755 /tmp/bad-core
gzip -9 -n -c /tmp/bad-core >/tmp/fake-rel/core-1.104.7-99/"$fname"
raw_sha=$(openssl dgst -sha256 -r /tmp/bad-core | cut -d ' ' -f 1)
raw_sz=$(wc -c </tmp/bad-core | tr -d ' ')
gz_sha=$(openssl dgst -sha256 -r /tmp/fake-rel/core-1.104.7-99/"$fname" | cut -d ' ' -f 1)
gz_sz=$(wc -c </tmp/fake-rel/core-1.104.7-99/"$fname" | tr -d ' ')
jq --arg a "$arch" --arg f "$fname" \
   --arg rsha "$raw_sha" --argjson rsz "$raw_sz" \
   --arg gsha "$gz_sha" --argjson gsz "$gz_sz" \
   '.serial = 99 | .revision = 99 | .tag = "core-1.104.7-99" | .assets[$a] = {file:$f, size:$gsz, sha256:$gsha, raw_size:$rsz, raw_sha256:$rsha}' \
   /koolshare/bifrost/core.json >/tmp/fake-rel/channel-stable/core.json
openssl dgst -sha256 -sign /tmp/fake-priv.pem -out /tmp/fake-rel/channel-stable/core.json.sig /tmp/fake-rel/channel-stable/core.json
BIFROST_RELEASE_BASE="http://127.0.0.1:18082" BIFROST_CHANNEL_URL="http://127.0.0.1:18082/channel-stable/core.json" \
    /koolshare/scripts/bifrost_config.sh 13 core-update >/dev/null
EOF
wait_for 90 r_job_done /tmp/upload/bifrost_update.json
code_7c=$(r_exec 'jq -r .code /tmp/upload/bifrost_update.json')
wait_for 20 r_state_is running || true
state_7c=$(r_exec 'jq -r .state /tmp/upload/bifrost_status.json')
if [ "$code_7c" = update_verify_failed ] && [ "$state_7c" = running ]; then
    pass "update-broken-core-rolled-back"
else
    fail_case "update-broken-core-rolled-back" "code=$code_7c state=$state_7c"
fi

# 8. Logout keeps the Settings-page prefs, across a restart, for the next login (PLAN 7.5).
echo "==> [B8] Testing that logout keeps settings for the next login..."
r_prefs() { r_exec '/koolshare/bin/bifrost debug prefs' | jq -c '{routes: .AdvertiseRoutes, accept: .RouteAll, host: .Hostname}'; }
r_saved() { r_exec '[ -f /koolshare/configs/bifrost/saved-prefs.json ]'; }
want_prefs='{"routes":["192.0.2.0/24"],"accept":true,"host":"it-router"}'
r_exec "/koolshare/scripts/bifrost_config.sh 14 set hostname it-router" >/dev/null
r_exec "/koolshare/scripts/bifrost_config.sh 15 set accept_routes 1" >/dev/null
r_exec "/koolshare/scripts/bifrost_config.sh 16 logout" >/dev/null
wait_for 20 r_state_is needs_login || true
got_prefs=$(r_prefs)
if [ "$got_prefs" = "$want_prefs" ] && r_saved; then
    pass "logout-keeps-prefs"
else
    fail_case "logout-keeps-prefs" "got $got_prefs"
fi
r_exec "/koolshare/scripts/bifrost_config.sh 17 disable" >/dev/null
wait_for 30 r_job_done /tmp/upload/bifrost_daemon.json || true
r_exec "/koolshare/scripts/bifrost_config.sh 18 enable" >/dev/null
wait_for 30 r_job_done /tmp/upload/bifrost_daemon.json || true
wait_for 20 r_state_is needs_login || true
got_prefs=$(r_prefs)
if [ "$got_prefs" = "$want_prefs" ]; then
    pass "restart-while-logged-out-keeps-prefs"
else
    fail_case "restart-while-logged-out-keeps-prefs" "got $got_prefs"
fi
r_exec "/koolshare/scripts/bifrost_config.sh 19 login '$HS_URL' '$AUTHKEY' 0" >/dev/null
if wait_for 45 r_state_is running && [ "$(r_prefs)" = "$want_prefs" ] && ! r_saved; then
    pass "login-after-logout-restores-prefs"
else
    fail_case "login-after-logout-restores-prefs" "got $(r_prefs)"
fi

# 9. Logout keeps the tags, and a login can request them (PLAN 7.5).
echo "==> [B9] Testing that logout keeps the tags for the next login..."
r_tags() {
    r_exec '/koolshare/scripts/bifrost_status.sh 20 >/dev/null && jq -c .self.tags /tmp/upload/bifrost_status.json'
}
r_tags_are() { [ "$(r_tags)" = "$1" ]; }
r_auth_url() {
    r_exec '/koolshare/scripts/bifrost_status.sh 21 >/dev/null && jq -er ".auth_url | select(. != \"\")" /tmp/upload/bifrost_status.json'
}
# Tailscale 1.104.7 dials only port 443 for 2 minutes after a control dial
# (controlhttp forceNoise443), and headscale here serves 8080. A daemon
# restart clears that, so the steps below restart between control calls.
r_restart() {
    r_exec "/koolshare/scripts/bifrost_config.sh $1 disable" >/dev/null
    wait_for 30 r_job_done /tmp/upload/bifrost_daemon.json || true
    r_exec "/koolshare/scripts/bifrost_config.sh $2 enable" >/dev/null
    wait_for 30 r_job_done /tmp/upload/bifrost_daemon.json || true
}
r_tag_node() {
    _rt_ip=$(r_exec 'jq -r ".self.ips[]" /tmp/upload/bifrost_status.json' | grep '^100\.' | head -n 1)
    _rt_id=$(hs_exec nodes list -o json | jq -r --arg ip "$_rt_ip" '.[] | select(.ip_addresses[]? == $ip) | .id' | head -n 1)
    hs_exec nodes tag -i "$_rt_id" -t tag:it >/dev/null || true
    wait_for 30 r_tags_are '["tag:it"]'
}
r_login_tags() { r_exec 'jq -c "{ok, code, tags: .data.tags, applied: .data.tags_applied}" /tmp/upload/bifrost_login.json'; }
if r_tag_node; then
    pass "admin-tags-in-status"
else
    fail_case "admin-tags-in-status" "got $(r_tags)"
fi
r_exec "/koolshare/scripts/bifrost_config.sh 22 logout" >/dev/null
wait_for 20 r_state_is needs_login || true
want_saved="{\"tags\":[\"tag:it\"],\"control\":\"$HS_URL\"}"
got_saved=$(r_exec 'jq -c "{tags, control}" /koolshare/configs/bifrost/saved-prefs.json' || true)
got_status=$(r_exec 'jq -c .saved_tags /tmp/upload/bifrost_status.json' || true)
if [ "$got_saved" = "$want_saved" ] && [ "$got_status" = "$want_saved" ]; then
    pass "logout-keeps-tags"
else
    fail_case "logout-keeps-tags" "file $got_saved status $got_status"
fi
# headscale gives no tags to a user's pre-auth key. This node was registered
# with the key and tagged by the admin: it logs in, without the tags, and the
# job reports them missing.
r_restart 23 24
r_exec "/koolshare/scripts/bifrost_config.sh 25 login '$HS_URL' '$AUTHKEY' 1" >/dev/null
wait_for 60 r_job_done /tmp/upload/bifrost_login.json || true
got_job=$(r_login_tags || true)
if [ "$got_job" = '{"ok":true,"code":null,"tags":true,"applied":false}' ] && r_state_is running && r_tags_are '[]'; then
    pass "authkey-login-reports-dropped-tags"
else
    fail_case "authkey-login-reports-dropped-tags" "job $got_job, tags $(r_tags)"
fi
# The tag owner's interactive login keeps the tags.
r_tag_node || true
r_exec "/koolshare/scripts/bifrost_config.sh 26 logout" >/dev/null
wait_for 20 r_state_is needs_login || true
r_restart 27 28
r_exec "/koolshare/scripts/bifrost_config.sh 29 login '$HS_URL' - 1" >/dev/null
auth_id=""
if wait_for 30 r_auth_url; then
    auth_id=$(r_auth_url | sed 's|.*/||')
    hs_exec auth register --user bifrost-test --auth-id "$auth_id" >/dev/null || true
fi
wait_for 60 r_job_done /tmp/upload/bifrost_login.json || true
got_job=$(r_login_tags || true)
if wait_for 30 r_tags_are '["tag:it"]' && r_state_is running && ! r_saved &&
    [ "$got_job" = '{"ok":true,"code":null,"tags":true,"applied":true}' ]; then
    pass "interactive-login-keeps-tags"
else
    fail_case "interactive-login-keeps-tags" "auth id ${auth_id:-none}, tags $(r_tags), job $got_job"
fi
# The node was tagged at registration, so headscale takes a user-key login for
# a new node and refuses the tags.
r_exec "/koolshare/scripts/bifrost_config.sh 30 logout" >/dev/null
wait_for 20 r_state_is needs_login || true
r_restart 31 32
r_exec "/koolshare/scripts/bifrost_config.sh 33 login '$HS_URL' '$AUTHKEY' 1" >/dev/null
wait_for 60 r_job_done /tmp/upload/bifrost_login.json || true
got_job=$(r_login_tags || true)
if [ "$got_job" = '{"ok":false,"code":"tags_rejected","tags":true,"applied":null}' ]; then
    pass "authkey-login-tags-rejected"
else
    fail_case "authkey-login-tags-rejected" "job $got_job"
fi

# 10. Uninstall cleanly.
echo "==> [B10] Uninstalling Bifrost..."
r_exec '/koolshare/scripts/uninstall_bifrost.sh >/dev/null'
if r_exec '[ ! -e /koolshare/bifrost ] && [ -d /koolshare/configs/bifrost ]'; then
    pass "uninstall-clean-and-state-kept"
else
    fail_case "uninstall-clean-and-state-kept" "leftover files or missing state dir"
fi

echo "container Stage B: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
