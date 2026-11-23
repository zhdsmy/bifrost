#!/bin/sh
# Bifrost uninstaller for KoolCenter / Koolshare software center.
# Installed as $BIFROST_SCRIPTS/uninstall_bifrost.sh.
# Follows docs/PLAN.md section 15.2 and docs/dev/contract.md sections 2 & 7.
# Asset cleanup and dbus removal adapted from po0fw asus-merlin (MIT), commit 0d9532d.

: "${BIFROST_INSTALL_LOCK_WAIT:=60}"

# Always resolve the installed library location via env.sh defaults (or test
# environment overrides), never from $0 (running from /tmp/bifrost/ must not
# target /tmp as root).
_un_ks=${BIFROST_KSROOT:-/koolshare}
_un_lib=${BIFROST_LIB:-$_un_ks/bifrost/lib}

if [ ! -f "$_un_lib/env.sh" ] || [ ! -f "$_un_lib/validate.sh" ] || [ ! -f "$_un_lib/common.sh" ]; then
    echo "未找到已安装的 Bifrost 脚本库（$_un_lib），无法安全卸载"
    exit 1
fi

# shellcheck disable=SC1091
. "$_un_lib/env.sh"
if [ -f "$BIFROST_SCRIPTS/base.sh" ]; then
    # shellcheck disable=SC1091
    . "$BIFROST_SCRIPTS/base.sh"
fi
# shellcheck disable=SC1091
. "$_un_lib/validate.sh"
# shellcheck disable=SC1091
. "$_un_lib/common.sh"

if ! has_cmd echo_date; then
    echo_date() { echo "$@"; }
fi

for _un_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$_un_lib/$_un_m.sh" ] && . "$_un_lib/$_un_m.sh"
done

_un_lock_held=0
_un_done=0
# shellcheck disable=SC2329
_un_on_exit() {
    if [ "$_un_lock_held" = 1 ]; then
        lock_release state
        _un_lock_held=0
    fi
    if [ "$_un_done" = 1 ]; then
        rmdir "$BIFROST_RUN" 2>/dev/null || true
    fi
}
trap '_un_on_exit' EXIT
trap '_un_on_exit; exit 130' INT
trap '_un_on_exit; exit 143' TERM

# Hold the state lock for the entire uninstall (contract section 2).
if ! lock_acquire state "$BIFROST_INSTALL_LOCK_WAIT"; then
    echo_date "另一个 Bifrost 操作正在进行，等待超时，退出卸载"
    log uninstall "failed to acquire state lock"
    exit 1
fi
_un_lock_held=1

echo_date "正在卸载 Bifrost..."
log uninstall "starting uninstall"

# Steps 1 & 2: require daemon_stop (removes watchdog cron, firewall chains,
# dnsmasq config, stops daemon and runs --cleanup; PLAN 6.3 & 15.2).
# If the service cannot be stopped, abort and keep scripts so the user can retry.
if ! has_cmd daemon_stop; then
    echo_date "缺少 daemon_stop 函数，无法安全停止 Bifrost 服务，已中止卸载并保留现有脚本"
    log uninstall "daemon_stop unavailable; aborting uninstall"
    exit 1
fi
if ! daemon_stop || daemon_running; then
    echo_date "无法停止 Bifrost 服务，已中止卸载并保留现有脚本，请稍后重试"
    log uninstall "daemon_stop failed or daemon still running; aborting uninstall"
    exit 1
fi

# Step 3: remove every file installed by install.sh and all runtime files (PLAN 15.2 step 3).
# Step 5: preserve $BIFROST_STATE (/koolshare/configs/bifrost/).
if [ -f "$BIFROST_HOME/installed.scripts" ]; then
    while IFS= read -r _un_name; do
        case "$_un_name" in
            */*) continue ;;
            bifrost_*.sh) rm -f "$BIFROST_SCRIPTS/$_un_name" || exit 1 ;;
        esac
    done <"$BIFROST_HOME/installed.scripts"
fi

rm -rf "$BIFROST_HOME" "$BIFROST_SOCK_DIR"
rm -f "$BIFROST_INITD/S99bifrost.sh" "$BIFROST_INITD/N99bifrost.sh"
rm -f "$BIFROST_KSBIN/bifrost"
# Older packages installed these two scripts before recording ownership.
rm -f "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_SCRIPTS/bifrost_status.sh" "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
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

echo_date "Bifrost 卸载完成（登录状态目录 $BIFROST_STATE 已保留）"
# Release the state lock last. A waiting installer can acquire it immediately.
for _un_file in "$BIFROST_RUN"/* "$BIFROST_RUN"/.[!.]* "$BIFROST_RUN"/..?*; do
    [ "$_un_file" = "$BIFROST_RUN/lock.state" ] || rm -rf "$_un_file" || exit 1
done
_un_done=1
exit 0
