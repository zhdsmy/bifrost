#!/bin/sh
# Tests for plugin/bifrost/lib/fw.sh and mock/bin/{iptables,ip6tables}.
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIXDIR="$T_SRC/tests/shell/fixtures/net"

dump_fw() {
    printf '=== iptables filter ===\n'
    iptables -t filter -S
    printf '=== iptables nat ===\n'
    iptables -t nat -S
    printf '=== ip6tables filter ===\n'
    ip6tables -t filter -S
}

reset_fw_state() {
    rm -rf "$MOCK_STATE/iptables" "$MOCK_STATE/ip6tables" \
        "$MOCK_STATE/iptables.log" "$MOCK_STATE/ip6tables.log" \
        "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match" \
        "$MOCK_STATE/iptables.drop_add" \
        "$MOCK_STATE/ip6tables.fail_count" "$MOCK_STATE/ip6tables.fail_match" \
        "$MOCK_STATE/ip6tables.drop_add" \
        "$BIFROST_RUN/fw.rules" "$BIFROST_RUN/fw6.rules" "$BIFROST_RUN/fw6.retry"
}

assert_fw_fixture() {
    _af_name=$1
    _af_file="$FIXDIR/$2"
    _af_got="$T/fw_got.txt"
    dump_fw >"$_af_got"
    if diff -u "$_af_file" "$_af_got" >"$T/fw_diff.txt"; then
        _t_pass
    else
        _t_fail "$_af_name (fixture $2)"
        head -n 40 "$T/fw_diff.txt"
    fi
}

t_setup
t_load
BIFROST_FW_RETRY_SLEEP=0

# --- lan_cidr tests ---
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0
eq lan_cidr-24 "192.168.1.0/24" "$(lan_cidr)"
nvram_seed lan_ipaddr=10.20.30.40 lan_netmask=255.255.0.0
eq lan_cidr-16 "10.20.0.0/16" "$(lan_cidr)"
nvram_seed lan_ipaddr=192.168.1.130 lan_netmask=255.255.255.128
eq lan_cidr-25 "192.168.1.128/25" "$(lan_cidr)"
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.0.255.0
no lan_cidr-noncontig lan_cidr
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=0.0.0.0
no lan_cidr-zero-mask lan_cidr
nvram_seed 'lan_ipaddr=bad;id' lan_netmask=255.255.255.0
no lan_cidr-bad-ip lan_cidr

# --- Full setting combination matrix (64 combinations vs golden fixtures) ---
sock_up
nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 http_enable=0 http_lanport=80 https_lanport=8443

for la in 0 1; do
    for masq in 0 1; do
        for snat_case in auto:1:0 auto:3:1 on:1:1 off:3:0; do
            snat_cfg=${snat_case%%:*}
            _rest=${snat_case#*:}
            sw_val=${_rest%%:*}
            snat_eff=${_rest#*:}
            for is_exit in 0 1; do
                for has_ip in 0 1; do
                    reset_fw_state
                    dbus_seed bifrost_port=41641 "bifrost_local_access=$la" \
                        "bifrost_lan_masq=$masq" "bifrost_snat=$snat_cfg"
                    nvram_seed "sw_mode=$sw_val"
                    if [ "$has_ip" = 1 ]; then
                        _ips='["100.64.0.1","fd7a:115c:a1e0::1"]'
                    else
                        _ips='[]'
                    fi
                    if [ "$is_exit" = 1 ]; then
                        _exo=true
                        _papi='["http://100.64.0.1:49152","http://[fd7a:115c:a1e0::1]:49153"]'
                    else
                        _exo=false
                        _papi='["http://100.64.0.1:49152","http://[fd7a:115c:a1e0::1]:49153"]'
                    fi
                    ts_out status "{\"BackendState\":\"Running\",\"TailscaleIPs\":$_ips,\"Self\":{\"TailscaleIPs\":$_ips,\"ExitNodeOption\":$_exo,\"PeerAPIURL\":$_papi}}"
                    ts_out debug-prefs '{"AdvertiseRoutes":[]}'

                    cname="la${la}_m${masq}_${snat_cfg}_sw${sw_val}_ex${is_exit}_ip${has_ip}"
                    ok "apply-$cname" fw_apply
                    ok "check-$cname" fw_check
                    if [ "$la" = 1 ]; then
                        assert_fw_fixture "rules-$cname" "fw_la1_masq${masq}_snat${snat_eff}_ip${has_ip}.txt"
                    else
                        assert_fw_fixture "rules-$cname" "fw_la0_masq${masq}_snat${snat_eff}_exit${is_exit}.txt"
                    fi
                done
            done
        done
    done
done

# --- Verify fw_apply uses status --json --peers=false ---
: >"$MOCK_STATE/ts.log"
ok apply-peers-false-call fw_apply
has fw-uses-peers-false "status --json --peers=false" "$(ts_log)"

# --- Exit node predicate unified: requires BOTH 0.0.0.0/0 and ::/0 ---
reset_fw_state
dbus_seed bifrost_port=41641 bifrost_local_access=0 bifrost_lan_masq=1 bifrost_snat=off
nvram_seed sw_mode=1
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"],"Self":{"ExitNodeOption":false,"PeerAPIURL":["http://100.64.0.1:49152","http://[fd7a:115c:a1e0::1]:49153"]}}'
ts_out debug-prefs '{"AdvertiseRoutes":["0.0.0.0/0"]}'
ok apply-exit-only-v4 fw_apply
assert_fw_fixture rules-exit-only-v4-not-exit fw_la0_masq1_snat0_exit0.txt

ts_out debug-prefs '{"AdvertiseRoutes":["0.0.0.0/0","::/0"]}'
ok apply-exit-from-prefs fw_apply
assert_fw_fixture rules-exit-from-prefs fw_la0_masq1_snat0_exit1.txt

# --- HTTP/HTTPS admin ports & custom UDP port ---
reset_fw_state
dbus_seed bifrost_port=51234 bifrost_local_access=1 bifrost_lan_masq=1 bifrost_snat=off
nvram_seed lan_ipaddr=192.168.1.1 sw_mode=1 http_enable=2 http_lanport=8080 https_lanport=8443
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
ok apply-http-both fw_apply
assert_fw_fixture rules-http-both fw_http_both.txt

reset_fw_state
dbus_seed bifrost_port=41641 bifrost_local_access=1 bifrost_lan_masq=1 bifrost_snat=off
nvram_seed lan_ipaddr=192.168.1.1 sw_mode=1 http_enable=1 https_lanport=8443
ok apply-https-only fw_apply
assert_fw_fixture rules-https-only fw_https_only.txt

# --- Invalid dynamic values are rejected safely (no DNAT / PeerAPI injection) ---
reset_fw_state
dbus_seed bifrost_port=41641 bifrost_local_access=1 bifrost_lan_masq=1 bifrost_snat=off
nvram_seed 'lan_ipaddr=192.168.1.1;evil' sw_mode=1 http_enable=0 http_lanport=80
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
ok apply-bad-lan-ip fw_apply
assert_fw_fixture rules-bad-lan-ip fw_la1_masq1_snat0_ip0.txt

reset_fw_state
nvram_seed lan_ipaddr=192.168.1.1 sw_mode=1 http_enable=0 'http_lanport=80;id'
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
ok apply-bad-admin-port fw_apply
assert_fw_fixture rules-bad-admin-port fw_la1_masq1_snat0_ip0.txt

reset_fw_state
nvram_seed lan_ipaddr=192.168.1.1 sw_mode=1 http_enable=0 http_lanport=80
ts_out status '{"BackendState":"Running","TailscaleIPs":["203.0.113.5"]}'
ok apply-non-tailnet-ip fw_apply
assert_fw_fixture rules-non-tailnet-ip fw_la1_masq1_snat0_ip0.txt

# --- Idempotency: running fw_apply twice produces identical rules ---
reset_fw_state
dbus_seed bifrost_port=41641 bifrost_local_access=1 bifrost_lan_masq=1 bifrost_snat=auto
nvram_seed lan_ipaddr=192.168.1.1 sw_mode=1 http_enable=0 http_lanport=80
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
ok idemp-apply1 fw_apply
dump_fw >"$T/fw_1.txt"
ok idemp-apply2 fw_apply
dump_fw >"$T/fw_2.txt"
ok idemp-same diff -u "$T/fw_1.txt" "$T/fw_2.txt"

# --- Jumps pushed down across INPUT, FORWARD, nat PREROUTING, nat POSTROUTING, ip6tables ---
iptables -t filter -I INPUT 1 -j OTHER_PLUGIN
no check-input-pushed-down fw_check
ok apply-restore-input fw_apply
ok check-input-restored fw_check
eq first-input-rule "-A INPUT -j BIFROST_INPUT" "$(iptables -t filter -S INPUT | grep '^-A INPUT ' | head -n 1)"
eq one-bifrost-jump 1 "$(iptables -t filter -S INPUT | grep -c '^-A INPUT -j BIFROST_INPUT$')"
ok other-plugin-kept iptables -t filter -C INPUT -j OTHER_PLUGIN

iptables -t filter -I FORWARD 1 -j OTHER_FWD
no check-forward-pushed-down fw_check
ok apply-restore-forward fw_apply
ok check-forward-restored fw_check
eq first-fwd-rule "-A FORWARD -j BIFROST_FORWARD" "$(iptables -t filter -S FORWARD | grep '^-A FORWARD ' | head -n 1)"
ok other-fwd-kept iptables -t filter -C FORWARD -j OTHER_FWD

iptables -t nat -I PREROUTING 1 -j OTHER_PRE
no check-pre-pushed-down fw_check
ok apply-restore-pre fw_apply
ok check-pre-restored fw_check
eq first-pre-rule "-A PREROUTING -j BIFROST_PREROUTING" "$(iptables -t nat -S PREROUTING | grep '^-A PREROUTING ' | head -n 1)"
ok other-pre-kept iptables -t nat -C PREROUTING -j OTHER_PRE

iptables -t nat -I POSTROUTING 1 -j OTHER_POST
no check-post-pushed-down fw_check
ok apply-restore-post fw_apply
ok check-post-restored fw_check
eq first-post-rule "-A POSTROUTING -j BIFROST_POSTROUTING" "$(iptables -t nat -S POSTROUTING | grep '^-A POSTROUTING ' | head -n 1)"
ok other-post-kept iptables -t nat -C POSTROUTING -j OTHER_POST

ip6tables -t filter -I FORWARD 1 -j OTHER_V6
no check-v6-pushed-down fw_check
ok apply-v6-restore fw_apply
ok check-v6-restored fw_check
eq first-v6-fwd "-A FORWARD -j BIFROST_FORWARD" "$(ip6tables -t filter -S FORWARD | grep '^-A FORWARD ' | head -n 1)"

# --- Duplicate jump in parent chain causes fw_check to fail and fw_apply to deduplicate ---
iptables -t filter -A INPUT -j BIFROST_INPUT
no check-dup-jump-fails fw_check
ok apply-dedup-jump fw_apply
ok check-dedup-ok fw_check
eq dedup-count 1 "$(iptables -t filter -S INPUT | grep -c '^-A INPUT -j BIFROST_INPUT$')"

for parent in FORWARD PREROUTING POSTROUTING; do
    case "$parent" in FORWARD) table=filter ;; *) table=nat ;; esac
    iptables -t "$table" -A "$parent" -j "BIFROST_$parent"
    no "duplicate-$parent" fw_check
    ok "repair-duplicate-$parent" fw_apply
    ok "unique-$parent" _fw_jump_is_first iptables "$table" "$parent" "BIFROST_$parent"
done

iptables -A BIFROST_INPUT -p icmp -j ACCEPT
no extra-owned-rule fw_check
ok remove-extra-owned-rule fw_apply
iptables -D BIFROST_INPUT -p udp --dport 41641 -j ACCEPT
iptables -A BIFROST_INPUT -p udp --dport 41641 -j ACCEPT
no reordered-owned-rules fw_check
ok repair-owned-order fw_apply
ip6tables -D BIFROST_FORWARD -o tailscale0 -j ACCEPT
no missing-v6-rule fw_check
ok repair-v6-rule fw_apply
ok complete-both-families fw_complete

# Dynamic inputs can change without login, settings, or firewall hooks.
ts_out status '{"BackendState":"Running","TailscaleIPs":[]}'
no tailnet-ip-lost fw_check
ok apply-without-address fw_apply
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
no tailnet-ip-appeared fw_check
ok repair-new-address fw_apply
nvram_seed lan_ipaddr=192.168.1.2
no lan-address-changed fw_check
ok apply-new-lan fw_apply
ok new-dnat iptables -t nat -C BIFROST_PREROUTING -i tailscale0 -d 100.64.0.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.2
ts_rc status 124
ok unknown-address-no-repair fw_check
ok unknown-address-kept fw_apply
ok previous-dnat-on-timeout iptables -t nat -C BIFROST_PREROUTING -i tailscale0 -d 100.64.0.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.2
ts_rc status 0
nvram_seed lan_ipaddr=192.168.1.1
dbus_seed bifrost_local_access=0
ts_out debug-prefs '{"AdvertiseRoutes":[]}'
ok apply-before-exit-approval fw_apply
ts_out status '{"Self":{"ExitNodeOption":true,"PeerAPIURL":["http://100.64.0.1:49152"]}}'
no exit-approval-changed fw_check
ok apply-approved-exit fw_apply
ts_out status '{"Self":{"ExitNodeOption":true,"PeerAPIURL":["http://100.64.0.1:49153"]}}'
no peerapi-port-changed fw_check
ok apply-new-peerapi fw_apply
ok new-peerapi-port iptables -C BIFROST_INPUT -i tailscale0 -p tcp --dport 49153 -j ACCEPT
dbus_seed bifrost_local_access=1
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"]}'
ok restore-local-access fw_apply

# --- Incomplete rules detection in fw_check (item 4) ---
# 1) Static/config rule deleted from BIFROST_FORWARD while chain & jump remain
iptables -t filter -D BIFROST_FORWARD -o tailscale0 -j ACCEPT
no check-missing-fwd-rule fw_check
ok apply-heals-fwd-rule fw_apply
ok check-healed-fwd-rule fw_check

# 2) Dynamic DNAT rule deleted from BIFROST_PREROUTING
iptables -t nat -D BIFROST_PREROUTING -i tailscale0 -d 100.64.0.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.1
no check-missing-dnat-rule fw_check
ok apply-heals-dnat-rule fw_apply
ok check-healed-dnat-rule fw_check

# 3) Compare an intact, previously verified snapshot against the partial rebuild.
cp "$BIFROST_RUN/fw.rules" "$T/pre-apply.rules"
iptables -F BIFROST_FORWARD
echo 10 >"$MOCK_STATE/iptables.fail_count"
printf '%s' "-A BIFROST_FORWARD -o tailscale0 -j ACCEPT" >"$MOCK_STATE/iptables.fail_match"
BIFROST_ERR=""
no apply-mid-fail fw_apply
eq apply-mid-fail-code fw_failed "$BIFROST_ERR"
cp "$T/pre-apply.rules" "$BIFROST_RUN/fw.rules"
no check-after-mid-fail fw_check
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"
ok apply-recover-after-mid-fail fw_apply
ok check-recovered-after-mid-fail fw_check

# --- ip6tables failure does NOT block IPv4; logs and shows fw_incomplete (item 5) ---
reset_fw_state
: >"$BIFROST_LOG"
echo 4 >"$MOCK_STATE/ip6tables.fail_count"
printf '%s' '-I FORWARD 1 -j BIFROST_FORWARD' >"$MOCK_STATE/ip6tables.fail_match"
ok apply-v6-fail-keeps-v4 fw_apply
# All IPv4 rules must be intact and verifiable
ok v4-input-present iptables -t filter -C BIFROST_INPUT -i tailscale0 -j ACCEPT
ok v4-fwd-present iptables -t filter -C BIFROST_FORWARD -i tailscale0 -j ACCEPT
ok v4-dnat-present iptables -t nat -C BIFROST_PREROUTING -i tailscale0 -d 100.64.0.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.1
ok v4-jump-first _fw_jump_is_first iptables filter INPUT BIFROST_INPUT
# The page reports the degraded family. The watchdog waits before retrying.
ok v6-fail-logged grep -Fq "ip6tables apply failed" "$BIFROST_LOG"
no v6-degraded-health fw_complete
no v6-partial-input-jump ip6tables -C INPUT -j BIFROST_INPUT
no v6-partial-forward-chain ip6tables -S BIFROST_FORWARD
ok v6-deferred-watchdog fw_check
: >"$MOCK_STATE/iptables.log"
: >"$MOCK_STATE/ip6tables.log"
ok v6-deferred-apply fw_apply
eq v6-no-deferred-calls "" "$(cat "$MOCK_STATE/ip6tables.log")"
eq v6-one-failure-log 1 "$(grep -c 'ip6tables apply failed' "$BIFROST_LOG")"
echo 0 >"$BIFROST_RUN/fw6.retry"
no v6-watchdog-retry-due fw_check
rm -f "$MOCK_STATE/ip6tables.fail_count"
ok v6-recover-apply fw_apply
ok v6-recover-check fw_check
ok v6-recover-complete fw_complete
no no-v4-rebuild grep -E ' -(A|D|F|I|N|X) ' "$MOCK_STATE/iptables.log"

# Missing verification record (e.g. upgrade) must force a repair.
rm -f "$BIFROST_RUN/fw.rules"
no check-without-record fw_check
ok rebuild-missing-record fw_apply

# --- Transient -S failure on existing chain recovers via -F instead of failing -N (item 6) ---
rm -f "$BIFROST_RUN/fw.rules"
echo 1 >"$MOCK_STATE/iptables.fail_count"
printf '%s' "-S BIFROST_INPUT" >"$MOCK_STATE/iptables.fail_match"
ok transient-s-recovers fw_apply
ok transient-s-check fw_check
eq transient-s-consumed 0 "$(cat "$MOCK_STATE/iptables.fail_count")"
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"

# --- fw_clear failure path (item 16) ---
echo 10 >"$MOCK_STATE/iptables.fail_count"
printf '%s' "-X BIFROST_INPUT" >"$MOCK_STATE/iptables.fail_match"
BIFROST_ERR=""
no clear-fails-on-x fw_clear
eq clear-fails-code fw_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/iptables.fail_count" "$MOCK_STATE/iptables.fail_match"

ok failed-chain-remains iptables -S BIFROST_INPUT
no other-filter-cleared iptables -S BIFROST_FORWARD
no nat-pre-cleared iptables -t nat -S BIFROST_PREROUTING
no nat-post-cleared iptables -t nat -S BIFROST_POSTROUTING
no v6-also-cleared ip6tables -S BIFROST_INPUT
echo 1 >"$MOCK_STATE/iptables.fail_count"
printf '%s' '-S BIFROST_INPUT' >"$MOCK_STATE/iptables.fail_match"
ok transient-clear-query fw_clear
no transient-clear-removed-chain iptables -S BIFROST_INPUT

# Re-apply so we can verify clean fw_clear keeps other plugins and removes all BIFROST chains
ok reapply-before-clear fw_apply
iptables -t filter -I INPUT 2 -j KEEP_OTHER
ok clear-ok fw_clear
no check-after-clear fw_check
no no-bifrost-in-v4-filter grep -q BIFROST <<EOF
$(iptables -t filter -S)
EOF
no no-bifrost-in-v4-nat grep -q BIFROST <<EOF
$(iptables -t nat -S)
EOF
no no-bifrost-in-v6-filter grep -q BIFROST <<EOF
$(ip6tables -t filter -S)
EOF
ok clear-keeps-other iptables -t filter -C INPUT -j KEEP_OTHER
ok clear-idempotent fw_clear

# --- Retry succeeds on transient failures (<= BIFROST_FW_RETRY) ---
reset_fw_state
echo 3 >"$MOCK_STATE/iptables.fail_count"
printf '%s' "-A BIFROST_INPUT" >"$MOCK_STATE/iptables.fail_match"
ok retry-succeeds fw_apply
ok retry-check fw_check
eq retry-exhausted 0 "$(cat "$MOCK_STATE/iptables.fail_count")"

# --- Exceeding retry limit fails with fw_failed ---
reset_fw_state
echo 4 >"$MOCK_STATE/iptables.fail_count"
printf '%s' "-A BIFROST_INPUT" >"$MOCK_STATE/iptables.fail_match"
BIFROST_ERR=""
no retry-exceeded-fails fw_apply
eq retry-exceeded-code fw_failed "$BIFROST_ERR"

# --- Verification (-C) catches silently dropped rule and fails with fw_failed ---
reset_fw_state
printf '%s' "BIFROST_FORWARD -o tailscale0 -j ACCEPT" >"$MOCK_STATE/iptables.drop_add"
BIFROST_ERR=""
no verify-catches-missing fw_apply
eq verify-catches-code fw_failed "$BIFROST_ERR"

# --- Without ip6tables in PATH, IPv4 still works cleanly ---
reset_fw_state
_old_path=$PATH
mkdir -p "$T/no6bin"
for _c in "$T_SRC"/tests/shell/mock/bin/*; do
    [ "${_c##*/}" = ip6tables ] && continue
    ln -sf "$_c" "$T/no6bin/${_c##*/}"
done
PATH="$T/no6bin:/opt/bb125/bin:/opt/tools/bin"
ok no-ip6tables-apply fw_apply
ok no-ip6tables-check fw_check
no no-ip6tables-touched [ -f "$MOCK_STATE/ip6tables.log" ]
ok no-ip6tables-clear fw_clear
PATH=$_old_path

t_done
