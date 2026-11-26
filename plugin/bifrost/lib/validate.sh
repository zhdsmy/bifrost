# shellcheck shell=sh
# Input validation. Contract file: see docs/dev/contract.md.
# Every value from the page, dbus, nvram or command output passes one of
# these checks before it reaches a command. Each function prints nothing and
# returns 0 when the value is valid, 1 otherwise.

# Unsigned decimal, no sign, no leading zero (except "0"), at most 10 digits.
valid_uint() {
    case "$1" in '' | *[!0-9]* | 0?*) return 1 ;; esac
    [ "${#1}" -le 10 ]
}

# valid_uint_range <value> <min> <max>
valid_uint_range() {
    valid_uint "$1" || return 1
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

valid_port() { valid_uint_range "$1" 1024 65535; }
valid_bool01() { case "$1" in 0 | 1) return 0 ;; esac; return 1; }
valid_snat() { case "$1" in auto | on | off) return 0 ;; esac; return 1; }
valid_lang() { case "$1" in zh-CN | en) return 0 ;; esac; return 1; }
valid_mode() { case "$1" in dark | light | system) return 0 ;; esac; return 1; }
valid_arch() { case "$1" in arm | arm64) return 0 ;; esac; return 1; }
valid_req_id() { valid_uint "$1"; }

# Job and action names: lower-case letters, digits, "_" and "-".
valid_name() {
    case "$1" in '' | [!a-z]* | *[!a-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -le 32 ]
}

# First-pass filter for every request parameter. "-" means "empty".
valid_param() {
    case "$1" in '' | *[!A-Za-z0-9._:/,~=@-]*) return 1 ;; esac
    [ "${#1}" -le 512 ]
}

valid_ipv4() (
    case "$1" in '' | *[!0-9.]* | .* | *. | *..*) exit 1 ;; esac
    IFS=.
    # shellcheck disable=SC2086
    set -- $1
    [ $# -eq 4 ] || exit 1
    for _vi_o in "$@"; do
        valid_uint_range "$_vi_o" 0 255 || exit 1
    done
)

# Canonical IPv4 prefix (host bits zero), never 0.0.0.0/0.
valid_cidr4() (
    case "$1" in */*) ;; *) exit 1 ;; esac
    _vc_ip=${1%/*}
    _vc_len=${1#*/}
    valid_ipv4 "$_vc_ip" || exit 1
    valid_uint_range "$_vc_len" 0 32 || exit 1
    [ "$_vc_len" -eq 0 ] && exit 1
    IFS=.
    # shellcheck disable=SC2086
    set -- $_vc_ip
    _vc_i=0
    for _vc_o in "$@"; do
        _vc_bits=$((_vc_len - _vc_i * 8))
        [ "$_vc_bits" -lt 0 ] && _vc_bits=0
        [ "$_vc_bits" -gt 8 ] && _vc_bits=8
        _vc_host=$(((1 << (8 - _vc_bits)) - 1))
        [ $((_vc_o & _vc_host)) -eq 0 ] || exit 1
        _vc_i=$((_vc_i + 1))
    done
)

# Comma-separated list of 1 to 16 canonical IPv4 prefixes, no duplicates.
valid_cidr4_list() (
    case "$1" in '' | ,* | *, | *,,*) exit 1 ;; esac
    IFS=,
    # shellcheck disable=SC2086
    set -- $1
    [ $# -le 16 ] || exit 1
    _vl_seen=,
    for _vl_c in "$@"; do
        valid_cidr4 "$_vl_c" || exit 1
        case "$_vl_seen" in *",$_vl_c,"*) exit 1 ;; esac
        _vl_seen="$_vl_seen$_vl_c,"
    done
)

# Device name: letters, digits and "-", 1-63 characters, no "-" at either end.
valid_hostname() {
    case "$1" in '' | -* | *- | *[!A-Za-z0-9-]*) return 1 ;; esac
    [ "${#1}" -le 63 ]
}

# ACL tag, as tailcfg.CheckTag: "tag:", a letter, then letters, digits and "-".
valid_tag() {
    case "$1" in tag:[A-Za-z]*) ;; *) return 1 ;; esac
    case "${1#tag:}" in *[!A-Za-z0-9-]*) return 1 ;; esac
}

# Comma-separated ACL tags.
valid_tag_list() (
    case "$1" in '' | ,* | *, | *,,*) exit 1 ;; esac
    IFS=,
    # shellcheck disable=SC2086
    set -- $1
    for _vtl_t in "$@"; do
        valid_tag "$_vtl_t" || exit 1
    done
)

# DNS name: lower-case labels of letters, digits and "-", joined by ".".
valid_dns_name() {
    case "$1" in '' | .* | *. | *..* | -* | *.-* | *-.* | *[!a-z0-9.-]*) return 1 ;; esac
    case "$1" in *-) return 1 ;; esac
    [ "${#1}" -le 253 ]
}

# Control server: http(s)://host[:port][/path]. No user info, query or spaces.
valid_login_server() (
    case "$1" in http://?* | https://?*) ;; *) exit 1 ;; esac
    [ "${#1}" -le 255 ] || exit 1
    _vs_rest=${1#*://}
    case "$_vs_rest" in *[!A-Za-z0-9.:/_~-]*) exit 1 ;; esac
    _vs_hostport=${_vs_rest%%/*}
    case "$_vs_hostport" in *:*:*) exit 1 ;; esac
    _vs_host=${_vs_hostport%%:*}
    case "$_vs_hostport" in
        *:*) valid_uint_range "${_vs_hostport#*:}" 1 65535 || exit 1 ;;
    esac
    case "$_vs_host" in '' | .* | *. | -* | *..* | *[!A-Za-z0-9.-]*) exit 1 ;; esac
    exit 0
)

valid_authkey() {
    case "$1" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -ge 16 ] && [ "${#1}" -le 128 ]
}

# Download mirror prefix: https://..., ends with "/", only [A-Za-z0-9./_-].
valid_mirror() {
    case "$1" in https://?*/) ;; *) return 1 ;; esac
    case "${1#https://}" in *[!A-Za-z0-9./_-]*) return 1 ;; esac
    [ "${#1}" -le 200 ]
}

# Tailscale address: IPv4 in 100.64.0.0/10 or IPv6 in fd7a:115c:a1e0::/48.
valid_tailnet_ip() {
    case "$1" in
        100.*)
            valid_ipv4 "$1" || return 1
            _vt_second=${1#100.}
            _vt_second=${_vt_second%%.*}
            [ "$_vt_second" -ge 64 ] && [ "$_vt_second" -le 127 ]
            ;;
        fd7a:115c:a1e0:* | FD7A:115C:A1E0:*)
            case "$1" in *[!0-9A-Fa-f:]*) return 1 ;; esac
            [ "${#1}" -le 39 ]
            ;;
        *) return 1 ;;
    esac
}

# valid_setting <dbus key> <value>: value check for each Bifrost dbus key.
valid_setting() {
    case "$1" in
        bifrost_enable | bifrost_local_access | bifrost_lan_masq | bifrost_magicdns | bifrost_no_logs)
            valid_bool01 "$2" ;;
        bifrost_port) valid_port "$2" ;;
        bifrost_snat) valid_snat "$2" ;;
        bifrost_mirror) [ -z "$2" ] || valid_mirror "$2" ;;
        bifrost_ui_lang) valid_lang "$2" ;;
        bifrost_ui_mode) valid_mode "$2" ;;
        *) return 1 ;;
    esac
}
