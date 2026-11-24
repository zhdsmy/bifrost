#!/bin/sh
# Verify that a v0.1.0 updater accepts the new manifest's additive fields and
# continues to select the uncompressed assets.
# shellcheck disable=SC1091
. tests/shell/lib.sh
t_setup
t_load
. "$T_SRC/tests/shell/fixtures/update/v010-parser.sh"

fixture="$T/core.json"
jq -n '
  def asset($arch; $file): {
    file:$file, size:123, sha256:("a" * 64), raw_size:456,
    raw_sha256:("b" * 64)
  };
  {
    schema:1, serial:2, tailscale:"1.104.7", revision:2,
    tag:"core-1.104.7-2", min_plugin:"0.1.0",
    build:{go:"1.27.4",commit:("c" * 40),omit:["aws"]},
    assets:{arm:asset("arm"; "bifrost-core-1.104.7-2-linux-arm.gz"),
            arm64:asset("arm64"; "bifrost-core-1.104.7-2-linux-arm64.gz")},
    upx_assets:{arm:asset("arm"; "bifrost-core-1.104.7-2-upx-linux-arm.gz"),
                arm64:asset("arm64"; "bifrost-core-1.104.7-2-upx-linux-arm64.gz")},
    upx:{version:"5.3.0",flags:["--best","--no-lzma"]}
  }
' >"$fixture"

ok v010-accepts-additive-fields _upd_parse_manifest_v010 "$fixture" arm any 0
eq v010-selects-normal-file "bifrost-core-1.104.7-2-linux-arm.gz" "$_UM_FILE"
eq v010-selects-normal-size 123 "$_UM_SIZE"

# The paths v0.1.0 uses for "check" (ge) and "update" (gt): installed
# serial 1, plugin 0.1.0.
mkdir -p "$BIFROST_HOME"
printf '0.1.0\n' >"$BIFROST_VERSION_FILE"
jq '.serial = 1 | .revision = 1 | .tag = "core-1.104.7-1" | .arch = "arm" |
    .assets = {arm: .assets.arm} | del(.upx_assets, .upx)' "$fixture" >"$BIFROST_MANIFEST"
ok v010-check-path _upd_parse_manifest_v010 "$fixture" arm ge 1
ok v010-update-path _upd_parse_manifest_v010 "$fixture" arm gt 1
eq v010-update-file "bifrost-core-1.104.7-2-linux-arm.gz" "$_UM_FILE"
ok v010-arm64-path _upd_parse_manifest_v010 "$fixture" arm64 gt 1
eq v010-arm64-file "bifrost-core-1.104.7-2-linux-arm64.gz" "$_UM_FILE"

t_done
