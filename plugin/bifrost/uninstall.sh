#!/bin/sh
# Bifrost uninstaller for KoolCenter / Koolshare software center.
# Installed as $BIFROST_SCRIPTS/uninstall_bifrost.sh.
# Follows docs/PLAN.md section 15.2 and docs/dev/contract.md section 2.
# Asset cleanup and dbus removal adapted from po0fw asus-merlin (MIT), commit 0d9532d.

: "${BIFROST_INSTALL_LOCK_WAIT:=60}"

# Derive Koolshare root from installed script path ($BIFROST_KSROOT/scripts/uninstall_bifrost.sh)
# unless overridden by the environment (tests).
_un_self_ks=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
if [ -z "${BIFROST_KSROOT:-}" ]; then
    BIFROST_KSROOT=$_un_self_ks
fi
_un_lib=${BIFROST_LIB:-$BIFROST_KSROOT/bifrost/lib}

if [ -f "$_un_lib/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$_un_lib/env.sh"
fi
if [ -f "${BIFROST_SCRIPTS:-$BIFROST_KSROOT/scripts}/base.sh" ]; then
    # shellcheck disable=SC1091
    . "${BIFROST_SCRIPTS:-$BIFROST_KSROOT/scripts}/base.sh"
fi
if [ -f "$_un_lib/validate.sh" ]; then
    # shellcheck disable=SC1091
    . "$_un_lib/validate.sh"
fi
if [ -f "$_un_lib/common.sh" ]; then
    # shellcheck disable=SC1091
    . "$_un_lib/common.sh"
fi

# Fallbacks in case libraries were partially removed before uninstall ran.
: "${BIFROST_HOME:=$BIFROST_KSROOT/bifrost}"
: "${BIFROST_SCRIPTS:=$BIFROST_KSROOT/scripts}"
: "${BIFROST_WEBS:=$BIFROST_KSROOT/webs}"
: "${BIFROST_RES:=$BIFROST_KSROOT/res}"
: "${BIFROST_INITD:=$BIFROST_KSROOT/init.d}"
: "${BIFROST_KSBIN:=$BIFROST_KSROOT/bin}"
: "${BIFROST_STATE:=$BIFROST_KSROOT/configs/bifrost}"
: "${BIFROST_RUN:=/tmp/bifrost-run}"
: "${BIFROST_SOCK_DIR:=/var/run/bifrost}"
: "${BIFROST_UPLOAD:=/tmp/upload}"
: "${BIFROST_DNSMASQ_CONF:=/jffs/configs/dnsmasq.d/bifrost.conf}"

if ! type has_cmd >/dev/null 2>&1; then
    has_cmd() { type "$1" >/dev/null 2>&1; }
fi
if ! has_cmd echo_date; then
    echo_date() { echo "$@"; }
fi
if ! has_cmd log; then
    log() { :; }
fi

for _un_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$_un_lib/$_un_m.sh" ] && . "$_un_lib/$_un_m.sh"
done

_un_lock_held=0
_un_done=0
# shellcheck disable=SC2329
_un_on_exit() {
    if [ "$_un_lock_held" = 1 ] && has_cmd lock_release; then
        lock_release state
        _un_lock_held=0
    fi
    if [ "$_un_done" = 1 ]; then
        rm -rf "$BIFROST_RUN"
    fi
}
trap '_un_on_exit' EXIT
trap '_un_on_exit; exit 130' INT
trap '_un_on_exit; exit 143' TERM

# Hold the state lock for the entire uninstall (contract section 2).
if has_cmd lock_acquire; then
    if ! lock_acquire state "$BIFROST_INSTALL_LOCK_WAIT"; then
        echo_date "另一个 Bifrost 操作正在进行，等待超时，退出卸载"
        log uninstall "failed to acquire state lock"
        exit 1
    fi
    _un_lock_held=1
fi

echo_date "正在卸载 Bifrost..."
log uninstall "starting uninstall"

# Step 1 & 2: stop daemon, remove watchdog cron, firewall chains, dnsmasq config (PLAN 15.2 steps 1-2).
if has_cmd daemon_stop; then
    daemon_stop || log uninstall "daemon_stop returned non-zero during uninstall"
fi
if has_cmd cru; then
    cru d bifrost >/dev/null 2>&1 || true
fi
if has_cmd fw_clear; then
    fw_clear >/dev/null 2>&1 || true
fi
if has_cmd dns_clear; then
    dns_clear >/dev/null 2>&1 || true
elif [ -f "$BIFROST_DNSMASQ_CONF" ]; then
    rm -f "$BIFROST_DNSMASQ_CONF"
    if has_cmd service; then
        service restart_dnsmasq >/dev/null 2>&1 || true
    fi
fi

# Step 3: remove all installed files and runtime files (PLAN 15.2 step 3).
# Step 5: preserve $BIFROST_STATE (/koolshare/configs/bifrost/).
rm -rf "$BIFROST_HOME" "$BIFROST_SOCK_DIR"
rm -f "$BIFROST_INITD/S99bifrost.sh" "$BIFROST_INITD/N99bifrost.sh"
rm -f "$BIFROST_KSBIN/bifrost"
rm -f "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_SCRIPTS/bifrost_status.sh"
rm -f "$BIFROST_WEBS/Module_bifrost.asp" \
    "$BIFROST_WEBS"/.bifrost-app.new "$BIFROST_WEBS"/.bifrost-app.new.*
rm -f "$BIFROST_RES/icon-bifrost.png" \
    "$BIFROST_RES"/.bifrost-app.new "$BIFROST_RES"/.bifrost-app.new.*

for _un_asset in "$BIFROST_RES"/bifrost-app.*.js "$BIFROST_RES"/bifrost-app.*.css; do
    [ -e "$_un_asset" ] || continue
    _un_base=${_un_asset##*/}
    if printf '%s\n' "$_un_base" | grep -Eq '^bifrost-app\.[0-9a-f]{20}\.(js|css)$'; then
        rm -f "$_un_asset"
    fi
done

rm -f "$BIFROST_UPLOAD"/bifrost_*

# Step 4: remove dbus keys (PLAN 15.2 step 4).
if has_cmd dbus; then
    {
        dbus list bifrost_ 2>/dev/null
        dbus list softcenter_module_bifrost_ 2>/dev/null
    } | cut -d '=' -f 1 | while IFS= read -r _un_k; do
        [ -n "$_un_k" ] && dbus remove "$_un_k" >/dev/null 2>&1
    done
fi

rm -f "$BIFROST_SCRIPTS/uninstall_bifrost.sh"

echo_date "Bifrost 卸载完成（登录状态目录 $BIFROST_STATE 已保留）"
_un_done=1
exit 0
