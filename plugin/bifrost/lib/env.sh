# shellcheck shell=sh
# Bifrost paths and defaults. Contract file: see docs/dev/contract.md.
# Every value can be overridden from the environment so tests can use
# temporary directories. Router scripts never set these variables.

: "${BIFROST_KSROOT:=/koolshare}"
: "${BIFROST_HOME:=$BIFROST_KSROOT/bifrost}"
: "${BIFROST_BIN:=$BIFROST_HOME/bin}"
: "${BIFROST_CORE:=$BIFROST_BIN/bifrostd}"
: "${BIFROST_CLI:=$BIFROST_BIN/tailscale}"
: "${BIFROST_LIB:=$BIFROST_HOME/lib}"
: "${BIFROST_KEYS:=$BIFROST_HOME/keys}"
: "${BIFROST_MANIFEST:=$BIFROST_HOME/core.json}"
: "${BIFROST_VERSION_FILE:=$BIFROST_HOME/version}"
: "${BIFROST_SCRIPTS:=$BIFROST_KSROOT/scripts}"
: "${BIFROST_WEBS:=$BIFROST_KSROOT/webs}"
: "${BIFROST_RES:=$BIFROST_KSROOT/res}"
: "${BIFROST_INITD:=$BIFROST_KSROOT/init.d}"
: "${BIFROST_KSBIN:=$BIFROST_KSROOT/bin}"
: "${BIFROST_STATE:=$BIFROST_KSROOT/configs/bifrost}"
# Redacted records of daemon exits; kept across reboots (PLAN 6.6).
: "${BIFROST_CRASH_DIR:=$BIFROST_HOME/crash}"

: "${BIFROST_RUN:=/tmp/bifrost-run}"
: "${BIFROST_LOG:=$BIFROST_RUN/bifrost.log}"
: "${BIFROST_DLOG:=$BIFROST_RUN/bifrostd.log}"
: "${BIFROST_TS_LOGS:=$BIFROST_RUN/logs}"
: "${BIFROST_PIDFILE:=$BIFROST_RUN/bifrostd.pid}"
: "${BIFROST_DAEMON_ERR:=$BIFROST_RUN/daemon.error}"
: "${BIFROST_SOCK_DIR:=/var/run/bifrost}"
: "${BIFROST_SOCK:=$BIFROST_SOCK_DIR/tailscaled.sock}"
: "${BIFROST_UPLOAD:=/tmp/upload}"
: "${BIFROST_DNSMASQ_DIR:=/jffs/configs/dnsmasq.d}"
: "${BIFROST_DNSMASQ_CONF:=$BIFROST_DNSMASQ_DIR/bifrost.conf}"
: "${BIFROST_MOUNTS:=/proc/mounts}"

: "${BIFROST_TUN:=tailscale0}"
: "${BIFROST_TUN_DEV:=/dev/net/tun}"
: "${BIFROST_RELEASE_BASE:=https://github.com/zhdsmy/bifrost/releases/download}"
: "${BIFROST_CHANNEL_URL:=$BIFROST_RELEASE_BASE/channel-stable/core.json}"
# Same releases through the GitHub API (PLAN 12.7). Empty turns it off.
: "${BIFROST_RELEASE_API=https://api.github.com/repos/zhdsmy/bifrost/releases}"

# The original Koolshare plugin (read only; Bifrost never changes its files).
: "${BIFROST_ORIG_STATE:=$BIFROST_KSROOT/configs/tailscale}"
: "${BIFROST_ORIG_CONFIG:=$BIFROST_SCRIPTS/tailscale_config}"
# 1: migration stops the original itself and restarts it on rollback
#    (PLAN 11.2 step 4, verified on a router with the original 2.0.8).
# 0: migration waits for the user to stop the original in its own page.
: "${BIFROST_MIGRATE_AUTOSTOP:=1}"

# dbus keys owned by Bifrost and their defaults (PLAN 4.2).
bifrost_default() {
    case "$1" in
        bifrost_enable) echo 0 ;;
        bifrost_port) echo 41641 ;;
        bifrost_local_access) echo 1 ;;
        bifrost_lan_masq) echo 1 ;;
        bifrost_snat) echo auto ;;
        bifrost_magicdns) echo 0 ;;
        bifrost_no_logs) echo 1 ;;
        bifrost_mirror) echo "" ;;
        bifrost_ui_lang) echo zh-CN ;;
        bifrost_ui_mode) echo dark ;;
        *) return 1 ;;
    esac
}

BIFROST_KEYS_ALL="bifrost_enable bifrost_port bifrost_local_access bifrost_lan_masq bifrost_snat bifrost_magicdns bifrost_no_logs bifrost_mirror bifrost_ui_lang bifrost_ui_mode"
