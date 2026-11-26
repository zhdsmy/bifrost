# shellcheck shell=sh
# Helpers for tests/shell/t_*.sh. Contract: docs/dev/contract.md, section 9.
#
#   . tests/shell/lib.sh
#   t_setup            fresh sandbox with the plugin laid out as installed
#   t_load             source the dispatcher and every lib into this shell
#   ok NAME CMD...     pass when CMD returns 0
#   no NAME CMD...     pass when CMD returns non-zero
#   eq NAME WANT GOT   pass when the strings are equal
#   has NAME NEEDLE HAYSTACK   pass when HAYSTACK contains NEEDLE
#   t_done             print the summary; last command of every test file
#
# The sandbox is $T. Mocks keep their state in $MOCK_STATE.

T_SRC=${T_SRC:-/src}
T_NAME=${0##*/}
T_PASS=0
T_FAIL=0
T=""

_t_pass() { T_PASS=$((T_PASS + 1)); }
_t_fail() {
    T_FAIL=$((T_FAIL + 1))
    echo "FAIL [$T_NAME] $*"
}

ok() {
    _ok_n=$1
    shift
    if "$@"; then _t_pass; else _t_fail "$_ok_n"; fi
}
no() {
    _no_n=$1
    shift
    if "$@"; then _t_fail "$_no_n"; else _t_pass; fi
}
eq() {
    if [ "$2" = "$3" ]; then
        _t_pass
    else
        _t_fail "$1"
        printf '  want: %s\n  got:  %s\n' "$2" "$3"
    fi
}
has() {
    case "$3" in
        *"$2"*) _t_pass ;;
        *)
            _t_fail "$1"
            printf '  missing: %s\n  in:      %s\n' "$2" "$3"
            ;;
    esac
}

t_done() {
    echo "$T_NAME: $T_PASS passed, $T_FAIL failed"
    [ -n "$T" ] && rm -rf "$T"
    [ "$T_FAIL" -eq 0 ]
}

# t_setup: new sandbox. Every path in env.sh points inside $T.
t_setup() {
    [ -n "$T" ] && rm -rf "$T"
    T=/tmp/bt.$$
    rm -rf "$T"
    # shellcheck disable=SC2013
    for _ts_v in $(sed -n 's/^: "\${\(BIFROST_[A-Z0-9_]*\):=.*/\1/p' "$T_SRC/plugin/bifrost/lib/env.sh"); do
        unset "$_ts_v"
    done
    unset BIFROST_REQ_ID BIFROST_ERR BIFROST_RESULT BIFROST_NO_MAIN BIFROST_BG_SYNC BIFROST_RELEASE_API
    export MOCK_STATE="$T/state"
    export BIFROST_KSROOT="$T/koolshare"
    export BIFROST_RUN="$T/run"
    export BIFROST_SOCK_DIR="$T/sock"
    export BIFROST_UPLOAD="$T/upload"
    export BIFROST_DNSMASQ_DIR="$T/dnsmasq.d"
    export BIFROST_TUN_DEV="$T/dev-net-tun"
    export BIFROST_BG_SYNC=1
    for _ts_d in "$MOCK_STATE/ts" "$MOCK_STATE/ip" "$MOCK_STATE/pidof" \
        "$BIFROST_KSROOT/scripts" "$BIFROST_KSROOT/bifrost/lib" "$BIFROST_KSROOT/bifrost/bin" \
        "$BIFROST_KSROOT/bifrost/keys" "$BIFROST_KSROOT/configs/bifrost" "$BIFROST_KSROOT/webs" \
        "$BIFROST_KSROOT/res" "$BIFROST_KSROOT/init.d" "$BIFROST_KSROOT/bin" "$BIFROST_DNSMASQ_DIR"; do
        mkdir -p "$_ts_d"
    done
    : >"$MOCK_STATE/dbus.env"
    : >"$MOCK_STATE/nvram.env"
    : >"$BIFROST_TUN_DEV"
    cp "$T_SRC"/plugin/bifrost/scripts/*.sh "$BIFROST_KSROOT/scripts/"
    cp "$T_SRC/tests/shell/mock/base.sh" "$BIFROST_KSROOT/scripts/base.sh"
    cp "$T_SRC"/plugin/bifrost/lib/*.sh "$BIFROST_KSROOT/bifrost/lib/"
    cp "$T_SRC/plugin/bifrost/version" "$BIFROST_KSROOT/bifrost/version"
    cp "$T_SRC/tests/shell/mock/bifrostd" "$BIFROST_KSROOT/bifrost/bin/bifrostd"
    chmod 755 "$BIFROST_KSROOT/bifrost/bin/bifrostd"
    ln -s bifrostd "$BIFROST_KSROOT/bifrost/bin/tailscale"
    T_SOCK="$BIFROST_SOCK_DIR/tailscaled.sock"
    return 0
}

# t_load: define every function of the plugin in this shell.
t_load() {
    BIFROST_NO_MAIN=1
    # shellcheck disable=SC1091
    . "$BIFROST_KSROOT/scripts/bifrost_config.sh"
}

# t_call ARGS...: run the dispatcher as the software center would.
t_call() { sh "$BIFROST_KSROOT/scripts/bifrost_config.sh" "$@"; }

# t_page ACTION [PARAMS...]: page request with ID 1; prints the response.
t_page() {
    t_call 1 "$@"
    t_resp
}
t_resp() { tail -n 1 "$MOCK_STATE/resp.log" 2>/dev/null; }

# Mock data.
dbus_seed() { for _db_kv in "$@"; do dbus set "$_db_kv"; done; }
nvram_seed() { for _nv_kv in "$@"; do nvram set "$_nv_kv"; done; }
# ts_out KEY TEXT: stdout of the fake CLI for a subcommand (KEY: status,
# debug-prefs, up, set, netcheck, ping, version, ...). ts_rc KEY RC.
ts_out() { printf '%s\n' "$2" >"$MOCK_STATE/ts/$1.out"; }
ts_out_file() { cp "$2" "$MOCK_STATE/ts/$1.out"; }
ts_rc() { echo "$2" >"$MOCK_STATE/ts/$1.rc"; }
ts_log() { cat "$MOCK_STATE/ts.log" 2>/dev/null; }
sock_up() {
    mkdir -p "$BIFROST_SOCK_DIR"
    : >"$T_SOCK"
}
# ip_out "ARGS" TEXT: output of "ip ARGS" (see mock/bin/ip).
ip_out() { printf '%s\n' "$2" >"$MOCK_STATE/ip/$(printf '%s' "$1" | tr ' /' '__').out"; }
# pidof_set NAME PID: make "pidof NAME" find a process.
pidof_set() { echo "$2" >"$MOCK_STATE/pidof/$1"; }
