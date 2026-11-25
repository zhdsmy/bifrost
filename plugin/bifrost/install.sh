#!/bin/sh
# Bifrost installer and upgrader for KoolCenter / Koolshare software center.
# Follows docs/PLAN.md section 15.1 and docs/dev/contract.md sections 2, 7 & 8.
# Page asset atomic swap and dbus registration adapted from po0fw asus-merlin (MIT), commit 0d9532d.

# The software center runs scripts with umask 0, which would make every
# directory and file we create world-writable.
umask 022

: "${BIFROST_INSTALL_LOCK_WAIT:=60}"

_in_dir=$(cd "$(dirname "$0")" && pwd)

# Load path defaults from the package first so tests can redirect the root.
if [ ! -f "$_in_dir/lib/env.sh" ] || [ ! -f "$_in_dir/lib/validate.sh" ] || [ ! -f "$_in_dir/lib/common.sh" ]; then
    echo "安装包不完整（缺少脚本库），退出安装"
    exit 1
fi
# shellcheck source=plugin/bifrost/lib/env.sh
. "$_in_dir/lib/env.sh"

# Step 1a: verify Koolshare software center before sourcing base.sh.
if [ ! -f "$BIFROST_SCRIPTS/base.sh" ]; then
    echo "未检测到 Koolshare 软件中心环境（缺少 base.sh），退出安装"
    exit 1
fi
# base.sh on the router defines echo_date as an alias. ash expands aliases
# while parsing, so a fallback function defined after it is a syntax error.
# Define the fallback first; the alias then takes precedence.
echo_date() { echo "$@"; }
# shellcheck disable=SC1091
. "$BIFROST_SCRIPTS/base.sh"
# shellcheck source=plugin/bifrost/lib/validate.sh
. "$_in_dir/lib/validate.sh"
# shellcheck source=plugin/bifrost/lib/common.sh
. "$_in_dir/lib/common.sh"

for _in_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$_in_dir/lib/$_in_m.sh" ] && . "$_in_dir/lib/$_in_m.sh"
done

_in_lock_held=0
_in_need_restart=0
_in_web_stage=""
_in_dirty=0
_in_dbus_dirty=0
_in_starting=0

# Restore exactly the paths recorded before the first file change. A missing
# backup means the path did not exist before installation.
_in_restore_path() {
    rm -rf "$1" || return 1
    if [ -e "$2" ] || [ -L "$2" ]; then
        cp -a "$2" "$1" || return 1
    fi
}

# Called by the EXIT trap.
# shellcheck disable=SC2329
_in_rollback() {
    if [ "$_in_starting" = 1 ] && daemon_running; then
        daemon_stop || return 1
    fi
    _ir_n=0
    while IFS= read -r _ir_path; do
        _ir_n=$((_ir_n + 1))
        _in_restore_path "$_ir_path" "$_in_web_stage/save.$_ir_n" || return 1
    done <"$_in_web_stage/paths"
    if [ "$_in_dbus_dirty" = 1 ]; then
        for _ir_key in $_in_keys; do
            if _ir_row=$(grep "^$_ir_key=" "$_in_web_stage/dbus"); then
                dbus set "$_ir_row" || return 1
            else
                dbus remove "$_ir_key" || return 1
            fi
        done
    fi
}

# shellcheck disable=SC2329
_in_on_exit() {
    trap '' INT TERM
    _ix_keep=0
    if [ "$1" -ne 0 ]; then
        if [ "$_in_dirty" = 1 ] && ! _in_rollback; then
            echo_date "恢复旧安装文件失败，已保留备份：$_in_web_stage"
            _ix_keep=1
        elif [ "$_in_need_restart" = 1 ]; then
            echo_date "升级中止，正在尝试恢复原 Bifrost 服务..."
            # Load the restored version, including when stop failed after cleanup.
            if ! (
                for _ix_lib in env validate common; do
                    # shellcheck disable=SC1090
                    . "$BIFROST_LIB/$_ix_lib.sh" || exit 1
                done
                # The same modules as the entry scripts: daemon_start needs core_version.
                for _ix_lib in daemon fw dns status login settings migrate update diag; do
                    # shellcheck disable=SC1090
                    [ ! -f "$BIFROST_LIB/$_ix_lib.sh" ] || . "$BIFROST_LIB/$_ix_lib.sh" || exit 1
                done
                daemon_start
            ); then
                echo_date "恢复原 Bifrost 服务失败，请到插件页面查看状态"
                log install "failed to restore daemon after aborted upgrade"
            fi
        fi
    fi
    if [ -n "$_in_web_stage" ] && [ "$_ix_keep" = 0 ]; then
        rm -rf "$_in_web_stage"
    fi
    if [ "$_in_lock_held" = 1 ]; then
        lock_release state
    fi
}
trap '_in_on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Hold the state lock for the entire install/upgrade (contract section 2).
if ! lock_acquire state "$BIFROST_INSTALL_LOCK_WAIT"; then
    echo_date "另一个 Bifrost 操作正在进行，等待超时，退出安装"
    log install "failed to acquire state lock"
    exit 1
fi
_in_lock_held=1

# Step 1b: environment checks (PLAN 15.1 step 1).
if ! has_cmd dbus; then
    echo_date "未检测到 Koolshare 软件中心环境（缺少 dbus），退出安装"
    log install "missing dbus command"
    exit 1
fi

_in_karch=$(uname -m 2>/dev/null)
case "$_in_karch" in
    armv7l | aarch64) ;;
    *)
        echo_date "不支持的系统架构：${_in_karch:-unknown}（仅支持 armv7l / aarch64）"
        log install "unsupported architecture: ${_in_karch:-unknown}"
        exit 1
        ;;
esac

if [ ! -e "$BIFROST_TUN_DEV" ]; then
    if has_cmd modprobe; then
        modprobe tun >/dev/null 2>&1 || true
    fi
fi
if [ ! -e "$BIFROST_TUN_DEV" ]; then
    echo_date "缺少 TUN 设备（$BIFROST_TUN_DEV），且无法加载 tun 模块，退出安装"
    log install "missing tun device: $BIFROST_TUN_DEV"
    exit 1
fi

for _in_tool in jq openssl curl gunzip; do
    if ! has_cmd "$_in_tool"; then
        echo_date "缺少必需命令 $_in_tool，退出安装"
        log install "missing required tool: $_in_tool"
        exit 1
    fi
done

# Validate package contents up front before stopping any running daemon or changing files.
if [ ! -s "$_in_dir/version" ]; then
    echo_date "安装包缺少版本文件，退出安装"
    log install "package missing version file"
    exit 1
fi
_in_ver=$(tr -d ' \t\r\n' <"$_in_dir/version")
if [ -z "$_in_ver" ]; then
    echo_date "安装包版本号为空，退出安装"
    log install "empty package version"
    exit 1
fi

if [ ! -s "$_in_dir/bin/bifrostd.gz" ] || [ ! -s "$_in_dir/bin/core.json" ]; then
    echo_date "安装包缺少核心文件或核心清单，退出安装"
    log install "package missing core archive or manifest"
    exit 1
fi

_in_pkg_arch=$(jq -r '.assets | keys[0] // empty' "$_in_dir/bin/core.json" 2>/dev/null)
if ! valid_arch "$_in_pkg_arch"; then
    echo_date "安装包核心清单格式无效，退出安装"
    log install "invalid package core manifest arch"
    exit 1
fi
if [ "$_in_pkg_arch" = arm64 ] && [ "$_in_karch" != aarch64 ]; then
    echo_date "安装包核心为 arm64，当前内核（$_in_karch）不支持，退出安装"
    log install "arch mismatch: package=$_in_pkg_arch kernel=$_in_karch"
    exit 1
fi

if [ ! -s "$_in_dir/webs/Module_bifrost.asp" ]; then
    echo_date "安装包缺少网页外壳文件，退出安装"
    log install "package missing Module_bifrost.asp"
    exit 1
fi

for _in_req in scripts/bifrost_config.sh scripts/bifrost_status.sh uninstall.sh bin/bifrost; do
    if [ ! -s "$_in_dir/$_in_req" ]; then
        echo_date "安装包缺少 $_in_req，退出安装"
        log install "package missing $_in_req"
        exit 1
    fi
done

# Snapshot ASP and hashed JS/CSS pair into $BIFROST_RUN now so a concurrent
# software-center upload clearing /tmp/bifrost cannot desynchronize them.
_in_web_stage="$BIFROST_RUN/install-web.$$"
(umask 077 && mkdir "$_in_web_stage") || {
    _in_web_stage=""
    echo_date "创建临时暂存目录失败，退出安装"
    log install "failed to create web stage dir"
    exit 1
}
if ! cp -f "$_in_dir/webs/Module_bifrost.asp" "$_in_web_stage/Module_bifrost.asp"; then
    echo_date "暂存网页外壳文件失败，退出安装"
    log install "failed to stage Module_bifrost.asp"
    exit 1
fi
_in_js=$(sed -n 's@.*src="/res/\(bifrost-app\.[0-9a-f]\{20\}\.js\)".*@\1@p' "$_in_web_stage/Module_bifrost.asp" 2>/dev/null | head -n 1)
if [ -z "$_in_js" ]; then
    echo_date "安装页缺少有效的资源文件名，退出安装"
    log install "asp missing hashed asset filename"
    exit 1
fi
_in_css=${_in_js%.js}.css
for _in_asset in "$_in_js" "$_in_css"; do
    if [ ! -s "$_in_dir/res/$_in_asset" ] || ! cp -f "$_in_dir/res/$_in_asset" "$_in_web_stage/$_in_asset" || [ ! -s "$_in_web_stage/$_in_asset" ]; then
        echo_date "安装包缺少网页资源 $_in_asset，退出安装"
        log install "package missing or failed to stage web asset: $_in_asset"
        exit 1
    fi
done

_in_save() {
    if grep -Fxq "$1" "$_in_web_stage/paths"; then return 0; fi
    _in_count=$((_in_count + 1))
    if [ -e "$1" ] || [ -L "$1" ]; then
        cp -a "$1" "$_in_web_stage/save.$_in_count" || return 1
    fi
    printf '%s\n' "$1" >>"$_in_web_stage/paths"
}

_in_snapshot() {
    _in_count=0
    : >"$_in_web_stage/paths" || return 1
    # Save the private tree first, including the matching core and manifest.
    for _is_path in "$BIFROST_HOME" "$BIFROST_SCRIPTS/uninstall_bifrost.sh" \
        "$BIFROST_KSBIN/bifrost" "$BIFROST_INITD/S99bifrost.sh" "$BIFROST_INITD/N99bifrost.sh" \
        "$BIFROST_WEBS/Module_bifrost.asp" "$BIFROST_RES/icon-bifrost.png" \
        "$BIFROST_RES/$_in_js" "$BIFROST_RES/$_in_css" \
        "$BIFROST_RES/.bifrost-app.new.$$" "$BIFROST_WEBS/.bifrost-app.new.$$"; do
        _in_save "$_is_path" || return 1
    done
    for _is_path in "$_in_dir"/scripts/bifrost_*.sh; do
        [ -f "$_is_path" ] || continue
        _in_save "$BIFROST_SCRIPTS/${_is_path##*/}" || return 1
    done
    for _is_path in "$BIFROST_RES"/bifrost-app.*; do
        if printf '%s\n' "${_is_path##*/}" | grep -Eq '^bifrost-app\.[0-9a-f]{20}\.(js|css)$'; then
            _in_save "$_is_path" || return 1
        fi
    done
    dbus list bifrost_ >"$_in_web_stage/dbus" &&
        dbus list softcenter_module_bifrost_ >>"$_in_web_stage/dbus"
}

_in_keys="$BIFROST_KEYS_ALL bifrost_version"
for _in_field in install name title description version; do
    _in_keys="$_in_keys softcenter_module_bifrost_$_in_field"
done
if ! _in_snapshot; then
    echo_date "无法备份现有安装，退出安装"
    exit 1
fi

# Step 2: fresh install vs upgrade (PLAN 15.1 step 2).
_in_upgrade=0
if grep -Fxq softcenter_module_bifrost_install=1 "$_in_web_stage/dbus"; then
    _in_upgrade=1
fi

# Step 3: on upgrade, remember running state and require daemon_stop to succeed (PLAN 15.1 step 3).
_in_was_running=0
if [ "$_in_upgrade" = 1 ]; then
    if daemon_running; then
        _in_was_running=1
    fi
    if ! has_cmd daemon_stop; then
        echo_date "缺少 daemon_stop 函数，无法安全停止旧服务，退出升级"
        log install "daemon_stop function unavailable; aborting upgrade"
        exit 1
    fi
    if [ "$_in_was_running" = 1 ]; then
        echo_date "正在停止运行中的 Bifrost 服务..."
        log install "stopping running daemon for upgrade"
    fi
    _in_need_restart=$_in_was_running
    if ! daemon_stop || daemon_running; then
        echo_date "停止 Bifrost 服务失败，已中止升级，请稍后重试"
        log install "daemon_stop failed or daemon still running; aborting upgrade"
        exit 1
    fi
fi

# Step 4: install core via P1 core_install_file (handles serial check, raw_sha256,
# --version probe, symlink and manifest write with top-level arch; PLAN 15.1 step 4).
_in_dirty=1
mkdir -p "$BIFROST_BIN" "$BIFROST_LIB" "$BIFROST_KEYS" \
    "$BIFROST_SCRIPTS" "$BIFROST_WEBS" "$BIFROST_RES" "$BIFROST_INITD" "$BIFROST_KSBIN" || {
    echo_date "创建安装目录失败，退出安装"
    log install "failed to create install directories"
    exit 1
}

BIFROST_ERR=""
_in_core_ok=0
if has_cmd core_install_file; then
    echo_date "正在安装并校验 Bifrost 核心（$_in_pkg_arch）..."
    if core_install_file "$_in_dir/bin/bifrostd.gz" "$_in_dir/bin/core.json" "$_in_pkg_arch"; then
        _in_core_ok=1
    fi
else
    BIFROST_ERR=not_implemented
fi

if [ "$_in_core_ok" = 1 ]; then
    ln -sf bifrostd "$BIFROST_CLI" || exit 1
    # Core updates no longer keep a rollback archive on internal flash; remove
    # one left by an older release. A pending journal still needs it.
    if [ -e "$BIFROST_BIN/bifrostd.prev.gz" ] && [ ! -d "$BIFROST_HOME/.core-update" ] &&
        core_storage && [ "$_CS_KIND" = internal ]; then
        if core_prev_drop; then
            echo_date "核心安装在路由器内置闪存上，已删除上一版核心备份以节省空间"
            log install "previous core removed from internal flash"
        else
            log install "failed to remove previous core from internal flash"
        fi
    fi
else
    if [ "$_in_upgrade" = 1 ]; then
        # core_install_file may fail after replacing the binary but before writing its manifest.
        _in_restore_path "$BIFROST_HOME" "$_in_web_stage/save.1" || exit 1
        if [ -x "$BIFROST_CORE" ]; then
            echo_date "新核心安装或校验失败（${BIFROST_ERR:-unknown}），保留原有核心继续使用"
            log install "core_install_file failed (${BIFROST_ERR:-unknown}) on upgrade; keeping old core"
            ln -sf bifrostd "$BIFROST_CLI" || exit 1
        else
            echo_date "新核心校验失败（${BIFROST_ERR:-unknown}）且原核心不可用，中止升级（保留现有设置）"
            log install "core_install_file failed (${BIFROST_ERR:-unknown}) on upgrade with no usable old core"
            exit 1
        fi
    else
        echo_date "核心安装或校验失败（${BIFROST_ERR:-unknown}），停止安装并清理"
        log install "core_install_file failed (${BIFROST_ERR:-unknown}) on fresh install; cleaning up"
        exit 1
    fi
fi

# Step 5: install scripts, libraries, icon, keys, licenses, symlinks, CLI wrapper (PLAN 15.1 step 5).
_in_copy_files() {
    for _ic_f in "$_in_dir"/scripts/bifrost_*.sh; do
        [ -f "$_ic_f" ] || continue
        _ic_dst="$BIFROST_SCRIPTS/${_ic_f##*/}"
        # Keep ownership across upgrades, even if a later package drops a script.
        _ic_name=${_ic_f##*/}
        if ! grep -Fxq "$_ic_name" "$BIFROST_HOME/installed.scripts" 2>/dev/null; then
            printf '%s\n' "$_ic_name" >>"$BIFROST_HOME/installed.scripts" || return 1
        fi
        cp -f "$_ic_f" "$_ic_dst" || return 1
        chmod 755 "$_ic_dst" || return 1
    done
    # The installed entry must still boot and take the state lock after the
    # private library tree has been retired. Embed the actual package defaults.
    {
        printf '#!/bin/sh\n' &&
            cat "$_in_dir/lib/env.sh" "$_in_dir/lib/validate.sh" "$_in_dir/lib/common.sh" "$_in_dir/uninstall.sh"
    } >"$BIFROST_SCRIPTS/uninstall_bifrost.sh" || return 1
    chmod 755 "$BIFROST_SCRIPTS/uninstall_bifrost.sh" || return 1

    for _ic_f in "$_in_dir"/lib/*.sh; do
        [ -f "$_ic_f" ] || continue
        cp -f "$_ic_f" "$BIFROST_LIB/${_ic_f##*/}" || return 1
        chmod 644 "$BIFROST_LIB/${_ic_f##*/}" || return 1
    done

    cp -f "$_in_dir/version" "$BIFROST_VERSION_FILE" || return 1
    chmod 644 "$BIFROST_VERSION_FILE" || return 1

    if [ -f "$_in_dir/res/icon-bifrost.png" ]; then
        cp -f "$_in_dir/res/icon-bifrost.png" "$BIFROST_RES/icon-bifrost.png" || return 1
        chmod 644 "$BIFROST_RES/icon-bifrost.png" || return 1
    fi

    _ic_has_key=0
    for _ic_k in "$_in_dir"/keys/*.pub.pem; do
        [ -f "$_ic_k" ] || continue
        _ic_has_key=1
        break
    done
    if [ "$_ic_has_key" = 1 ]; then
        rm -f "$BIFROST_KEYS"/*.pub.pem || return 1
        for _ic_k in "$_in_dir"/keys/*.pub.pem; do
            [ -f "$_ic_k" ] || continue
            cp -f "$_ic_k" "$BIFROST_KEYS/${_ic_k##*/}" || return 1
            chmod 644 "$BIFROST_KEYS/${_ic_k##*/}" || return 1
        done
    fi

    for _ic_doc in LICENSE LICENSE.tailscale NOTICE.md THIRD_PARTY_NOTICES.core.md; do
        if [ -f "$_in_dir/$_ic_doc" ]; then
            cp -f "$_in_dir/$_ic_doc" "$BIFROST_HOME/$_ic_doc" || return 1
            chmod 644 "$BIFROST_HOME/$_ic_doc" || return 1
        fi
    done

    ln -sf "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_INITD/S99bifrost.sh" || return 1
    ln -sf "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_INITD/N99bifrost.sh" || return 1

    cp -f "$_in_dir/bin/bifrost" "$BIFROST_KSBIN/bifrost" || return 1
    chmod 755 "$BIFROST_KSBIN/bifrost" || return 1

}

if ! _in_copy_files; then
    echo_date "复制插件文件失败，退出安装"
    log install "failed to copy plugin files"
    exit 1
fi

# Step 6: atomic web asset and ASP replacement from staged snapshot (PLAN 15.1 step 6).
_in_publish() {
    _ip_tmp="${2%/*}/.bifrost-app.new.$$"
    if cp -f "$1" "$_ip_tmp" && mv -f "$_ip_tmp" "$2"; then
        return 0
    fi
    rm -f "$_ip_tmp"
    return 1
}

_in_page="$BIFROST_WEBS/Module_bifrost.asp"
if ! _in_publish "$_in_web_stage/$_in_js" "$BIFROST_RES/$_in_js" ||
   ! _in_publish "$_in_web_stage/$_in_css" "$BIFROST_RES/$_in_css" ||
   ! _in_publish "$_in_web_stage/Module_bifrost.asp" "$_in_page"; then
    echo_date "网页资源安装失败，退出安装"
    log install "failed to publish web assets"
    exit 1
fi

for _in_old in "$BIFROST_RES"/bifrost-app.*.js "$BIFROST_RES"/bifrost-app.*.css; do
    [ -e "$_in_old" ] || continue
    _in_base=${_in_old##*/}
    case "$_in_base" in
        "$_in_js" | "$_in_css") continue ;;
    esac
    if printf '%s\n' "$_in_base" | grep -Eq '^bifrost-app\.[0-9a-f]{20}\.(js|css)$'; then
        rm -f "$_in_old" || {
            echo_date "清理旧网页资源失败：$_in_base"
            log install "failed to remove stale web asset: $_in_base"
            exit 1
        }
    fi
done

# Step 7: register software center and plugin dbus keys (PLAN 4.2 & 15.1 step 7).
_in_dbus_dirty=1
for _in_k in $BIFROST_KEYS_ALL; do
    _in_def=$(bifrost_default "$_in_k")
    if [ "$_in_upgrade" = 0 ]; then
        if [ -n "$_in_def" ]; then
            dbus set "$_in_k=$_in_def" >/dev/null 2>&1 || exit 1
        else
            dbus remove "$_in_k" >/dev/null 2>&1 || exit 1
        fi
    else
        if [ -z "$(dbus get "$_in_k" 2>/dev/null)" ] && [ -n "$_in_def" ]; then
            dbus set "$_in_k=$_in_def" >/dev/null 2>&1 || exit 1
        fi
    fi
done

[ "$_in_upgrade" = 0 ] || dbus remove bifrost_version >/dev/null 2>&1 || exit 1
dbus set softcenter_module_bifrost_install=1 >/dev/null 2>&1 || exit 1
dbus set softcenter_module_bifrost_name=bifrost >/dev/null 2>&1 || exit 1
dbus set softcenter_module_bifrost_title="Bifrost" >/dev/null 2>&1 || exit 1
dbus set softcenter_module_bifrost_description="非官方 Tailscale 插件（与 Tailscale Inc. 无关），支持原版迁移与自建控制服务器" >/dev/null 2>&1 || exit 1
dbus set softcenter_module_bifrost_version="$_in_ver" >/dev/null 2>&1 || exit 1

# Steps 8-9: restart on upgrade if previously running; do not start on fresh install.
# Step 10: $BIFROST_STATE is never modified during install or upgrade.
if [ "$_in_upgrade" = 1 ]; then
    if [ "$_in_was_running" = 1 ]; then
        _in_starting=1
        echo_date "正在重新启动 Bifrost 服务..."
        log install "restarting daemon after upgrade"
        if ! has_cmd daemon_start || ! daemon_start; then
            echo_date "Bifrost 重启失败（${BIFROST_ERR:-unknown}），请到插件页面查看状态"
            log install "daemon_start failed after upgrade: ${BIFROST_ERR:-unknown}"
            exit 1
        fi
    fi
    echo_date "Bifrost $_in_ver 升级完成"
    log install "upgraded to $_in_ver"
else
    if orig_installed; then
        echo_date "检测到原版 tailscale 插件，安装未改动原版；可在 Bifrost 页面中点击「迁移并切换」"
        log install "original plugin detected on fresh install"
    fi
    echo_date "Bifrost $_in_ver 安装完成"
    log install "installed $_in_ver"
fi
exit 0
