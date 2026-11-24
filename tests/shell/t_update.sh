#!/bin/sh
# Tests for plugin/bifrost/lib/update.sh, tools/dev-keys.sh, tools/sign.sh:
# signing, key rotation, manifest validation, core_version, core_install_file,
# core-check, core-update happy paths, mirror, rollback, arch switching, busy.
# Runs with the real P2/P3 libraries (no unnecessary stubs).
# shellcheck disable=SC1091,SC2153
. tests/shell/lib.sh
t_setup
t_load

BIFROST_WAIT_READY=3
BIFROST_STOP_TIMEOUT=2
BIFROST_UPDATE_VERIFY_SECS=2
export BIFROST_WAIT_READY BIFROST_STOP_TIMEOUT BIFROST_UPDATE_VERIFY_SECS

nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1
ts_out status '{"BackendState":"Running","Self":{"HostName":"router"}}'
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":"off","NoSNAT":false,"ShieldsUp":false}'

# ---- Test fixture builders ----
# make_fake_core <out_raw> <version> [pad_bytes]
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

curl_map_set() { printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/curl.map"; }
curl_map_reset() {
    : >"$MOCK_STATE/curl.map"
    : >"$MOCK_STATE/curl.log"
}
df_reset() { rm -f "$MOCK_STATE/df.map" "$MOCK_STATE/df_avail_kb"; }
df_set() { printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/df.map"; }
uname_set() { printf '%s\n' "$1" >"$MOCK_STATE/uname_m"; }

# Prepare keys and fake cores: v1 (1.104.7, serial 1) and v2 (1.105.0, serial 2)
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
while :; do
    sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m2.json" || exit 1
    [ "$(file_size "$FIX/m2.json.sig")" != 72 ] || break
done
eq sign-m2 72 "$(file_size "$FIX/m2.json.sig")"

# ---- 1. manifest_verify, key rotation & strict DER framing ----
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

# Appending trailing byte to ANY signature (even 72-byte DER) must always be rejected.
cp "$FIX/m2.json.sig" "$FIX/m2-trail.sig"
printf 'X' >>"$FIX/m2-trail.sig"
no verify-trailing-byte manifest_verify "$FIX/m2.json" "$FIX/m2-trail.sig"
eq verify-trailing-code bad_signature "$BIFROST_ERR"
. tests/shell/fixtures/update/framing.sh
ok trailing-rejected-before-crypto reject_before_crypto "$FIX/m2.json" "$FIX/m2-trail.sig" "$T/crypto-called"

saved_keys=$BIFROST_KEYS
BIFROST_KEYS="$FIX/empty-keys"
mkdir "$BIFROST_KEYS"
no reject-empty-keys manifest_verify "$FIX/m2.json" "$FIX/m2.json.sig"
eq empty-keys-code bad_signature "$BIFROST_ERR"
rmdir "$BIFROST_KEYS"
no reject-missing-keys manifest_verify "$FIX/m2.json" "$FIX/m2.json.sig"
eq missing-keys-code bad_signature "$BIFROST_ERR"
BIFROST_KEYS=$saved_keys

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

for invalid in '.assets.arm.file = "../evil-linux-arm.gz"' '.assets.arm.file = "core.tar"' \
    '.assets.arm.sha256 |= ascii_upcase' '.assets.arm.raw_sha256 = "abcd"' \
    '.assets.arm64.file = "core-linux-arm.gz"'; do
    jq "$invalid" "$FIX/m2.json" >"$FIX/invalid.json"
    no manifest-asset-format _upd_parse_manifest "$FIX/invalid.json" arm any 0
    eq manifest-asset-code bad_manifest "$BIFROST_ERR"
done

# ---- 3. core_version & core_install_file (PLAN 15.1 step 4) ----
uname_set armv7l
eq core-ver-initial 1.104.7 "$(core_version)"
rm -f "$BIFROST_CORE" "$BIFROST_CLI" "$BIFROST_MANIFEST"
no core-ver-missing core_version
eq core-ver-missing-code core_missing "$BIFROST_ERR"

# core_install_file error paths: arch_unsupported, no_arch, no_space
no install-file-arch-unsup core_install_file "$FIX/v2-arm64.gz" "$FIX/m2.json" arm64
eq install-file-arch-unsup-code arch_unsupported "$BIFROST_ERR"

uname_set aarch64
no install-file-no-arch core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm64
eq install-file-no-arch-code no_arch "$BIFROST_ERR"
uname_set armv7l

df_reset
# shellcheck disable=SC2329
gunzip() { command gunzip "$@" >/dev/full; }
no install-file-no-space core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm
eq install-file-no-space-code no_space "$BIFROST_ERR"
unset -f gunzip

ok install-file-fresh core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm
eq install-file-ver 1.104.7 "$(core_version)"
eq install-file-sha "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"
ok install-file-symlink [ -L "$BIFROST_CLI" ]
eq install-file-manifest-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq install-file-manifest-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"

# Upgrade no-downgrade and same-serial package selection (package wins for equal serial)
uname_set aarch64
ok install-file-v2-arm64 core_install_file "$FIX/v2-arm64.gz" "$FIX/m2.json" arm64
eq install-file-v2-ver 1.105.0 "$(core_version)"
eq install-file-v2-arch arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"
ok install-file-same-serial-keeps core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-same-serial-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq install-file-same-serial-sha "$(sha256_file "$FIX/v2-arm")" "$(sha256_file "$BIFROST_CORE")"
# The same core again is not rewritten: the inode stays the same.
# shellcheck disable=SC2012
_ino_before=$(ls -i "$BIFROST_CORE" | awk '{print $1}')
ok install-file-identical-skips core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
# shellcheck disable=SC2012
_ino_after=$(ls -i "$BIFROST_CORE" | awk '{print $1}')
eq install-file-identical-inode "$_ino_before" "$_ino_after"
ok install-file-lower-serial-keeps core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm
eq install-file-kept-serial 2 "$(jq -r .serial "$BIFROST_MANIFEST")"
uname_set armv7l

# core_install_file refuses when real daemon is running
ok start-for-ci daemon_start
no install-file-running core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-running-code already_running "$BIFROST_ERR"
ok stop-for-ci daemon_stop

# Reset installed core to v1 (serial 1, arm)
rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST"
ok install-reset-v1 core_install_file "$FIX/v1-arm.gz" "$FIX/m1.json" arm

# core_install_file rejects tampered raw payload (hash_mismatch), bad gzip (hash_mismatch), bad --version
cp "$FIX/v2-arm" "$FIX/v2-badraw"
printf '# tampered\n' >>"$FIX/v2-badraw"
gzip -c "$FIX/v2-badraw" >"$FIX/v2-badraw.gz"
no install-file-badraw core_install_file "$FIX/v2-badraw.gz" "$FIX/m2.json" arm
eq install-file-badraw-code hash_mismatch "$BIFROST_ERR"
ok install-file-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-v1-intact "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

printf 'not-valid-gzip' >"$FIX/notgz.gz"
no install-file-notgz core_install_file "$FIX/notgz.gz" "$FIX/m2.json" arm
eq install-file-notgz-code hash_mismatch "$BIFROST_ERR"
ok install-file-notgz-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-notgz-v1 "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

printf '9.9.9\n' >"$MOCK_STATE/core_version"
no install-file-badver core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
eq install-file-badver-code core_test_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/core_version"
ok install-file-badver-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
eq install-file-badver-v1 "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"

# core_install_file: manifest mv failure restores old core atomically
_v1_sha=$(sha256_file "$BIFROST_CORE")
_m1_sha=$(sha256_file "$BIFROST_MANIFEST")
# shellcheck disable=SC2329
mv() {
    case "$*" in *"$BIFROST_MANIFEST") return 1 ;; esac
    command mv "$@"
}
no install-file-man-fail core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm
unset -f mv
eq install-file-man-fail-code internal "$BIFROST_ERR"
eq install-file-man-fail-core "$_v1_sha" "$(sha256_file "$BIFROST_CORE")"
eq install-file-man-fail-man "$_m1_sha" "$(sha256_file "$BIFROST_MANIFEST")"
ok install-file-man-fail-no-old [ ! -e "$BIFROST_BIN/bifrostd.old" ]

# ---- 4. core-check: update available, up-to-date, and mirror ----
jf=$(job_file update)
# Up-to-date check (serial == installed 1): job still ok, data.latest filled, up_to_date=true
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m1.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m1.json.sig"
ok act-check-utd act_core_check
bg_drain
eq check-utd-ok "false true done 100 1 true" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.latest.serial) \(.data.up_to_date)"' "$jf")"

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
eq check-record-schema 1 "$(jq -r .schema "$BIFROST_HOME/core-check.json")"
eq check-record-status ok "$(jq -r .core.status "$BIFROST_HOME/core-check.json")"

# Check through mirror prefix
MIR="https://mirror.example.com/gh/"
ok set-mirror-check cfg_set bifrost_mirror "$MIR"
curl_map_reset
curl_map_set "${MIR}${BIFROST_CHANNEL_URL}" "file:$FIX/m2.json"
curl_map_set "${MIR}${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
ok act-check-mirror act_core_check
bg_drain
eq check-mirror-ok true "$(jq -r .ok "$jf")"
has check-mirror-url "${MIR}${BIFROST_CHANNEL_URL}" "$(cat "$MOCK_STATE/curl.log")"
has check-mirror-sig "${MIR}${BIFROST_CHANNEL_URL}.sig" "$(cat "$MOCK_STATE/curl.log")"
ok clear-mirror-check cfg_set bifrost_mirror ""

# ---- 5. core-update happy path (with real daemon running) + prev.gz kept ----
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
ok update-no-new [ ! -e "$BIFROST_BIN/bifrostd.new" ]
ok update-no-old [ ! -e "$BIFROST_BIN/bifrostd.old" ]
ok update-no-tmp [ ! -d "$BIFROST_RUN/update" ]

# ---- 6. core-rollback under mirror (makes zero curl calls) + no_prev after ----
ok set-mirror-rb cfg_set bifrost_mirror "$MIR"
curl_map_reset
ok act-rollback act_core_rollback
bg_drain
eq rollback-ok "false true done 100 rollback false" \
    "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.action) \(.data.kept_prev)"' "$jf")"
eq rollback-ver 1.104.7 "$(core_version)"
eq rollback-sha "$(sha256_file "$FIX/v1-arm")" "$(sha256_file "$BIFROST_CORE")"
eq rollback-man-serial 1 "$(jq -r .serial "$BIFROST_MANIFEST")"
eq rollback-no-curl "" "$(cat "$MOCK_STATE/curl.log")"
ok rollback-daemon-running daemon_running
ok rollback-prev-consumed [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]
ok rollback-prev-man-consumed [ ! -f "$BIFROST_BIN/bifrostd.prev.json" ]
ok clear-mirror-rb cfg_set bifrost_mirror ""

# Now no prev exists -> act_core_rollback, dispatcher core-rollback, and job_update fail no_prev
no rollback-no-prev-act act_core_rollback
eq rollback-no-prev-act-code no_prev "$BIFROST_ERR"
eq rollback-no-prev-page '{"ok":false,"code":"no_prev"}' "$(t_page core-rollback)"
job_begin update
no rollback-no-prev-job job_update rollback
eq rollback-no-prev-job-code no_prev "$BIFROST_ERR"
job_end update fail no_prev

# ---- 7. Mirror prefix download ----
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
ok stop-for-noprev daemon_stop
# Rollback when daemon is NOT running: succeeds and keeps daemon stopped
ok act-rb-stopped act_core_rollback
bg_drain
eq rb-stopped-ok true "$(jq -r .ok "$jf")"
eq rb-stopped-ver 1.104.7 "$(core_version)"
no rb-stopped-stays-stopped daemon_running

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

# ---- 9. Architecture switching (core-arch): stopped & running ----
rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST" "$BIFROST_HOME/core-channel.serial" "$BIFROST_RUN/core_latest.json"
ok install-v2-for-arch core_install_file "$FIX/v2-arm.gz" "$FIX/m2.json" arm

# On armv7l: arm64 must be rejected with arch_unsupported
uname_set armv7l
no arch-arm64-on-armv7 act_core_arch arm64
eq arch-arm64-on-armv7-code arch_unsupported "$BIFROST_ERR"
eq arch-arm64-on-armv7-page '{"ok":false,"code":"arch_unsupported"}' "$(t_page core-arch arm64)"
no arch-invalid act_core_arch amd64
eq arch-invalid-code invalid_param "$BIFROST_ERR"

# On aarch64 while daemon is stopped: switch arm -> arm64 at SAME serial (2), stays stopped
uname_set aarch64
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm64.gz" "file:$FIX/v2-arm64.gz"

ok arch-stopped-switch act_core_arch arm64
bg_drain
eq arch-stopped-ok "true arch" "$(jq -r '"\(.ok) \(.data.action)"' "$jf")"
eq arch-stopped-manifest arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"
eq arch-stopped-sha "$(sha256_file "$FIX/v2-arm64")" "$(sha256_file "$BIFROST_CORE")"
no arch-stopped-stays-stopped daemon_running

# Now start real daemon and switch back arm64 -> arm at same serial (2)
ok start-for-arch daemon_start
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"

ok arch-switch-arm act_core_arch arm
bg_drain
eq arch-arm-ok true "$(jq -r .ok "$jf")"
eq arch-arm-manifest arm "$(jq -r .arch "$BIFROST_MANIFEST")"
eq arch-arm-sha "$(sha256_file "$FIX/v2-arm")" "$(sha256_file "$BIFROST_CORE")"
ok arch-arm-daemon daemon_running

# ---- 10. Core type switching reuses the update transaction ----
cp "$FIX/v2-arm.gz" "$FIX/v2-upx-arm.gz"
jq '.upx_assets = {arm:(.assets.arm | .file = "bifrost-core-1.105.0-1-upx-linux-arm.gz")}' \
    "$FIX/m2.json" >"$FIX/m2-upx.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m2-upx.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-upx.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-upx.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-upx-linux-arm.gz" "file:$FIX/v2-upx-arm.gz"
ok type-upx-act act_core_type upx
bg_drain
eq type-upx-ok true "$(jq -r .ok "$jf")"
eq type-upx-action type "$(jq -r .data.action "$jf")"
eq type-upx-manifest upx "$(jq -r .variant "$BIFROST_MANIFEST")"
eq type-upx-file bifrost-core-1.105.0-1-upx-linux-arm.gz "$(jq -r '.assets.arm.file' "$BIFROST_MANIFEST")"
ok type-upx-daemon daemon_running

jq '.assets.arm.raw_sha256 = ("0" * 64)' "$FIX/m2.json" >"$FIX/m2-bad-normal.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/key1.key.pem" "$FIX/m2-bad-normal.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-bad-normal.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-bad-normal.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"
ok type-normal-fail-act act_core_type normal
bg_drain
eq type-normal-fail-code hash_mismatch "$(jq -r .code "$jf")"
eq type-normal-fail-keeps upx "$(jq -r .variant "$BIFROST_MANIFEST")"

curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz" "file:$FIX/v2-arm.gz"
ok type-normal-act act_core_type normal
bg_drain
eq type-normal-ok true "$(jq -r .ok "$jf")"
eq type-normal-manifest normal "$(jq -r .variant "$BIFROST_MANIFEST")"
eq type-normal-file bifrost-core-1.105.0-1-linux-arm.gz "$(jq -r '.assets.arm.file' "$BIFROST_MANIFEST")"
eq type-invalid-page '{"ok":false,"code":"invalid_param"}' "$(t_page core-type lzma)"
eq type-nargs-page '{"ok":false,"code":"invalid_param"}' "$(t_page core-type)"

# ---- 11. Concurrent update job returns busy ----
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
