#!/bin/sh
# Bifrost uninstaller for KoolCenter / Koolshare software center.
# Installed as $BIFROST_SCRIPTS/uninstall_bifrost.sh.
# Follows docs/PLAN.md section 15.2 and docs/dev/contract.md sections 2 & 7.
# Asset cleanup and dbus removal adapted from po0fw asus-merlin (MIT), commit 0d9532d.

: "${BIFROST_INSTALL_LOCK_WAIT:=60}"

# install.sh embeds the package bootstrap in the installed entry. When invoked
# from an unpacked distribution, read the same bootstrap next to this script.
if ! type lock_acquire >/dev/null 2>&1; then
    _un_source=$(dirname "$0")/lib
    for _un_m in env validate common; do
        # shellcheck disable=SC1090
        . "$_un_source/$_un_m.sh" || exit 1
    done
fi
if [ -f "$BIFROST_SCRIPTS/base.sh" ]; then
    # shellcheck disable=SC1091
    . "$BIFROST_SCRIPTS/base.sh"
fi
if ! has_cmd echo_date; then
    echo_date() { echo "$@"; }
fi

_un_lock_held=0
_un_done=0
# shellcheck disable=SC2329
_un_on_exit() {
    trap '' INT TERM
    if [ "$_un_lock_held" = 1 ]; then
        lock_release state
        _un_lock_held=0
    fi
    if [ "$_un_done" = 1 ]; then
        rmdir "$BIFROST_RUN" 2>/dev/null || true
    fi
}
trap '_un_on_exit' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Hold the state lock for the entire uninstall (contract section 2).
if ! lock_acquire state "$BIFROST_INSTALL_LOCK_WAIT"; then
    echo_date "另一个 Bifrost 操作正在进行，等待超时，退出卸载"
    log uninstall "failed to acquire state lock"
    exit 1
fi
_un_lock_held=1

echo_date "正在卸载 Bifrost..."
log uninstall "starting uninstall"

# Rename the complete library tree only after all other steps succeed. A retry
# sees either a usable installation or an unregistered, stopped retired tree.
_un_retired="$BIFROST_HOME/.uninstall-lib"
_un_registered=$(dbus get softcenter_module_bifrost_install) || exit 1
if [ -d "$BIFROST_LIB" ] || [ "$_un_registered" = 1 ]; then
    for _un_m in daemon fw dns status; do
        # shellcheck disable=SC1090
        [ ! -f "$BIFROST_LIB/$_un_m.sh" ] || . "$BIFROST_LIB/$_un_m.sh" || exit 1
    done
    if ! has_cmd daemon_stop; then
        echo_date "缺少 daemon_stop 函数，无法安全停止 Bifrost 服务，已中止卸载并保留现有脚本"
        exit 1
    fi
    if ! daemon_stop || daemon_running; then
        echo_date "停止 Bifrost 服务或清理规则失败，已中止卸载并保留现有脚本，请稍后重试"
        exit 1
    fi
    if ! daemon_watchdog_remove; then
        echo_date "删除 Bifrost 守护任务失败，已中止卸载并保留现有脚本，请稍后重试"
        exit 1
    fi

    if [ -f "$BIFROST_HOME/installed.scripts" ]; then
        while IFS= read -r _un_name; do
            case "$_un_name" in
                */*) continue ;;
                bifrost_*.sh) rm -f "$BIFROST_SCRIPTS/$_un_name" || exit 1 ;;
            esac
        done <"$BIFROST_HOME/installed.scripts"
    fi
    rm -f "$BIFROST_INITD/S99bifrost.sh" "$BIFROST_INITD/N99bifrost.sh" \
        "$BIFROST_KSBIN/bifrost" "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_SCRIPTS/bifrost_status.sh" \
        "$BIFROST_WEBS/Module_bifrost.asp" "$BIFROST_WEBS"/.bifrost-app.new "$BIFROST_WEBS"/.bifrost-app.new.* \
        "$BIFROST_RES/icon-bifrost.png" "$BIFROST_RES"/.bifrost-app.new "$BIFROST_RES"/.bifrost-app.new.* || exit 1
    for _un_asset in "$BIFROST_RES"/bifrost-app.*.js "$BIFROST_RES"/bifrost-app.*.css; do
        if printf '%s\n' "${_un_asset##*/}" | grep -Eq '^bifrost-app\.[0-9a-f]{20}\.(js|css)$'; then
            rm -f "$_un_asset" || exit 1
        fi
    done
    for _un_output in status.json diag.json daemon.json login.json migrate.json update.json netcheck.json logs.txt; do
        rm -f "$BIFROST_UPLOAD/bifrost_$_un_output" || exit 1
    done
    rm -rf "$BIFROST_SOCK_DIR" || exit 1

    for _un_prefix in bifrost_ softcenter_module_bifrost_; do
        _un_rows=$(dbus list "$_un_prefix") || exit 1
        while IFS='=' read -r _un_k _; do
            case "$_un_k" in
                softcenter_module_bifrost_install) continue ;;
                "$_un_prefix"*) dbus remove "$_un_k" >/dev/null || exit 1 ;;
            esac
        done <<EOF
$_un_rows
EOF
    done
    dbus remove softcenter_module_bifrost_install >/dev/null || exit 1
    rm -rf "$_un_retired" || exit 1
    mv "$BIFROST_LIB" "$_un_retired" || exit 1
elif daemon_running; then
    echo_date "缺少脚本库且 Bifrost 服务仍在运行，已中止卸载"
    exit 1
fi

rm -rf "$BIFROST_HOME" || exit 1
for _un_file in "$BIFROST_RUN"/* "$BIFROST_RUN"/.[!.]* "$BIFROST_RUN"/..?*; do
    [ "$_un_file" = "$BIFROST_RUN/lock.state" ] || rm -rf "$_un_file" || exit 1
done
rm -f "$BIFROST_SCRIPTS/uninstall_bifrost.sh" || exit 1
_un_done=1
echo_date "Bifrost 卸载完成（登录状态目录 $BIFROST_STATE 已保留）"
exit 0
