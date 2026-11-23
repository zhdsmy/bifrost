# shellcheck shell=sh
# Bifrost-managed iptables and ip6tables rules (PLAN section 9).
# Contract file: see docs/dev/contract.md.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.

: "${BIFROST_FW_RETRY:=3}"
: "${BIFROST_FW_RETRY_SLEEP:=1}"

# lan_cidr: print canonical LAN CIDR from nvram lan_ipaddr / lan_netmask.
lan_cidr() (
    _lc_ip=$(nvram get lan_ipaddr 2>/dev/null)
    _lc_mask=$(nvram get lan_netmask 2>/dev/null)
    valid_ipv4 "$_lc_ip" || exit 1
    valid_ipv4 "$_lc_mask" || exit 1
    IFS=.
    # shellcheck disable=SC2086
    set -- $_lc_ip $_lc_mask
    [ $# -eq 8 ] || exit 1
    _lc_i1=$1 _lc_i2=$2 _lc_i3=$3 _lc_i4=$4
    _lc_m1=$5 _lc_m2=$6 _lc_m3=$7 _lc_m4=$8
    _lc_plen=0
    _lc_zero=0
    for _lc_mo in "$_lc_m1" "$_lc_m2" "$_lc_m3" "$_lc_m4"; do
        if [ "$_lc_zero" -eq 1 ]; then
            [ "$_lc_mo" -eq 0 ] || exit 1
            continue
        fi
        case "$_lc_mo" in
            255) _lc_plen=$((_lc_plen + 8)) ;;
            254) _lc_plen=$((_lc_plen + 7)); _lc_zero=1 ;;
            252) _lc_plen=$((_lc_plen + 6)); _lc_zero=1 ;;
            248) _lc_plen=$((_lc_plen + 5)); _lc_zero=1 ;;
            240) _lc_plen=$((_lc_plen + 4)); _lc_zero=1 ;;
            224) _lc_plen=$((_lc_plen + 3)); _lc_zero=1 ;;
            192) _lc_plen=$((_lc_plen + 2)); _lc_zero=1 ;;
            128) _lc_plen=$((_lc_plen + 1)); _lc_zero=1 ;;
            0) _lc_zero=1 ;;
            *) exit 1 ;;
        esac
    done
    [ "$_lc_plen" -gt 0 ] || exit 1
    _lc_out="$((_lc_i1 & _lc_m1)).$((_lc_i2 & _lc_m2)).$((_lc_i3 & _lc_m3)).$((_lc_i4 & _lc_m4))/$_lc_plen"
    valid_cidr4 "$_lc_out" || exit 1
    printf '%s\n' "$_lc_out"
)

# fw_snat_effective: 0 when SNAT into LAN should be active, 1 otherwise.
# "auto" enables SNAT when nvram sw_mode is not 1 (router mode).
fw_snat_effective() {
    _fse_mode=$(cfg bifrost_snat)
    case "$_fse_mode" in
        on) return 0 ;;
        off) return 1 ;;
        auto)
            _fse_sw=$(nvram get sw_mode 2>/dev/null)
            [ "$_fse_sw" != 1 ]
            ;;
        *) return 1 ;;
    esac
}

# fw_exit_routes_jq: canonical jq predicate for exit-node routes (both 0.0.0.0/0
# and ::/0, matching Tailscale's tsaddr.ContainsExitRoutes / Prefs.AdvertisesExitNode).
# Shared by fw.sh and status.sh so both agree on exit-node detection.
fw_exit_routes_jq() {
    printf '%s' '((index("0.0.0.0/0") != null) and (index("::/0") != null))'
}

# _fw_run <cmd...>: run an iptables/ip6tables command, retrying on failure.
_fw_run() {
    _fr_i=0
    while :; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$_fr_i" -ge "$BIFROST_FW_RETRY" ]; then
            log fw "command failed after retries: $*"
            fail fw_failed
            return 1
        fi
        _fr_i=$((_fr_i + 1))
        if [ "$BIFROST_FW_RETRY_SLEEP" -gt 0 ]; then
            sleep "$BIFROST_FW_RETRY_SLEEP"
        fi
    done
}

# _fw_chain_exists <cmd> <table> <chain>
_fw_chain_exists() {
    "$1" -t "$2" -S "$3" >/dev/null 2>&1
}

# _fw_jump_is_first <cmd> <table> <parent> <chain>
_fw_jump_is_first() {
    "$1" -t "$2" -S "$3" 2>/dev/null | awk -v parent="$3" -v chain="$4" '
        $1 == "-A" && $2 == parent {
            rules++
            if (NF == 4 && $3 == "-j" && $4 == chain) {
                jumps++
                if (rules == 1) first = 1
            }
        }
        END { exit !(first && jumps == 1) }
    '
}

# -S may fail transiently on an existing chain. Recheck after a failed create.
_fw_prepare_chain() {
    if ! _fw_chain_exists "$1" "$2" "$3"; then
        "$1" -t "$2" -N "$3" >/dev/null 2>&1 && return 0
        _fw_chain_exists "$1" "$2" "$3" || return 1
    fi
    "$1" -t "$2" -F "$3"
}

# _fw_ensure_jump <cmd> <table> <parent> <chain>: place -j <chain> first in <parent>.
_fw_ensure_jump() {
    if _fw_jump_is_first "$1" "$2" "$3" "$4"; then
        return 0
    fi
    while "$1" -t "$2" -C "$3" -j "$4" >/dev/null 2>&1; do
        _fw_run "$1" -t "$2" -D "$3" -j "$4" || return 1
    done
    _fw_run "$1" -t "$2" -I "$3" 1 -j "$4"
}

# _fw_read_dynamic: populate _fw_ts_ip4, _fw_is_exit, _fw_peerapi4, _fw_peerapi6,
# _fw_lan_ip, _fw_admin_ports from tailscale CLI (--peers=false) and nvram,
# validating every value.
_fw_read_dynamic() {
    _fw_ts_ip4=""
    _fw_is_exit=0
    _fw_peerapi4=""
    _fw_peerapi6=""
    _fw_lan_ip=""
    _fw_admin_ports=""
    _fw_ex_jq=$(fw_exit_routes_jq)

    _fw_st=$(ts_cli status --json --peers=false 2>/dev/null) || _fw_st=""
    if [ -n "$_fw_st" ]; then
        _fw_parsed=$(printf '%s\n' "$_fw_st" | jq -r "
            ((.TailscaleIPs // .Self.TailscaleIPs // [])
                | map(select(type == \"string\" and (contains(\":\") | not)))
                | .[0] // \"-\"),
            (if (.Self.ExitNodeOption == true) or ((.Self.AllowedIPs // []) | $_fw_ex_jq) then \"1\" else \"0\" end),
            ((.Self.PeerAPIURL // [])
                | map(select(type == \"string\" and test(\"^http://[0-9.]+:[0-9]+/?$\"))
                    | sub(\"^http://[0-9.]+:\"; \"\") | sub(\"/$\"; \"\"))
                | .[0] // \"-\"),
            ((.Self.PeerAPIURL // [])
                | map(select(type == \"string\" and startswith(\"http://[\"))
                    | sub(\"/$\"; \"\") | split(\"]:\")
                    | select(length == 2 and (.[0][8:] | test(\"^[0-9A-Fa-f:]+$\")) and (.[1] | test(\"^[0-9]+$\")))
                    | .[1])
                | .[0] // \"-\")
        " 2>/dev/null)
        if [ -n "$_fw_parsed" ]; then
            _fw_r1=$(printf '%s\n' "$_fw_parsed" | sed -n '1p')
            _fw_r2=$(printf '%s\n' "$_fw_parsed" | sed -n '2p')
            _fw_r3=$(printf '%s\n' "$_fw_parsed" | sed -n '3p')
            _fw_r4=$(printf '%s\n' "$_fw_parsed" | sed -n '4p')
            if [ "$_fw_r1" != - ] && valid_ipv4 "$_fw_r1" && valid_tailnet_ip "$_fw_r1"; then
                _fw_ts_ip4=$_fw_r1
            fi
            [ "$_fw_r2" = 1 ] && _fw_is_exit=1
            if [ "$_fw_r3" != - ] && valid_uint_range "$_fw_r3" 1 65535; then
                _fw_peerapi4=$_fw_r3
            fi
            if [ "$_fw_r4" != - ] && valid_uint_range "$_fw_r4" 1 65535; then
                _fw_peerapi6=$_fw_r4
            fi
        fi
    fi

    # When local_access is off and status did not already show an approved exit
    # node, check prefs so PeerAPI is allowed even while exit-node approval is pending.
    if [ "$_fw_local_access" = 0 ] && [ "$_fw_is_exit" = 0 ]; then
        _fw_pr=$(ts_cli debug prefs 2>/dev/null) || _fw_pr=""
        if [ -n "$_fw_pr" ]; then
            _fw_adv_exit=$(printf '%s\n' "$_fw_pr" | jq -r "
                if ((.AdvertiseRoutes // []) | $_fw_ex_jq) then \"1\" else \"0\" end
            " 2>/dev/null)
            [ "$_fw_adv_exit" = 1 ] && _fw_is_exit=1
        fi
    fi

    if [ "$_fw_local_access" = 1 ]; then
        _fw_raw_lan=$(nvram get lan_ipaddr 2>/dev/null)
        if valid_ipv4 "$_fw_raw_lan"; then
            _fw_lan_ip=$_fw_raw_lan
        fi
        _fw_he=$(nvram get http_enable 2>/dev/null)
        case "$_fw_he" in
            1 | 2) ;;
            *) _fw_he=0 ;;
        esac
        _fw_hp=""
        _fw_sp=""
        if [ "$_fw_he" = 0 ] || [ "$_fw_he" = 2 ]; then
            _fw_hp=$(nvram get http_lanport 2>/dev/null)
            [ -n "$_fw_hp" ] || _fw_hp=80
            valid_uint_range "$_fw_hp" 1 65535 || _fw_hp=""
        fi
        if [ "$_fw_he" = 1 ] || [ "$_fw_he" = 2 ]; then
            _fw_sp=$(nvram get https_lanport 2>/dev/null)
            [ -n "$_fw_sp" ] || _fw_sp=8443
            valid_uint_range "$_fw_sp" 1 65535 || _fw_sp=""
        fi
        [ -n "$_fw_hp" ] && _fw_admin_ports=$_fw_hp
        if [ -n "$_fw_sp" ] && [ "$_fw_sp" != "$_fw_hp" ]; then
            _fw_admin_ports="${_fw_admin_ports:+$_fw_admin_ports }$_fw_sp"
        fi
    fi
}

# _fw_rules_v4 <-A|-C>: IPv4 rules from PLAN 9.2.
_fw_rules_v4() {
    _fp4_m=$1

    # IPv4 filter: BIFROST_INPUT
    _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -p udp --dport "$_fw_port" -j ACCEPT || return 1
    if [ "$_fw_local_access" = 1 ]; then
        _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -i "$BIFROST_TUN" -j ACCEPT || return 1
    else
        _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -i "$BIFROST_TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT || return 1
        _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -i "$BIFROST_TUN" -p icmp -j ACCEPT || return 1
        if [ "$_fw_is_exit" = 1 ] && [ -n "$_fw_peerapi4" ]; then
            _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -i "$BIFROST_TUN" -p tcp --dport "$_fw_peerapi4" -j ACCEPT || return 1
        fi
        _fw_run iptables -t filter "$_fp4_m" BIFROST_INPUT -i "$BIFROST_TUN" -j DROP || return 1
    fi

    # IPv4 filter: BIFROST_FORWARD
    if [ "$_fw_snat_on" = 1 ]; then
        _fw_run iptables -t filter "$_fp4_m" BIFROST_FORWARD -i "$BIFROST_TUN" -j MARK --set-xmark 0x40000/0xff0000 || return 1
    fi
    _fw_run iptables -t filter "$_fp4_m" BIFROST_FORWARD -i "$BIFROST_TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
    _fw_run iptables -t filter "$_fp4_m" BIFROST_FORWARD -o "$BIFROST_TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
    _fw_run iptables -t filter "$_fp4_m" BIFROST_FORWARD -i "$BIFROST_TUN" -j ACCEPT || return 1
    _fw_run iptables -t filter "$_fp4_m" BIFROST_FORWARD -o "$BIFROST_TUN" -j ACCEPT || return 1

    # IPv4 nat: BIFROST_POSTROUTING
    if [ "$_fw_snat_on" = 1 ]; then
        _fw_run iptables -t nat "$_fp4_m" BIFROST_POSTROUTING -m mark --mark 0x40000/0xff0000 ! -o "$BIFROST_TUN" -j MASQUERADE || return 1
    fi
    if [ "$_fw_lan_masq" = 1 ]; then
        _fw_run iptables -t nat "$_fp4_m" BIFROST_POSTROUTING -o "$BIFROST_TUN" -j MASQUERADE || return 1
    fi

    # IPv4 nat: BIFROST_PREROUTING
    if [ "$_fw_local_access" = 1 ] && [ -n "$_fw_ts_ip4" ] && [ -n "$_fw_lan_ip" ]; then
        for _fp4_ap in $_fw_admin_ports; do
            _fw_run iptables -t nat "$_fp4_m" BIFROST_PREROUTING \
                -i "$BIFROST_TUN" -d "$_fw_ts_ip4" -p tcp --dport "$_fp4_ap" \
                -j DNAT --to-destination "$_fw_lan_ip" || return 1
        done
    fi
}

# _fw_rules_v6 <-A|-C>: IPv6 filter rules from PLAN 9.2.
_fw_rules_v6() {
    _fp6_m=$1
    _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -p udp --dport "$_fw_port" -j ACCEPT || return 1
    if [ "$_fw_local_access" = 1 ]; then
        _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -i "$BIFROST_TUN" -j ACCEPT || return 1
    else
        _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -i "$BIFROST_TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT || return 1
        _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -i "$BIFROST_TUN" -p icmpv6 -j ACCEPT || return 1
        if [ "$_fw_is_exit" = 1 ] && [ -n "$_fw_peerapi6" ]; then
            _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -i "$BIFROST_TUN" -p tcp --dport "$_fw_peerapi6" -j ACCEPT || return 1
        fi
        _fw_run ip6tables -t filter "$_fp6_m" BIFROST_INPUT -i "$BIFROST_TUN" -j DROP || return 1
    fi
    _fw_run ip6tables -t filter "$_fp6_m" BIFROST_FORWARD -i "$BIFROST_TUN" -j ACCEPT || return 1
    _fw_run ip6tables -t filter "$_fp6_m" BIFROST_FORWARD -o "$BIFROST_TUN" -j ACCEPT || return 1
}

# Walk exactly the chains owned by each family. The callback receives
# command, table, parent, and plugin chain in that order.
_fw_chains() {
    "$2" "$1" filter INPUT BIFROST_INPUT || return 1
    "$2" "$1" filter FORWARD BIFROST_FORWARD || return 1
    if [ "$1" = iptables ]; then
        "$2" "$1" nat PREROUTING BIFROST_PREROUTING || return 1
        "$2" "$1" nat POSTROUTING BIFROST_POSTROUTING || return 1
    fi
}

_fw_prepare() { _fw_run _fw_prepare_chain "$1" "$2" "$4"; }

# Compare the kernel's own -S representation, preserving rule order. Rules
# owned by other plugins below the leading jump do not affect the snapshot.
_fw_snapshot_chain() {
    _fw_jump_is_first "$@" && "$1" -t "$2" -S "$4"
}

_fw_apply_family() {
    _fw_chains "$1" _fw_prepare &&
        "$2" -A &&
        _fw_chains "$1" _fw_ensure_jump &&
        _fw_chains "$1" _fw_snapshot_chain >>"$_fw_snapshot" &&
        "$2" -C
}

fw_apply() {
    _fw_port=$(cfg bifrost_port)
    _fw_local_access=$(cfg bifrost_local_access)
    _fw_lan_masq=$(cfg bifrost_lan_masq)
    if fw_snat_effective; then _fw_snat_on=1; else _fw_snat_on=0; fi
    _fw_read_dynamic

    # Publish the snapshot only after every rule passed -C. An interrupted
    # apply (or an upgrade with no snapshot yet) must trigger a watchdog repair.
    _fw_snapshot="$BIFROST_RUN/fw.rules.tmp.$$"
    if ! mkdir -p "$BIFROST_RUN" || ! rm -f "$BIFROST_RUN/fw.rules" || ! : >"$_fw_snapshot"; then
        fail fw_failed
        return 1
    fi
    if ! _fw_apply_family iptables _fw_rules_v4; then
        rm -f "$_fw_snapshot"
        fail fw_failed
        return 1
    fi
    if has_cmd ip6tables && ! _fw_apply_family ip6tables _fw_rules_v6; then
        log fw "ip6tables apply failed; IPv4 rules remain active"
        rm -f "$_fw_snapshot"
        BIFROST_ERR=""
        return 0
    fi
    mv -f "$_fw_snapshot" "$BIFROST_RUN/fw.rules" || fail fw_failed
}

# _fw_clear_chain <cmd> <table> <parent> <chain>
_fw_clear_chain() {
    while "$1" -t "$2" -C "$3" -j "$4" >/dev/null 2>&1; do
        _fw_run "$1" -t "$2" -D "$3" -j "$4" || return 1
    done
    if _fw_chain_exists "$1" "$2" "$4"; then
        _fw_run "$1" -t "$2" -F "$4" || return 1
        _fw_run "$1" -t "$2" -X "$4" || return 1
    fi
    return 0
}

# fw_clear: remove Bifrost jumps, flush and delete all Bifrost chains.
fw_clear() {
    rm -f "$BIFROST_RUN/fw.rules" || { fail fw_failed; return 1; }
    _fw_chains iptables _fw_clear_chain || return 1
    if has_cmd ip6tables; then
        _fw_chains ip6tables _fw_clear_chain || return 1
    fi
}

fw_check() {
    [ -s "$BIFROST_RUN/fw.rules" ] || return 1
    _fc_rules=$(
        _fw_chains iptables _fw_snapshot_chain || exit 1
        if has_cmd ip6tables; then _fw_chains ip6tables _fw_snapshot_chain; fi
    ) || return 1
    printf '%s\n' "$_fc_rules" | cmp -s - "$BIFROST_RUN/fw.rules"
}
