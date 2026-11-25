#!/bin/sh
# Comprehensive install, upgrade and uninstall tests for plugin/bifrost/install.sh
# and plugin/bifrost/uninstall.sh (PLAN sections 13.11 & 15).
# Uses the real P1/P2/P3 libraries (update.sh, daemon.sh, fw.sh, dns.sh, status.sh)
# with the BusyBox test image's mock core and mock commands; stubs are injected
# ONLY to trigger specific fault/timing scenarios.
# Page asset swap & concurrency checks adapted from po0fw asus-merlin (MIT), commit 0d9532d.

# shellcheck source=tests/shell/lib.sh
. tests/shell/lib.sh

# shellcheck source=tests/install/lib.sh
. tests/install/lib.sh

# Helper to verify no file matching a glob exists without silencing _t_fail.
no_glob() {
    _ng_name=$1
    shift
    _ng_found=0
    for _ng_f in "$@"; do
        [ -e "$_ng_f" ] && _ng_found=1
    done
    eq "$_ng_name" 0 "$_ng_found"
}

# make_pkg <dir> <version> <serial> <arch> <js_body> <css_body> [core_mode]
# Uses the real plugin/bifrost/lib/*.sh and plugin/bifrost/bin/bifrost.
# core_mode: ok (default) | bad_hash | bad_version
# Prints the 20-char asset hash.
make_pkg() {
    _mp_dir=$1
    _mp_ver=$2
    _mp_ser=$3
    _mp_arch=$4
    _mp_js=$5
    _mp_css=$6
    _mp_cmode=${7:-ok}

    rm -rf "$_mp_dir"
    mkdir -p "$_mp_dir/bin" "$_mp_dir/lib" "$_mp_dir/scripts" \
        "$_mp_dir/webs" "$_mp_dir/res" "$_mp_dir/keys"

    cp "$T_SRC/plugin/bifrost/.valid" "$_mp_dir/.valid"
    cp "$T_SRC/plugin/bifrost/install.sh" "$_mp_dir/install.sh"
    cp "$T_SRC/plugin/bifrost/uninstall.sh" "$_mp_dir/uninstall.sh"
    cp "$T_SRC/plugin/bifrost/scripts/bifrost_config.sh" "$_mp_dir/scripts/"
    cp "$T_SRC/plugin/bifrost/scripts/bifrost_status.sh" "$_mp_dir/scripts/"
    cp "$T_SRC"/plugin/bifrost/lib/*.sh "$_mp_dir/lib/"
    cp "$T_SRC/plugin/bifrost/bin/bifrost" "$_mp_dir/bin/bifrost"
    chmod 755 "$_mp_dir/bin/bifrost"
    printf '%s\n' "$_mp_ver" >"$_mp_dir/version"
    printf 'fake-png-icon\n' >"$_mp_dir/res/icon-bifrost.png"
    printf 'MIT License\n' >"$_mp_dir/LICENSE"
    printf 'BSD-3-Clause\n' >"$_mp_dir/LICENSE.tailscale"
    printf 'Third-party notices\n' >"$_mp_dir/NOTICE.md"
    printf 'Core third-party notices\n' >"$_mp_dir/THIRD_PARTY_NOTICES.core.md"
    printf -- '-----BEGIN PUBLIC KEY-----\nTESTKEY\n-----END PUBLIC KEY-----\n' >"$_mp_dir/keys/dev.pub.pem"

    # Build fake core binary (embed serial comment so different serials have distinct hashes).
    _mp_raw="$_mp_dir/bin/bifrostd.raw"
    cp "$T_SRC/tests/shell/mock/bifrostd" "$_mp_raw"
    printf '\n# fake-core-serial=%s\n' "$_mp_ser" >>"$_mp_raw"
    if [ "$_mp_cmode" = bad_version ]; then
        printf '#!/bin/sh\necho 0.0.0-broken\n' >"$_mp_raw"
    fi
    chmod 755 "$_mp_raw"
    gzip -9 -c "$_mp_raw" >"$_mp_dir/bin/bifrostd.gz"

    _mp_raw_sha=$(openssl dgst -sha256 -r "$_mp_raw" | cut -d ' ' -f 1)
    _mp_raw_size=$(wc -c <"$_mp_raw" | tr -d ' ')
    _mp_gz_sha=$(openssl dgst -sha256 -r "$_mp_dir/bin/bifrostd.gz" | cut -d ' ' -f 1)
    _mp_gz_size=$(wc -c <"$_mp_dir/bin/bifrostd.gz" | tr -d ' ')
    rm -f "$_mp_raw"

    if [ "$_mp_cmode" = bad_hash ]; then
        _mp_raw_sha="0000000000000000000000000000000000000000000000000000000000000000"
    fi

    jq -n \
        --argjson ser "$_mp_ser" \
        --arg arch "$_mp_arch" \
        --arg gz_sha "$_mp_gz_sha" \
        --argjson gz_size "$_mp_gz_size" \
        --arg raw_sha "$_mp_raw_sha" \
        --argjson raw_size "$_mp_raw_size" \
        '{
          schema: 1, serial: $ser, tailscale: "1.104.7", revision: 1,
          tag: "core-1.104.7-1", min_plugin: "0.1.0",
          build: { go: "1.27.4", commit: "cbc74fe48ef1b1649f69a4d9a602319427e25102", omit: ["aws"] },
          assets: { ($arch): {
            file: ("bifrost-core-1.104.7-1-linux-" + $arch + ".gz"),
            size: $gz_size, sha256: $gz_sha,
            raw_size: $raw_size, raw_sha256: $raw_sha
          } }
        }' >"$_mp_dir/bin/core.json"

    # Compute 20-hex combined digest over JS and CSS (contract section 10).
    _mp_hash=$(printf '%s\n%s\n' "$_mp_js" "$_mp_css" | openssl dgst -sha256 -r | cut -c1-20)
    printf '%s\n' "$_mp_js" >"$_mp_dir/res/bifrost-app.$_mp_hash.js"
    printf '%s\n' "$_mp_css" >"$_mp_dir/res/bifrost-app.$_mp_hash.css"

    cat >"$_mp_dir/webs/Module_bifrost.asp" <<EOF
<!DOCTYPE html>
<html>
<body id="app" skin="ASUSWRT" onload="init();">
<div id="bifrost-app"></div>
<script defer src="/res/bifrost-app.$_mp_hash.js"></script>
</body>
</html>
EOF
    printf '%s\n' "$_mp_hash"
}

check_assets() {
    _ca_label=$1
    _ca_hash=$2
    _ca_js="bifrost-app.$_ca_hash.js"
    _ca_css="bifrost-app.$_ca_hash.css"
    ok "$_ca_label-asp-ref" grep -Fq "src=\"/res/$_ca_js\"" "$BIFROST_WEBS/Module_bifrost.asp"
    ok "$_ca_label-js-exists" test -s "$BIFROST_RES/$_ca_js"
    ok "$_ca_label-css-exists" test -s "$BIFROST_RES/$_ca_css"
    # shellcheck disable=SC2012
    _ca_got=$(ls -1A "$BIFROST_RES" | sed '/^icon-tailscale\.png$/d' | sort)
    _ca_want=$(printf '%s\n' "$_ca_js" "$_ca_css" icon-bifrost.png unrelated.js bifrost-app.notes.css | sort)
    eq "$_ca_label-res-exact" "$_ca_want" "$_ca_got"
    no_glob "$_ca_label-no-asp-tmp" "$BIFROST_WEBS"/.bifrost-app.new*
    no_glob "$_ca_label-no-res-tmp" "$BIFROST_RES"/.bifrost-app.new*
}

# =====================================================================
# 1. Fresh install with REAL libs (files, symlinks, dbus defaults, does not start)
# =====================================================================
inst_setup
mkdir -p "$BIFROST_ORIG_STATE"
printf 'orig-state\n' >"$BIFROST_ORIG_STATE/tailscaled.state"
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"

h1=$(make_pkg "$T/pkgs/v1" "0.1.0" 1 arm "console.log('v1');" ":host{color:#111;}")
# Add an extra scripts/bifrost_extra.sh to verify install + uninstall track dynamic scripts (Item 11).
printf '#!/bin/sh\necho extra\n' >"$T/pkgs/v1/scripts/bifrost_extra.sh"
# The software center runs install.sh with umask 0.
out=$(umask 000; sh "$T/pkgs/v1/install.sh" 2>&1)
eq fresh-rc 0 "$?"
has fresh-done "安装完成" "$out"
has fresh-orig-hint "迁移" "$out"
eq fresh-orig-untouched "orig-state" "$(cat "$BIFROST_ORIG_STATE/tailscaled.state")"
no fresh-no-command-v test -e "$MOCK_STATE/used-command"

# Installed files, symlinks, real core_install_file manifest with top-level arch (contract 8)
ok fresh-core test -x "$BIFROST_CORE"
eq fresh-cli-link "bifrostd" "$(readlink "$BIFROST_CLI")"
eq fresh-manifest-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"
eq fresh-manifest-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq fresh-manifest-asset-len 1 "$(jq -r '.assets | length' "$BIFROST_MANIFEST")"
eq fresh-version-file "0.1.0" "$(cat "$BIFROST_VERSION_FILE")"
ok fresh-license test -f "$BIFROST_HOME/LICENSE"
ok fresh-license-ts test -f "$BIFROST_HOME/LICENSE.tailscale"
ok fresh-notice test -f "$BIFROST_HOME/NOTICE.md"
ok fresh-core-notice test -f "$BIFROST_HOME/THIRD_PARTY_NOTICES.core.md"
ok fresh-key test -f "$BIFROST_KEYS/dev.pub.pem"
ok fresh-cfg-script test -x "$BIFROST_SCRIPTS/bifrost_config.sh"
ok fresh-status-script test -x "$BIFROST_SCRIPTS/bifrost_status.sh"
ok fresh-extra-script test -x "$BIFROST_SCRIPTS/bifrost_extra.sh"
ok fresh-uninst-script test -x "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
eq fresh-s99 "$BIFROST_SCRIPTS/bifrost_config.sh" "$(readlink "$BIFROST_INITD/S99bifrost.sh")"
eq fresh-n99 "$BIFROST_SCRIPTS/bifrost_config.sh" "$(readlink "$BIFROST_INITD/N99bifrost.sh")"
ok fresh-ksbin test -x "$BIFROST_KSBIN/bifrost"
check_assets fresh "$h1"
for _m_d in "$BIFROST_HOME" "$BIFROST_BIN" "$BIFROST_LIB" "$BIFROST_KEYS"; do
    # shellcheck disable=SC2012
    eq "fresh-mode-${_m_d##*/}" "drwxr-xr-x" "$(ls -ld "$_m_d" | cut -c1-10)"
done
# shellcheck disable=SC2012
eq fresh-mode-installed-scripts "-rw-r--r--" "$(ls -l "$BIFROST_HOME/installed.scripts" | cut -c1-10)"

# dbus defaults & software center registration (NO bifrost_version key per Item 8)
eq fresh-dbus-install 1 "$(dbus get softcenter_module_bifrost_install)"
eq fresh-dbus-name bifrost "$(dbus get softcenter_module_bifrost_name)"
eq fresh-dbus-title Bifrost "$(dbus get softcenter_module_bifrost_title)"
has fresh-dbus-desc "Tailscale" "$(dbus get softcenter_module_bifrost_description)"
eq fresh-dbus-scver "0.1.0" "$(dbus get softcenter_module_bifrost_version)"
eq fresh-no-bifrost-ver "" "$(dbus get bifrost_version)"
eq fresh-def-enable 0 "$(dbus get bifrost_enable)"
eq fresh-def-port 41641 "$(dbus get bifrost_port)"
eq fresh-def-local 1 "$(dbus get bifrost_local_access)"
eq fresh-def-masq 1 "$(dbus get bifrost_lan_masq)"
eq fresh-def-snat auto "$(dbus get bifrost_snat)"
eq fresh-def-magicdns 0 "$(dbus get bifrost_magicdns)"
eq fresh-def-nologs 1 "$(dbus get bifrost_no_logs)"
eq fresh-def-mirror "" "$(dbus get bifrost_mirror)"
eq fresh-def-lang zh-CN "$(dbus get bifrost_ui_lang)"
eq fresh-def-mode dark "$(dbus get bifrost_ui_mode)"

# Fresh install must NOT start daemon and must release lock
no fresh-not-running test -f "$BIFROST_PIDFILE"
no fresh-lock-released test -d "$BIFROST_RUN/lock.state"

# =====================================================================
# 2. Upgrade while running (REAL daemon_start / daemon_stop / core_install_file)
# =====================================================================
dbus set bifrost_enable=1
dbus set bifrost_version=0.1.0
dbus set bifrost_port=51234
dbus set bifrost_snat=on
dbus set bifrost_ui_lang=en
dbus remove bifrost_magicdns
mkdir -p "$BIFROST_STATE"
printf 'keep-this-state\n' >"$BIFROST_STATE/tailscaled.state"

# Start real daemon via real daemon_start (registers watchdog cron, fw rules, PID, socket).
sh -c '
    . "$BIFROST_LIB/env.sh"
    . "$BIFROST_LIB/validate.sh"
    . "$BIFROST_LIB/common.sh"
    for m in daemon fw dns status login settings migrate update diag; do . "$BIFROST_LIB/$m.sh"; done
    daemon_start
'
eq upg-pre-start-rc 0 "$?"
old_pid=$(cat "$BIFROST_PIDFILE")
ok upg-pre-pid-alive kill -0 "$old_pid"
has upg-pre-watchdog "bifrost_watchdog" "$(cru l)"

h2=$(make_pkg "$T/pkgs/v2" "0.2.0" 2 arm "console.log('v2');" ":host{color:#222;}")
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq upg-run-rc 0 "$?"
has upg-run-done "升级完成" "$out"

eq upg-run-port 51234 "$(dbus get bifrost_port)"
eq upg-run-snat on "$(dbus get bifrost_snat)"
eq upg-run-enable 1 "$(dbus get bifrost_enable)"
eq upg-run-lang en "$(dbus get bifrost_ui_lang)"
eq upg-run-missing-filled 0 "$(dbus get bifrost_magicdns)"
eq upg-run-scver "0.2.0" "$(dbus get softcenter_module_bifrost_version)"
eq upg-run-no-bfver "" "$(dbus get bifrost_version)"
eq upg-run-state "keep-this-state" "$(cat "$BIFROST_STATE/tailscaled.state")"
eq upg-run-serial 2 "$(jq -r .serial "$BIFROST_MANIFEST")"
check_assets upg-run "$h2"
new_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null || true)
ok upg-run-restarted-alive test -n "$new_pid"
ok upg-run-pid-running kill -0 "$new_pid"
no upg-run-pid-changed test "$new_pid" = "$old_pid"

# =====================================================================
# 3. Upgrade failure AFTER daemon_stop restores previously running daemon (Item 2)
# =====================================================================
make_pkg "$T/pkgs/v2fail" "0.2.9" 9 arm "console.log('v2fail');" ":host{color:#229;}" >/dev/null
# Force distinct payloads and save references for exact rollback checks.
echo '# upgrade only' >>"$T/pkgs/v2fail/lib/login.sh"
echo '# upgrade only' >>"$T/pkgs/v2fail/scripts/bifrost_config.sh"
cp "$BIFROST_MANIFEST" "$T/old-manifest"
cp "$BIFROST_CORE" "$T/old-core"
mkdir -p "$T/reject-mv"
cat >"$T/reject-mv/mv" <<EOF
#!/bin/sh
for _a in "\$@"; do
    [ "\$_a" = "$BIFROST_WEBS/Module_bifrost.asp" ] && exit 1
done
exec /opt/bb125/busybox mv "\$@"
EOF
chmod 755 "$T/reject-mv/mv"
out=$(PATH="$T/reject-mv:$PATH" sh "$T/pkgs/v2fail/install.sh" 2>&1)
rc=$?
no upg-fail-restore-rc test "$rc" -eq 0
has upg-fail-restore-msg "网页资源安装失败" "$out"
has upg-fail-restore-notice "恢复原 Bifrost 服务" "$out"
check_assets upg-fail-keeps-h2 "$h2"
restored_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null || true)
ok upg-fail-daemon-restored test -n "$restored_pid"
ok upg-fail-daemon-alive kill -0 "$restored_pid"

no upg-fail-lock test -e "$BIFROST_RUN/lock.state"
eq upg-fail-version 0.2.0 "$(cat "$BIFROST_VERSION_FILE")"
eq upg-fail-dbus-version 0.2.0 "$(dbus get softcenter_module_bifrost_version)"
ok upg-fail-manifest cmp "$T/old-manifest" "$BIFROST_MANIFEST"
ok upg-fail-core cmp "$T/old-core" "$BIFROST_CORE"
ok upg-fail-library cmp "$T/pkgs/v2/lib/login.sh" "$BIFROST_LIB/login.sh"
ok upg-fail-script cmp "$T/pkgs/v2/scripts/bifrost_config.sh" "$BIFROST_SCRIPTS/bifrost_config.sh"

# Fail after registration, while starting the new version. Recover using the
# old libraries and preserve an explicitly empty dbus key.
cp -R "$T/pkgs/v2fail" "$T/pkgs/startfail"
printf '\ndaemon_start() { return 1; }\n' >>"$T/pkgs/startfail/lib/daemon.sh"
dbus set bifrost_magicdns=
dbus set bifrost_version=legacy
out=$(sh "$T/pkgs/startfail/install.sh" 2>&1)
eq startfail-exit 1 "$?"
has startfail-message "重启失败" "$out"
ok startfail-old-core cmp "$T/old-core" "$BIFROST_CORE"
eq startfail-version 0.2.0 "$(cat "$BIFROST_VERSION_FILE")"
eq startfail-dbus-version 0.2.0 "$(dbus get softcenter_module_bifrost_version)"
eq startfail-empty-key 'bifrost_magicdns=' "$(dbus list bifrost_magicdns)"
eq startfail-legacy-key legacy "$(dbus get bifrost_version)"
ok startfail-live kill -0 "$(cat "$BIFROST_PIDFILE")"
no startfail-lock test -d "$BIFROST_RUN/lock.state"
check_assets startfail-page "$h2"

# Both contractual stop errors must abort, release the lock and invoke start.
cp -R "$T/pkgs/v2fail" "$T/pkgs/stoperr"
sed 's/^daemon_stop()/real_stop()/' "$T/pkgs/stoperr/lib/daemon.sh" >"$T/stoperr"
cat "$T/stoperr" >"$T/pkgs/stoperr/lib/daemon.sh"
cat >>"$T/pkgs/stoperr/lib/daemon.sh" <<'EOF'
daemon_stop() {
    if [ "$STOP_ERROR" = cleanup ]; then real_stop || return 1; fi
    return 1
}
EOF
for error in running cleanup; do
    out=$(STOP_ERROR=$error sh "$T/pkgs/stoperr/install.sh" 2>&1)
    eq "stop-error-$error" 1 "$?"
    has "stop-error-$error-restore" "恢复原 Bifrost 服务" "$out"
    ok "stop-error-$error-live" kill -0 "$(cat "$BIFROST_PIDFILE")"
    no "stop-error-$error-lock" test -d "$BIFROST_RUN/lock.state"
done

# Deliver real signals inside the foreground installer, with state locked and
# the old process already stopped (noninteractive background jobs ignore INT).
cp -R "$T/pkgs/v2fail" "$T/pkgs/signal"
cat >>"$T/pkgs/signal/lib/update.sh" <<'EOF'
core_install_file() { kill -"$INSTALL_SIGNAL" "$$"; return 1; }
EOF
for sig in INT TERM; do
    case "$sig" in INT) expected=130 ;; TERM) expected=143 ;; esac
    out=$(INSTALL_SIGNAL=$sig sh "$T/pkgs/signal/install.sh" 2>&1)
    eq "signal-$sig-exit" "$expected" "$?"
    no "signal-$sig-lock" test -d "$BIFROST_RUN/lock.state"
    ok "signal-$sig-live" kill -0 "$(cat "$BIFROST_PIDFILE")"
done

# A failed recovery must be visible. Restore the original library for retry.
cp "$BIFROST_LIB/daemon.sh" "$T/daemon.good"
printf '\ndaemon_start() { return 1; }\n' >>"$BIFROST_LIB/daemon.sh"
out=$(STOP_ERROR=running sh "$T/pkgs/stoperr/install.sh" 2>&1)
eq restore-error-exit 1 "$?"
has restore-error-visible "恢复原 Bifrost 服务失败" "$out"
no restore-error-lock test -d "$BIFROST_RUN/lock.state"
cp "$T/daemon.good" "$BIFROST_LIB/daemon.sh"

make_pkg "$T/pkgs/bad-running" "0.2.8" 8 arm "bad-core" ":host{}" bad_hash >/dev/null
out=$(sh "$T/pkgs/bad-running/install.sh" 2>&1)
eq bad-running-exit 0 "$?"
has bad-running-warning "保留原有核心" "$out"
ok bad-running-core cmp "$T/old-core" "$BIFROST_CORE"
ok bad-running-manifest cmp "$T/old-manifest" "$BIFROST_MANIFEST"
ok bad-running-live kill -0 "$(cat "$BIFROST_PIDFILE")"

# Stop daemon cleanly via real daemon_stop before stopped-upgrade test.
sh -c '
    . "$BIFROST_LIB/env.sh"
    . "$BIFROST_LIB/validate.sh"
    . "$BIFROST_LIB/common.sh"
    for m in daemon fw dns status login settings migrate update diag; do . "$BIFROST_LIB/$m.sh"; done
    daemon_stop
'
eq stop-before-t3-rc 0 "$?"
no stop-before-t3-nopid test -f "$BIFROST_PIDFILE"

# =====================================================================
# 4. Upgrade while stopped: does NOT start daemon
# =====================================================================
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq upg-stop-rc 0 "$?"
no upg-stop-still-stopped test -f "$BIFROST_PIDFILE"

# An upgrade keeps a previous core on other storage and removes it from
# internal flash, where core updates no longer keep one.
printf 'old' >"$BIFROST_BIN/bifrostd.prev.gz"
printf '{}' >"$BIFROST_BIN/bifrostd.prev.json"
printf '900000\n' >"$MOCK_STATE/df_avail_kb"
export BIFROST_MOUNTS="$T/mounts"
printf '/dev/mock /jffs ext4 rw 0 0\n' >"$BIFROST_MOUNTS"
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq upg-prev-other-rc 0 "$?"
ok upg-prev-other-kept test -f "$BIFROST_BIN/bifrostd.prev.gz"
printf '/dev/mock /jffs jffs2 rw 0 0\n' >"$BIFROST_MOUNTS"
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq upg-prev-internal-rc 0 "$?"
has upg-prev-internal-msg "已删除上一版核心备份" "$out"
no upg-prev-internal-gz test -e "$BIFROST_BIN/bifrostd.prev.gz"
no upg-prev-internal-man test -e "$BIFROST_BIN/bifrostd.prev.json"
rm -f "$MOCK_STATE/df_avail_kb"
export BIFROST_MOUNTS=/proc/mounts

# =====================================================================
# 5. JS-only upgrade, CSS-only upgrade & mid-install package mutation immunity (Item 6)
# =====================================================================
h_js=$(make_pkg "$T/pkgs/v2js" "0.2.1" 2 arm "console.log('v2-js-changed');" ":host{color:#222;}")
no js-only-hash-diff test "$h_js" = "$h2"
out=$(sh "$T/pkgs/v2js/install.sh" 2>&1)
eq js-only-rc 0 "$?"
check_assets js-only "$h_js"

h_css=$(make_pkg "$T/pkgs/v2css" "0.2.2" 2 arm "console.log('v2-js-changed');" ":host{color:#333;}")
no css-only-hash-diff test "$h_css" = "$h_js"
out=$(sh "$T/pkgs/v2css/install.sh" 2>&1)
eq css-only-rc 0 "$?"
check_assets css-only "$h_css"

# Item 6: simulate concurrent upload wiping/replacing /tmp/bifrost mid-install
# (injected fault wrapper around real core_install_file).
h_snap=$(make_pkg "$T/pkgs/vsnap" "0.2.3" 3 arm "console.log('snap-js');" ":host{color:#444;}")
wrap_real_core_install() {
    sed 's/^core_install_file()/_inner_cif()/' "$1" >"$1.wrapped" && mv "$1.wrapped" "$1"
}
wrap_real_core_install "$T/pkgs/vsnap/lib/update.sh"
cat >>"$T/pkgs/vsnap/lib/update.sh" <<EOF
core_install_file() {
    _inner_cif "\$@" || return 1
    # Wipe package web files mid-install (simulating software center rm -rf /tmp/bifrost).
    rm -rf "$T/pkgs/vsnap/webs" "$T/pkgs/vsnap/res"
    return 0
}
EOF
out=$(sh "$T/pkgs/vsnap/install.sh" 2>&1)
eq web-stage-immune-rc 0 "$?"
check_assets web-stage-immune "$h_snap"

# =====================================================================
# 6. No core downgrade when installed serial > package serial (delegated to P1)
# =====================================================================
h5=$(make_pkg "$T/pkgs/v5" "0.5.0" 5 arm "console.log('v5');" ":host{color:#555;}")
out=$(sh "$T/pkgs/v5/install.sh" 2>&1)
eq serial5-rc 0 "$?"
eq serial5-installed 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
core_sha_5=$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)

out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq nodowngrade-rc 0 "$?"
eq nodowngrade-serial 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
eq nodowngrade-core-unchanged "$core_sha_5" "$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)"

# =====================================================================
# 7. Core verification failure: upgrade keeps old core; missing old core
#    aborts without wiping plugin (Item 5); fresh install aborts & cleans
# =====================================================================
h_bad=$(make_pkg "$T/pkgs/v6bad" "0.6.0" 6 arm "console.log('v6');" ":host{color:#666;}" bad_hash)
out=$(sh "$T/pkgs/v6bad/install.sh" 2>&1)
eq corefail-upg-rc 0 "$?"
has corefail-upg-warn "保留原有核心" "$out"
eq corefail-upg-old-core "$core_sha_5" "$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)"
eq corefail-upg-old-serial 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
no corefail-upg-no-new test -e "$BIFROST_CORE.new"
check_assets corefail-upg "$h_bad"

# Item 5: upgrade when old core was deleted + corrupt new core MUST NOT run _in_cleanup_fresh!
rm -f "$BIFROST_CORE"
out=$(sh "$T/pkgs/v6bad/install.sh" 2>&1)
rc=$?
no corefail-upg-nocore-rc test "$rc" -eq 0
has corefail-upg-nocore-msg "原核心不可用" "$out"
ok corefail-upg-nocore-keeps-asp test -s "$BIFROST_WEBS/Module_bifrost.asp"
ok corefail-upg-nocore-keeps-scripts test -x "$BIFROST_SCRIPTS/bifrost_config.sh"
eq corefail-upg-nocore-keeps-dbus 1 "$(dbus get softcenter_module_bifrost_install)"

# Fresh install with bad hash & bad version
inst_setup
make_pkg "$T/pkgs/badhash" "0.1.0" 1 arm "console.log('a');" ":host{}" bad_hash >/dev/null
out=$(sh "$T/pkgs/badhash/install.sh" 2>&1)
rc=$?
no corefail-fresh-hash-rc test "$rc" -eq 0
has corefail-fresh-hash-msg "hash_mismatch" "$out"
no corefail-fresh-no-home test -e "$BIFROST_HOME"
no corefail-fresh-no-asp test -e "$BIFROST_WEBS/Module_bifrost.asp"
eq corefail-fresh-no-dbus "" "$(dbus get softcenter_module_bifrost_install)"

make_pkg "$T/pkgs/badver" "0.1.0" 1 arm "console.log('a');" ":host{}" bad_version >/dev/null
out=$(sh "$T/pkgs/badver/install.sh" 2>&1)
rc=$?
no corefail-fresh-ver-rc test "$rc" -eq 0
has corefail-fresh-ver-msg "core_test_failed" "$out"
no corefail-fresh-ver-no-home test -e "$BIFROST_HOME"

no corefail-fresh-lock test -d "$BIFROST_RUN/lock.state"

# A directory at an old hashed asset makes rm -f fail after publication.
stale="$BIFROST_RES/bifrost-app.0123456789abcdef0123.js"
mkdir "$stale"
make_pkg "$T/pkgs/stale" "0.1.0" 1 arm "stale" ":host{}" >/dev/null
out=$(sh "$T/pkgs/stale/install.sh" 2>&1)
eq stale-cleanup-rc 1 "$?"
has stale-cleanup-message "清理旧网页资源失败" "$out"
no stale-cleanup-home test -e "$BIFROST_HOME"
no stale-cleanup-asp test -e "$BIFROST_WEBS/Module_bifrost.asp"
no stale-cleanup-wrapper test -e "$BIFROST_KSBIN/bifrost"
ok stale-cleanup-original test -d "$stale"
eq stale-cleanup-assets "${stale##*/}" "$(ls "$BIFROST_RES")"
eq stale-cleanup-dbus "" "$(dbus list softcenter_module_bifrost_)"
no stale-cleanup-lock test -d "$BIFROST_RUN/lock.state"

# =====================================================================
# 8. Missing web asset & daemon_stop failure abort cleanly (Item 4)
# =====================================================================
inst_setup
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"
ha=$(make_pkg "$T/pkgs/pa" "0.1.0" 1 arm "console.log('A');" ":host{color:#aaa;}")
out=$(sh "$T/pkgs/pa/install.sh" 2>&1)
eq prep-a-rc 0 "$?"
check_assets prep-a "$ha"

hb=$(make_pkg "$T/pkgs/pb" "0.2.0" 2 arm "console.log('B');" ":host{color:#bbb;}")
rm -f "$T/pkgs/pb/res/bifrost-app.$hb.css"
out=$(sh "$T/pkgs/pb/install.sh" 2>&1)
rc=$?
no missing-css-fail-rc test "$rc" -eq 0
has missing-css-fail-msg "缺少网页资源" "$out"
check_assets missing-css-keeps-a "$ha"

# Item 4: upgrade aborts if daemon_stop fails (fault injection on daemon_stop).
make_pkg "$T/pkgs/pstopfail" "0.2.0" 2 arm "console.log('SF');" ":host{color:#5f0;}" >/dev/null
printf '\ndaemon_stop() { return 1; }\n' >>"$T/pkgs/pstopfail/lib/daemon.sh"
out=$(sh "$T/pkgs/pstopfail/install.sh" 2>&1)
rc=$?
no upg-stopfail-rc test "$rc" -eq 0
has upg-stopfail-msg "停止 Bifrost 服务失败" "$out"
check_assets upg-stopfail-keeps-a "$ha"

rm "$T/pkgs/pstopfail/lib/daemon.sh"
out=$(sh "$T/pkgs/pstopfail/install.sh" 2>&1)
eq upg-missing-stop-rc 1 "$?"
has upg-missing-stop-msg "缺少 daemon_stop" "$out"
ok upg-missing-stop-preserves-script test -x "$BIFROST_SCRIPTS/bifrost_config.sh"

# =====================================================================
# 9. Unmet environment checks — every case verifies error reason (Item 22)
# =====================================================================
inst_setup
make_pkg "$T/pkgs/envok" "0.1.0" 1 arm "console.log('e');" ":host{}" >/dev/null

# Missing TUN
rm -f "$BIFROST_TUN_DEV"
out=$(sh "$T/pkgs/envok/install.sh" 2>&1)
rc=$?
no env-no-tun-rc test "$rc" -eq 0
has env-no-tun-msg "TUN" "$out"
: >"$BIFROST_TUN_DEV"

# Unsupported arch x86_64
echo x86_64 >"$MOCK_STATE/uname_m"
out=$(sh "$T/pkgs/envok/install.sh" 2>&1)
rc=$?
no env-bad-arch-rc test "$rc" -eq 0
has env-bad-arch-msg "架构" "$out"

# arm64 package on armv7l kernel
echo armv7l >"$MOCK_STATE/uname_m"
make_pkg "$T/pkgs/arm64pkg" "0.1.0" 1 arm64 "console.log('e');" ":host{}" >/dev/null
out=$(sh "$T/pkgs/arm64pkg/install.sh" 2>&1)
rc=$?
no env-arm64-on-v7-rc test "$rc" -eq 0
has env-arm64-on-v7-msg "arm64" "$out"
echo aarch64 >"$MOCK_STATE/uname_m"

# Missing curl: build a clean mock bin dir without curl (Item 1 fix!)
mkdir -p "$T/nocurl-bin"
for _mb in /src/tests/shell/mock/bin/*; do
    [ "${_mb##*/}" = curl ] && continue
    ln -sf "$_mb" "$T/nocurl-bin/${_mb##*/}"
done
out=$(PATH="$T/nocurl-bin:/opt/bb125/bin:/opt/tools/bin" sh "$T/pkgs/envok/install.sh" 2>&1)
rc=$?
no env-no-curl-rc test "$rc" -eq 0
has env-no-curl-msg "curl" "$out"

# Missing base.sh
rm -f "$BIFROST_KSROOT/scripts/base.sh"
out=$(sh "$T/pkgs/envok/install.sh" 2>&1)
rc=$?
no env-no-base-rc test "$rc" -eq 0
has env-no-base-msg "base.sh" "$out"

# =====================================================================
# 10. Lock held: waits then fails AND leaves lock dir untouched (Item 22)
# =====================================================================
inst_setup
make_pkg "$T/pkgs/locktest" "0.1.0" 1 arm "console.log('l');" ":host{}" >/dev/null
mkdir -p "$BIFROST_RUN/lock.state"
sleep 30 &
holder=$!
echo "$holder" >"$BIFROST_RUN/lock.state/pid"

t0=$(date +%s)
out=$(BIFROST_INSTALL_LOCK_WAIT=2 sh "$T/pkgs/locktest/install.sh" 2>&1)
rc=$?
t1=$(date +%s)

no lock-busy-rc test "$rc" -eq 0
ok lock-busy-waited test "$((t1 - t0))" -ge 2
has lock-busy-msg "正在进行" "$out"
ok lock-busy-dir-still-exists test -d "$BIFROST_RUN/lock.state"
eq lock-busy-pid-preserved "$holder" "$(cat "$BIFROST_RUN/lock.state/pid" 2>/dev/null)"

kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -rf "$BIFROST_RUN/lock.state"

# =====================================================================
# 11. Concurrent installs: deterministic exclusion & serialization (Item 1)
# =====================================================================
inst_setup
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"
hc1=$(make_pkg "$T/pkgs/c1" "0.1.0" 1 arm "console.log('C1');" ":host{color:#c01;}")
hc2=$(make_pkg "$T/pkgs/c2" "0.2.0" 2 arm "console.log('C2');" ":host{color:#c02;}")

# Wrap real core_install_file ONLY to coordinate deterministic overlap timing.
for _cp in "$T/pkgs/c1" "$T/pkgs/c2"; do
    wrap_real_core_install "$_cp/lib/update.sh"
    cat >>"$_cp/lib/update.sh" <<'EOF'
core_install_file() {
    echo "ENTER $$" >>"$MOCK_STATE/concurrency.log"
    : >"$MOCK_STATE/in_critical"
    if [ -n "${BIFROST_TEST_GATE:-}" ]; then
        _gate_wait=0
        while [ ! -f "$BIFROST_TEST_GATE" ]; do
            [ "$_gate_wait" -lt 300 ] || return 1
            usleep 100000
            _gate_wait=$((_gate_wait + 1))
        done
    fi
    _inner_cif "$@"
    _rc=$?
    echo "LEAVE $$" >>"$MOCK_STATE/concurrency.log"
    return "$_rc"
}
EOF
done

# Part A: while c1 holds the lock (in_critical exists), c2 with wait=0 MUST fail busy.
rm -f "$MOCK_STATE/in_critical"
BIFROST_TEST_GATE="$T/release1" BIFROST_INSTALL_LOCK_WAIT=0 sh "$T/pkgs/c1/install.sh" >"$T/c1.out" 2>&1 &
p1=$!
_wi=0
while [ ! -f "$MOCK_STATE/in_critical" ] && [ "$_wi" -lt 300 ]; do
    usleep 100000 2>/dev/null || sleep 1
    _wi=$((_wi + 1))
done
ok conc-c1-entered test -f "$MOCK_STATE/in_critical"
c2_out=$(BIFROST_INSTALL_LOCK_WAIT=0 sh "$T/pkgs/c2/install.sh" 2>&1)
r2=$?
: >"$T/release1"
r1=0; wait "$p1" || r1=$?
eq conc-c1-wins 0 "$r1"
no conc-c2-rejected test "$r2" -eq 0
has conc-c2-busy-msg "正在进行" "$c2_out"
check_assets conc-winner "$hc1"

# Part B: with wait=60, c2 waits for c1 and executes serially with zero overlap.
: >"$MOCK_STATE/concurrency.log"
rm -f "$MOCK_STATE/in_critical"
BIFROST_TEST_GATE="$T/release2" BIFROST_INSTALL_LOCK_WAIT=60 sh "$T/pkgs/c1/install.sh" >"$T/c1b.out" 2>&1 &
p1=$!
_wi=0
while [ ! -f "$MOCK_STATE/in_critical" ] && [ "$_wi" -lt 300 ]; do
    usleep 100000 2>/dev/null || sleep 1
    _wi=$((_wi + 1))
done
mkdir "$T/watch-lock"
cat >"$T/watch-lock/mkdir" <<'EOF'
#!/bin/sh
/opt/bb125/busybox mkdir "$@" && exit 0
[ "$1" != "$BIFROST_RUN/lock.state" ] || : >"$MOCK_STATE/c2-contended"
exit 1
EOF
chmod 755 "$T/watch-lock/mkdir"
PATH="$T/watch-lock:$PATH" BIFROST_INSTALL_LOCK_WAIT=60 sh "$T/pkgs/c2/install.sh" >"$T/c2b.out" 2>&1 &
p2=$!
_wi=0
while [ ! -e "$MOCK_STATE/c2-contended" ] && [ "$_wi" -lt 100 ]; do
    usleep 100000
    _wi=$((_wi + 1))
done
ok conc-ser-contended test -f "$MOCK_STATE/c2-contended"
eq conc-ser-owner "$p1" "$(cat "$BIFROST_RUN/lock.state/pid")"
eq conc-ser-waiting "ENTER $p1" "$(cat "$MOCK_STATE/concurrency.log")"
: >"$T/release2"
r1=0; wait "$p1" || r1=$?
r2=0; wait "$p2" || r2=$?
eq conc-ser-r1 0 "$r1"
eq conc-ser-r2 0 "$r2"
eq conc-ser-order "$(printf 'ENTER\nLEAVE\nENTER\nLEAVE')" "$(cut -d ' ' -f 1 "$MOCK_STATE/concurrency.log")"
check_assets conc-ser-final "$hc2"

# =====================================================================
# 12. Uninstall: failure when daemon_stop fails (Item 4), $0 safety (Item 7),
#     and complete snapshot-verified removal preserving state (Items 3 & 11)
# =====================================================================
inst_setup
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"
: >"$BIFROST_SCRIPTS/bifrost_local.sh"
dbus set other_plugin_enable=1
mkdir -p "$BIFROST_ORIG_STATE"
for path in "$BIFROST_ORIG_CONFIG" "$BIFROST_WEBS/Module_tailscale.asp" "$BIFROST_RES/icon-tailscale.png" \
    "$BIFROST_ORIG_STATE/tailscaled.state" "$BIFROST_UPLOAD/bifrost_user.json"; do
    printf 'preserve original\n' >"$path"
done
snapshot_sandbox >"$T/uninst_before.snap"

hu=$(make_pkg "$T/pkgs/vu" "0.3.0" 3 arm "console.log('U');" ":host{color:#777;}")
printf '#!/bin/sh\necho extra\n' >"$T/pkgs/vu/scripts/bifrost_extra.sh"
out=$(sh "$T/pkgs/vu/install.sh" 2>&1)
eq uninst-prep-rc 0 "$?"
check_assets uninst-prep "$hu"

mkdir -p "$BIFROST_STATE"
printf 'preserve-me\n' >"$BIFROST_STATE/tailscaled.state"
dbus set bifrost_enable=1
dbus set bifrost_magicdns=1

# Start real daemon so real PID, socket, fw chains, dnsmasq conf, and bifrost_watchdog cron exist!
sh -c '
    . "$BIFROST_LIB/env.sh"
    . "$BIFROST_LIB/validate.sh"
    . "$BIFROST_LIB/common.sh"
    for m in daemon fw dns status login settings migrate update diag; do . "$BIFROST_LIB/$m.sh"; done
    daemon_start
'
eq uninst-start-rc 0 "$?"
has uninst-pre-cru "bifrost_watchdog" "$(cru l)"
ok uninst-pre-dns test -f "$BIFROST_DNSMASQ_CONF"
: >"$BIFROST_UPLOAD/bifrost_update.json"
: >"$BIFROST_UPLOAD/bifrost_logs.txt"
: >"$BIFROST_RES/.bifrost-app.new"
: >"$BIFROST_WEBS/.bifrost-app.new"
: >"$BIFROST_RES/bifrost-app.0123456789abcdef0123.js"

# Item 4: if daemon_stop fails during uninstall, uninstall MUST abort and keep scripts/core/dbus!
cp "$BIFROST_LIB/daemon.sh" "$T/daemon.sh.orig"
printf '\ndaemon_stop() { return 1; }\n' >>"$BIFROST_LIB/daemon.sh"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
rc=$?
no uninst-stopfail-rc test "$rc" -eq 0
has uninst-stopfail-msg "已中止卸载并保留现有脚本" "$out"
ok uninst-stopfail-keeps-self test -x "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
ok uninst-stopfail-keeps-core test -x "$BIFROST_CORE"
ok uninst-stopfail-keeps-cfg test -x "$BIFROST_SCRIPTS/bifrost_config.sh"
eq uninst-stopfail-keeps-dbus 1 "$(dbus get softcenter_module_bifrost_install)"
# Fail after the real daemon stops, as with unsuccessful rule cleanup.
sed 's/^daemon_stop()/real_stop()/' "$T/daemon.sh.orig" >"$BIFROST_LIB/daemon.sh"
printf '\ndaemon_stop() { real_stop; return 1; }\n' >>"$BIFROST_LIB/daemon.sh"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq uninst-cleanupfail-rc 1 "$?"
has uninst-cleanupfail-retry "请稍后重试" "$out"
ok uninst-cleanupfail-keeps-self test -x "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
ok uninst-cleanupfail-keeps-core test -x "$BIFROST_CORE"
eq uninst-cleanupfail-keeps-dbus 1 "$(dbus get softcenter_module_bifrost_install)"
rm "$BIFROST_LIB/daemon.sh"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq uninst-missing-stop-rc 1 "$?"
has uninst-missing-stop-msg "缺少 daemon_stop" "$out"
ok uninst-missing-stop-keeps-core test -x "$BIFROST_CORE"
mv -f "$T/daemon.sh.orig" "$BIFROST_LIB/daemon.sh"

# Item 7: running uninstall.sh from the package dir (under $T/pkgs/vu) must target $BIFROST_KSROOT,
# NOT $T/pkgs (must NOT delete $T/pkgs/vu/version or anything outside $BIFROST_KSROOT!).
# Model the revised stop contract on older P2 implementations, retaining the
# real cron commands and the real stop sequence.
sed '/^daemon_stop()/,/^}/s/^    daemon_watchdog_remove || true$/    :/' "$BIFROST_LIB/daemon.sh" >"$T/daemon.contract"
cp "$T/daemon.contract" "$BIFROST_LIB/daemon.sh"
# The previous failed stop may have removed the job on the older P2 baseline.
cru a bifrost_watchdog '* * * * * /bin/true'
: >"$MOCK_STATE/cru.log"
mkdir "$T/interrupt-remove"
cat >"$T/interrupt-remove/rm" <<'EOF'
#!/bin/sh
if [ "$2" = "$BIFROST_HOME" ] && [ -d "$2/.uninstall-lib" ]; then
    /opt/bb125/busybox rm "$@" || exit 1
    kill -TERM "$PPID"
    exit 0
fi
exec /opt/bb125/busybox rm "$@"
EOF
chmod 755 "$T/interrupt-remove/rm"
export BIFROST_HOME
# An unrecovered migration journal: the original plugin was disabled and not yet restored.
dbus set tailscale_enable=0
mkdir -m 700 "$BIFROST_HOME/.migration"
printf 'stopping 1 0 1 0\n' >"$BIFROST_HOME/.migration/record"
out=$(PATH="$T/interrupt-remove:$PATH" sh "$T/pkgs/vu/uninstall.sh" 2>&1)
eq uninst-interrupted 143 "$?"
eq uninst-migration-restored-orig 1 "$(dbus get tailscale_enable)"
dbus remove tailscale_enable
no uninst-interrupted-lib test -e "$BIFROST_LIB"
ok uninst-interrupted-self test -x "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
no uninst-interrupted-lock test -d "$BIFROST_RUN/lock.state"
ok uninst-watchdog-removed-by-entry grep -Fxq 'CRU d bifrost_watchdog' "$MOCK_STATE/cru.log"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq uninst-rc 0 "$?"
has uninst-done "卸载完成" "$out"
has uninst-done-state-kept "已保留" "$out"
ok uninst-pkgdir-untouched test -f "$T/pkgs/vu/version"

# Item 11: exact before/after sandbox snapshot equality (proves zero leftover files/symlinks/dirs!)
snapshot_sandbox >"$T/uninst_after.snap"
eq uninst-snapshot-exact "$(cat "$T/uninst_before.snap")" "$(cat "$T/uninst_after.snap")"

# Verify cron, fw, dns, dbus cleaned and state + unrelated preserved
eq uninst-cru-empty "" "$(cru l | grep bifrost || true)"
no uninst-dnsmasq test -e "$BIFROST_DNSMASQ_CONF"
eq uninst-dbus-bifrost "" "$(dbus list bifrost_)"
eq uninst-dbus-sc "" "$(dbus list softcenter_module_bifrost_)"
no uninst-no-command-v test -e "$MOCK_STATE/used-command"
eq uninst-state-kept "preserve-me" "$(cat "$BIFROST_STATE/tailscaled.state")"
eq uninst-other-dbus 1 "$(dbus get other_plugin_enable)"

# Without a state directory the message does not claim one was kept.
rm -rf "$BIFROST_STATE"
out=$(sh "$T/pkgs/vu/install.sh" 2>&1)
eq uninst-nostate-prep-rc 0 "$?"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq uninst-nostate-rc 0 "$?"
has uninst-nostate-done "卸载完成" "$out"
no uninst-nostate-msg grep -q "已保留" <<EOF2
$out
EOF2

t_done
