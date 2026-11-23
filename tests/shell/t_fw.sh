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
        "$MOCK_STATE/ip6tables.drop_add"
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

# --- Full setting combination matrix ---
# local_access (0,1) x lan_masq (0,1) x snat/sw_mode ((auto,1),(auto,3),(on,1),(off,3))
# x exit_node (0,1) x has_tailnet_ip (0,1) = 64 combinations, every one verified
# verbatim against fixtures under tests/shell/fixtures/net/.
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

# --- Exit node detected from debug prefs (advertised, not yet approved) ---
reset_fw_state
dbus_seed bifrost_port=41641 bifrost_local_access=0 bifrost_lan_masq=1 bifrost_snat=off
nvram_seed sw_mode=1
ts_out status '{"BackendState":"Running","TailscaleIPs":["100.64.0.1"],"Self":{"ExitNodeOption":false,"PeerAPIURL":["http://100.64.0.1:49152","http://[fd7a:115c:a1e0::1]:49153"]}}'
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

# --- Another plugin inserts jump ahead of Bifrost ---
iptables -t filter -I INPUT 1 -j OTHER_PLUGIN
no check-pushed-down fw_check
ok apply-restore-order fw_apply
ok check-restored fw_check
eq first-input-rule "-A INPUT -j BIFROST_INPUT" "$(iptables -t filter -S INPUT | grep '^-A INPUT ' | head -n 1)"
eq one-bifrost-jump 1 "$(iptables -t filter -S INPUT | grep -c '^-A INPUT -j BIFROST_INPUT$')"
ok other-plugin-kept iptables -t filter -C INPUT -j OTHER_PLUGIN

# Same for ip6tables
ip6tables -t filter -I FORWARD 1 -j OTHER_V6
no check-v6-pushed-down fw_check
ok apply-v6-restore fw_apply
ok check-v6-restored fw_check
eq first-v6-fwd "-A FORWARD -j BIFROST_FORWARD" "$(ip6tables -t filter -S FORWARD | grep '^-A FORWARD ' | head -n 1)"

# --- fw_clear removes all chains and jumps, idempotent when empty ---
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
# Other plugin rules were not touched
ok clear-keeps-other iptables -t filter -C INPUT -j OTHER_PLUGIN
# Second fw_clear on clean state still succeeds
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
