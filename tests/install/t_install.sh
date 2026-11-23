#!/bin/sh
# Comprehensive install, upgrade and uninstall tests for plugin/bifrost/install.sh
# and plugin/bifrost/uninstall.sh (PLAN sections 13.11 & 15).
# Page asset swap & concurrency checks adapted from po0fw asus-merlin (MIT), commit 0d9532d.

# shellcheck source=tests/shell/lib.sh
. tests/shell/lib.sh

# Clean router-like sandbox WITHOUT pre-installing Bifrost (fresh Koolshare root).
inst_setup() {
    [ -n "$T" ] && rm -rf "$T"
    T=/tmp/bi.$$
    rm -rf "$T"
    # shellcheck disable=SC2013
    for _is_v in $(sed -n 's/^: "\${\(BIFROST_[A-Z0-9_]*\):=.*/\1/p' "$T_SRC/plugin/bifrost/lib/env.sh"); do
        unset "$_is_v"
    done
    unset BIFROST_REQ_ID BIFROST_ERR BIFROST_RESULT BIFROST_NO_MAIN BIFROST_BG_SYNC BIFROST_INSTALL_LOCK_WAIT
    export MOCK_STATE="$T/state"
    export BIFROST_KSROOT="$T/koolshare"
    export BIFROST_RUN="$T/run"
    export BIFROST_SOCK_DIR="$T/sock"
    export BIFROST_UPLOAD="$T/upload"
    export BIFROST_DNSMASQ_DIR="$T/dnsmasq.d"
    export BIFROST_TUN_DEV="$T/dev-net-tun"
    export BIFROST_INSTALL_LOCK_WAIT=5

    for _is_d in "$MOCK_STATE" "$BIFROST_KSROOT/scripts" "$BIFROST_KSROOT/webs" \
        "$BIFROST_KSROOT/res" "$BIFROST_KSROOT/init.d" "$BIFROST_KSROOT/bin" \
        "$BIFROST_UPLOAD" "$BIFROST_DNSMASQ_DIR" "$T/pkgs"; do
        mkdir -p "$_is_d"
    done
    : >"$MOCK_STATE/dbus.env"
    : >"$MOCK_STATE/nvram.env"
    : >"$BIFROST_TUN_DEV"
    echo aarch64 >"$MOCK_STATE/uname_m"
    cp "$T_SRC/tests/shell/mock/base.sh" "$BIFROST_KSROOT/scripts/base.sh"
    # Verify BusyBox 1.25 has no "command -v" usage inside install/uninstall.
    cat >>"$BIFROST_KSROOT/scripts/base.sh" <<'EOF'
command() { touch "$MOCK_STATE/used-command"; return 127; }
EOF
    # Re-source env.sh to populate convenience path variables in test shell.
    # shellcheck source=plugin/bifrost/lib/env.sh
    . "$T_SRC/plugin/bifrost/lib/env.sh"
}

# make_pkg <dir> <version> <serial> <arch> <js_body> <css_body> [core_mode]
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
    printf '%s\n' "$_mp_ver" >"$_mp_dir/version"
    printf 'fake-png-icon\n' >"$_mp_dir/res/icon-bifrost.png"
    printf 'MIT License\n' >"$_mp_dir/LICENSE"
    printf 'BSD-3-Clause\n' >"$_mp_dir/LICENSE.tailscale"
    printf 'Third-party notices\n' >"$_mp_dir/NOTICE.md"
    printf -- '-----BEGIN PUBLIC KEY-----\nTESTKEY\n-----END PUBLIC KEY-----\n' >"$_mp_dir/keys/dev.pub.pem"

    cat >"$_mp_dir/bin/bifrost" <<'EOF'
#!/bin/sh
_bf_ks=$(cd "$(dirname "$0")/.." && pwd)
. "${BIFROST_LIB:-$_bf_ks/bifrost/lib}/env.sh"
exec "$BIFROST_CLI" --socket="$BIFROST_SOCK" "$@"
EOF
    chmod 755 "$_mp_dir/bin/bifrost"

    # Inject stubs for P1 (core_install_file) and P2 (daemon_stop, daemon_start)
    # when the real libraries are not present in this branch yet.
    if [ "${BIFROST_INSTALL_REAL_LIBS:-0}" != 1 ] || [ ! -f "$_mp_dir/lib/daemon.sh" ]; then
        cat >"$_mp_dir/lib/daemon.sh" <<'EOF'
# shellcheck shell=sh
daemon_stop() {
    echo "daemon_stop" >>"$MOCK_STATE/install_calls.log"
    _ds_pid=$(daemon_pid 2>/dev/null)
    if [ -n "$_ds_pid" ]; then
        kill "$_ds_pid" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
    return 0
}
daemon_start() {
    echo "daemon_start" >>"$MOCK_STATE/install_calls.log"
    mkdir -p "$BIFROST_RUN" "$BIFROST_SOCK_DIR"
    "$BIFROST_CORE" --socket="$BIFROST_SOCK" >/dev/null 2>&1 &
    echo "$!" >"$BIFROST_PIDFILE"
    return 0
}
EOF
    fi
    if [ "${BIFROST_INSTALL_REAL_LIBS:-0}" != 1 ] || [ ! -f "$_mp_dir/lib/update.sh" ]; then
        cat >"$_mp_dir/lib/update.sh" <<'EOF'
# shellcheck shell=sh
core_install_file() {
    _ci_gz=$1
    _ci_mf=$2
    _ci_arch=$3
    echo "core_install_file $_ci_arch" >>"$MOCK_STATE/install_calls.log"
    if [ -f "$MOCK_STATE/core_sleep" ]; then
        echo "ENTER $$" >>"$MOCK_STATE/concurrency.log"
        sleep "$(cat "$MOCK_STATE/core_sleep")"
        echo "LEAVE $$" >>"$MOCK_STATE/concurrency.log"
    fi
    mkdir -p "$BIFROST_BIN"
    if ! gunzip -c "$_ci_gz" >"$BIFROST_CORE.new" 2>/dev/null; then
        rm -f "$BIFROST_CORE.new"
        fail no_space
        return 1
    fi
    chmod 755 "$BIFROST_CORE.new"
    _ci_want_sha=$(jq -r --arg a "$_ci_arch" '.assets[$a].raw_sha256 // empty' "$_ci_mf" 2>/dev/null)
    _ci_got_sha=$(sha256_file "$BIFROST_CORE.new" 2>/dev/null)
    if [ -z "$_ci_want_sha" ] || [ "$_ci_want_sha" != "$_ci_got_sha" ]; then
        rm -f "$BIFROST_CORE.new"
        fail hash_mismatch
        return 1
    fi
    _ci_want_ver=$(jq -r '.tailscale // empty' "$_ci_mf" 2>/dev/null)
    _ci_got_ver=$("$BIFROST_CORE.new" --version 2>/dev/null | head -n 1)
    if [ -z "$_ci_want_ver" ] || [ "$_ci_want_ver" != "$_ci_got_ver" ]; then
        rm -f "$BIFROST_CORE.new"
        fail core_test_failed
        return 1
    fi
    mv -f "$BIFROST_CORE.new" "$BIFROST_CORE" || {
        rm -f "$BIFROST_CORE.new"
        fail internal
        return 1
    }
    return 0
}
EOF
    fi

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
    # Verify only this pair + icon + unrelated files exist in $BIFROST_RES.
    # shellcheck disable=SC2012
    _ca_got=$(ls -1A "$BIFROST_RES" | sort)
    _ca_want=$(printf '%s\n' "$_ca_js" "$_ca_css" icon-bifrost.png unrelated.js bifrost-app.notes.css | sort)
    eq "$_ca_label-res-exact" "$_ca_want" "$_ca_got"
    no "$_ca_label-no-asp-tmp" ls "$BIFROST_WEBS"/.bifrost-app.new* >/dev/null 2>&1
    no "$_ca_label-no-res-tmp" ls "$BIFROST_RES"/.bifrost-app.new* >/dev/null 2>&1
}

# =====================================================================
# 1. Fresh install (files, symlinks, dbus defaults, does not start, orig hint)
# =====================================================================
inst_setup
mkdir -p "$BIFROST_ORIG_STATE"
printf 'orig-state\n' >"$BIFROST_ORIG_STATE/tailscaled.state"
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"

h1=$(make_pkg "$T/pkgs/v1" "0.1.0" 1 arm "console.log('v1');" ":host{color:#111;}")
out=$(sh "$T/pkgs/v1/install.sh" 2>&1)
eq fresh-rc 0 "$?"
has fresh-done "安装完成" "$out"
has fresh-orig-hint "迁移" "$out"
eq fresh-orig-untouched "orig-state" "$(cat "$BIFROST_ORIG_STATE/tailscaled.state")"
no fresh-no-command-v test -e "$MOCK_STATE/used-command"

# Installed files & symlinks
ok fresh-core test -x "$BIFROST_CORE"
eq fresh-cli-link "bifrostd" "$(readlink "$BIFROST_CLI")"
eq fresh-manifest-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"
eq fresh-version-file "0.1.0" "$(cat "$BIFROST_VERSION_FILE")"
ok fresh-license test -f "$BIFROST_HOME/LICENSE"
ok fresh-license-ts test -f "$BIFROST_HOME/LICENSE.tailscale"
ok fresh-notice test -f "$BIFROST_HOME/NOTICE.md"
ok fresh-key test -f "$BIFROST_KEYS/dev.pub.pem"
ok fresh-cfg-script test -x "$BIFROST_SCRIPTS/bifrost_config.sh"
ok fresh-status-script test -x "$BIFROST_SCRIPTS/bifrost_status.sh"
ok fresh-uninst-script test -x "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
eq fresh-s99 "$BIFROST_SCRIPTS/bifrost_config.sh" "$(readlink "$BIFROST_INITD/S99bifrost.sh")"
eq fresh-n99 "$BIFROST_SCRIPTS/bifrost_config.sh" "$(readlink "$BIFROST_INITD/N99bifrost.sh")"
ok fresh-ksbin test -x "$BIFROST_KSBIN/bifrost"
check_assets fresh "$h1"

# dbus defaults & software center registration
eq fresh-dbus-install 1 "$(dbus get softcenter_module_bifrost_install)"
eq fresh-dbus-name bifrost "$(dbus get softcenter_module_bifrost_name)"
eq fresh-dbus-title Bifrost "$(dbus get softcenter_module_bifrost_title)"
has fresh-dbus-desc "Tailscale" "$(dbus get softcenter_module_bifrost_description)"
eq fresh-dbus-scver "0.1.0" "$(dbus get softcenter_module_bifrost_version)"
eq fresh-dbus-ver "0.1.0" "$(dbus get bifrost_version)"
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

# Fresh install must NOT start daemon
eq fresh-calls "core_install_file arm" "$(cat "$MOCK_STATE/install_calls.log")"
no fresh-lock-released test -d "$BIFROST_RUN/lock.state"

# =====================================================================
# 2. Upgrade while running: keeps settings & state, restarts, swaps assets
# =====================================================================
dbus set bifrost_enable=1
dbus set bifrost_port=51234
dbus set bifrost_snat=on
dbus set bifrost_ui_lang=en
dbus remove bifrost_magicdns
mkdir -p "$BIFROST_STATE"
printf 'keep-this-state\n' >"$BIFROST_STATE/tailscaled.state"

# Start fake daemon so real daemon_running() returns 0
mkdir -p "$BIFROST_RUN" "$BIFROST_SOCK_DIR"
"$BIFROST_CORE" --socket="$BIFROST_SOCK" >/dev/null 2>&1 &
old_pid=$!
echo "$old_pid" >"$BIFROST_PIDFILE"
sleep 1

: >"$MOCK_STATE/install_calls.log"
h2=$(make_pkg "$T/pkgs/v2" "0.2.0" 2 arm "console.log('v2');" ":host{color:#222;}")
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq upg-run-rc 0 "$?"
has upg-run-done "升级完成" "$out"

eq upg-run-port 51234 "$(dbus get bifrost_port)"
eq upg-run-snat on "$(dbus get bifrost_snat)"
eq upg-run-enable 1 "$(dbus get bifrost_enable)"
eq upg-run-lang en "$(dbus get bifrost_ui_lang)"
eq upg-run-missing-filled 0 "$(dbus get bifrost_magicdns)"
eq upg-run-ver "0.2.0" "$(dbus get bifrost_version)"
eq upg-run-scver "0.2.0" "$(dbus get softcenter_module_bifrost_version)"
eq upg-run-state "keep-this-state" "$(cat "$BIFROST_STATE/tailscaled.state")"
eq upg-run-serial 2 "$(jq -r .serial "$BIFROST_MANIFEST")"
check_assets upg-run "$h2"
eq upg-run-calls "$(printf 'daemon_stop\ncore_install_file arm\ndaemon_start')" "$(cat "$MOCK_STATE/install_calls.log")"

# Clean up restarted mock daemon before next test
new_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null || true)
[ -n "$new_pid" ] && kill "$new_pid" 2>/dev/null || true
rm -f "$BIFROST_PIDFILE"

# =====================================================================
# 3. Upgrade while stopped: does NOT start daemon
# =====================================================================
: >"$MOCK_STATE/install_calls.log"
ok upg-stop-rc sh "$T/pkgs/v2/install.sh" >/dev/null 2>&1
eq upg-stop-calls "$(printf 'daemon_stop\ncore_install_file arm')" "$(cat "$MOCK_STATE/install_calls.log")"

# =====================================================================
# 4. JS-only upgrade & CSS-only upgrade
# =====================================================================
h_js=$(make_pkg "$T/pkgs/v2js" "0.2.1" 2 arm "console.log('v2-js-changed');" ":host{color:#222;}")
no js-only-hash-diff test "$h_js" = "$h2"
ok js-only-rc sh "$T/pkgs/v2js/install.sh" >/dev/null 2>&1
check_assets js-only "$h_js"

h_css=$(make_pkg "$T/pkgs/v2css" "0.2.2" 2 arm "console.log('v2-js-changed');" ":host{color:#333;}")
no css-only-hash-diff test "$h_css" = "$h_js"
ok css-only-rc sh "$T/pkgs/v2css/install.sh" >/dev/null 2>&1
check_assets css-only "$h_css"

# =====================================================================
# 5. No core downgrade when installed serial > package serial
# =====================================================================
h5=$(make_pkg "$T/pkgs/v5" "0.5.0" 5 arm "console.log('v5');" ":host{color:#555;}")
ok serial5-rc sh "$T/pkgs/v5/install.sh" >/dev/null 2>&1
eq serial5-installed 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
core_sha_5=$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)

: >"$MOCK_STATE/install_calls.log"
out=$(sh "$T/pkgs/v2/install.sh" 2>&1)
eq nodowngrade-rc 0 "$?"
has nodowngrade-msg "不降级" "$out"
eq nodowngrade-serial 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
eq nodowngrade-core-unchanged "$core_sha_5" "$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)"
eq nodowngrade-calls "daemon_stop" "$(cat "$MOCK_STATE/install_calls.log")"

# =====================================================================
# 6. Core verification failure: upgrade keeps old core; fresh install aborts & cleans
# =====================================================================
h_bad=$(make_pkg "$T/pkgs/v6bad" "0.6.0" 6 arm "console.log('v6');" ":host{color:#666;}" bad_hash)
out=$(sh "$T/pkgs/v6bad/install.sh" 2>&1)
eq corefail-upg-rc 0 "$?"
has corefail-upg-warn "保留原有核心" "$out"
eq corefail-upg-old-core "$core_sha_5" "$(openssl dgst -sha256 -r "$BIFROST_CORE" | cut -d ' ' -f 1)"
eq corefail-upg-old-serial 5 "$(jq -r .serial "$BIFROST_MANIFEST")"
no corefail-upg-no-new test -e "$BIFROST_CORE.new"
check_assets corefail-upg "$h_bad"

# Fresh install with bad hash & bad version
inst_setup
make_pkg "$T/pkgs/badhash" "0.1.0" 1 arm "console.log('a');" ":host{}" bad_hash >/dev/null
no corefail-fresh-hash sh "$T/pkgs/badhash/install.sh" >/dev/null 2>&1
no corefail-fresh-no-home test -e "$BIFROST_HOME"
no corefail-fresh-no-asp test -e "$BIFROST_WEBS/Module_bifrost.asp"
eq corefail-fresh-no-dbus "" "$(dbus get softcenter_module_bifrost_install)"

make_pkg "$T/pkgs/badver" "0.1.0" 1 arm "console.log('a');" ":host{}" bad_version >/dev/null
no corefail-fresh-ver sh "$T/pkgs/badver/install.sh" >/dev/null 2>&1
no corefail-fresh-ver-no-home test -e "$BIFROST_HOME"

# =====================================================================
# 7. Missing web asset & failed atomic publish leave no new assets
# =====================================================================
inst_setup
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"
ha=$(make_pkg "$T/pkgs/pa" "0.1.0" 1 arm "console.log('A');" ":host{color:#aaa;}")
ok prep-a sh "$T/pkgs/pa/install.sh" >/dev/null 2>&1
check_assets prep-a "$ha"

hb=$(make_pkg "$T/pkgs/pb" "0.2.0" 2 arm "console.log('B');" ":host{color:#bbb;}")
rm -f "$T/pkgs/pb/res/bifrost-app.$hb.css"
: >"$MOCK_STATE/install_calls.log"
no missing-css-fail sh "$T/pkgs/pb/install.sh" >/dev/null 2>&1
eq missing-css-no-stop "" "$(cat "$MOCK_STATE/install_calls.log")"
check_assets missing-css-keeps-a "$ha"

# Failed rename of Module_bifrost.asp keeps old ASP and removes newly copied B assets
hb=$(make_pkg "$T/pkgs/pb2" "0.2.0" 2 arm "console.log('B2');" ":host{color:#bbb;}")
mkdir -p "$T/reject-mv"
cat >"$T/reject-mv/mv" <<EOF
#!/bin/sh
for _a in "\$@"; do
    [ "\$_a" = "$BIFROST_WEBS/Module_bifrost.asp" ] && exit 1
done
exec /opt/bb125/busybox mv "\$@"
EOF
chmod 755 "$T/reject-mv/mv"
no fail-publish-rc env PATH="$T/reject-mv:$PATH" sh "$T/pkgs/pb2/install.sh" >/dev/null 2>&1
check_assets fail-publish-keeps-a "$ha"

# =====================================================================
# 8. Unmet environment checks (no tun, bad arch, arm64 on armv7l, missing tool)
# =====================================================================
inst_setup
make_pkg "$T/pkgs/envok" "0.1.0" 1 arm "console.log('e');" ":host{}" >/dev/null

# Missing TUN
rm -f "$BIFROST_TUN_DEV"
out=$(sh "$T/pkgs/envok/install.sh" 2>&1)
no env-no-tun-rc test "$?" -eq 0
has env-no-tun-msg "TUN" "$out"
: >"$BIFROST_TUN_DEV"

# Unsupported arch x86_64
echo x86_64 >"$MOCK_STATE/uname_m"
out=$(sh "$T/pkgs/envok/install.sh" 2>&1)
no env-bad-arch-rc test "$?" -eq 0
has env-bad-arch-msg "架构" "$out"

# arm64 package on armv7l kernel
echo armv7l >"$MOCK_STATE/uname_m"
make_pkg "$T/pkgs/arm64pkg" "0.1.0" 1 arm64 "console.log('e');" ":host{}" >/dev/null
out=$(sh "$T/pkgs/arm64pkg/install.sh" 2>&1)
no env-arm64-on-v7-rc test "$?" -eq 0
has env-arm64-on-v7-msg "arm64" "$out"
echo aarch64 >"$MOCK_STATE/uname_m"

# Missing curl
no env-no-curl env PATH="/src/tests/shell/mock/bin:/opt/bb125/bin:/opt/tools/bin" \
    sh "$T/pkgs/envok/install.sh" >/dev/null 2>&1

# Missing base.sh
rm -f "$BIFROST_KSROOT/scripts/base.sh"
no env-no-base sh "$T/pkgs/envok/install.sh" >/dev/null 2>&1

# =====================================================================
# 9. Lock held: waits then fails
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
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

no lock-busy-rc test "$rc" -eq 0
ok lock-busy-waited test "$((t1 - t0))" -ge 2
has lock-busy-msg "正在进行" "$out"

# =====================================================================
# 10. Concurrent installs: only one proceeds (wait=0) & serialized (wait=10)
# =====================================================================
inst_setup
: >"$BIFROST_RES/unrelated.js"
: >"$BIFROST_RES/bifrost-app.notes.css"
hc1=$(make_pkg "$T/pkgs/c1" "0.1.0" 1 arm "console.log('C1');" ":host{color:#c01;}")
hc2=$(make_pkg "$T/pkgs/c2" "0.1.0" 1 arm "console.log('C2');" ":host{color:#c02;}")
echo 2 >"$MOCK_STATE/core_sleep"

# Part A: with wait=0, two simultaneous installs -> exactly one succeeds, one fails busy
BIFROST_INSTALL_LOCK_WAIT=0 sh "$T/pkgs/c1/install.sh" >/dev/null 2>&1 &
p1=$!
BIFROST_INSTALL_LOCK_WAIT=0 sh "$T/pkgs/c2/install.sh" >/dev/null 2>&1 &
p2=$!
r1=0; wait "$p1" || r1=$?
r2=0; wait "$p2" || r2=$?
ok conc-one-wins test \( "$r1" -eq 0 -a "$r2" -ne 0 \) -o \( "$r1" -ne 0 -a "$r2" -eq 0 \)
if [ "$r1" -eq 0 ]; then
    check_assets conc-winner "$hc1"
else
    check_assets conc-winner "$hc2"
fi

# Part B: with wait=10, two simultaneous installs serialize cleanly with zero overlap
: >"$MOCK_STATE/concurrency.log"
echo 1 >"$MOCK_STATE/core_sleep"
BIFROST_INSTALL_LOCK_WAIT=10 sh "$T/pkgs/c1/install.sh" >/dev/null 2>&1 &
p1=$!
BIFROST_INSTALL_LOCK_WAIT=10 sh "$T/pkgs/c2/install.sh" >/dev/null 2>&1 &
p2=$!
r1=0; wait "$p1" || r1=$?
r2=0; wait "$p2" || r2=$?
eq conc-ser-r1 0 "$r1"
eq conc-ser-r2 0 "$r2"
# Verify ENTER/LEAVE pairs never overlap (line 1 ENTER pA, line 2 LEAVE pA, line 3 ENTER pB, line 4 LEAVE pB)
eq conc-ser-order "$(printf 'ENTER\nLEAVE\nENTER\nLEAVE')" "$(cut -d ' ' -f 1 "$MOCK_STATE/concurrency.log")"
if grep -Fq "src=\"/res/bifrost-app.$hc1.js\"" "$BIFROST_WEBS/Module_bifrost.asp"; then
    check_assets conc-ser-final "$hc1"
else
    check_assets conc-ser-final "$hc2"
fi
rm -f "$MOCK_STATE/core_sleep"

# =====================================================================
# 11. Uninstall: every item in PLAN 15.2 removed; state & unrelated kept
# =====================================================================
mkdir -p "$BIFROST_STATE" "$BIFROST_RUN" "$BIFROST_SOCK_DIR"
printf 'preserve-me\n' >"$BIFROST_STATE/tailscaled.state"
: >"$BIFROST_RUN/bifrost.log"
: >"$BIFROST_RUN/bifrostd.log"
: >"$BIFROST_SOCK"
: >"$BIFROST_UPLOAD/bifrost_status.json"
: >"$BIFROST_UPLOAD/bifrost_update.json"
: >"$BIFROST_UPLOAD/bifrost_logs.txt"
: >"$BIFROST_DNSMASQ_CONF"
: >"$BIFROST_RES/.bifrost-app.new"
: >"$BIFROST_WEBS/.bifrost-app.new"
: >"$BIFROST_RES/bifrost-app.0123456789abcdef0123.js"
cru a bifrost "*/2 * * * * sh $BIFROST_SCRIPTS/bifrost_config.sh local watchdog"
dbus set other_plugin_enable=1

: >"$MOCK_STATE/install_calls.log"
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq uninst-rc 0 "$?"
has uninst-done "卸载完成" "$out"
has uninst-called-stop "daemon_stop" "$(cat "$MOCK_STATE/install_calls.log")"

# Every single installed and runtime path removed
no uninst-home test -e "$BIFROST_HOME"
no uninst-sock test -e "$BIFROST_SOCK_DIR"
no uninst-run test -e "$BIFROST_RUN"
no uninst-dnsmasq test -e "$BIFROST_DNSMASQ_CONF"
no uninst-s99 test -e "$BIFROST_INITD/S99bifrost.sh"
no uninst-n99 test -e "$BIFROST_INITD/N99bifrost.sh"
no uninst-ksbin test -e "$BIFROST_KSBIN/bifrost"
no uninst-cfg-sh test -e "$BIFROST_SCRIPTS/bifrost_config.sh"
no uninst-status-sh test -e "$BIFROST_SCRIPTS/bifrost_status.sh"
no uninst-self test -e "$BIFROST_SCRIPTS/uninstall_bifrost.sh"
no uninst-asp test -e "$BIFROST_WEBS/Module_bifrost.asp"
no uninst-asp-tmp test -e "$BIFROST_WEBS/.bifrost-app.new"
no uninst-icon test -e "$BIFROST_RES/icon-bifrost.png"
no uninst-res-tmp test -e "$BIFROST_RES/.bifrost-app.new"
no uninst-upload ls "$BIFROST_UPLOAD"/bifrost_* >/dev/null 2>&1
# shellcheck disable=SC2012
eq uninst-res-unrelated "$(printf 'bifrost-app.notes.css\nunrelated.js')" "$(ls -1A "$BIFROST_RES" | sort)"
eq uninst-cru "" "$(cru l | grep '#bifrost#' || true)"
eq uninst-dbus-bifrost "" "$(dbus list bifrost_)"
eq uninst-dbus-sc "" "$(dbus list softcenter_module_bifrost_)"
no uninst-no-command-v test -e "$MOCK_STATE/used-command"

# Preserved items untouched
eq uninst-state-kept "preserve-me" "$(cat "$BIFROST_STATE/tailscaled.state")"
eq uninst-other-dbus 1 "$(dbus get other_plugin_enable)"

t_done
