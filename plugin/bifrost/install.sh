#!/bin/sh
# Bifrost installer and upgrader for KoolCenter / Koolshare software center.
# Follows docs/PLAN.md section 15.1 and docs/dev/contract.md section 2 & 7.
# Page asset atomic swap and dbus registration adapted from po0fw asus-merlin (MIT), commit 0d9532d.

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
# shellcheck disable=SC1091
. "$BIFROST_SCRIPTS/base.sh"
# shellcheck source=plugin/bifrost/lib/validate.sh
. "$_in_dir/lib/validate.sh"
# shellcheck source=plugin/bifrost/lib/common.sh
. "$_in_dir/lib/common.sh"
if ! has_cmd echo_date; then
    echo_date() { echo "$@"; }
fi

for _in_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$_in_dir/lib/$_in_m.sh" ] && . "$_in_dir/lib/$_in_m.sh"
done

_in_lock_held=0
# shellcheck disable=SC2329
_in_on_exit() {
    if [ "$_in_lock_held" = 1 ]; then
        lock_release state
        _in_lock_held=0
    fi
}
trap '_in_on_exit' EXIT
trap '_in_on_exit; exit 130' INT
trap '_in_on_exit; exit 143' TERM

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
_in_pkg_serial=$(jq -r '.serial // empty' "$_in_dir/bin/core.json" 2>/dev/null)
if ! valid_arch "$_in_pkg_arch" || ! valid_uint "$_in_pkg_serial"; then
    echo_date "安装包核心清单格式无效，退出安装"
    log install "invalid package core manifest"
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
_in_js=$(sed -n 's@.*src="/res/\(bifrost-app\.[0-9a-f]\{20\}\.js\)".*@\1@p' "$_in_dir/webs/Module_bifrost.asp" 2>/dev/null | head -n 1)
if [ -z "$_in_js" ]; then
    echo_date "安装页缺少有效的资源文件名，退出安装"
    log install "asp missing hashed asset filename"
    exit 1
fi
_in_css=${_in_js%.js}.css
for _in_asset in "$_in_js" "$_in_css"; do
    if [ ! -s "$_in_dir/res/$_in_asset" ]; then
        echo_date "安装包缺少网页资源 $_in_asset，退出安装"
        log install "package missing web asset: $_in_asset"
        exit 1
    fi
done

for _in_req in scripts/bifrost_config.sh scripts/bifrost_status.sh uninstall.sh; do
    if [ ! -s "$_in_dir/$_in_req" ]; then
        echo_date "安装包缺少 $_in_req，退出安装"
        log install "package missing $_in_req"
        exit 1
    fi
done

# Cleanup helper for a failed fresh install (never touches $BIFROST_STATE).
_in_cleanup_fresh() {
    rm -rf "$BIFROST_HOME"
    rm -f "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_SCRIPTS/bifrost_status.sh" \
        "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
    rm -f "$BIFROST_INITD/S99bifrost.sh" "$BIFROST_INITD/N99bifrost.sh"
    rm -f "$BIFROST_KSBIN/bifrost"
    rm -f "$BIFROST_RES/icon-bifrost.png" "$BIFROST_RES/$_in_js" "$BIFROST_RES/$_in_css" \
        "$BIFROST_RES"/.bifrost-app.new "$BIFROST_RES"/.bifrost-app.new.*
    rm -f "$BIFROST_WEBS/Module_bifrost.asp" \
        "$BIFROST_WEBS"/.bifrost-app.new "$BIFROST_WEBS"/.bifrost-app.new.*
}

# Step 2: fresh install vs upgrade (PLAN 15.1 step 2).
_in_upgrade=0
if [ "$(dbus get softcenter_module_bifrost_install 2>/dev/null)" = 1 ]; then
    _in_upgrade=1
fi

# Step 3: on upgrade, remember running state and stop the daemon (PLAN 15.1 step 3).
_in_was_running=0
if [ "$_in_upgrade" = 1 ]; then
    if daemon_running; then
        _in_was_running=1
    fi
    if [ "$_in_was_running" = 1 ]; then
        echo_date "正在停止运行中的 Bifrost 服务..."
        log install "stopping running daemon for upgrade"
    fi
    if has_cmd daemon_stop; then
        if ! daemon_stop; then
            echo_date "停止 Bifrost 服务失败，退出安装"
            log install "daemon_stop failed"
            exit 1
        fi
    fi
fi

# Step 4: install core (PLAN 15.1 step 4).
mkdir -p "$BIFROST_BIN" "$BIFROST_LIB" "$BIFROST_KEYS" \
    "$BIFROST_SCRIPTS" "$BIFROST_WEBS" "$BIFROST_RES" "$BIFROST_INITD" "$BIFROST_KSBIN" || {
    echo_date "创建安装目录失败，退出安装"
    log install "failed to create install directories"
    [ "$_in_upgrade" = 0 ] && _in_cleanup_fresh
    exit 1
}

_in_skip_core=0
if [ "$_in_upgrade" = 1 ] && [ -x "$BIFROST_CORE" ] && [ -f "$BIFROST_MANIFEST" ]; then
    _in_cur_serial=$(jq -r '.serial // empty' "$BIFROST_MANIFEST" 2>/dev/null)
    if valid_uint "$_in_cur_serial" && [ "$_in_cur_serial" -gt "$_in_pkg_serial" ]; then
        _in_skip_core=1
        echo_date "已安装的核心更新（serial $_in_cur_serial > $_in_pkg_serial），保留现有核心，不降级"
        log install "keeping newer installed core serial=$_in_cur_serial over package serial=$_in_pkg_serial"
        ln -sf bifrostd "$BIFROST_CLI"
    fi
fi

if [ "$_in_skip_core" = 0 ]; then
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
        ln -sf bifrostd "$BIFROST_CLI"
        if [ "$(jq -r '.serial // empty' "$BIFROST_MANIFEST" 2>/dev/null)" != "$_in_pkg_serial" ]; then
            atomic_write "$BIFROST_MANIFEST" 644 <"$_in_dir/bin/core.json" || {
                echo_date "写入核心清单失败，退出安装"
                log install "failed to write installed core manifest"
                [ "$_in_upgrade" = 0 ] && _in_cleanup_fresh
                exit 1
            }
        fi
    else
        rm -f "$BIFROST_CORE.new"
        if [ "$_in_upgrade" = 1 ] && [ -x "$BIFROST_CORE" ]; then
            echo_date "新核心安装或校验失败（${BIFROST_ERR:-unknown}），保留原有核心继续使用"
            log install "core_install_file failed (${BIFROST_ERR:-unknown}) on upgrade; keeping old core"
            ln -sf bifrostd "$BIFROST_CLI"
        else
            echo_date "核心安装或校验失败（${BIFROST_ERR:-unknown}），停止安装并清理"
            log install "core_install_file failed (${BIFROST_ERR:-unknown}) on fresh install; cleaning up"
            _in_cleanup_fresh
            exit 1
        fi
    fi
fi

# Step 5: install scripts, libraries, icon, keys, licenses, symlinks, CLI wrapper (PLAN 15.1 step 5).
_in_copy_files() {
    for _ic_f in "$_in_dir"/scripts/bifrost_*.sh; do
        [ -f "$_ic_f" ] || continue
        cp -f "$_ic_f" "$BIFROST_SCRIPTS/${_ic_f##*/}" || return 1
        chmod 755 "$BIFROST_SCRIPTS/${_ic_f##*/}" || return 1
    done
    cp -f "$_in_dir/uninstall.sh" "$BIFROST_SCRIPTS/uninstall_bifrost.sh" || return 1
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
        rm -f "$BIFROST_KEYS"/*.pub.pem
        for _ic_k in "$_in_dir"/keys/*.pub.pem; do
            [ -f "$_ic_k" ] || continue
            cp -f "$_ic_k" "$BIFROST_KEYS/${_ic_k##*/}" || return 1
            chmod 644 "$BIFROST_KEYS/${_ic_k##*/}" || return 1
        done
    fi

    for _ic_doc in LICENSE LICENSE.tailscale NOTICE.md; do
        if [ -f "$_in_dir/$_ic_doc" ]; then
            cp -f "$_in_dir/$_ic_doc" "$BIFROST_HOME/$_ic_doc" || return 1
            chmod 644 "$BIFROST_HOME/$_ic_doc" || return 1
        fi
    done

    ln -sf "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_INITD/S99bifrost.sh" || return 1
    ln -sf "$BIFROST_SCRIPTS/bifrost_config.sh" "$BIFROST_INITD/N99bifrost.sh" || return 1

    if [ -f "$_in_dir/bin/bifrost" ]; then
        cp -f "$_in_dir/bin/bifrost" "$BIFROST_KSBIN/bifrost" || return 1
        chmod 755 "$BIFROST_KSBIN/bifrost" || return 1
    else
        cat >"$BIFROST_KSBIN/bifrost" <<'EOF' || return 1
#!/bin/sh
# Fallback CLI wrapper when packaged before bin/bifrost exists.
_bf_ks=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "${BIFROST_LIB:-$_bf_ks/bifrost/lib}/env.sh"
exec "$BIFROST_CLI" --socket="$BIFROST_SOCK" "$@"
EOF
        chmod 755 "$BIFROST_KSBIN/bifrost" || return 1
    fi
}

if ! _in_copy_files; then
    echo_date "复制插件文件失败，退出安装"
    log install "failed to copy plugin files"
    [ "$_in_upgrade" = 0 ] && _in_cleanup_fresh
    exit 1
fi

# Step 6: atomic web asset and ASP replacement (PLAN 15.1 step 6).
_in_publish() {
    _ip_tmp="${2%/*}/.bifrost-app.new.$$"
    if cp -f "$1" "$_ip_tmp" && mv -f "$_ip_tmp" "$2"; then
        return 0
    fi
    rm -f "$_ip_tmp"
    return 1
}

_in_page="$BIFROST_WEBS/Module_bifrost.asp"
if ! _in_publish "$_in_dir/res/$_in_js" "$BIFROST_RES/$_in_js" ||
   ! _in_publish "$_in_dir/res/$_in_css" "$BIFROST_RES/$_in_css" ||
   ! _in_publish "$_in_dir/webs/Module_bifrost.asp" "$_in_page"; then
    if ! grep -Fq "src=\"/res/$_in_js\"" "$_in_page" 2>/dev/null; then
        rm -f "$BIFROST_RES/$_in_js" "$BIFROST_RES/$_in_css"
    fi
    echo_date "网页资源安装失败，退出安装"
    log install "failed to publish web assets"
    [ "$_in_upgrade" = 0 ] && _in_cleanup_fresh
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

# Step 7: register software center and plugin dbus keys (PLAN 15.1 step 7).
for _in_k in $BIFROST_KEYS_ALL; do
    _in_def=$(bifrost_default "$_in_k")
    if [ "$_in_upgrade" = 0 ]; then
        if [ -n "$_in_def" ]; then
            dbus set "$_in_k=$_in_def" >/dev/null 2>&1
        else
            dbus remove "$_in_k" >/dev/null 2>&1
        fi
    else
        if [ -z "$(dbus get "$_in_k" 2>/dev/null)" ] && [ -n "$_in_def" ]; then
            dbus set "$_in_k=$_in_def" >/dev/null 2>&1
        fi
    fi
done

dbus set bifrost_version="$_in_ver" >/dev/null 2>&1
dbus set softcenter_module_bifrost_install=1 >/dev/null 2>&1
dbus set softcenter_module_bifrost_name=bifrost >/dev/null 2>&1
dbus set softcenter_module_bifrost_title="Bifrost" >/dev/null 2>&1
dbus set softcenter_module_bifrost_description="非官方 Tailscale 插件（与 Tailscale Inc. 无关），支持原版迁移与自建控制服务器" >/dev/null 2>&1
dbus set softcenter_module_bifrost_version="$_in_ver" >/dev/null 2>&1

# Steps 8-9: restart on upgrade if previously running; do not start on fresh install.
# Step 10: $BIFROST_STATE is never modified during install or upgrade.
if [ "$_in_upgrade" = 1 ]; then
    if [ "$_in_was_running" = 1 ]; then
        echo_date "正在重新启动 Bifrost 服务..."
        log install "restarting daemon after upgrade"
        if has_cmd daemon_start; then
            if ! daemon_start; then
                echo_date "Bifrost 重启失败（${BIFROST_ERR:-unknown}），请到插件页面查看状态"
                log install "daemon_start failed after upgrade: ${BIFROST_ERR:-unknown}"
            fi
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
