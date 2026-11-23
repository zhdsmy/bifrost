#!/bin/sh
# Smoke test for a built Bifrost package tarball (bifrost-<ver>-hnd.tar.gz).
# Verifies extraction, fresh install, upgrade, and clean uninstall inside the
# BusyBox 1.25 router environment.

# shellcheck source=tests/shell/lib.sh
. tests/shell/lib.sh

pkg_tar=${1:?usage: t_package_smoke.sh <package.tar.gz>}

T=/tmp/bps.$$
rm -rf "$T"
# shellcheck disable=SC2013
for _ps_v in $(sed -n 's/^: "\${\(BIFROST_[A-Z0-9_]*\):=.*/\1/p' "$T_SRC/plugin/bifrost/lib/env.sh"); do
    unset "$_ps_v"
done
export MOCK_STATE="$T/state"
export BIFROST_KSROOT="$T/koolshare"
export BIFROST_RUN="$T/run"
export BIFROST_SOCK_DIR="$T/sock"
export BIFROST_UPLOAD="$T/upload"
export BIFROST_DNSMASQ_DIR="$T/dnsmasq.d"
export BIFROST_TUN_DEV="$T/dev-net-tun"
export BIFROST_INSTALL_LOCK_WAIT=5

for _ps_d in "$MOCK_STATE" "$BIFROST_KSROOT/scripts" "$BIFROST_KSROOT/webs" \
    "$BIFROST_KSROOT/res" "$BIFROST_KSROOT/init.d" "$BIFROST_KSROOT/bin" \
    "$BIFROST_UPLOAD" "$BIFROST_DNSMASQ_DIR" "$T/unpack"; do
    mkdir -p "$_ps_d"
done
: >"$MOCK_STATE/dbus.env"
: >"$MOCK_STATE/nvram.env"
: >"$BIFROST_TUN_DEV"
echo aarch64 >"$MOCK_STATE/uname_m"
cp "$T_SRC/tests/shell/mock/base.sh" "$BIFROST_KSROOT/scripts/base.sh"
# shellcheck source=plugin/bifrost/lib/env.sh
. "$T_SRC/plugin/bifrost/lib/env.sh"

ok tar-extract tar -xzf "$pkg_tar" -C "$T/unpack"
pkg="$T/unpack/bifrost"
ok pkg-topdir test -d "$pkg"
eq pkg-valid hnd "$(tr -d ' \r\n' <"$pkg/.valid")"

# Inject stubs only if P1/P2 libs are not yet in the built tarball (Round 1).
if [ ! -f "$pkg/lib/daemon.sh" ]; then
    cat >"$pkg/lib/daemon.sh" <<'EOF'
# shellcheck shell=sh
daemon_stop() { return 0; }
daemon_start() { return 0; }
EOF
fi
if [ ! -f "$pkg/lib/update.sh" ]; then
    cat >"$pkg/lib/update.sh" <<'EOF'
# shellcheck shell=sh
core_install_file() {
    mkdir -p "$BIFROST_BIN"
    gunzip -c "$1" >"$BIFROST_CORE.new" || return 1
    chmod 755 "$BIFROST_CORE.new"
    _ws=$(jq -r --arg a "$3" '.assets[$a].raw_sha256 // empty' "$2")
    _gs=$(sha256_file "$BIFROST_CORE.new")
    [ -n "$_ws" ] && [ "$_ws" = "$_gs" ] || { rm -f "$BIFROST_CORE.new"; fail hash_mismatch; return 1; }
    _wv=$(jq -r '.tailscale // empty' "$2")
    _gv=$("$BIFROST_CORE.new" --version 2>/dev/null | head -n 1)
    [ -n "$_wv" ] && [ "$_wv" = "$_gv" ] || { rm -f "$BIFROST_CORE.new"; fail core_test_failed; return 1; }
    mv -f "$BIFROST_CORE.new" "$BIFROST_CORE"
}
EOF
fi

ver=$(tr -d ' \r\n' <"$pkg/version")
ok smoke-install sh "$pkg/install.sh" >/dev/null
eq smoke-ver "$ver" "$(dbus get bifrost_version)"
ok smoke-core test -x "$BIFROST_CORE"
ok smoke-asp test -s "$BIFROST_WEBS/Module_bifrost.asp"
ok smoke-ksbin test -x "$BIFROST_KSBIN/bifrost"
ok smoke-license test -s "$BIFROST_HOME/LICENSE"
ok smoke-license-ts test -s "$BIFROST_HOME/LICENSE.tailscale"
ok smoke-notice test -s "$BIFROST_HOME/NOTICE.md"

# Upgrade idempotency
mkdir -p "$BIFROST_STATE"
printf 'keep\n' >"$BIFROST_STATE/tailscaled.state"
ok smoke-upgrade sh "$pkg/install.sh" >/dev/null
eq smoke-state-after-upg keep "$(cat "$BIFROST_STATE/tailscaled.state")"

# Clean uninstall
ok smoke-uninstall sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" >/dev/null
no smoke-uninst-home test -e "$BIFROST_HOME"
no smoke-uninst-asp test -e "$BIFROST_WEBS/Module_bifrost.asp"
no smoke-uninst-run test -e "$BIFROST_RUN"
eq smoke-uninst-dbus "" "$(dbus list bifrost_)"
eq smoke-state-after-uninst keep "$(cat "$BIFROST_STATE/tailscaled.state")"

t_done
