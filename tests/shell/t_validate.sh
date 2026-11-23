#!/bin/sh
# Tests for plugin/bifrost/lib/validate.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh
t_setup
t_load

for v in 0 1 42 4294967295 9999999999; do ok "uint $v" valid_uint "$v"; done
for v in '' -1 01 1.5 ' 1' 12345678901 a1; do no "uint '$v'" valid_uint "$v"; done

for v in 1024 41641 65535; do ok "port $v" valid_port "$v"; done
for v in 0 80 1023 65536 '' 0x10; do no "port '$v'" valid_port "$v"; done

ok bool0 valid_bool01 0
ok bool1 valid_bool01 1
no bool2 valid_bool01 2
no boolempty valid_bool01 ''
for v in auto on off; do ok "snat $v" valid_snat "$v"; done
no "snat yes" valid_snat yes
ok lang-zh valid_lang zh-CN
ok lang-en valid_lang en
no lang-zh2 valid_lang zh
for v in dark light system; do ok "mode $v" valid_mode "$v"; done
no mode-auto valid_mode auto
ok arch-arm valid_arch arm
ok arch-arm64 valid_arch arm64
no arch-x86 valid_arch amd64

for v in login core-check job_1 a; do ok "name $v" valid_name "$v"; done
for v in '' Login 1abc 'a b' 'a;b' abcdefghijklmnopqrstuvwxyz0123456; do no "name '$v'" valid_name "$v"; done

for v in - 192.168.1.0/24,10.0.0.0/8 https://h.example/p host:443 a=b x@y; do ok "param $v" valid_param "$v"; done
# shellcheck disable=SC2016
for v in '' 'a b' 'a;b' '$(id)' 'a`b' "a'b" 'a"b' 'a|b' 'a&b' 'a*b' 'a?b'; do no "param '$v'" valid_param "$v"; done

for v in 0.0.0.0 192.168.1.1 255.255.255.255 100.64.0.1; do ok "ipv4 $v" valid_ipv4 "$v"; done
for v in '' 1.2.3 1.2.3.4.5 256.1.1.1 1.2.3.04 1..2.3 .1.2.3 1.2.3. a.b.c.d; do no "ipv4 '$v'" valid_ipv4 "$v"; done

for v in 192.168.1.0/24 10.0.0.0/8 192.168.1.1/32 172.16.0.0/12 128.0.0.0/1; do ok "cidr $v" valid_cidr4 "$v"; done
for v in 0.0.0.0/0 192.168.1.1/24 10.0.0.0/33 10.0.0.0 10.0.0.0/ 10.0.0.0/08 172.17.0.0/12; do no "cidr '$v'" valid_cidr4 "$v"; done

ok list1 valid_cidr4_list 192.168.1.0/24
ok list2 valid_cidr4_list 192.168.1.0/24,10.0.0.0/8
no list-dup valid_cidr4_list 192.168.1.0/24,192.168.1.0/24
no list-empty valid_cidr4_list ''
no list-trail valid_cidr4_list 192.168.1.0/24,
no list-bad valid_cidr4_list 192.168.1.0/24,10.0.0.1/8
l=""
i=0
while [ $i -lt 17 ]; do
    l="$l,10.$i.0.0/16"
    i=$((i + 1))
done
no list-17 valid_cidr4_list "${l#,}"
ok list-16 valid_cidr4_list "$(printf '%s' "${l#,}" | sed 's/,10\.16\.0\.0\/16$//')"

for v in router a my-router-1 A1; do ok "hostname $v" valid_hostname "$v"; done
a63=$(printf '%063d' 0 | tr 0 a)
ok hostname-63 valid_hostname "$a63"
for v in '' -a a- 'a b' a.b a_b "${a63}a"; do no "hostname '$v'" valid_hostname "$v"; done

for v in example.ts.net tail-1234.example.ts.net a.b-c.d; do ok "dns $v" valid_dns_name "$v"; done
for v in '' Example.ts.net .a a. a..b -a.b a-.b a.-b 'a b' a_b; do no "dns '$v'" valid_dns_name "$v"; done

for v in https://hs.example.com http://hs.example.com:8080 https://hs.example.com/path https://10.0.0.1:443/; do ok "server $v" valid_login_server "$v"; done
for v in '' ftp://x https:// https://user@h https://h?x=1 'https://h p' https://h:99999 https://h:1:2 https://.h https://h..x; do no "server '$v'" valid_login_server "$v"; done

ok key valid_authkey tskey-auth-abcdef1234567890
ok key-hs valid_authkey 0123456789abcdef0123456789abcdef
no key-short valid_authkey tskey-short
# shellcheck disable=SC2016
no key-bad valid_authkey 'tskey-auth-abc$def1234567890'

ok mirror valid_mirror https://mirror.example.com/
ok mirror2 valid_mirror https://mirror.example.com/gh/
no mirror-http valid_mirror http://mirror.example.com/
no mirror-noslash valid_mirror https://mirror.example.com
no mirror-q valid_mirror 'https://m.example.com/?u='

for v in 100.64.0.1 100.127.255.254 fd7a:115c:a1e0::1 fd7a:115c:a1e0:ab12:4843:cd96:6258:b240; do ok "tsip $v" valid_tailnet_ip "$v"; done
for v in 100.63.0.1 100.128.0.1 192.168.1.1 fd7a:115c:a1e1::1 'fd7a:115c:a1e0::1;x'; do no "tsip '$v'" valid_tailnet_ip "$v"; done

ok set-port valid_setting bifrost_port 41641
no set-port-bad valid_setting bifrost_port 80
ok set-mirror-empty valid_setting bifrost_mirror ''
no set-unknown valid_setting bifrost_other 1
for k in $BIFROST_KEYS_ALL; do
    ok "default $k is valid" valid_setting "$k" "$(bifrost_default "$k")"
done

t_done
