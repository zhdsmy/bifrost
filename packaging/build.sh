#!/bin/sh
# Build a reproducible KoolCenter / Koolshare offline package tarball for Bifrost.
# Follows docs/PLAN.md sections 12.2, 12.3, 16.1, 16.2 and docs/dev/contract.md sections 8 & 10.
# Package layout and build flow adapted from po0fw asus-merlin (MIT), commit 0d9532d.
#
# Usage:
#   packaging/build.sh --core-dir <dir> [--arch arm|arm64] [--out <dir>] [--web-dist <dir>]
#   packaging/build.sh --core-release <tag> [--arch arm|arm64] [--out <dir>] [--web-dist <dir>]
#                      [--keys-dir <dir>] [--release-base <url>]
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# shellcheck source=plugin/bifrost/lib/env.sh
. "$REPO_ROOT/plugin/bifrost/lib/env.sh"
# shellcheck source=plugin/bifrost/lib/validate.sh
. "$REPO_ROOT/plugin/bifrost/lib/validate.sh"
# shellcheck source=plugin/bifrost/lib/common.sh
. "$REPO_ROOT/plugin/bifrost/lib/common.sh"
if [ -f "$REPO_ROOT/plugin/bifrost/lib/update.sh" ]; then
    # shellcheck disable=SC1091
    . "$REPO_ROOT/plugin/bifrost/lib/update.sh"
fi

usage() {
    cat <<'EOF'
Usage: packaging/build.sh (--core-dir <dir> | --core-release <tag>) [options]

Options:
  --core-dir <dir>         Local core build output directory (verifies hashes only)
  --core-release <tag>     Download core release <tag>, verify signature and hashes
  --arch <arm|arm64>       Core architecture to bundle (default: arm)
  --out <dir>              Output directory (default: dist)
  --web-dist <dir>         Use pre-built web dist directory instead of running npm build
  --keys-dir <dir>         Public keys directory for signature verification (default: plugin/bifrost/keys)
  --release-base <url>     Override GitHub release download base URL
  --source-date-epoch <s>  Fixed Unix timestamp for reproducible tar mtimes
  -h, --help               Show this help
EOF
}

core_dir=""
core_release=""
arch="arm"
out_dir="dist"
web_dist=""
keys_dir="$REPO_ROOT/plugin/bifrost/keys"
release_base="$BIFROST_RELEASE_BASE"
epoch="${SOURCE_DATE_EPOCH:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --core-dir)
            [ $# -ge 2 ] || { echo "missing value for --core-dir" >&2; exit 2; }
            core_dir=$2
            shift 2
            ;;
        --core-release)
            [ $# -ge 2 ] || { echo "missing value for --core-release" >&2; exit 2; }
            core_release=$2
            shift 2
            ;;
        --arch)
            [ $# -ge 2 ] || { echo "missing value for --arch" >&2; exit 2; }
            arch=$2
            shift 2
            ;;
        --out)
            [ $# -ge 2 ] || { echo "missing value for --out" >&2; exit 2; }
            out_dir=$2
            shift 2
            ;;
        --web-dist)
            [ $# -ge 2 ] || { echo "missing value for --web-dist" >&2; exit 2; }
            web_dist=$2
            shift 2
            ;;
        --keys-dir)
            [ $# -ge 2 ] || { echo "missing value for --keys-dir" >&2; exit 2; }
            keys_dir=$2
            shift 2
            ;;
        --release-base)
            [ $# -ge 2 ] || { echo "missing value for --release-base" >&2; exit 2; }
            release_base=$2
            shift 2
            ;;
        --source-date-epoch)
            [ $# -ge 2 ] || { echo "missing value for --source-date-epoch" >&2; exit 2; }
            epoch=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$core_dir" ] && [ -n "$core_release" ]; then
    echo "error: --core-dir and --core-release are mutually exclusive" >&2
    exit 2
fi
if [ -z "$core_dir" ] && [ -z "$core_release" ]; then
    echo "error: must specify --core-dir or --core-release" >&2
    exit 2
fi
if ! valid_arch "$arch"; then
    echo "error: unsupported arch '$arch' (expected arm or arm64)" >&2
    exit 2
fi

for tool in jq openssl gzip gunzip tar; do
    if ! type "$tool" >/dev/null 2>&1; then
        echo "error: required tool missing: $tool" >&2
        exit 1
    fi
done

if [ -z "$epoch" ]; then
    epoch=$(git log -1 --format=%ct 2>/dev/null || echo 1700000000)
fi
if ! valid_uint "$epoch"; then
    echo "error: invalid SOURCE_DATE_EPOCH: $epoch" >&2
    exit 2
fi

# Fallback manifest_verify when P1's plugin/bifrost/lib/update.sh is not present yet.
if ! has_cmd manifest_verify; then
    manifest_verify() {
        _mv_json=$1
        _mv_sig=$2
        [ -s "$_mv_json" ] && [ -s "$_mv_sig" ] || return 1
        _mv_ok=0
        for _mv_pub in "$BIFROST_KEYS"/*.pub.pem; do
            [ -f "$_mv_pub" ] || continue
            if openssl dgst -sha256 -verify "$_mv_pub" -signature "$_mv_sig" "$_mv_json" >/dev/null 2>&1; then
                _mv_ok=1
                break
            fi
        done
        [ "$_mv_ok" = 1 ]
    }
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# 1. Resolve and verify core files.
core_work="$stage/core"
mkdir -p "$core_work"

if [ -n "$core_dir" ]; then
    [ -f "$core_dir/core.json" ] || { echo "error: $core_dir/core.json not found" >&2; exit 1; }
    cp "$core_dir/core.json" "$core_work/core.json"
    asset_file=$(jq -r --arg a "$arch" '.assets[$a].file // empty' "$core_work/core.json")
    [ -n "$asset_file" ] || { echo "error: manifest has no asset for arch '$arch'" >&2; exit 3; }
    [ -f "$core_dir/$asset_file" ] || { echo "error: $core_dir/$asset_file not found" >&2; exit 1; }
    cp "$core_dir/$asset_file" "$core_work/bifrostd.gz"
else
    type curl >/dev/null 2>&1 || { echo "error: curl is required for --core-release" >&2; exit 1; }
    base_url="${release_base%/}/${core_release}"
    echo "Downloading core manifest for ${core_release}..."
    curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 \
        "${base_url}/core.json" -o "$core_work/core.json"
    curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 \
        "${base_url}/core.json.sig" -o "$core_work/core.json.sig"

    BIFROST_KEYS="$keys_dir"
    if ! manifest_verify "$core_work/core.json" "$core_work/core.json.sig"; then
        echo "error: manifest signature verification failed for ${core_release} (keys: $keys_dir)" >&2
        exit 1
    fi

    asset_file=$(jq -r --arg a "$arch" '.assets[$a].file // empty' "$core_work/core.json")
    [ -n "$asset_file" ] || { echo "error: release ${core_release} has no asset for arch '$arch'" >&2; exit 3; }
    echo "Downloading core asset ${asset_file}..."
    curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 \
        "${base_url}/${asset_file}" -o "$core_work/bifrostd.gz"
fi

# Verify manifest schema, .gz size/sha256, and unpacked raw_size/raw_sha256.
schema=$(jq -r '.schema // empty' "$core_work/core.json")
serial=$(jq -r '.serial // empty' "$core_work/core.json")
ts_ver=$(jq -r '.tailscale // empty' "$core_work/core.json")
want_size=$(jq -r --arg a "$arch" '.assets[$a].size // empty' "$core_work/core.json")
want_sha=$(jq -r --arg a "$arch" '.assets[$a].sha256 // empty' "$core_work/core.json")
want_raw_size=$(jq -r --arg a "$arch" '.assets[$a].raw_size // empty' "$core_work/core.json")
want_raw_sha=$(jq -r --arg a "$arch" '.assets[$a].raw_sha256 // empty' "$core_work/core.json")

if [ "$schema" != 1 ] || ! valid_uint "$serial" || [ -z "$ts_ver" ] ||
   ! valid_uint "$want_size" || [ -z "$want_sha" ] ||
   ! valid_uint "$want_raw_size" || [ -z "$want_raw_sha" ]; then
    echo "error: invalid core manifest fields" >&2
    exit 1
fi

got_size=$(file_size "$core_work/bifrostd.gz")
got_sha=$(sha256_file "$core_work/bifrostd.gz")
if [ "$got_size" != "$want_size" ] || [ "$got_sha" != "$want_sha" ]; then
    echo "error: gz integrity mismatch (size: $got_size vs $want_size, sha256: $got_sha vs $want_sha)" >&2
    exit 1
fi

gunzip -c "$core_work/bifrostd.gz" >"$core_work/bifrostd.raw"
got_raw_size=$(file_size "$core_work/bifrostd.raw")
got_raw_sha=$(sha256_file "$core_work/bifrostd.raw")
rm -f "$core_work/bifrostd.raw"
if [ "$got_raw_size" != "$want_raw_size" ] || [ "$got_raw_sha" != "$want_raw_sha" ]; then
    echo "error: raw core integrity mismatch (size: $got_raw_size vs $want_raw_size, sha256: $got_raw_sha vs $want_raw_sha)" >&2
    exit 1
fi

# 2. Build (or use pre-built) web application (contract section 10).
if [ -z "$web_dist" ]; then
    for tool in node npm; do
        type "$tool" >/dev/null 2>&1 || { echo "error: $tool is required to build web/" >&2; exit 1; }
    done
    [ -f "$REPO_ROOT/web/package.json" ] || { echo "error: web/package.json not found (pass --web-dist for pre-built assets)" >&2; exit 1; }
    echo "Building web application..."
    (cd "$REPO_ROOT/web" && npm ci --include=dev --no-audit --no-fund && npm run build)
    web_dist="$REPO_ROOT/web/dist"
fi

[ -s "$web_dist/Module_bifrost.asp" ] || { echo "error: $web_dist/Module_bifrost.asp not found" >&2; exit 1; }
asset_js=$(sed -n 's@.*src="/res/\(bifrost-app\.[0-9a-f]\{20\}\.js\)".*@\1@p' "$web_dist/Module_bifrost.asp" | head -n 1)
[ -n "$asset_js" ] || { echo "error: $web_dist/Module_bifrost.asp missing hashed JS reference" >&2; exit 1; }
asset_css=${asset_js%.js}.css
[ -s "$web_dist/res/$asset_js" ] || { echo "error: $web_dist/res/$asset_js not found" >&2; exit 1; }
[ -s "$web_dist/res/$asset_css" ] || { echo "error: $web_dist/res/$asset_css not found" >&2; exit 1; }

# 3. Assemble package staging tree: bifrost/ (PLAN 16.1 & 16.2).
version=$(tr -d ' \t\r\n' <"$REPO_ROOT/plugin/bifrost/version")
[ -n "$version" ] || { echo "error: plugin/bifrost/version is empty" >&2; exit 1; }

pkg="$stage/bifrost"
mkdir -p "$pkg/bin" "$pkg/lib" "$pkg/scripts" "$pkg/webs" "$pkg/res" "$pkg/keys"

cp "$REPO_ROOT/plugin/bifrost/.valid" "$pkg/.valid"
cp "$REPO_ROOT/plugin/bifrost/version" "$pkg/version"
cp "$REPO_ROOT/plugin/bifrost/install.sh" "$pkg/install.sh"
cp "$REPO_ROOT/plugin/bifrost/uninstall.sh" "$pkg/uninstall.sh"
cp "$REPO_ROOT/LICENSE" "$pkg/LICENSE"
cp "$SCRIPT_DIR/LICENSE.tailscale" "$pkg/LICENSE.tailscale"
cp "$REPO_ROOT/NOTICE.md" "$pkg/NOTICE.md"

cp "$core_work/bifrostd.gz" "$pkg/bin/bifrostd.gz"
jq --arg a "$arch" '.assets = {($a): .assets[$a]}' "$core_work/core.json" >"$pkg/bin/core.json"
if [ -f "$REPO_ROOT/plugin/bifrost/bin/bifrost" ]; then
    cp "$REPO_ROOT/plugin/bifrost/bin/bifrost" "$pkg/bin/bifrost"
fi

for f in "$REPO_ROOT"/plugin/bifrost/scripts/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$pkg/scripts/${f##*/}"
done
for f in "$REPO_ROOT"/plugin/bifrost/lib/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$pkg/lib/${f##*/}"
done

cp "$web_dist/Module_bifrost.asp" "$pkg/webs/Module_bifrost.asp"
cp "$web_dist/res/$asset_js" "$pkg/res/$asset_js"
cp "$web_dist/res/$asset_css" "$pkg/res/$asset_css"

if [ -f "$REPO_ROOT/plugin/bifrost/res/icon-bifrost.png" ]; then
    cp "$REPO_ROOT/plugin/bifrost/res/icon-bifrost.png" "$pkg/res/icon-bifrost.png"
elif [ -f "$web_dist/res/icon-bifrost.png" ]; then
    cp "$web_dist/res/icon-bifrost.png" "$pkg/res/icon-bifrost.png"
else
    echo "error: icon-bifrost.png not found in plugin/bifrost/res/ or $web_dist/res/" >&2
    exit 1
fi

if [ -d "$keys_dir" ]; then
    for k in "$keys_dir"/*.pub.pem; do
        [ -f "$k" ] || continue
        cp "$k" "$pkg/keys/${k##*/}"
    done
fi

# Normalize permissions deterministically (independent of host umask).
find "$pkg" -type d -exec chmod 755 {} +
find "$pkg" -type f -exec chmod 644 {} +
chmod 755 "$pkg/install.sh" "$pkg/uninstall.sh"
for f in "$pkg"/scripts/*.sh; do
    [ -f "$f" ] && chmod 755 "$f"
done
[ -f "$pkg/bin/bifrost" ] && chmod 755 "$pkg/bin/bifrost"

# 4. Create reproducible ustar tar.gz on both Linux (GNU tar) and macOS (bsdtar).
mkdir -p "$out_dir"
if [ "$arch" = arm ]; then
    out_name="bifrost-${version}-hnd.tar.gz"
else
    out_name="bifrost-${version}-hnd-${arch}.tar.gz"
fi
out_path="${out_dir%/}/${out_name}"

# Format UTC timestamp YYYYMMDDhhmm.ss for portable touch -t (works on macOS and Linux).
utc_stamp=$(TZ=UTC date -u -r "$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null ||
    TZ=UTC date -u -d "@$epoch" '+%Y%m%d%H%M.%S')

# Normalize mtime on every staged file and directory (deepest first so directory mtimes stick).
(
    cd "$stage"
    LC_ALL=C find bifrost | LC_ALL=C sort >"$stage/entries.txt"
    LC_ALL=C find bifrost | LC_ALL=C sort -r | while IFS= read -r p; do
        TZ=UTC touch -t "$utc_stamp" "$p"
    done
)

tar_out="$stage/package.tar.gz"
if tar --version 2>/dev/null | grep -qi 'GNU tar'; then
    LC_ALL=C tar \
        --format=ustar \
        --sort=name \
        --mtime="@$epoch" \
        --owner=0 --group=0 --numeric-owner \
        -cf - -C "$stage" bifrost | gzip -9 -n >"$tar_out"
else
    # macOS bsdtar: explicit sorted entry list + --no-recursion + zero uid/gid/uname/gname.
    COPYFILE_DISABLE=1 LC_ALL=C tar \
        --format=ustar \
        --no-xattrs \
        --uid 0 --gid 0 --uname "" --gname "" \
        --no-recursion \
        -C "$stage" -T "$stage/entries.txt" -cf - | gzip -9 -n >"$tar_out"
fi

# 5. Post-build self-check on the produced tarball.
verify_dir="$stage/verify"
mkdir -p "$verify_dir"
tar -tzf "$tar_out" >"$verify_dir/list.txt"

# Every entry must stay under bifrost/ and have no macOS metadata files.
while IFS= read -r entry; do
    case "$entry" in
        bifrost | bifrost/*) ;;
        *) echo "self-check failed: unexpected tar entry: $entry" >&2; exit 1 ;;
    esac
    case "$entry" in
        *.DS_Store | */._* | *../*) echo "self-check failed: forbidden tar entry: $entry" >&2; exit 1 ;;
    esac
done <"$verify_dir/list.txt"

for req in \
    bifrost/.valid \
    bifrost/version \
    bifrost/install.sh \
    bifrost/uninstall.sh \
    bifrost/LICENSE \
    bifrost/LICENSE.tailscale \
    bifrost/NOTICE.md \
    bifrost/bin/bifrostd.gz \
    bifrost/bin/core.json \
    bifrost/scripts/bifrost_config.sh \
    bifrost/scripts/bifrost_status.sh \
    bifrost/lib/env.sh \
    bifrost/lib/validate.sh \
    bifrost/lib/common.sh \
    bifrost/webs/Module_bifrost.asp \
    bifrost/res/icon-bifrost.png \
    "bifrost/res/$asset_js" \
    "bifrost/res/$asset_css"; do
    if ! grep -Fqx "$req" "$verify_dir/list.txt"; then
        echo "self-check failed: missing required entry in tarball: $req" >&2
        exit 1
    fi
done

tar -xzf "$tar_out" -C "$verify_dir"
[ "$(tr -d ' \t\r\n' <"$verify_dir/bifrost/.valid")" = hnd ] || { echo "self-check failed: .valid != hnd" >&2; exit 1; }
[ "$(tr -d ' \t\r\n' <"$verify_dir/bifrost/version")" = "$version" ] || { echo "self-check failed: version mismatch" >&2; exit 1; }
if grep -Fq '__BIFROST_ASSETS__' "$verify_dir/bifrost/webs/Module_bifrost.asp"; then
    echo "self-check failed: unreplaced __BIFROST_ASSETS__ placeholder in Module_bifrost.asp" >&2
    exit 1
fi
if grep -Fq 'rogcss' "$verify_dir/bifrost/webs/Module_bifrost.asp"; then
    echo "self-check failed: Module_bifrost.asp contains forbidden word rogcss" >&2
    exit 1
fi
if ! grep -Fq "src=\"/res/$asset_js\"" "$verify_dir/bifrost/webs/Module_bifrost.asp"; then
    echo "self-check failed: Module_bifrost.asp does not reference $asset_js" >&2
    exit 1
fi
if grep -Eq 'detect_package|ks_tar_install' "$verify_dir/bifrost/install.sh"; then
    echo "self-check failed: install.sh contains forbidden software-center keyword" >&2
    exit 1
fi
pkg_arches=$(jq -r '.assets | keys | join(",")' "$verify_dir/bifrost/bin/core.json")
[ "$pkg_arches" = "$arch" ] || { echo "self-check failed: bin/core.json assets=$pkg_arches (want $arch)" >&2; exit 1; }

mv -f "$tar_out" "$out_path"
pkg_sha=$(sha256_file "$out_path")
pkg_size=$(file_size "$out_path")
echo "Built $out_path (${pkg_size} bytes, sha256=${pkg_sha}, core=${ts_ver}/${arch})"
