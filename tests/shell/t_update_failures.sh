#!/bin/sh
# Failure-path tests for plugin/bifrost/lib/update.sh:
# All 7 PLAN 18 M5 failure scenarios plus min_plugin, no_arch, core_test_failed,
# malformed signed manifest, and space-cleanup behavior.
# Every failure scenario verifies: installed core sha256 unchanged, installed
# manifest sha256 unchanged, daemon still running, and no temp/new files left.
# shellcheck disable=SC1091,SC2153
. tests/shell/lib.sh
t_setup
t_load

BIFROST_UPDATE_VERIFY_SECS=2
export BIFROST_UPDATE_VERIFY_SECS

# ---- P2 daemon stubs (tests only) ----
daemon_start() {
    mkdir -p "$BIFROST_RUN" "$BIFROST_SOCK_DIR"
    "$BIFROST_CORE" --statedir="$BIFROST_STATE" --socket="$BIFROST_SOCK" >/dev/null 2>&1 &
    echo "$!" >"$BIFROST_PIDFILE"
    _ds_i=0
    while [ ! -e "$BIFROST_SOCK" ] && [ "$_ds_i" -lt 20 ]; do
        usleep 100000 2>/dev/null || sleep 1
        _ds_i=$((_ds_i + 1))
    done
    # Simulate new core modifying state file if trigger flag is set.
    if [ -f "$MOCK_STATE/mutate_state_on_v2" ]; then
        _ds_v=$(core_version 2>/dev/null || echo "")
        if [ "$_ds_v" = 1.105.0 ]; then
            printf 'corrupted-by-v2' >"$BIFROST_STATE/tailscaled.state"
        fi
    fi
    [ -e "$BIFROST_SOCK" ]
}

daemon_stop() {
    _dt_pid=$(daemon_pid 2>/dev/null || echo "")
    if [ -n "$_dt_pid" ]; then
        kill -TERM "$_dt_pid" 2>/dev/null || true
        wait "$_dt_pid" 2>/dev/null || true
    fi
    rm -f "$BIFROST_PIDFILE" "$BIFROST_SOCK"
    return 0
}

daemon_wait_ready() {
    [ -e "$BIFROST_SOCK" ] && daemon_running
}

backend_state() {
    # When fail_v2_bstate is set, report wrong BackendState whenever v2 is active.
    if [ -f "$MOCK_STATE/fail_v2_bstate" ]; then
        _bs_v=$(core_version 2>/dev/null || echo "")
        if [ "$_bs_v" = 1.105.0 ]; then
            printf 'NeedsLogin\n'
            return 0
        fi
    fi
    printf 'Running\n'
}

make_fake_core() {
    sed "s/echo 1\\.104\\.7/echo $2/" "$T_SRC/tests/shell/mock/bifrostd" >"$1"
    chmod 755 "$1"
}

make_manifest() {
    _mm_out=$1
    _mm_ser=$2
    _mm_ver=$3
    _mm_min=$4
    _mm_arch=$5
    _mm_raw=$6
    _mm_gz=$7
    _mm_tag="core-${_mm_ver}-1"
    _mm_fn="bifrost-core-${_mm_ver}-1-linux-${_mm_arch}.gz"
    jq -n \
        --argjson serial "$_mm_ser" \
        --arg ts "$_mm_ver" \
        --arg tag "$_mm_tag" \
        --arg minp "$_mm_min" \
        --arg a "$_mm_arch" \
        --arg f "$_mm_fn" \
        --argjson sz "$(file_size "$_mm_gz")" \
        --arg sha "$(sha256_file "$_mm_gz")" \
        --argjson rsz "$(file_size "$_mm_raw")" \
        --arg rsha "$(sha256_file "$_mm_raw")" \
        '{schema:1, serial:$serial, tailscale:$ts, revision:1, tag:$tag, min_plugin:$minp,
          build:{go:"1.27.4", commit:"cbc74fe48ef1b1649f69a4d9a602319427e25102", omit:["aws"]},
          assets:{($a):{file:$f, size:$sz, sha256:$sha, raw_size:$rsz, raw_sha256:$rsha}}}' >"$_mm_out"
}

curl_map_reset() {
    : >"$MOCK_STATE/curl.map"
    : >"$MOCK_STATE/curl.log"
}
curl_map_set() {
    printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/curl.map"
}
df_reset() {
    rm -f "$MOCK_STATE/df.map" "$MOCK_STATE/df_avail_kb"
}
df_set() {
    printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/df.map"
}

# Setup: keypair, installed v1 (serial 5, arm) running with state file.
printf 'armv7l\n' >"$MOCK_STATE/uname_m"
KEYDIR="$T/devkeys"
FIX="$T/fix"
mkdir -p "$KEYDIR" "$FIX"
sh "$T_SRC/tools/dev-keys.sh" "$KEYDIR" prod
cp "$KEYDIR/prod.pub.pem" "$BIFROST_KEYS/prod.pub.pem"

make_fake_core "$FIX/v1" 1.104.7
gzip -c "$FIX/v1" >"$FIX/v1.gz"
make_manifest "$FIX/m1.json" 5 1.104.7 0.1.0 arm "$FIX/v1" "$FIX/v1.gz"

make_fake_core "$FIX/v2" 1.105.0
gzip -c "$FIX/v2" >"$FIX/v2.gz"
make_manifest "$FIX/m2.json" 6 1.105.0 0.1.0 arm "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2.json"

rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST"
core_install_file "$FIX/v1.gz" "$FIX/m1.json" arm
printf 'original-state-v1' >"$BIFROST_STATE/tailscaled.state"
chmod 600 "$BIFROST_STATE/tailscaled.state"
ok initial-start daemon_start

OLD_CORE_SHA=$(sha256_file "$BIFROST_CORE")
OLD_MAN_SHA=$(sha256_file "$BIFROST_MANIFEST")
JF=$(job_file update)
V2_URL="$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz"

assert_unchanged() {
    _au_name=$1
    _au_code=$2
    eq "${_au_name}-ok" false "$(jq -r .ok "$JF")"
    eq "${_au_name}-code" "$_au_code" "$(jq -r .code "$JF")"
    eq "${_au_name}-core-sha" "$OLD_CORE_SHA" "$(sha256_file "$BIFROST_CORE")"
    eq "${_au_name}-man-sha" "$OLD_MAN_SHA" "$(sha256_file "$BIFROST_MANIFEST")"
    ok "${_au_name}-running" daemon_running
    ok "${_au_name}-no-new" [ ! -e "$BIFROST_BIN/bifrostd.new" ]
    ok "${_au_name}-no-old" [ ! -e "$BIFROST_BIN/bifrostd.old" ]
    ok "${_au_name}-no-tmp" [ ! -d "$BIFROST_RUN/update" ]
}

# ---- Scenario 1: Modified manifest content ----
sed 's/"serial": 6/"serial": 9/' "$FIX/m2.json" >"$FIX/m2-tampered.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-tampered.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s1-tampered-manifest bad_signature

# Also: validly signed manifest with bad schema / bad filename
jq '.schema = 2' "$FIX/m2.json" >"$FIX/m2-badschema.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badschema.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badschema.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badschema.json.sig"
act_core_update
bg_drain
assert_unchanged s1b-bad-schema bad_manifest

jq '.assets.arm.file = "../evil.gz"' "$FIX/m2.json" >"$FIX/m2-badfile.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badfile.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badfile.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badfile.json.sig"
act_core_update
bg_drain
assert_unchanged s1c-bad-filename bad_manifest

# ---- Scenario 2: Modified signature ----
cp "$FIX/m2.json.sig" "$FIX/m2-badsig.sig"
printf 'X' >>"$FIX/m2-badsig.sig"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badsig.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s2-tampered-sig bad_signature

# ---- Scenario 3: Modified core file ----
cp "$FIX/v2.gz" "$FIX/v2-tampered.gz"
printf 'Z' >>"$FIX/v2-tampered.gz"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2-tampered.gz"
act_core_update
bg_drain
assert_unchanged s3-tampered-gz hash_mismatch

# Also: gz hash matches manifest, but raw_sha256 disagrees
jq '.assets.arm.raw_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$FIX/m2.json" >"$FIX/m2-badraw.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badraw.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badraw.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badraw.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s3b-raw-hash-mismatch hash_mismatch

# Also: new core fails --version trial run (reports wrong version)
printf '9.9.9\n' >"$MOCK_STATE/core_version"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
rm -f "$MOCK_STATE/core_version"
assert_unchanged s3c-core-test-failed core_test_failed

# ---- Scenario 4: Older manifest (valid signature, smaller serial) ----
make_manifest "$FIX/m-old.json" 4 1.104.0 0.1.0 arm "$FIX/v1" "$FIX/v1.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-old.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-old.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-old.json.sig"
act_core_update
bg_drain
assert_unchanged s4-old-serial old_serial

# Same serial on core-update is also rejected as old_serial
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m1.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m1.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m1.json.sig"
act_core_update
bg_drain
assert_unchanged s4b-same-serial old_serial

# Older serial on core-check is also rejected as old_serial
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-old.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-old.json.sig"
act_core_check
bg_drain
assert_unchanged s4c-check-old-serial old_serial

# ---- Scenario 5: Download interrupted / HTTP error ----
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "trunc:$FIX/v2.gz:64"
act_core_update
bg_drain
assert_unchanged s5-download-trunc download_failed

# HTTP 500 on manifest
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "fail:22"
act_core_update
bg_drain
assert_unchanged s5b-http-error download_failed

# ---- Scenario 6: Not enough space ----
df_reset
df_set "$BIFROST_BIN" 1
df_set "$BIFROST_RUN" 10000
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
df_reset
assert_unchanged s6-no-space-bin no_space

# Also: space low in bin with prev.gz present -> deletes prev.gz, still low -> no_space
printf 'oldprev' >"$BIFROST_BIN/bifrostd.prev.gz"
df_reset
df_set "$BIFROST_BIN" 1
df_set "$BIFROST_RUN" 10000
act_core_update
bg_drain
df_reset
ok s6b-prev-dropped [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]
assert_unchanged s6b-still-no-space no_space

# ---- Scenario 7: New core passes --version, starts, but BackendState wrong -> auto-revert ----
: >"$MOCK_STATE/fail_v2_bstate"
: >"$MOCK_STATE/mutate_state_on_v2"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
rm -f "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/mutate_state_on_v2"

assert_unchanged s7-bad-backend-state update_verify_failed
eq s7-phase rollback "$(jq -r .phase "$JF")"
eq s7-state-restored original-state-v1 "$(cat "$BIFROST_STATE/tailscaled.state")"
eq s7-ver-back 1.104.7 "$(core_version)"
eq s7-bstate-back Running "$(backend_state)"

# ---- Extra: min_plugin too high -> plugin_too_old ----
make_manifest "$FIX/m-minp.json" 6 1.105.0 0.2.0 arm "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-minp.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-minp.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-minp.json.sig"
act_core_update
bg_drain
assert_unchanged plugin-too-old plugin_too_old

# ---- Extra: manifest missing local arch -> no_arch ----
make_manifest "$FIX/m-arm64only.json" 6 1.105.0 0.1.0 arm64 "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-arm64only.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-arm64only.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-arm64only.json.sig"
act_core_update
bg_drain
assert_unchanged no-arch no_arch

daemon_stop
t_done
