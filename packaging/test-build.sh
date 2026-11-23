#!/bin/sh
# Self-test for packaging/build.sh:
#   1. Build twice from fake core dir + fake web dist -> verify identical sha256.
#   2. Build with --core-release via file:// URL + ECDSA P-256 signature verification
#      (both valid signature and tampered manifest rejection).
#   3. Smoke-test the produced tarball in BusyBox 1.25 via tests/install/run.sh --package.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Generate fake core output matching core/build.sh output layout.
core_dir="$work/core-out"
mkdir -p "$core_dir"
cp "$REPO_ROOT/tests/shell/mock/bifrostd" "$work/bifrostd.raw"
chmod 755 "$work/bifrostd.raw"
gzip -9 -n -c "$work/bifrostd.raw" >"$core_dir/bifrost-core-1.104.7-1-linux-arm.gz"
raw_sha=$(openssl dgst -sha256 -r "$work/bifrostd.raw" | cut -d ' ' -f 1)
raw_size=$(wc -c <"$work/bifrostd.raw" | tr -d ' ')
gz_sha=$(openssl dgst -sha256 -r "$core_dir/bifrost-core-1.104.7-1-linux-arm.gz" | cut -d ' ' -f 1)
gz_size=$(wc -c <"$core_dir/bifrost-core-1.104.7-1-linux-arm.gz" | tr -d ' ')

jq -n \
    --arg gz_sha "$gz_sha" --argjson gz_size "$gz_size" \
    --arg raw_sha "$raw_sha" --argjson raw_size "$raw_size" \
    '{
      schema: 1, serial: 1, tailscale: "1.104.7", revision: 1,
      tag: "core-1.104.7-1", min_plugin: "0.1.0",
      build: { go: "1.27.4", commit: "cbc74fe48ef1b1649f69a4d9a602319427e25102", omit: ["aws"] },
      assets: {
        arm: {
          file: "bifrost-core-1.104.7-1-linux-arm.gz",
          size: $gz_size, sha256: $gz_sha,
          raw_size: $raw_size, raw_sha256: $raw_sha
        }
      }
    }' >"$core_dir/core.json"

# Generate fake web build output matching contract section 10.
web_dist="$work/web-dist"
mkdir -p "$web_dist/res"
js_body="console.log('bifrost-pkg-test');"
css_body=":host { display: block; }"
h=$(printf '%s\n%s\n' "$js_body" "$css_body" | openssl dgst -sha256 -r | cut -c1-20)
printf '%s\n' "$js_body" >"$web_dist/res/bifrost-app.$h.js"
printf '%s\n' "$css_body" >"$web_dist/res/bifrost-app.$h.css"
printf 'fake-png-icon\n' >"$web_dist/res/icon-bifrost.png"
cat >"$web_dist/Module_bifrost.asp" <<EOF
<!DOCTYPE html>
<html>
<body id="app" skin="ASUSWRT" onload="init();">
<div id="bifrost-app"></div>
<script defer src="/res/bifrost-app.$h.js"></script>
</body>
</html>
EOF

# 1. Reproducibility: build twice into separate dirs at different times -> identical sha256.
ver=$(tr -d ' \t\r\n' <"$REPO_ROOT/plugin/bifrost/version")
mkdir -p "$work/out1" "$work/out2"
packaging/build.sh --core-dir "$core_dir" --web-dist "$web_dist" --out "$work/out1" --source-date-epoch 1700000000
sleep 1
packaging/build.sh --core-dir "$core_dir" --web-dist "$web_dist" --out "$work/out2" --source-date-epoch 1700000000

sha1=$(openssl dgst -sha256 -r "$work/out1/bifrost-${ver}-hnd.tar.gz" | cut -d ' ' -f 1)
sha2=$(openssl dgst -sha256 -r "$work/out2/bifrost-${ver}-hnd.tar.gz" | cut -d ' ' -f 1)
if [ "$sha1" != "$sha2" ]; then
    echo "FAIL: non-reproducible build: $sha1 != $sha2" >&2
    exit 1
fi
echo "PASS reproducibility: sha256=$sha1"

# 2. Signed --core-release verification via local file:// release mirror (ECDSA P-256).
keys_dir="$work/keys"
rel_dir="$work/releases/core-1.104.7-1"
mkdir -p "$keys_dir" "$rel_dir" "$work/out3"
openssl ecparam -name prime256v1 -genkey -noout -out "$work/priv.pem" 2>/dev/null
openssl ec -in "$work/priv.pem" -pubout -out "$keys_dir/test.pub.pem" 2>/dev/null
cp "$core_dir/core.json" "$core_dir/bifrost-core-1.104.7-1-linux-arm.gz" "$rel_dir/"
openssl dgst -sha256 -sign "$work/priv.pem" -out "$rel_dir/core.json.sig" "$rel_dir/core.json"

packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" \
    --keys-dir "$keys_dir" \
    --web-dist "$web_dist" \
    --out "$work/out3" \
    --source-date-epoch 1700000000
echo "PASS signed --core-release verification"

# Tampered manifest must be rejected!
jq '.serial = 99' "$rel_dir/core.json" >"$rel_dir/core.json.bad"
mv "$rel_dir/core.json.bad" "$rel_dir/core.json"
if packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" \
    --keys-dir "$keys_dir" \
    --web-dist "$web_dist" \
    --out "$work/out3" >/dev/null 2>&1; then
    echo "FAIL: tampered manifest should have been rejected" >&2
    exit 1
fi
echo "PASS tampered manifest rejected"

# 3. Smoke-test built tarball in BusyBox 1.25 container.
tests/install/run.sh --package "$work/out1/bifrost-${ver}-hnd.tar.gz"
echo "PASS packaging build + BusyBox 1.25 install smoke test"
