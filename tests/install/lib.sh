# shellcheck shell=sh
# Clean router-like sandbox WITHOUT pre-installing Bifrost (fresh Koolshare root).
inst_setup() {
    # Stop any leftover mock bifrostd from a previous section.
    if [ -n "${BIFROST_PIDFILE:-}" ] && [ -f "$BIFROST_PIDFILE" ]; then
        _cl_p=$(cat "$BIFROST_PIDFILE" 2>/dev/null || true)
        [ -n "$_cl_p" ] && kill "$_cl_p" 2>/dev/null || true
    fi
    [ -n "$T" ] && rm -rf "$T"
    T=/tmp/bi.$$
    rm -rf "$T"
    # shellcheck disable=SC2013
    for _is_v in $(sed -n 's/^: "\${\(BIFROST_[A-Z0-9_]*\):=.*/\1/p' "$T_SRC/plugin/bifrost/lib/env.sh"); do
        unset "$_is_v"
    done
    unset BIFROST_REQ_ID BIFROST_ERR BIFROST_RESULT BIFROST_NO_MAIN BIFROST_BG_SYNC \
        BIFROST_INSTALL_LOCK_WAIT BIFROST_DNSMASQ_MAIN BIFROST_FW_RETRY_SLEEP
    export MOCK_STATE="$T/state"
    export BIFROST_KSROOT="$T/koolshare"
    export BIFROST_RUN="$T/run"
    export BIFROST_SOCK_DIR="$T/sock"
    export BIFROST_UPLOAD="$T/upload"
    export BIFROST_DNSMASQ_DIR="$T/dnsmasq.d"
    export BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
    export BIFROST_TUN_DEV="$T/dev-net-tun"
    export BIFROST_INSTALL_LOCK_WAIT=5
    export BIFROST_FW_RETRY_SLEEP=0

    for _is_d in "$MOCK_STATE/ts" "$MOCK_STATE/ip" "$MOCK_STATE/pidof" \
        "$BIFROST_KSROOT/scripts" "$BIFROST_KSROOT/webs" "$BIFROST_KSROOT/res" \
        "$BIFROST_KSROOT/init.d" "$BIFROST_KSROOT/bin" \
        "$BIFROST_UPLOAD" "$BIFROST_DNSMASQ_DIR" "$T/pkgs"; do
        mkdir -p "$_is_d"
    done
    : >"$MOCK_STATE/dbus.env"
    printf '%s\n' \
        'lan_ipaddr=192.0.2.1' \
        'lan_netmask=255.255.255.0' \
        'sw_mode=1' \
        'http_lanport=80' \
        'https_lanport=8443' \
        'sc_skin=ASUSWRT' \
        >"$MOCK_STATE/nvram.env"
    printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
    : >"$BIFROST_TUN_DEV"
    echo aarch64 >"$MOCK_STATE/uname_m"

    # Seed realistic mock CLI outputs so real daemon_start / daemon_stop / status_refresh succeed.
    cat >"$MOCK_STATE/ts/status.out" <<'EOF'
{"BackendState":"Running","Self":{"HostName":"router","DNSName":"router.example.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true},"MagicDNSSuffix":"example.ts.net","Peer":{}}
EOF
    cat >"$MOCK_STATE/ts/debug-prefs.out" <<'EOF'
{"ControlURL":"","RouteAll":false,"CorpDNS":false,"AdvertiseRoutes":[],"Hostname":"","NoSNAT":false,"NetfilterMode":0,"ShieldsUp":false}
EOF

    cp "$T_SRC/tests/shell/mock/base.sh" "$BIFROST_KSROOT/scripts/base.sh"
    # Verify BusyBox 1.25 has no "command -v" usage inside install/uninstall.
    cat >>"$BIFROST_KSROOT/scripts/base.sh" <<'EOF'
command() { touch "$MOCK_STATE/used-command"; return 127; }
EOF
    # Re-source env.sh to populate convenience path variables in test shell.
    # shellcheck source=plugin/bifrost/lib/env.sh
    . "$T_SRC/plugin/bifrost/lib/env.sh"
    export BIFROST_LIB="$BIFROST_KSROOT/bifrost/lib"
}

# Sorted snapshot of every file/symlink/dir in the sandbox EXCEPT $BIFROST_STATE.
# Used to prove uninstall removes every single installed and runtime artifact.
snapshot_sandbox() {
    for _sn_root in "$BIFROST_KSROOT" "$BIFROST_UPLOAD" "$BIFROST_DNSMASQ_DIR" "$BIFROST_RUN" "$BIFROST_SOCK_DIR"; do
        [ -e "$_sn_root" ] || continue
        find "$_sn_root" | while IFS= read -r _sn_p; do
            case "$_sn_p" in
                "$BIFROST_KSROOT/configs" | "$BIFROST_STATE" | "$BIFROST_STATE"/*) continue ;;
            esac
            printf '%s\n' "$_sn_p"
        done
    done | sort
}
