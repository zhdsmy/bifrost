# shellcheck shell=sh
# Bifrost-managed iptables and ip6tables rules (PLAN section 9).
# Contract file: see docs/dev/contract.md.
# No "local" in POSIX sh: function variables use a _<abbr>_ prefix.

: "${BIFROST_FW_RETRY:=3}"
: "${BIFROST_FW_RETRY_SLEEP:=1}"
: "${BIFROST_FW_V6_RETRY_INTERVAL:=900}"

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

# Both consumers use the same upstream rules for advertised and approved exits.
fw_exit_jq() {
    cat <<'JQ'
def exit_routes: index("0.0.0.0/0") != null and index("::/0") != null;
def approved_exit: .Self.ExitNodeOption == true or ((.Self.AllowedIPs // []) | exit_routes);
JQ
}

# _fw_run <cmd...>: run an iptables/ip6tables command, retrying on failure.
_fw_run() {
    _fr_i=0
    while :; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$_fr_i" -ge "$BIFROST_FW_RETRY" ]; then
            fail fw_failed
            return 1
        fi
        _fr_i=$((_fr_i + 1))
        if [ "$BIFROST_FW_RETRY_SLEEP" -gt 0 ]; then
            sleep "$BIFROST_FW_RETRY_SLEEP"
        fi
    done
}

# The chain probe alone cannot distinguish a missing chain from a failed
# query. Confirm absence from a successful table listing; retry query errors.
_fw_probe_chain() {
    _fpc_present=1
    "$1" -t "$2" -S "$3" >/dev/null 2>&1 && return 0
    _fpc_table=$("$1" -t "$2" -S) || return 1
    printf '%s\n' "$_fpc_table" | awk -v chain="$3" '$1 == "-N" && $2 == chain { found=1 } END { exit !found }' ||
        _fpc_present=0
    return 0
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
    _fw_probe_chain "$1" "$2" "$3" || return 1
    if [ "$_fpc_present" = 0 ]; then
        "$1" -t "$2" -N "$3" >/dev/null 2>&1 && return 0
        _fw_probe_chain "$1" "$2" "$3" && [ "$_fpc_present" = 1 ] || return 1
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
    _fw_dynamic_known=0
    _fw_ex_jq=$(fw_exit_jq)

    _fw_st=$(ts_cli status --json --peers=false 2>/dev/null) || _fw_st=""
    if [ -n "$_fw_st" ]; then
        _fw_parsed=$(printf '%s\n' "$_fw_st" | jq -r "$_fw_ex_jq
            select(type == \"object\") |
            ((.TailscaleIPs // .Self.TailscaleIPs // [])
                | map(select(type == \"string\" and (contains(\":\") | not)))
                | .[0] // \"-\"),
            (if approved_exit then \"1\" else \"0\" end),
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
        " 2>/dev/null) || _fw_parsed=""
        if [ -n "$_fw_parsed" ]; then
            _fw_dynamic_known=1
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
        _fw_adv_exit=$(printf '%s\n' "$_fw_pr" | jq -r "$_fw_ex_jq
            select(type == \"object\") | (.AdvertiseRoutes // []) | exit_routes
        " 2>/dev/null)
        case "$_fw_adv_exit" in
            true) _fw_is_exit=1 ;;
            false) ;;
            *) _fw_dynamic_known=0 ;;
        esac
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
    _fch_rc=0
    for _fch_parent in INPUT FORWARD PREROUTING POSTROUTING; do
        case "$_fch_parent" in
            INPUT | FORWARD) _fch_table=filter ;;
            *) [ "$1" = iptables ] || continue; _fch_table=nat ;;
        esac
        "$2" "$1" "$_fch_table" "$_fch_parent" "BIFROST_$_fch_parent" || {
            [ "$2" = _fw_clear_chain ] || return 1
            _fch_rc=1
        }
    done
    return "$_fch_rc"
}

_fw_prepare() { _fw_run _fw_prepare_chain "$1" "$2" "$4"; }

# Compare the kernel's own -S representation, preserving rule order. Rules
# owned by other plugins below the leading jump do not affect the snapshot.
_fw_snapshot_chain() {
    _fw_jump_is_first "$@" && "$1" -t "$2" -S "$4"
}

# Read the effective inputs of each family, including values that can change
# between two watchdog runs without a page action or a new login.
_fw_inputs() {
    _fw_port=$(cfg bifrost_port)
    _fw_local_access=$(cfg bifrost_local_access)
    _fw_lan_masq=$(cfg bifrost_lan_masq)
    if fw_snat_effective; then _fw_snat_on=1; else _fw_snat_on=0; fi
    _fw_read_dynamic
    _fi_common="inputs $BIFROST_TUN $_fw_port $_fw_local_access"
    _fw_v4="$_fi_common $_fw_snat_on $_fw_lan_masq"
    _fw_v6=$_fi_common
    if [ "$_fw_local_access" = 1 ]; then
        _fw_v4="$_fw_v4 lan:$_fw_lan_ip/$_fw_admin_ports cli:$_fw_ts_ip4"
    else
        if [ "$_fw_is_exit" != 1 ]; then _fw_peerapi4=""; _fw_peerapi6=""; fi
        _fw_v4="$_fw_v4 cli:$_fw_peerapi4"
        _fw_v6="$_fw_v6 cli:$_fw_peerapi6"
    fi
}

# The first line records desired inputs. The rest records kernel rule order.
# The page checks installed rules without polling the CLI a second time.
_fw_matches() {
    [ -s "$2" ] && IFS= read -r _fm_inputs <"$2" || return 1
    case "$_fm_inputs" in "inputs "*) ;; *) return 1 ;; esac
    if [ "$#" -eq 3 ] && [ "$_fm_inputs" != "$3" ]; then
        # A failed CLI read is not a withdrawal. Local settings and the kernel
        # still need checking; defer only the unobserved CLI fields.
        [ "$_fw_dynamic_known" = 0 ] && [ "${_fm_inputs% cli:*}" = "${3% cli:*}" ] || return 1
    fi
    _fm_rules=$(_fw_chains "$1" _fw_snapshot_chain) || return 1
    printf '%s\n' "$_fm_inputs" "$_fm_rules" | cmp -s - "$2"
}

# Read a parent successfully before interpreting missing jumps as detached.
_fw_detach() {
    _fd_rules=$("$1" -t "$2" -S "$3") || return 1
    _fd_count=$(printf '%s\n' "$_fd_rules" | awk -v par="$3" -v dest="$4" '
        $1=="-A" && $2==par && $3=="-j" && $4==dest && NF==4 { n++ }
        END { print n+0 }')
    while [ "$_fd_count" -gt 0 ]; do
        "$1" -t "$2" -D "$3" -j "$4" || return 1
        _fd_count=$((_fd_count - 1))
    done
}

_fw_clear_chain() {
    _fw_run _fw_probe_chain "$1" "$2" "$4" || return 1
    [ "$_fpc_present" = 1 ] || return 0
    _fw_run _fw_detach "$@" &&
        _fw_run "$1" -t "$2" -F "$4" &&
        _fw_run "$1" -t "$2" -X "$4"
}

_fw_detach_retry() { _fw_run _fw_detach "$@"; }

# Leave a previous IPv6 ruleset attached only while it is still complete.
# Attach new chains only after every rule was added and verified.
_fw_apply_family() {
    _fw_matches "$1" "$3" "$4" && return 0
    rm -f "$3" || return 1
    if [ "$1" = ip6tables ]; then
        _fw_chains "$1" _fw_detach_retry || return 1
    fi
    _fw_chains "$1" _fw_prepare &&
        "$2" -A && "$2" -C &&
        _fw_chains "$1" _fw_ensure_jump &&
        { printf '%s\n' "$4" && _fw_chains "$1" _fw_snapshot_chain; } >"$3.tmp.$$" &&
        mv -f "$3.tmp.$$" "$3" && return 0
    rm -f "$3.tmp.$$"
    return 1
}

_fw_v6_deferred() {
    [ -r "$BIFROST_RUN/fw6.retry" ] && IFS= read -r _fvd_last <"$BIFROST_RUN/fw6.retry" || return 1
    valid_uint "$_fvd_last" || return 1
    _fvd_age=$(($(now) - _fvd_last))
    [ "$_fvd_age" -ge 0 ] && [ "$_fvd_age" -lt "$BIFROST_FW_V6_RETRY_INTERVAL" ]
}

fw_apply() {
    mkdir -p "$BIFROST_RUN" || { fail fw_failed; return 1; }
    _fw_inputs
    if ! _fw_apply_family iptables _fw_rules_v4 "$BIFROST_RUN/fw.rules" "$_fw_v4"; then
        log fw "IPv4 firewall apply failed"
        fail fw_failed
        return 1
    fi
    if has_cmd ip6tables && ! _fw_v6_deferred; then
        if _fw_apply_family ip6tables _fw_rules_v6 "$BIFROST_RUN/fw6.rules" "$_fw_v6"; then
            rm -f "$BIFROST_RUN/fw6.retry" || { fail fw_failed; return 1; }
        else
            # Attempt every owned chain, including a jump installed before a
            # later attach failed. A failed table read must not flush a live chain.
            _fw_chains ip6tables _fw_clear_chain || :
            log fw "ip6tables apply failed; IPv4 rules remain active"
            now | atomic_write "$BIFROST_RUN/fw6.retry" 600 || { fail fw_failed; return 1; }
            BIFROST_ERR=""
        fi
    fi
    return 0
}

fw_clear() {
    _fcl_failed=0
    rm -f "$BIFROST_RUN/fw.rules" "$BIFROST_RUN/fw6.rules" "$BIFROST_RUN/fw6.retry" || _fcl_failed=1
    _fw_chains iptables _fw_clear_chain || _fcl_failed=1
    if has_cmd ip6tables; then _fw_chains ip6tables _fw_clear_chain || _fcl_failed=1; fi
    [ "$_fcl_failed" = 0 ] || fail fw_failed
}

# Strict installed health for status and diagnostics, including a deferred family.
fw_complete() {
    _fw_matches iptables "$BIFROST_RUN/fw.rules" || return 1
    if has_cmd ip6tables; then
        [ ! -e "$BIFROST_RUN/fw6.retry" ] && _fw_matches ip6tables "$BIFROST_RUN/fw6.rules"
    fi
}

# Watchdog repair decision. A known IPv6 failure is retried only when due.
fw_check() {
    _fw_inputs
    _fw_matches iptables "$BIFROST_RUN/fw.rules" "$_fw_v4" || return 1
    if has_cmd ip6tables && ! _fw_v6_deferred; then
        _fw_matches ip6tables "$BIFROST_RUN/fw6.rules" "$_fw_v6"
    fi
}
