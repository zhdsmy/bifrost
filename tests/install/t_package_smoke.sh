#!/bin/sh
# Smoke test for a built Bifrost package tarball (bifrost-<ver>-hnd.tar.gz).
# Uses the REAL libraries bundled in the tarball (zero injected stubs) and
# compares before/after sandbox snapshots to prove clean install, upgrade and
# uninstall inside the BusyBox 1.25 router environment.

# shellcheck source=tests/shell/lib.sh
. tests/shell/lib.sh

pkg_tar=${1:?usage: t_package_smoke.sh <package.tar.gz>}

# shellcheck source=tests/install/lib.sh
. tests/install/lib.sh
inst_setup
mkdir -p "$T/unpack"
snapshot_sandbox >"$T/before.snap"

ok tar-extract tar -xzf "$pkg_tar" -C "$T/unpack"
pkg="$T/unpack/bifrost"
ok pkg-topdir test -d "$pkg"
eq pkg-valid hnd "$(tr -d ' \r\n' <"$pkg/.valid")"

ver=$(tr -d ' \r\n' <"$pkg/version")
out=$(sh "$pkg/install.sh" 2>&1)
eq smoke-install-rc 0 "$?"
has smoke-install-msg "安装完成" "$out"
eq smoke-scver "$ver" "$(dbus get softcenter_module_bifrost_version)"
eq smoke-no-bfver "" "$(dbus get bifrost_version)"
ok smoke-core test -x "$BIFROST_CORE"
ok smoke-asp test -s "$BIFROST_WEBS/Module_bifrost.asp"
ok smoke-ksbin test -x "$BIFROST_KSBIN/bifrost"
ok smoke-license test -s "$BIFROST_HOME/LICENSE"
ok smoke-license-ts test -s "$BIFROST_HOME/LICENSE.tailscale"
ok smoke-notice test -s "$BIFROST_HOME/NOTICE.md"
ok smoke-core-notice test -s "$BIFROST_HOME/THIRD_PARTY_NOTICES.core.md"
eq smoke-manifest-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"

# Upgrade idempotency
mkdir -p "$BIFROST_STATE"
printf 'keep\n' >"$BIFROST_STATE/tailscaled.state"
out=$(sh "$pkg/install.sh" 2>&1)
eq smoke-upgrade-rc 0 "$?"
has smoke-upgrade-msg "升级完成" "$out"
eq smoke-state-after-upg keep "$(cat "$BIFROST_STATE/tailscaled.state")"

# Clean uninstall + exact snapshot match
out=$(sh "$BIFROST_SCRIPTS/uninstall_bifrost.sh" 2>&1)
eq smoke-uninstall-rc 0 "$?"
has smoke-uninstall-msg "卸载完成" "$out"
snapshot_sandbox >"$T/after.snap"
eq smoke-snapshot-clean "$(cat "$T/before.snap")" "$(cat "$T/after.snap")"
eq smoke-uninst-dbus "" "$(dbus list bifrost_)"
eq smoke-uninst-sc "" "$(dbus list softcenter_module_bifrost_)"
eq smoke-state-after-uninst keep "$(cat "$BIFROST_STATE/tailscaled.state")"

t_done
