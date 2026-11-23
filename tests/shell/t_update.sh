#!/bin/sh
# Tests for plugin/bifrost/lib/update.sh, tools/dev-keys.sh, tools/sign.sh:
# signing, key rotation, manifest validation, core_version, core_install_file,
# core-check, core-update happy paths, mirror, rollback, arch switching, busy.
# shellcheck disable=SC1091,SC2153
. tests/shell/lib.sh
t_setup
t_load

BIFROST_UPDATE_VERIFY_SECS=2
export BIFROST_UPDATE_VERIFY_SECS

# ---- P2 daemon stubs (not in this branch; tests only) ----
daemon_start() {
    echo "start" >>"$MOCK_STATE/daemon_stub.log"
    if [ -f "$MOCK_STATE/stub_start_fail" ]; then
        fail start_failed
        return 1
    fi
    mkdir -p "$BIFROST_RUN" "$BIFROST_SOCK_DIR"
    "$BIFROST_CORE" --statedir="$BIFROST_STATE" --socket="$BIFROST_SOCK" >/dev/null 2>&1 &
    echo "$!" >"$BIFROST_PIDFILE"
    _ds_i=0
    while [ ! -e "$BIFROST_SOCK" ] && [ "$_ds_i" -lt 20 ]; do
        usleep 100000 2>/dev/null || sleep 1
        _ds_i=$((_ds_i + 1))
    done
    [ -e "$BIFROST_SOCK" ]
}

daemon_stop() {
    echo "stop" >>"$MOCK_STATE/daemon_stub.log"
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
    if [ -r "$MOCK_STATE/stub_backend_state" ]; then
        cat "$MOCK_STATE/stub_backend_state"
        return 0
    fi
    printf 'Running\n'
}

# ---- Test fixture builders ----
# make_fake_core <out_raw> <version> <pad_bytes>
make_fake_core() {
    _fc_out=$1
    _fc_ver=$2
    _fc_pad=${3:-0}
    sed "s/echo 1\\.104\\.7/echo $_fc_ver/" "$T_SRC/tests/shell/mock/bifrostd" >"$_fc_out"
    if [ "$_fc_pad" -gt 0 ]; then
        {
            printf '\n# '
            dd if=/dev/zero bs=1 count="$_fc_pad" 2>/dev/null | tr '\000' 'x'
            printf '\n'
        } >>"$_fc_out"
    fi
    chmod 755 "$_fc_out"
}

# make_manifest <out_json> <serial> <ver> <rev> <min_plugin> <arch1> <raw1> <gz1> [arch2 raw2 gz2]
make_manifest() {
    _mm_out=$1
    _mm_ser=$2
    _mm_ver=$3
    _mm_rev=$4
    _mm_min=$5
    shift 5
    _mm_tag="core-${_mm_ver}-${_mm_rev}"
    _mm_assets='{}'
    while [ $# -ge 3 ]; do
        _mm_a=$1
        _mm_raw=$2
        _mm_gz=$3
        shift 3
        _mm_fn="bifrost-core-${_mm_ver}-${_mm_rev}-linux-${_mm_a}.gz"
        _mm_assets=$(jq -cn \
            --argjson assets "$_mm_assets" \
            --arg a "$_mm_a" \
            --arg f "$_mm_fn" \
            --argjson sz "$(file_size "$_mm_gz")" \
            --arg sha "$(sha256_file "$_mm_gz")" \
            --argjson rsz "$(file_size "$_mm_raw")" \
            --arg rsha "$(sha256_file "$_mm_raw")" \
            '$assets + {($a):{file:$f, size:$sz, sha256:$sha, raw_size:$rsz, raw_sha256:$rsha}}')
    done
    jq -n \
        --argjson serial "$_mm_ser" \
        --arg ts "$_mm_ver" \
        --argjson rev "$_mm_rev" \
        --arg tag "$_mm_tag" \
        --arg minp "$_mm_min" \
        --argjson assets "$_mm_assets" \
        '{schema:1, serial:$serial, tailscale:$ts, revision:$rev, tag:$tag, min_plugin:$minp,
          build:{go:"1.27.4", commit:"cbc74fe48ef1b1649f69a4d9a602319427e25102", omit:["aws"]},
          assets:$assets}' >"$_mm_out"
}

curl_map_set() {
    printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/curl.map"
}
curl_map_reset() {
    : >"$MOCK_STATE/curl.map"
    : >"$MOCK_STATE/curl.log"
}

df_reset() {
    rm -f "$MOCK_STATE/df.map" "$MOCK_STATE/df_avail_kb"
}
df_set() {
    printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/df.map"
}

uname_set() {
    printf '%s\n' "$1" >"$MOCK_STATE/uname_m"
}

# Prepare keys and two fake cores: v1 (1.104.7, serial 1) and v2 (1.105.0, serial 2)
KEYDIR="$T/devkeys"
FIX="$T/fix"
mkdir -p "$KEYDIR" "$FIX"

ok dev-keys-1 sh "$T_SRC/tools/dev-keys.sh" "$KEYDIR" key1
ok dev-keys-2 sh "$T_SRC/tools/dev-keys.sh" "$KEYDIR" key2
ok dev-key-priv-exists [ -f "$KEYDIR/key1.key.pem" ]
ok dev-key-pub-exists [ -f "$KEYDIR/key1.pub.pem" ]
# shellcheck disable=SC2012
eq dev-key-priv-mode "-rw-------" "$(ls -l "$KEYDIR/key1.key.pem" | cut -c1-10)"
cp "$KEYDIR/key1.pub.pem" "$BIFROST_KEYS/key1.pub.pem"

make_fake_core "$FIX/v1-arm" 1.104.7 0
gzip -c "$FIX/v1-arm" >"$FIX/v1-arm.gz"
make_manifest "$FIX/m1.json" 1 1.104.7 1 0.1.0 arm "$FIX/v1-arm" "$FIX/v1-arm.gz"
ok sign-m1 sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m1.json"

make_fake_core "$FIX/v2-arm" 1.105.0 0
gzip -c "$FIX/v2-arm" >"$FIX/v2-arm.gz"
make_fake_core "$FIX/v2-arm64" 1.105.0 32
gzip -c "$FIX/v2-arm64" >"$FIX/v2-arm64.gz"
make_manifest "$FIX/m2.json" 2 1.105.0 1 0.1.0 \
    arm "$FIX/v2-arm" "$FIX/v2-arm.gz" \
    arm64 "$FIX/v2-arm64" "$FIX/v2-arm64.gz"
ok sign-m2 sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m2.json"

# ---- 1. manifest_verify & key rotation ----
ok verify-ok manifest_verify "$FIX/m2.json" "$FIX/m2.json.sig"

cp "$FIX/m2.json" "$FIX/m2-k2.json"
ok sign-key2 sh "$T_SRC/tools/sign.sh" "$KEYDIR/key2.key.pem" "$FIX/m2-k2.json"
no verify-unknown-key manifest_verify "$FIX/m2-k2.json" "$FIX/m2-k2.json.sig"
eq verify-unknown-code bad_signature "$BIFROST_ERR"

cp "$KEYDIR/key2.pub.pem" "$BIFROST_KEYS/key2.pub.pem"
ok verify-rotated-key manifest_verify "$FIX/m2-k2.json" "$FIX/m2-k2.json.sig"
rm -f "$BIFROST_KEYS/key2.pub.pem"

no verify-empty-sig manifest_verify "$FIX/m2.json" "$FIX/nonexistent.sig"
eq verify-empty-code bad_signature "$BIFROST_ERR"

# ---- 2. Version comparison & format validators ----
ok ver-eq _upd_ver_ge 0.1.0 0.1.0
ok ver-patch _upd_ver_ge 0.1.2 0.1.1
ok ver-minor _upd_ver_ge 0.2.0 0.1.9
ok ver-major _upd_ver_ge 1.0.0 0.99.99
no ver-lt-patch _upd_ver_ge 0.1.0 0.1.1
no ver-lt-minor _upd_ver_ge 0.1.9 0.2.0
no ver-lt-major _upd_ver_ge 0.9.9 1.0.0
no ver-bad _upd_ver_ge 0.1 0.1.0
no ver-leadzero _upd_ver_ge 0.01.0 0.1.0

no file-traversal _upd_valid_asset_file '../evil.gz'
no file-slash _upd_valid_asset_file 'a/b.gz'
no file-notgz _upd_valid_asset_file 'core.tar'
ok file-ok _upd_valid_asset_file 'bifrost-core-1.104.7-1-linux-arm.gz'
no sha-upper _upd_valid_sha256 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
no sha-short _upd_valid_sha256 'abcd'

# ---- 3. core_version & core_install_file (PLAN 15.1 step 4) ----
uname_set armv7l
eq core-ver-initial 1.104.7 "$(core_version)"
rm -f "$BIFROST_CORE" "$BIFROST_CLI" "$BIFROST_MANIFEST"
no core-ver-missing core_version
eq core-ver-missing-code core_missing "$BIFROST_ERR"

ok install-file-fresh core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm
eq install-file-ver 1.104.7 "$(core_version)"
eq install-file-sha "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"
ok install-file-symlink [ -L "$BIFROST_CLI" ]
eq install-file-manifest-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq install-file-manifest-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"

# Upgrade no-downgrade: install serial 2, then try installing serial 1 -> keeps serial 2
ok install-file-v2 core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-v2-ver 1.105.0 "$(core_version)"
ok install-file-no-downgrade core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm
eq install-file-kept-v2 1.105.0 "$(core_version)"
eq install-file-kept-serial 2 "$(jq -r .serial "$BIFROST_MANIFEST")"

# core_install_file refuses when daemon is running
ok stub-start-for-ci daemon_start
no install-file-running core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-running-code already_running "$BIFROST_ERR"
daemon_stop

# Reset installed core to v1 (serial 1, arm)
rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST"
ok install-reset-v1 core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm

# core_install_file rejects tampered raw payload (hash_mismatch), bad gzip, and bad --version
cp "$FIX/v2-arm" "$FIX/v2-badraw"
printf '# tampered\n' >>"$FIX/v2-badraw"
gzip -c "$FIX/v2-badraw" >"$FIX/v2-badraw.gz"
no install-file-badraw core_install_file "$FIX/v2-badraw.gz" "$FIX/m2.json" arm
eq install-file-badraw-code hash_mismatch "$BIFROST_ERR"
ok install-file-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-v1-intact "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

printf 'not-valid-gzip' >"$FIX/notgz.gz"
no install-file-notgz core_install_file "$FIX/notgz.gz" "$FIX/m2.json" arm
ok install-file-notgz-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-notgz-v1 "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

printf '9.9.9\n' >"$MOCK_STATE/core_version"
no install-file-badver core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-badver-code core_test_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/core_version"
ok install-file-badver-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-badver-v1 "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

# ---- 4. core-check: update available vs up-to-date ----
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"

ok act-check act_core_check
eq act-check-res '{"job":"update"}' "$BIFROST_RESULT"
bg_drain
jf=$(job_file update)
eq check-avail-ok "false true done 100 check 2 false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.action) \(.data.latest.serial) \(.data.up_to_date)"' "$jf")"
ok check-latest-written [ -f "$BIFROST_RUN/core_latest.json" ]
eq check-latest-tag core-1.105.0-1 "$(jq -r .tag "$BIFROST_RUN/core_latest.json")"

# Up-to-date check (serial == installed 1): job still ok, data.latest filled, up_to_date=true
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m1.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m1.json.sig"
ok act-check-utd act_core_check
bg_drain
eq check-utd-ok "false true done 100 1 true" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.latest.serial) \(.data.up_to_date)"' "$jf")"

# ---- 5. core-update happy path (with daemon running) + prev.gz kept ----
printf 'state-v1' >"$BIFROST_STATE/tailscaled.state"
ok start-before-upd daemon_start
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"

ok act-update act_core_update
bg_drain
eq update-ok "false true done 100 update 2 true" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.action) \(.data.latest.serial) \(.data.kept_prev)"' "$jf")"
eq update-new-ver 1.105.0 "$(core_version)"
eq update-new-sha "$(sha256_file "$FIX/v2-arm")" "$(sha256_file "$BIFROST_CORE")"
eq update-man-serial 2 "$(jq -r .serial "$BIFROST_MANIFEST")"
ok update-prev-exists [ -f "$BIFROST_BIN/bifrostd.prev.gz" ]
ok update-prev-man-exists [ -f "$BIFROST_BIN/bifrostd.prev.json" ]
ok update-daemon-running daemon_running
ok update-no-leftovers [ ! -e "$BIFROST_BIN/bifrostd.new" ] && [ ! -e "$BIFROST_BIN/bifrostd.old" ] && [ ! -d "$BIFROST_RUN/update" ]

# ---- 6. core-rollback happy path + no_prev after rollback ----
ok act-rollback act_core_rollback
bg_drain
eq rollback-ok "false true done 100 rollback false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.action) \(.data.kept_prev)"' "$jf")"
eq rollback-ver 1.104.7 "$(core_version)"
eq rollback-sha "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"
eq rollback-man-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"
ok rollback-daemon-running daemon_running
ok rollback-prev-consumed [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]

# Now no prev exists -> act_core_rollback, dispatcher core-rollback, and job_update fail no_prev
no rollback-no-prev-act act_core_rollback
eq rollback-no-prev-act-code no_prev "$BIFROST_ERR"
eq rollback-no-prev-page '{"ok":false,"code":"no_prev"}' "$(t_page core-rollback)"
job_begin update
no rollback-no-prev-job job_update rollback
eq rollback-no-prev-job-code no_prev "$BIFROST_ERR"
job_end update fail no_prev

# ---- 7. Mirror prefix download ----
MIR="https://mirror.example.com/gh/"
ok set-mirror cfg_set bifrost_mirror "$MIR"
curl_map_reset
curl_map_set "${MIR}${BIFROST_CHANNEL_URL}" "file:$FIX/m2.json"
curl_map_set "${MIR}${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "${MIR}${BIFROST_RELEASE_BASE}/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"

ok act-update-mirror act_core_update
bg_drain
eq mirror-ok true "$(jq -r .ok "$jf")"
eq mirror-ver 1.105.0 "$(core_version)"
has mirror-url-manifest "${MIR}${BIFROST_CHANNEL_URL}" "$(cat "$MOCK_STATE/curl.log")"
has mirror-url-sig "${MIR}${BIFROST_CHANNEL_URL}.sig" "$(cat "$MOCK_STATE/curl.log")"
has mirror-url-gz "${MIR}${BIFROST_RELEASE_BASE}/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "$(cat "$MOCK_STATE/curl.log")"
ok clear-mirror cfg_set bifrost_mirror ""

# ---- 8. Low space after update: succeeds with kept_prev=false ----
daemon_stop
# Pad current core with incompressible hex (~9 KiB gzipped) while v3 raw is ~3 KiB.
make_fake_core "$FIX/v2rand-arm" 1.105.0 0
{
    printf '\n# '
    openssl rand -hex 8192
    printf '\n'
} >>"$FIX/v2rand-arm"
gzip -c "$FIX/v2rand-arm" >"$FIX/v2rand-arm.gz"
make_manifest "$FIX/m2rand.json" 2 1.105.0 1 0.1.0 arm "$FIX/v2rand-arm" "$FIX/v2rand-arm.gz"
rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST" "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
ok install-v2rand core_install_file "$FIX/v2rand-arm.gz" "$FIX/m2rand.json" arm

make_fake_core "$FIX/v3small-arm" 1.106.0 0
gzip -c "$FIX/v3small-arm" >"$FIX/v3small-arm.gz"
make_manifest "$FIX/m3small.json" 3 1.106.0 1 0.1.0 arm "$FIX/v3small-arm" "$FIX/v3small-arm.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m3small.json"

# v3small raw is ~3 KiB, v2rand gzipped is ~9 KiB -> bin avail 5 KiB fits v3small, not prev.gz.
df_reset
df_set "$BIFROST_BIN" 5
df_set "$BIFROST_RUN" 10000
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m3small.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m3small.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.106.0-1/bifrost-core-1.106.0-1-linux-arm.gz" "file:$FIX/v3small-arm.gz"

ok act-upd-noprev act_core_update
bg_drain
eq upd-noprev-ok "true false" "$(jq -r '"\(.ok) \(.data.kept_prev)"' "$jf")"
ok upd-noprev-absent [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]
df_reset

# ---- 9. Architecture switching (core-arch) ----
# Reset to v2 arm (serial 2)
rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST"
ok install-v2-for-arch core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
ok start-for-arch daemon_start

# On armv7l: arm64 must be rejected with arch_unsupported
uname_set armv7l
no arch-arm64-on-armv7 act_core_arch arm64
eq arch-arm64-on-armv7-code arch_unsupported "$BIFROST_ERR"
eq arch-arm64-on-armv7-page '{"ok":false,"code":"arch_unsupported"}' "$(t_page core-arch arm64)"
no arch-invalid act_core_arch amd64
eq arch-invalid-code invalid_param "$BIFROST_ERR"

# On aarch64: switching arm -> arm64 at SAME serial (2) succeeds
uname_set aarch64
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm64.gz" "file:$FIX/v2-arm64.gz"

ok arch-switch-arm64 act_core_arch arm64
bg_drain
eq arch-arm64-ok "true arch" "$(jq -r '"\(.ok) \(.data.action)"' "$jf")"
eq arch-arm64-manifest arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"
eq arch-arm64-sha "$(sha256_file "$FIX/v2-arm64")" "$(sha256_file "$BIFROST_CORE")"
ok arch-arm64-daemon daemon_running

# Switch back arm64 -> arm at same serial (2)
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"

ok arch-switch-arm act_core_arch arm
bg_drain
eq arch-arm-ok true "$(jq -r .ok "$jf")"
eq arch-arm-manifest arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq arch-arm-sha "$(sha256_file "$FIX/v2-arm")" "$(sha256_file "$BIFROST_CORE")"

# ---- 10. Concurrent update job returns busy ----
job_begin update
no busy-check act_core_check
eq busy-check-code busy "$BIFROST_ERR"
no busy-update act_core_update
eq busy-update-code busy "$BIFROST_ERR"
no busy-arch act_core_arch arm64
eq busy-arch-code busy "$BIFROST_ERR"
no busy-rollback act_core_rollback
eq busy-rollback-code busy "$BIFROST_ERR"
job_end update ok

daemon_stop
t_done
