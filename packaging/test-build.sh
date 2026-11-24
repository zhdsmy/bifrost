#!/bin/sh
# Self-test for packaging/build.sh (Items 13, 14, 15, 22):
#   1. Build twice using the REAL web build -> identical sha256.
#   2. Signed --core-release via file:// URL + ECDSA P-256 verification.
#   3. Negative tests (each asserts exact failure message):
#      - tampered manifest, wrong public key, empty keys dir (--core-release vs --core-dir warning),
#      - bad gz size, bad gz sha256, bad raw size, bad raw sha256, corrupted gz under --core-dir,
#      - min_plugin > plugin version, Module_bifrost.asp <body> missing app/onload/skin.
#   4. Relative path resolution from a non-repo working directory.
#   5. BusyBox 1.25 smoke install via tests/install/run.sh --package (real libs + snapshot check).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

expect_fail() {
    _ef_name=$1
    _ef_needle=$2
    shift 2
    _ef_out=$("$@" 2>&1) && {
        echo "FAIL [$_ef_name]: expected failure, got exit 0" >&2
        exit 1
    }
    case "$_ef_out" in
        *"$_ef_needle"*)
            echo "PASS [$_ef_name]"
            ;;
        *)
            echo "FAIL [$_ef_name]: missing '$_ef_needle' in output:" >&2
            printf '%s\n' "$_ef_out" >&2
            exit 1
            ;;
    esac
}

# Generate a fake core output matching core/build.sh layout (mock bifrostd so BusyBox smoke can run it).
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

# Generate ECDSA P-256 test keypairs (key1 valid, key2 wrong key).
keys_dir="$work/keys"
wrong_keys_dir="$work/wrong-keys"
empty_keys_dir="$work/empty-keys"
mkdir -p "$keys_dir" "$wrong_keys_dir" "$empty_keys_dir"
openssl ecparam -name prime256v1 -genkey -noout -out "$work/priv1.pem" 2>/dev/null
openssl ec -in "$work/priv1.pem" -pubout -out "$keys_dir/test1.pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$work/priv2.pem" 2>/dev/null
openssl ec -in "$work/priv2.pem" -pubout -out "$wrong_keys_dir/test2.pub.pem" 2>/dev/null

# 1. Reproducibility using the REAL web build (build 1 builds web/; build 2 reuses web/dist).
ver=$(tr -d ' \t\r\n' <"$REPO_ROOT/plugin/bifrost/version")
mkdir -p "$work/out1" "$work/out2"
packaging/build.sh --core-dir "$core_dir" --keys-dir "$keys_dir" --out "$work/out1" --source-date-epoch 1700000000
sleep 1
packaging/build.sh --core-dir "$core_dir" --keys-dir "$keys_dir" --web-dist "$REPO_ROOT/web/dist" --out "$work/out2" --source-date-epoch 1700000000

sha1=$(openssl dgst -sha256 -r "$work/out1/bifrost-${ver}-hnd.tar.gz" | cut -d ' ' -f 1)
sha2=$(openssl dgst -sha256 -r "$work/out2/bifrost-${ver}-hnd.tar.gz" | cut -d ' ' -f 1)
if [ "$sha1" != "$sha2" ]; then
    echo "FAIL [reproducibility]: $sha1 != $sha2" >&2
    exit 1
fi
echo "PASS [reproducibility] sha256=$sha1"

web_dist="$REPO_ROOT/web/dist"

# 2. Signed --core-release via file:// URL.
rel_dir="$work/releases/core-1.104.7-1"
mkdir -p "$rel_dir" "$work/out3"
cp "$core_dir/core.json" "$core_dir/bifrost-core-1.104.7-1-linux-arm.gz" "$rel_dir/"
openssl dgst -sha256 -sign "$work/priv1.pem" -out "$rel_dir/core.json.sig" "$rel_dir/core.json"

packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" \
    --keys-dir "$keys_dir" \
    --web-dist "$web_dist" \
    --out "$work/out3" \
    --source-date-epoch 1700000000
echo "PASS [signed-core-release]"
rc=0
missing=$(packaging/build.sh --core-release core-1.104.7-1 --arch arm64 \
    --release-base "file://$work/releases" --keys-dir "$keys_dir" \
    --web-dist "$web_dist" --out "$work/out3" 2>&1) || rc=$?
if [ "$rc" != 3 ] || [ -e "$work/out3/bifrost-${ver}-hnd-arm64.tar.gz" ]; then
    echo "FAIL [signed-release-without-arm64]: exit $rc or unexpected package" >&2
    exit 1
fi
case "$missing" in
    *"no asset for arch 'arm64'"*) echo "PASS [signed-release-without-arm64]" ;;
    *) echo "FAIL [signed-release-without-arm64]: $missing" >&2; exit 1 ;;
esac

mkdir "$work/extract"
tar -xzf "$work/out3/bifrost-${ver}-hnd.tar.gz" -C "$work/extract"
extracted="$work/extract/bifrost"
for lib in daemon update; do
    mv "$extracted/lib/$lib.sh" "$work/lib.saved"
    expect_fail "missing-$lib" "missing or empty lib/$lib.sh" \
        python3 packaging/check-contents.py "$extracted" "$keys_dir" 1
    mv "$work/lib.saved" "$extracted/lib/$lib.sh"
done
rm "$extracted/keys/test1.pub.pem"
expect_fail missing-packaged-key "public key count differs" \
    python3 packaging/check-contents.py "$extracted" "$keys_dir" 1

# 3. Negative checks (Items 13 & 14).
# 3a. Wrong public key
expect_fail wrong-public-key "signature verification failed" \
    packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" --keys-dir "$wrong_keys_dir" \
    --web-dist "$web_dist" --out "$work/out-bad"

# 3b. Empty keys dir: fatal on --core-release, warning on --core-dir
expect_fail empty-keys-release "no *.pub.pem public keys found" \
    packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" --keys-dir "$empty_keys_dir" \
    --web-dist "$web_dist" --out "$work/out-bad"

warn_out=$(packaging/build.sh --core-dir "$core_dir" --keys-dir "$empty_keys_dir" \
    --web-dist "$web_dist" --out "$work/out-warn" --source-date-epoch 1700000000 2>&1)
case "$warn_out" in
    *"warning: no *.pub.pem"*) echo "PASS [empty-keys-core-dir-warns]" ;;
    *) echo "FAIL [empty-keys-core-dir-warns]: missing warning in: $warn_out" >&2; exit 1 ;;
esac

# 3c. Tampered manifest after signing
cp "$rel_dir/core.json" "$work/core.json.good"
jq '.serial = 99' "$work/core.json.good" >"$rel_dir/core.json"
expect_fail tampered-manifest "signature verification failed" \
    packaging/build.sh --core-release core-1.104.7-1 \
    --release-base "file://$work/releases" --keys-dir "$keys_dir" \
    --web-dist "$web_dist" --out "$work/out-bad"
mv "$work/core.json.good" "$rel_dir/core.json"

# 3d. Bad gz size, bad gz sha256, bad raw size, bad raw sha256, corrupted gz under --core-dir
make_mutated_core() {
    _mc_dir=$1
    _mc_jq=$2
    rm -rf "$_mc_dir"
    mkdir -p "$_mc_dir"
    cp "$core_dir/bifrost-core-1.104.7-1-linux-arm.gz" "$_mc_dir/"
    jq "$_mc_jq" "$core_dir/core.json" >"$_mc_dir/core.json"
}

make_mutated_core "$work/bad-gz-size" '.assets.arm.size += 1'
expect_fail bad-gz-size "gz integrity mismatch" \
    packaging/build.sh --core-dir "$work/bad-gz-size" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

make_mutated_core "$work/bad-gz-sha" '.assets.arm.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
expect_fail bad-gz-sha "gz integrity mismatch" \
    packaging/build.sh --core-dir "$work/bad-gz-sha" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

make_mutated_core "$work/bad-raw-size" '.assets.arm.raw_size += 1'
expect_fail bad-raw-size "raw core integrity mismatch" \
    packaging/build.sh --core-dir "$work/bad-raw-size" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

make_mutated_core "$work/bad-raw-sha" '.assets.arm.raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
expect_fail bad-raw-sha "raw core integrity mismatch" \
    packaging/build.sh --core-dir "$work/bad-raw-sha" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

# Corrupted gz file whose size/sha matches manifest but gunzip fails
mkdir -p "$work/bad-corrupt-gz"
printf 'not-a-valid-gzip-stream\n' >"$work/bad-corrupt-gz/bifrost-core-1.104.7-1-linux-arm.gz"
c_sha=$(openssl dgst -sha256 -r "$work/bad-corrupt-gz/bifrost-core-1.104.7-1-linux-arm.gz" | cut -d ' ' -f 1)
c_sz=$(wc -c <"$work/bad-corrupt-gz/bifrost-core-1.104.7-1-linux-arm.gz" | tr -d ' ')
jq --arg s "$c_sha" --argjson z "$c_sz" '.assets.arm.sha256 = $s | .assets.arm.size = $z' \
    "$core_dir/core.json" >"$work/bad-corrupt-gz/core.json"
expect_fail corrupt-gz-file "corrupted gz archive" \
    packaging/build.sh --core-dir "$work/bad-corrupt-gz" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

# 3e. min_plugin > plugin version
make_mutated_core "$work/bad-min-plugin" '.min_plugin = "99.0.0"'
expect_fail min-plugin-too-new "plugin_too_old, min_plugin=99.0.0" \
    packaging/build.sh --core-dir "$work/bad-min-plugin" --keys-dir "$keys_dir" --web-dist "$web_dist" --out "$work/out-bad"

# 3f. Module_bifrost.asp <body> missing skin / onload / app
cp -R "$web_dist" "$work/bad-web-dist"
sed 's/skin/x/g' "$web_dist/Module_bifrost.asp" >"$work/bad-web-dist/Module_bifrost.asp"
expect_fail bad-asp-body-skin "<body> line missing 'skin'" \
    packaging/build.sh --core-dir "$core_dir" --keys-dir "$keys_dir" --web-dist "$work/bad-web-dist" --out "$work/out-bad"
sed 's/onload/onx/g' "$web_dist/Module_bifrost.asp" >"$work/bad-web-dist/Module_bifrost.asp"
expect_fail bad-asp-body-onload "<body> line missing 'onload'" \
    packaging/build.sh --core-dir "$core_dir" --keys-dir "$keys_dir" --web-dist "$work/bad-web-dist" --out "$work/out-bad"
sed 's/id="app"/class="app-x" data-id="app"/g' "$web_dist/Module_bifrost.asp" >"$work/bad-web-dist/Module_bifrost.asp"
expect_fail bad-asp-body-app "<body> line missing 'app'" \
    packaging/build.sh --core-dir "$core_dir" --keys-dir "$keys_dir" --web-dist "$work/bad-web-dist" --out "$work/out-bad"

# 4. Relative path resolution from caller's working directory (Item 15).
ln -s "$web_dist" "$work/real-web"
mkdir -p "$work/sub"
(
    cd "$work/sub"
    "$REPO_ROOT/packaging/build.sh" \
        --core-dir "../core-out" \
        --keys-dir "../keys" \
        --web-dist "../real-web" \
        --out "./rel-out" \
        --source-date-epoch 1700000000
)
[ -s "$work/sub/rel-out/bifrost-${ver}-hnd.tar.gz" ] || {
    echo "FAIL [relative-paths]: output tarball not found at caller-relative ./rel-out" >&2
    exit 1
}
echo "PASS [relative-paths]"

# 5. Smoke-test built tarball in BusyBox 1.25 container (real libs + snapshot verification).
tests/install/run.sh --package "$work/out1/bifrost-${ver}-hnd.tar.gz"
echo "PASS packaging build + BusyBox 1.25 install smoke test"
