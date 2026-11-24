#!/bin/sh
# Build reproducible Bifrost cores from Tailscale upstream source (PLAN 5.1).
# Runs on macOS and Linux (POSIX sh, no GNU-only options).
#
# Usage:
#   core/build.sh [--serial N] [--min-plugin X.Y.Z] [--out DIR] [--src DIR]
#   core/build.sh --check-recipe [--src DIR]
#   core/build.sh --test-arch <amd64|arm64> [--out DIR] [--src DIR]
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

RECIPE="$SCRIPT_DIR/recipe.json"
OUT_DIR="${CORE_OUT_DIR:-$SCRIPT_DIR/out}"
SRC_DIR="${CORE_SRC_DIR:-}"
SERIAL="${CORE_SERIAL:-1}"
MIN_PLUGIN="${CORE_MIN_PLUGIN:-}"
UPX_BIN="${CORE_UPX_BIN:-}"
REPO_URL="${TAILSCALE_REPO_URL:-https://github.com/tailscale/tailscale.git}"
MODE="build"
TEST_ARCH=""

# Keep cache locations, but never inherit target, toolchain or compiler flags.
build_env() {
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        GOCACHE="${GOCACHE:-}" GOMODCACHE="${GOMODCACHE:-}" \
        HTTPS_PROXY="${HTTPS_PROXY:-}" HTTP_PROXY="${HTTP_PROXY:-}" NO_PROXY="${NO_PROXY:-}" \
        https_proxy="${https_proxy:-}" http_proxy="${http_proxy:-}" no_proxy="${no_proxy:-}" \
        ALL_PROXY="${ALL_PROXY:-}" all_proxy="${all_proxy:-}" GOPROXY="${GOPROXY:-}" \
        GIT_OPTIONAL_LOCKS=0 GOENV=off GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 "$@"
}

usage() {
    cat <<'EOF'
Usage:
  core/build.sh [--serial N] [--min-plugin X.Y.Z] [--out DIR] [--src DIR]
  core/build.sh --check-recipe [--src DIR]
  core/build.sh --test-arch <amd64|arm64> [--out DIR] [--src DIR]

Options:
  --check-recipe       Validate recipe.json and featuretags only; do not compile.
  --test-arch ARCH     Compile an uncompressed test binary for linux/<amd64|arm64>
                       into <out>/test/bifrostd-linux-<ARCH>.
  --serial N           Manifest serial integer (>= 1; default: $CORE_SERIAL or 1).
  --min-plugin X.Y.Z   Minimum plugin version (default: recipe.json .min_plugin or 0.1.0).
  --out DIR            Output directory (default: core/out).
  --src DIR            Tailscale git checkout directory (default: <out>/src/<commit>).
                       External (non-build.sh) git repos are checked read-only and never modified.
  --recipe FILE        Path to recipe.json (default: core/recipe.json).
  -h, --help           Show this help.
EOF
}

die() {
    echo "core/build.sh: $*" >&2
    exit 1
}

need_cmd() {
    type "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

is_uint_pos() {
    case "$1" in '' | 0 | *[!0-9]* | 0?*) return 1 ;; esac
    return 0
}

is_semver() {
    case "$1" in *.*.*) ;; *) return 1 ;; esac
    _sv_a=${1%%.*}
    _sv_rest=${1#*.}
    _sv_b=${_sv_rest%%.*}
    _sv_c=${_sv_rest#*.}
    case "$_sv_c" in *.*) return 1 ;; esac
    for _sv_p in "$_sv_a" "$_sv_b" "$_sv_c"; do
        case "$_sv_p" in '' | *[!0-9]* | 0?*) return 1 ;; esac
    done
    return 0
}

sha256_file() {
    _sf_out=$(openssl dgst -sha256 -r "$1") || die "sha256 failed: $1"
    _sf_hex=${_sf_out%% *}
    [ "${#_sf_hex}" -eq 64 ] || die "unexpected sha256 output for $1"
    printf '%s\n' "$_sf_hex"
}

file_size() {
    wc -c <"$1" | tr -d ' '
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check-recipe)
            [ "$MODE" = build ] || die "conflicting mode flags"
            MODE="check"
            shift
            ;;
        --test-arch)
            [ "$MODE" = build ] || die "conflicting mode flags"
            [ $# -ge 2 ] || die "--test-arch requires an argument"
            MODE="test-arch"
            TEST_ARCH=$2
            shift 2
            ;;
        --serial)
            [ $# -ge 2 ] || die "--serial requires an argument"
            SERIAL=$2
            shift 2
            ;;
        --min-plugin)
            [ $# -ge 2 ] || die "--min-plugin requires an argument"
            MIN_PLUGIN=$2
            shift 2
            ;;
        --out)
            [ $# -ge 2 ] || die "--out requires an argument"
            OUT_DIR=$2
            shift 2
            ;;
        --src)
            [ $# -ge 2 ] || die "--src requires an argument"
            SRC_DIR=$2
            shift 2
            ;;
        --recipe)
            [ $# -ge 2 ] || die "--recipe requires an argument"
            RECIPE=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

need_cmd jq
need_cmd git
need_cmd go
need_cmd openssl
need_cmd gzip

[ -f "$RECIPE" ] || die "recipe not found: $RECIPE"

# Resolve paths to absolute before changing directories.
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
WORK_DIR="$OUT_DIR/.work.$$"
cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "$OUT_DIR"/*.tmp.$$
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_recipe() {
    jq -e '
        type == "object" and
        (.tailscale | type == "object") and
        (.tailscale.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.tailscale.commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.go | type == "string" and test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
        (.revision | type == "number" and floor == . and . >= 1) and
        (.upx | type == "object" and
            (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
            (.url | type == "string" and startswith("https://")) and
            (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
        (.featuretags | type == "array" and length > 0 and
            all(type == "string" and test("^[a-z0-9_]+$")) and
            (length == (unique | length))) and
        ((has("min_plugin") | not) or (.min_plugin | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) and
        (.omit | type == "array" and length > 0 and
            all(type == "string" and test("^[a-z0-9_]+$")) and
            (length == (unique | length))) and
        (.targets | type == "array" and length > 0 and
            all(type == "object" and
                (.name | type == "string" and test("^(arm|arm64)$")) and
                (.GOARCH | type == "string" and test("^[a-z0-9]+$")) and
                ((has("GOARM") | not) or (.GOARM | type == "string" and test("^[567]$")))) and
            (([.[].name] | length) == ([.[].name] | unique | length)))
    ' "$RECIPE" >/dev/null 2>&1 || die "invalid recipe schema in $RECIPE"

    # Guard against accidentally omitting essential router features (PLAN 5.2).
    _vr_bad=$(jq -r '
        ["advertiseroutes","useroutes","advertiseexitnode","useexitnode",
         "osrouter","iptables","dns","netstack","portmapper","health",
         "logtail","debug"] as $keep |
        [.omit[] | select(. as $x | $keep | index($x))] | join(",")
    ' "$RECIPE")
    [ -z "$_vr_bad" ] || die "recipe omits essential router features: $_vr_bad"
}

validate_recipe

TS_VERSION=$(jq -r '.tailscale.version' "$RECIPE")
TS_COMMIT=$(jq -r '.tailscale.commit' "$RECIPE")
RECIPE_GO=$(jq -r '.go' "$RECIPE")
REVISION=$(jq -r '.revision' "$RECIPE")
OMIT_CSV=$(jq -r '.omit | join(",")' "$RECIPE")
TAG="core-${TS_VERSION}-${REVISION}"
UPX_VERSION=$(jq -r '.upx.version' "$RECIPE")
UPX_URL=$(jq -r '.upx.url' "$RECIPE")
UPX_SHA=$(jq -r '.upx.sha256' "$RECIPE")

if [ -z "$MIN_PLUGIN" ]; then
    MIN_PLUGIN=$(jq -r '.min_plugin // "0.1.0"' "$RECIPE")
fi

case "$MODE" in
    build)
        is_uint_pos "$SERIAL" || die "invalid --serial: $SERIAL"
        is_semver "$MIN_PLUGIN" || die "invalid --min-plugin: $MIN_PLUGIN"
        ;;
    test-arch)
        case "$TEST_ARCH" in
            amd64 | arm64) ;;
            *) die "--test-arch must be amd64 or arm64 (got: $TEST_ARCH)" ;;
        esac
        ;;
esac

check_go_host() {
    _cg_raw=$(build_env go env GOVERSION) || die "failed to query Go version"
    _cg_ver=${_cg_raw#go}
    [ "$_cg_ver" = "$RECIPE_GO" ] || die "Go version mismatch: host has $_cg_ver, recipe requires $RECIPE_GO"
}

upx_version() {
    "$1" --version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
}

# CORE_UPX_BIN must be the pinned version. Another upx on PATH (CI runner
# images ship one) is skipped in favour of the pinned, hash-checked download.
ensure_upx() {
    _eu_candidate=$UPX_BIN
    if [ -z "$_eu_candidate" ] && type upx >/dev/null 2>&1 &&
        [ "$(upx_version "$(command -v upx)")" = "$UPX_VERSION" ]; then
        _eu_candidate=$(command -v upx)
    fi
    if [ -z "$_eu_candidate" ]; then
        need_cmd curl
        need_cmd tar
        _eu_archive="$WORK_DIR/upx.tar.xz"
        mkdir -p "$WORK_DIR/upx"
        curl -fsSL --retry 2 --connect-timeout 10 -o "$_eu_archive" "$UPX_URL" ||
            die "failed to download UPX $UPX_VERSION"
        [ "$(sha256_file "$_eu_archive")" = "$UPX_SHA" ] || die "UPX archive sha256 mismatch"
        tar -xJf "$_eu_archive" -C "$WORK_DIR/upx" || die "failed to unpack UPX $UPX_VERSION"
        for _eu_candidate in "$WORK_DIR"/upx/*/upx; do
            [ -x "$_eu_candidate" ] && break
        done
    fi
    [ -x "$_eu_candidate" ] || die "UPX executable not found"
    _eu_got=$(upx_version "$_eu_candidate")
    [ "$_eu_got" = "$UPX_VERSION" ] || die "UPX version mismatch: got $_eu_got, want $UPX_VERSION"
    UPX_BIN=$_eu_candidate
}

ensure_source() {
    SRC_DIR=${SRC_DIR:-"$OUT_DIR/src/$TS_COMMIT"}
    if [ ! -e "$SRC_DIR/.git" ]; then
        # git clone itself refuses nonempty destinations.
        mkdir -p "$(dirname "$SRC_DIR")"
        git -c advice.detachedHead=false clone --depth 1 --branch "v${TS_VERSION}" "$REPO_URL" "$SRC_DIR"
    fi
    SRC_DIR=$(cd "$SRC_DIR" && pwd)
    _es_head=$(git -C "$SRC_DIR" rev-parse HEAD)
    [ "$_es_head" = "$TS_COMMIT" ] || die "commit mismatch: v$TS_VERSION HEAD is $_es_head, recipe expects $TS_COMMIT"

    _es_dirty=$(git --no-optional-locks -C "$SRC_DIR" status --porcelain --ignored --untracked-files=all)
    [ -z "$_es_dirty" ] || die "source checkout is dirty: $SRC_DIR"

    _es_mod_go=$(awk '$1 == "go" { print $2; exit }' "$SRC_DIR/go.mod")
    [ "$_es_mod_go" = "$RECIPE_GO" ] || die "go.mod Go version mismatch: source has $_es_mod_go, recipe requires $RECIPE_GO"
}

compute_tags() {
    _ct_tags=$(
        cd "$SRC_DIR" || exit 1
        build_env go run ./cmd/featuretags --remove="$OMIT_CSV"
    ) || die "featuretags validation failed"
    [ -n "$_ct_tags" ] || die "featuretags returned empty tag list"
    printf 'ts_include_cli,%s\n' "$_ct_tags"
}

verify_binary() {
    _vb_bin=$1
    _vb_tags=$2
    _vb_meta=$(build_env go version -m "$_vb_bin") || die "go version -m failed: $_vb_bin"

    _vb_got_tags=$(printf '%s\n' "$_vb_meta" | awk -F'\t' '$2 == "build" && $3 ~ /^-tags=/ { sub(/^-tags=/, "", $3); print $3; exit }')
    [ "$_vb_got_tags" = "$_vb_tags" ] || die "embedded build tags mismatch for $_vb_bin"

    _vb_got_rev=$(printf '%s\n' "$_vb_meta" | awk -F'\t' '$2 == "build" && $3 ~ /^vcs\.revision=/ { sub(/^vcs\.revision=/, "", $3); print $3; exit }')
    [ "$_vb_got_rev" = "$TS_COMMIT" ] || die "embedded vcs.revision mismatch: got $_vb_got_rev, want $TS_COMMIT"

    printf '%s\n' "$_vb_meta" | grep -Fq "	build	-trimpath=true" ||
        die "binary was not built with -trimpath: $_vb_bin"

    printf '%s\n' "$_vb_meta" | grep -Fq "	build	vcs.modified=false" ||
        die "binary has vcs.modified!=false: $_vb_bin"

    _vb_short_commit=$(printf '%s' "$TS_COMMIT" | cut -c1-9)
    _vb_long_stamp="${TS_VERSION}-t${_vb_short_commit}"

    if type strings >/dev/null 2>&1; then
        strings "$_vb_bin" | grep -Fq "$_vb_long_stamp" || die "version string $_vb_long_stamp not found in binary"
    else
        LC_ALL=C grep -aFq "$_vb_long_stamp" "$_vb_bin" || die "version string $_vb_long_stamp not found in binary"
    fi
}

build_one() {
    _bo_goarch=$1
    _bo_goarm=$2
    _bo_out=$3
    _bo_tags=$4

    mkdir -p "$(dirname "$_bo_out")"
    (
        cd "$SRC_DIR" || exit 1
        if [ -n "$_bo_goarm" ]; then
            build_env GOOS=linux GOARCH="$_bo_goarch" GOARM="$_bo_goarm" TAGS="$_bo_tags" \
                ./build_dist.sh --strip -o "$_bo_out" ./cmd/tailscaled
        else
            build_env GOOS=linux GOARCH="$_bo_goarch" TAGS="$_bo_tags" \
                ./build_dist.sh --strip -o "$_bo_out" ./cmd/tailscaled
        fi
    ) || die "build failed for linux/$_bo_goarch"
    chmod 755 "$_bo_out"
    verify_binary "$_bo_out" "$_bo_tags"
}

check_go_host

ensure_source
BUILD_TAGS=$(compute_tags)

if [ "$MODE" = check ]; then
    echo "recipe OK: tailscale=$TS_VERSION commit=$TS_COMMIT go=$RECIPE_GO revision=$REVISION"
    echo "tags=$BUILD_TAGS"
    exit 0
fi

if [ "$MODE" = test-arch ]; then
    TEST_BIN="$OUT_DIR/test/bifrostd-linux-${TEST_ARCH}"
    echo "core/build.sh: building test binary linux/$TEST_ARCH -> $TEST_BIN" >&2
    build_one "$TEST_ARCH" "" "$TEST_BIN" "$BUILD_TAGS"
    echo "test binary OK: $TEST_BIN ($(file_size "$TEST_BIN") bytes, sha256=$(sha256_file "$TEST_BIN"))"
    exit 0
fi

# Full release build for all targets in recipe.json.
mkdir -p "$WORK_DIR"
ensure_upx
ASSETS_JSON='{}'
UPX_ASSETS_JSON='{}'
TARGET_COUNT=$(jq '.targets | length' "$RECIPE")
IDX=0

while [ "$IDX" -lt "$TARGET_COUNT" ]; do
    T_NAME=$(jq -r ".targets[$IDX].name" "$RECIPE")
    T_GOARCH=$(jq -r ".targets[$IDX].GOARCH" "$RECIPE")
    T_GOARM=$(jq -r ".targets[$IDX].GOARM // \"\"" "$RECIPE")

    RAW_BIN="$WORK_DIR/bifrostd-linux-${T_NAME}"
    GZ_NAME="bifrost-core-${TS_VERSION}-${REVISION}-linux-${T_NAME}.gz"
    GZ_PATH="$OUT_DIR/$GZ_NAME"

    echo "core/build.sh: building $T_NAME (GOARCH=$T_GOARCH${T_GOARM:+ GOARM=$T_GOARM})" >&2
    build_one "$T_GOARCH" "$T_GOARM" "$RAW_BIN" "$BUILD_TAGS"

    RAW_SIZE=$(file_size "$RAW_BIN")
    RAW_SHA=$(sha256_file "$RAW_BIN")

    (unset GZIP; gzip -9 -n -c "$RAW_BIN") >"$GZ_PATH.tmp.$$" || die "gzip failed for $T_NAME"
    mv -f "$GZ_PATH.tmp.$$" "$GZ_PATH"

    GZ_SIZE=$(file_size "$GZ_PATH")
    GZ_SHA=$(sha256_file "$GZ_PATH")

    ASSETS_JSON=$(jq -cn \
        --argjson assets "$ASSETS_JSON" \
        --arg name "$T_NAME" \
        --arg file "$GZ_NAME" \
        --argjson size "$GZ_SIZE" \
        --arg sha256 "$GZ_SHA" \
        --argjson raw_size "$RAW_SIZE" \
        --arg raw_sha256 "$RAW_SHA" \
        '$assets + {($name): {file:$file, size:$size, sha256:$sha256, raw_size:$raw_size, raw_sha256:$raw_sha256}}')

    UPX_RAW="$WORK_DIR/bifrostd-linux-${T_NAME}-upx"
    cp "$RAW_BIN" "$UPX_RAW"
    "$UPX_BIN" --best --no-lzma --force "$UPX_RAW" >/dev/null || die "UPX compression failed for $T_NAME"
    chmod 755 "$UPX_RAW"
    UPX_RAW_SIZE=$(file_size "$UPX_RAW")
    UPX_RAW_SHA=$(sha256_file "$UPX_RAW")
    UPX_GZ_NAME="bifrost-core-${TS_VERSION}-${REVISION}-upx-linux-${T_NAME}.gz"
    UPX_GZ_PATH="$OUT_DIR/$UPX_GZ_NAME"
    (unset GZIP; gzip -9 -n -c "$UPX_RAW") >"$UPX_GZ_PATH.tmp.$$" || die "gzip failed for UPX $T_NAME"
    mv -f "$UPX_GZ_PATH.tmp.$$" "$UPX_GZ_PATH"
    UPX_GZ_SIZE=$(file_size "$UPX_GZ_PATH")
    UPX_GZ_SHA=$(sha256_file "$UPX_GZ_PATH")
    UPX_ASSETS_JSON=$(jq -cn \
        --argjson assets "$UPX_ASSETS_JSON" \
        --arg name "$T_NAME" \
        --arg file "$UPX_GZ_NAME" \
        --argjson size "$UPX_GZ_SIZE" \
        --arg sha256 "$UPX_GZ_SHA" \
        --argjson raw_size "$UPX_RAW_SIZE" \
        --arg raw_sha256 "$UPX_RAW_SHA" \
        '$assets + {($name): {file:$file, size:$size, sha256:$sha256, raw_size:$raw_size, raw_sha256:$raw_sha256}}')

    printf 'built %-5s raw=%s (%s) gz=%s (%s); upx raw=%s (%s) gz=%s (%s)\n' \
        "$T_NAME" "$RAW_SIZE" "$RAW_SHA" "$GZ_SIZE" "$GZ_SHA" \
        "$UPX_RAW_SIZE" "$UPX_RAW_SHA" "$UPX_GZ_SIZE" "$UPX_GZ_SHA"
    IDX=$((IDX + 1))
done

OMIT_JSON=$(jq -c '.omit' "$RECIPE")
MANIFEST_PATH="$OUT_DIR/core.json"
jq -n \
    --argjson serial "$SERIAL" \
    --arg tailscale "$TS_VERSION" \
    --argjson revision "$REVISION" \
    --arg tag "$TAG" \
    --arg min_plugin "$MIN_PLUGIN" \
    --arg go_ver "$RECIPE_GO" \
    --arg commit "$TS_COMMIT" \
    --argjson omit "$OMIT_JSON" \
    --argjson assets "$ASSETS_JSON" \
    --argjson upx_assets "$UPX_ASSETS_JSON" \
    --arg upx_version "$UPX_VERSION" \
    '{
        schema: 1,
        serial: $serial,
        tailscale: $tailscale,
        revision: $revision,
        tag: $tag,
        min_plugin: $min_plugin,
        build: {
            go: $go_ver,
            commit: $commit,
            omit: $omit
        },
        assets: $assets,
        upx_assets: $upx_assets,
        upx: {version: $upx_version, flags: ["--best", "--no-lzma"]}
    }' >"$MANIFEST_PATH.tmp.$$" || die "failed to write manifest"
mv -f "$MANIFEST_PATH.tmp.$$" "$MANIFEST_PATH"

cp "$SRC_DIR/LICENSE" "$OUT_DIR/LICENSE.tailscale"

echo "manifest written: $MANIFEST_PATH (tag=$TAG serial=$SERIAL)"
