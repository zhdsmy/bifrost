#!/bin/sh
# Failure-path tests for plugin/bifrost/lib/update.sh:
# All 7 PLAN 18 M5 failure scenarios plus strict DER sig check, manifest
# hardening, partial download, gunzip ENOSPC, conservative df, daemon_stop
# failure, manifest-commit rollback, rollback-start failure, and full failure
# coverage for core-rollback, core-arch, and core-check.
# Runs with the real P2/P3 libraries (no unnecessary stubs).
# shellcheck disable=SC1091,SC2153
. tests/shell/lib.sh
t_setup
t_load

BIFROST_WAIT_READY=3
BIFROST_STOP_TIMEOUT=2
BIFROST_UPDATE_VERIFY_SECS=2
export BIFROST_WAIT_READY BIFROST_STOP_TIMEOUT BIFROST_UPDATE_VERIFY_SECS BIFROST_STATE

nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1
ts_out status '{"BackendState":"Running","Self":{"HostName":"router"}}'
ts_out debug-prefs '{"CorpDNS":false,"NetfilterMode":"off","NoSNAT":false,"ShieldsUp":false}'

# Build a fake core based on mock/bifrostd that optionally injects post-swap
# faults when specific $MOCK_STATE flags are present (while running through
# real daemon_start, daemon_stop, daemon_wait_ready, and backend_state).
make_fake_core() {
    _fc_out=$1
    _fc_ver=$2
    sed "s/echo 1\\.104\\.7/echo $_fc_ver/" "$T_SRC/tests/shell/mock/bifrostd" |
        awk -v ver="$_fc_ver" '
            /^[[:space:]]*echo "started \$\$" >>/ {
                print "if [ \"" ver "\" = \"1.105.0\" ]; then"
                print "    [ -f \"$MOCK_STATE/mutate_state_on_v2\" ] && printf '\''corrupted-by-v2'\'' >\"$BIFROST_STATE/tailscaled.state\""
                print "    [ -f \"$MOCK_STATE/fail_v2_bstate\" ] && printf '\''{\"BackendState\":\"NeedsLogin\"}\\n'\'' >\"$MOCK_STATE/ts/status.out\""
                print "    [ -f \"$MOCK_STATE/fail_old_start_after_v2\" ] && : >\"$MOCK_STATE/daemon.fail\""
                print "else"
                print "    [ -f \"$MOCK_STATE/restore_running_on_v1\" ] && printf '\''{\"BackendState\":\"Running\"}\\n'\'' >\"$MOCK_STATE/ts/status.out\""
                print "    [ -f \"$MOCK_STATE/fail_v1_bstate\" ] && printf '\''{\"BackendState\":\"NeedsLogin\"}\\n'\'' >\"$MOCK_STATE/ts/status.out\""
                print "fi"
            }
            { print }
        ' >"$_fc_out"
    chmod 755 "$_fc_out"
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

# Flip byte 10 inside a DER signature (guarantees cryptographic mutation).
corrupt_sig_inside() {
    _cs_in=$1
    _cs_out=$2
    _cs_b=$(dd if="$_cs_in" bs=1 skip=10 count=1 2>/dev/null | hexdump -n 1 -e '1/1 "%u"')
    if [ "$_cs_b" = 65 ]; then _cs_rep=B; else _cs_rep=A; fi
    {
        dd if="$_cs_in" bs=1 count=10 2>/dev/null
        printf '%s' "$_cs_rep"
        dd if="$_cs_in" bs=1 skip=11 2>/dev/null
    } >"$_cs_out"
}

curl_map_reset() {
    : >"$MOCK_STATE/curl.map"
    : >"$MOCK_STATE/curl.log"
}
curl_map_set() { printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/curl.map"; }
df_reset() { rm -f "$MOCK_STATE/df.map" "$MOCK_STATE/df_avail_kb"; }
df_set() { printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/df.map"; }

# Setup: keypair, installed v1 (serial 5, arm) running with state, prev pair, and core_latest.json.
printf 'armv7l\n' >"$MOCK_STATE/uname_m"
KEYDIR="$T/devkeys"
FIX="$T/fix"
mkdir -p "$KEYDIR" "$FIX"
sh "$T_SRC/tools/dev-keys.sh" "$KEYDIR" prod
cp "$KEYDIR/prod.pub.pem" "$BIFROST_KEYS/prod.pub.pem"

make_fake_core "$FIX/v0" 1.103.0
gzip -c "$FIX/v0" >"$FIX/v0.gz"
make_manifest "$FIX/m0.json" 4 1.103.0 0.1.0 arm "$FIX/v0" "$FIX/v0.gz"

make_fake_core "$FIX/v1" 1.104.7
gzip -c "$FIX/v1" >"$FIX/v1.gz"
make_manifest "$FIX/m1.json" 5 1.104.7 0.1.0 arm "$FIX/v1" "$FIX/v1.gz"

make_fake_core "$FIX/v2" 1.105.0
gzip -c "$FIX/v2" >"$FIX/v2.gz"
make_manifest "$FIX/m2.json" 6 1.105.0 0.1.0 arm "$FIX/v2" "$FIX/v2.gz"
while :; do
    sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2.json" || exit 1
    [ "$(file_size "$FIX/m2.json.sig")" != 72 ] || break
done

rm -f "$BIFROST_CORE" "$BIFROST_MANIFEST"
core_install_file "$FIX/v1.gz" "$FIX/m1.json" arm

# Seed existing prev.gz + prev.json and core_latest.json to verify failures never clobber them.
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
jq -c '.arch = "arm"' "$FIX/m0.json" >"$BIFROST_BIN/bifrostd.prev.json"
mkdir -p "$BIFROST_RUN"
cp "$FIX/m1.json" "$BIFROST_RUN/core_latest.json"

printf 'original-state-v1' >"$BIFROST_STATE/tailscaled.state"
chmod 600 "$BIFROST_STATE/tailscaled.state"
ok initial-start daemon_start

OLD_CORE_SHA=$(sha256_file "$BIFROST_CORE")
OLD_MAN_SHA=$(sha256_file "$BIFROST_MANIFEST")
OLD_PREV_GZ_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")
OLD_PREV_MAN_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.json")
OLD_LATEST_SHA=$(sha256_file "$BIFROST_RUN/core_latest.json")
JF=$(job_file update)
V2_URL="$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm.gz"

assert_unchanged() {
    _au_name=$1
    _au_code=$2
    eq "${_au_name}-ok" false "$(jq -r .ok "$JF")"
    eq "${_au_name}-code" "$_au_code" "$(jq -r .code "$JF")"
    eq "${_au_name}-core-sha" "$OLD_CORE_SHA" "$(sha256_file "$BIFROST_CORE")"
    eq "${_au_name}-man-sha" "$OLD_MAN_SHA" "$(sha256_file "$BIFROST_MANIFEST")"
    eq "${_au_name}-prev-gz-sha" "$OLD_PREV_GZ_SHA" "$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")"
    eq "${_au_name}-prev-man-sha" "$OLD_PREV_MAN_SHA" "$(sha256_file "$BIFROST_BIN/bifrostd.prev.json")"
    eq "${_au_name}-latest-sha" "$OLD_LATEST_SHA" "$(sha256_file "$BIFROST_RUN/core_latest.json")"
    ok "${_au_name}-running" daemon_running
    ok "${_au_name}-no-new" [ ! -e "$BIFROST_BIN/bifrostd.new" ]
    ok "${_au_name}-no-old" [ ! -e "$BIFROST_BIN/bifrostd.old" ]
    eq "${_au_name}-no-tmp-dir" "" "$(find "$BIFROST_RUN" -maxdepth 1 -name 'update*')"
    eq "${_au_name}-no-bin-tmp" "" "$(find "$BIFROST_BIN" -name '*.tmp.*' 2>/dev/null)"
    eq "${_au_name}-no-home-tmp" "" "$(find "$BIFROST_HOME" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)"
}

# ---- Scenario 1: Modified manifest content & manifest hardening ----
sed 's/"serial": 6/"serial": 9/' "$FIX/m2.json" >"$FIX/m2-tampered.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-tampered.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s1-tampered-manifest bad_signature

jq '.schema = 2' "$FIX/m2.json" >"$FIX/m2-badschema.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badschema.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badschema.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badschema.json.sig"
act_core_update
bg_drain
assert_unchanged s1b-bad-schema bad_manifest

jq '.assets.arm.file = "../evil-linux-arm.gz"' "$FIX/m2.json" >"$FIX/m2-badfile.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badfile.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badfile.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badfile.json.sig"
act_core_update
bg_drain
assert_unchanged s1c-bad-filename bad_manifest

# Tag mismatch (does not match core-<tailscale>-<revision>) -> bad_manifest
jq '.tag = "core-1.105.0-9"' "$FIX/m2.json" >"$FIX/m2-badtag.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badtag.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badtag.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badtag.json.sig"
act_core_update
bg_drain
assert_unchanged s1d-tag-mismatch bad_manifest

# Asset filename arch suffix mismatch (-linux-arm64.gz under assets.arm) -> bad_manifest
jq '.assets.arm.file = "bifrost-core-1.105.0-1-linux-arm64.gz"' "$FIX/m2.json" >"$FIX/m2-badarchfn.json"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m2-badarchfn.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2-badarchfn.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badarchfn.json.sig"
act_core_update
bg_drain
assert_unchanged s1e-file-arch-mismatch bad_manifest

# ---- Scenario 2: Modified signature (byte flip inside DER + guaranteed trailing-byte rejection) ----
corrupt_sig_inside "$FIX/m2.json.sig" "$FIX/m2-badsig.sig"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badsig.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s2-tampered-sig bad_signature

# A full-length valid signature followed by exactly one additional byte.
eq full-sig-length 72 "$(file_size "$FIX/m2.json.sig")"
cp "$FIX/m2.json.sig" "$FIX/m2-trail72.sig"
printf X >>"$FIX/m2-trail72.sig"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-trail72.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
assert_unchanged s2b-trailing-byte-sig bad_signature

# ---- Scenario 3: Modified core file, raw mismatch, partial 0-exit download, core_test_failed ----
cp "$FIX/v2.gz" "$FIX/v2-tampered.gz"
printf 'Z' >>"$FIX/v2-tampered.gz"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2-tampered.gz"
act_core_update
bg_drain
assert_unchanged s3-tampered-gz hash_mismatch
has oversized-download-limited "$V2_URL $(file_size "$FIX/v2.gz")" "$(cat "$MOCK_STATE/curl.limited")"

# Mock curl partial: mode (returns exit 0 with truncated body -> caught by verify)
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "partial:$FIX/v2.gz:64"
act_core_update
bg_drain
assert_unchanged s3p-partial-download hash_mismatch

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

printf '9.9.9\n' >"$MOCK_STATE/core_version"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
rm -f "$MOCK_STATE/core_version"
assert_unchanged s3c-core-test-failed core_test_failed

# ---- Scenario 4: Older manifest (valid signature, smaller / equal serial) ----
make_manifest "$FIX/m-old.json" 4 1.104.0 0.1.0 arm "$FIX/v1" "$FIX/v1.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-old.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-old.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-old.json.sig"
act_core_update
bg_drain
assert_unchanged s4-old-serial old_serial

sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m1.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m1.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m1.json.sig"
act_core_update
bg_drain
assert_unchanged s4b-same-serial old_serial

# ---- Scenario 5: Download interrupted / HTTP error (prev.gz stays intact even under low bin df) ----
df_reset
df_set "$BIFROST_BIN" 0
df_set "$BIFROST_RUN" 10000
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "trunc:$FIX/v2.gz:64"
act_core_update
bg_drain
df_reset
assert_unchanged s5-download-trunc download_failed

curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "fail:22"
act_core_update
bg_drain
assert_unchanged s5b-http-error download_failed

# tmpfs must hold the download. On flash, only a failing write proves ENOSPC.
df_set "$BIFROST_RUN" 0
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
df_reset
assert_unchanged s6-no-space-download no_space

# Exercise BusyBox gunzip's actual ENOSPC diagnostic and restore the stashed pair.
df_set "$BIFROST_BIN" 0
# shellcheck disable=SC2329
gunzip() { command gunzip "$@" >/dev/full; }
act_core_update
bg_drain
unset -f gunzip
df_reset
assert_unchanged s6-gunzip-enospc no_space

# ---- Scenario 7: New core passes --version, starts, but BackendState wrong -> auto-revert ----
: >"$MOCK_STATE/fail_v2_bstate"
: >"$MOCK_STATE/mutate_state_on_v2"
: >"$MOCK_STATE/restore_running_on_v1"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
rm -f "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/mutate_state_on_v2" "$MOCK_STATE/restore_running_on_v1"

assert_unchanged s7-bad-backend-state update_verify_failed
eq s7-phase rollback "$(jq -r .phase "$JF")"
eq s7-state-restored original-state-v1 "$(cat "$BIFROST_STATE/tailscaled.state")"
eq s7-ver-back 1.104.7 "$(core_version)"
eq s7-bstate-back Running "$(backend_state)"

# ---- Scenario 7b: Manifest commit failure after swap reverts BOTH core and manifest ----
# shellcheck disable=SC2329
mv() {
    case "$*" in *"$BIFROST_MANIFEST") return 1 ;; esac
    command mv "$@"
}
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
unset -f mv
assert_unchanged s7b-manifest-commit-fail internal

# ---- Scenario 7c: daemon_stop failure before swap aborts without touching core ----
# shellcheck disable=SC2329
daemon_stop() { fail internal; }
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
t_load
assert_unchanged s7c-daemon-stop-fail internal

# The contracted cleanup error may occur after the process actually stopped.
# shellcheck disable=SC2329
daemon_stop() {
    (. "$BIFROST_LIB/daemon.sh" && daemon_stop) || return 1
    fail fw_failed
}
act_core_update
bg_drain
t_load
assert_unchanged stop-cleanup fw_failed

# Inject the same stop error after the candidate failed verification. Keep
# the live candidate paired, then retry restoration when cleanup works again.
daemon_stop() {
    (. "$BIFROST_LIB/daemon.sh" && daemon_stop) || return 1
    if [ "$(core_version)" = 1.105.0 ]; then fail fw_failed; fi
}
: >"$MOCK_STATE/fail_v2_bstate"
: >"$MOCK_STATE/restore_running_on_v1"
act_core_update
bg_drain
eq revert-stop-code fw_failed "$(jq -r .code "$JF")"
eq revert-stop-candidate 1.105.0 "$(core_version)"
eq revert-stop-manifest 1.105.0 "$(jq -r .tailscale "$BIFROST_MANIFEST")"
ok revert-stop-running daemon_running
t_load
ok revert-stop-retry with_lock state 0 core_recover
rm -f "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/restore_running_on_v1"
assert_unchanged revert-stop-recovered fw_failed

# Fail only the restoration rename (the initial candidate rename succeeds).
for fault in manifest state; do
    case "$fault" in
        manifest) fault_file=$BIFROST_MANIFEST; fault_code=internal ;;
        state) fault_file="$BIFROST_STATE/tailscaled.state"; fault_code=state_not_writable ;;
    esac
    # shellcheck disable=SC2329
    mv() {
        if [ "${2:-}" = "$fault_file.tmp.$$" ]; then return 1; fi
        command mv "$@"
    }
    : >"$MOCK_STATE/mutate_state_on_v2"
    : >"$MOCK_STATE/fail_v2_bstate"
    : >"$MOCK_STATE/restore_running_on_v1"
    act_core_update
    bg_drain
    unset -f mv
    eq "$fault-restore-code" "$fault_code" "$(jq -r .code "$JF")"
    eq "$fault-restore-core" "$OLD_CORE_SHA" "$(sha256_file "$BIFROST_CORE")"
    ok "$fault-restore-running" daemon_running
    ok "$fault-restore-pending" [ -s "$BIFROST_HOME/.core-update/phase" ]
    ok "$fault-restore-retry" with_lock state 0 core_recover
    ok "$fault-restore-repeat" with_lock state 0 core_recover
    rm -f "$MOCK_STATE/mutate_state_on_v2" "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/restore_running_on_v1"
    assert_unchanged "$fault-recovered" "$fault_code"
    eq "$fault-state-restored" original-state-v1 "$(cat "$BIFROST_STATE/tailscaled.state")"
done

# Terminate a separate locked worker between the two actual renames.
for sig in TERM INT HUP KILL; do
    rm -f "$MOCK_STATE/signal-fired"
    if [ "$sig" != KILL ]; then df_set "$BIFROST_BIN" 0; fi
    job_begin update
    no "$sig-worker-interrupted" sh tests/shell/fixtures/update/interrupted-job.sh "$sig"
    df_reset
    ok "$sig-injection-ran" [ -f "$MOCK_STATE/signal-fired" ]
    if [ "$sig" = KILL ]; then
        eq cold-candidate 1.105.0 "$(core_version)"
        eq cold-manifest-before-recovery "$OLD_MAN_SHA" "$(sha256_file "$BIFROST_MANIFEST")"
        eq cold-phase replacing "$(cat "$BIFROST_HOME/.core-update/phase")"
        no cold-daemon-stopped daemon_running
        # Discard volatile runtime and job data as on reboot. Enter through
        # a normal channel check, which must recover before its download.
        rm -rf "$BIFROST_RUN" "$BIFROST_UPLOAD"
        curl_map_reset
        curl_map_set "$BIFROST_CHANNEL_URL" fail:22
        act_core_check
        bg_drain
        eq cold-check-code download_failed "$(jq -r .code "$JF")"
        eq cold-current "$OLD_CORE_SHA" "$(sha256_file "$BIFROST_CORE")"
        eq cold-manifest "$OLD_MAN_SHA" "$(sha256_file "$BIFROST_MANIFEST")"
        eq cold-state original-state-v1 "$(cat "$BIFROST_STATE/tailscaled.state")"
        ok cold-running daemon_running
        ok cold-idempotent with_lock state 0 core_recover
        cp "$FIX/m1.json" "$BIFROST_RUN/core_latest.json"
        curl_map_reset
        curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
        curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
        curl_map_set "$V2_URL" "file:$FIX/v2.gz"
    else
        assert_unchanged "$sig-recovered" internal
    fi
    ok "$sig-no-journal" [ ! -e "$BIFROST_HOME/.core-update" ]
    ok "$sig-no-lock" [ ! -e "$BIFROST_RUN/lock.state" ]
done

# ---- Scenario 7d: Rollback path daemon_start fails -> reports start_failed, NOT update_verify_failed ----
: >"$MOCK_STATE/fail_v2_bstate"
: >"$MOCK_STATE/fail_old_start_after_v2"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
act_core_update
bg_drain
rm -f "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/fail_old_start_after_v2" "$MOCK_STATE/daemon.fail"
ts_out status '{"BackendState":"Running","Self":{"HostName":"router"}}'
eq s7d-ok false "$(jq -r .ok "$JF")"
eq s7d-code start_failed "$(jq -r .code "$JF")"
eq s7d-core-restored "$OLD_CORE_SHA" "$(sha256_file "$BIFROST_CORE")"
eq s7d-man-restored "$OLD_MAN_SHA" "$(sha256_file "$BIFROST_MANIFEST")"
ok s7d-restart-daemon daemon_start

# ---- core-check failure paths: bad_signature, old_serial, plugin_too_old, no_arch ----
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2-badsig.sig"
act_core_check
bg_drain
assert_unchanged chk-bad-sig bad_signature

curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-old.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-old.json.sig"
act_core_check
bg_drain
assert_unchanged chk-old-serial old_serial

make_manifest "$FIX/m-minp.json" 6 1.105.0 0.2.0 arm "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-minp.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-minp.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-minp.json.sig"
act_core_check
bg_drain
assert_unchanged chk-plugin-too-old plugin_too_old

act_core_update
bg_drain
assert_unchanged upd-plugin-too-old plugin_too_old

# Cache commit failure on a successful channel check must reach the job caller.
# shellcheck disable=SC2329
mv() {
    case "$*" in *"$BIFROST_RUN/core_latest.json") return 1 ;; esac
    command mv "$@"
}
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
act_core_check
bg_drain
unset -f mv
assert_unchanged chk-cache-write internal

make_manifest "$FIX/m-arm64only.json" 6 1.105.0 0.1.0 arm64 "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-arm64only.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-arm64only.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-arm64only.json.sig"
act_core_check
bg_drain
assert_unchanged chk-no-arch no_arch

act_core_update
bg_drain
assert_unchanged upd-no-arch no_arch

# ---- core-arch failure paths: no_arch, plugin_too_old, post-swap revert ----
printf 'aarch64\n' >"$MOCK_STATE/uname_m"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
act_core_arch arm64
bg_drain
assert_unchanged arch-no-arch no_arch

make_manifest "$FIX/m-minp64.json" 6 1.105.0 0.2.0 arm64 "$FIX/v2" "$FIX/v2.gz"
sh "$T_SRC/tools/sign.sh" "$KEYDIR/prod.key.pem" "$FIX/m-minp64.json"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-minp64.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-minp64.json.sig"
act_core_arch arm64
bg_drain
assert_unchanged arch-plugin-too-old plugin_too_old

: >"$MOCK_STATE/fail_v2_bstate"
: >"$MOCK_STATE/restore_running_on_v1"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-arm64only.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-arm64only.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm64.gz" "file:$FIX/v2.gz"
act_core_arch arm64
bg_drain
rm -f "$MOCK_STATE/fail_v2_bstate" "$MOCK_STATE/restore_running_on_v1"
assert_unchanged arch-verify-revert update_verify_failed
eq arch-revert-man-arch arm "$(jq -r .arch "$BIFROST_MANIFEST")"
printf 'armv7l\n' >"$MOCK_STATE/uname_m"

# ---- core-rollback failure paths ----
# 1. prev.gz tampered (valid gzip of modified raw -> hash_mismatch)
cp "$FIX/v0" "$FIX/v0-tampered"
printf '# bad\n' >>"$FIX/v0-tampered"
gzip -c "$FIX/v0-tampered" >"$BIFROST_BIN/bifrostd.prev.gz"
OLD_PREV_GZ_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")
act_core_rollback
bg_drain
assert_unchanged rb-tampered-prev hash_mismatch

# 2. prev.gz corrupt non-gzip -> hash_mismatch (NOT no_space)
printf 'not-gzip-data' >"$BIFROST_BIN/bifrostd.prev.gz"
OLD_PREV_GZ_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")
act_core_rollback
bg_drain
assert_unchanged rb-corrupt-prev hash_mismatch

# Restore valid prev.gz
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
OLD_PREV_GZ_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")

# 3. rollback core_test_failed
printf '9.9.9\n' >"$MOCK_STATE/core_version"
act_core_rollback
bg_drain
rm -f "$MOCK_STATE/core_version"
assert_unchanged rb-test-failed core_test_failed

# 4. rollback no_space
# shellcheck disable=SC2329
gunzip() { command gunzip "$@" >/dev/full; }
act_core_rollback
bg_drain
unset -f gunzip
assert_unchanged rb-no-space no_space

# 5. rollback post-swap verify failure -> auto-reverts to current v1
# Make v0 fail BackendState while v1 returns Running.
make_fake_core "$FIX/v0-badbs" 1.103.0
# shellcheck disable=SC2016
sed 's/echo "started \$\$"/printf '\''{"BackendState":"NeedsLogin"}\\n'\'' >"$MOCK_STATE\/ts\/status.out"; echo "started \$\$"/' \
    "$FIX/v0-badbs" >"$FIX/v0-badbs.t"
mv -f "$FIX/v0-badbs.t" "$FIX/v0-badbs"
chmod 755 "$FIX/v0-badbs"
gzip -c "$FIX/v0-badbs" >"$BIFROST_BIN/bifrostd.prev.gz"
make_manifest "$FIX/m0-badbs.json" 4 1.103.0 0.1.0 arm "$FIX/v0-badbs" "$BIFROST_BIN/bifrostd.prev.gz"
jq -c '.arch = "arm"' "$FIX/m0-badbs.json" >"$BIFROST_BIN/bifrostd.prev.json"
OLD_PREV_GZ_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.gz")
OLD_PREV_MAN_SHA=$(sha256_file "$BIFROST_BIN/bifrostd.prev.json")
: >"$MOCK_STATE/restore_running_on_v1"
act_core_rollback
bg_drain
rm -f "$MOCK_STATE/restore_running_on_v1"
assert_unchanged rb-verify-failed update_verify_failed

# 6. rollback with missing prev.json -> succeeds and writes minimal manifest (status_refresh compatible)
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
rm -f "$BIFROST_BIN/bifrostd.prev.json"
ok rb-no-prevjson-act act_core_rollback
bg_drain
eq rb-no-prevjson-ok true "$(jq -r .ok "$JF")"
eq rb-no-prevjson-ver 1.103.0 "$(core_version)"
eq rb-no-prevjson-man-ts 1.103.0 "$(jq -r .tailscale "$BIFROST_MANIFEST")"
eq rb-no-prevjson-man-ser 0 "$(jq -r .serial "$BIFROST_MANIFEST")"
ok rb-no-prevjson-status status_refresh
eq rb-no-prevjson-status-ts 1.103.0 "$(jq -r .core.tailscale "$BIFROST_UPLOAD/bifrost_status.json")"
eq rb-no-prevjson-status-ser 0 "$(jq -r .core.serial "$BIFROST_UPLOAD/bifrost_status.json")"

# 7. Present but invalid metadata cannot use the legacy no-manifest path.
cp "$FIX/v1.gz" "$BIFROST_BIN/bifrostd.prev.gz"
printf '{broken-json' >"$BIFROST_BIN/bifrostd.prev.json"
ok rb-bad-prevjson-act act_core_rollback
bg_drain
eq rb-bad-prevjson-ok false "$(jq -r .ok "$JF")"
eq rb-bad-prevjson-code bad_manifest "$(jq -r .code "$JF")"
eq rb-bad-prevjson-ver 1.103.0 "$(core_version)"
eq rb-bad-prevjson-man-ts 1.103.0 "$(jq -r .tailscale "$BIFROST_MANIFEST")"
eq rb-bad-prevjson-man-ser 0 "$(jq -r .serial "$BIFROST_MANIFEST")"

# 8. Even zero reported flash space cannot veto a successful unpack.
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
jq -c '.arch = "arm"' "$FIX/m0.json" >"$BIFROST_BIN/bifrostd.prev.json"
df_reset
df_set "$BIFROST_BIN" 0
df_set "$BIFROST_RUN" 10000
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m2.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m2.json.sig"
curl_map_set "$V2_URL" "file:$FIX/v2.gz"
ok conservative-df-act act_core_update
bg_drain
df_reset
eq conservative-df-ok true "$(jq -r .ok "$JF")"
eq conservative-df-ver 1.105.0 "$(core_version)"

# First gunzip gets a real ENOSPC despite optimistic df. Retry exactly once
# after reclaiming prev.gz, including when that archive is the rollback input.
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
jq -c '.arch = "arm"' "$FIX/m0.json" >"$BIFROST_BIN/bifrostd.prev.json"
# shellcheck disable=SC2329
gunzip() {
    echo "$2" >>"$T/unpack-attempts"
    if [ -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        command gunzip "$@" >/dev/full
    else
        command gunzip "$@"
    fi
}
act_core_rollback
bg_drain
unset -f gunzip
eq optimistic-retry-ok true "$(jq -r .ok "$JF")"
eq optimistic-retry-ver 1.103.0 "$(core_version)"
eq optimistic-attempts "$BIFROST_BIN/bifrostd.prev.gz
$BIFROST_RUN/update-work/stash.gz" "$(cat "$T/unpack-attempts")"

# Only the obsolete archive consumes the missing space at finalize time.
cp "$FIX/v1.gz" "$BIFROST_BIN/bifrostd.prev.gz"
cp "$FIX/m1.json" "$BIFROST_BIN/bifrostd.prev.json"
# shellcheck disable=SC2329
df() {
    if [ "${2:-}" = "$BIFROST_BIN" ] && [ -f "$BIFROST_BIN/bifrostd.prev.gz" ] &&
        cmp -s "$BIFROST_CORE" "$FIX/v2"; then
        printf 'Filesystem Blocks Used Available Use%% Mounted on\n/dev/mock 2 2 0 100%% /\n'
    else
        command df "$@"
    fi
}
act_core_update
bg_drain
unset -f df
eq reclaimed-prev-kept 'true true' "$(jq -r '"\(.ok) \(.data.kept_prev)"' "$JF")"
gunzip -c "$BIFROST_BIN/bifrostd.prev.gz" >"$T/retained"
ok reclaimed-prev-bytes cmp "$T/retained" "$FIX/v0"
eq reclaimed-prev-serial 4 "$(jq -r .serial "$BIFROST_BIN/bifrostd.prev.json")"
# Reboot after publishing that archive, before disarming the flash journal.
journal="$BIFROST_HOME/.core-update"
mkdir "$journal"
echo committed >"$journal/phase"
echo keep >"$journal/action"
cp "$BIFROST_BIN/bifrostd.prev.json" "$journal/installed.json"
ok committed-replay with_lock state 0 core_recover
gunzip -c "$BIFROST_BIN/bifrostd.prev.gz" >"$T/replayed"
ok committed-prev-bytes cmp "$T/replayed" "$FIX/v0"
eq committed-prev-serial 4 "$(jq -r .serial "$BIFROST_BIN/bifrostd.prev.json")"

# Finalizing an optional rollback archive can fail between the two renames.
# Only expose the new metadata while the old archive is already withdrawn.
ok pair-stop daemon_stop
rm -f "$BIFROST_MANIFEST"
ok pair-seed core_install_file "$FIX/v1.gz" "$FIX/m1.json" arm
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
cp "$FIX/m0.json" "$BIFROST_BIN/bifrostd.prev.json"
# shellcheck disable=SC2329
mv() {
    case "$*" in
        *"$BIFROST_BIN/bifrostd.prev.json")
            [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ] || : >"$T/mixed-pair"
            ;;
        *"$BIFROST_BIN/bifrostd.prev.gz") return 1 ;;
        *"$BIFROST_CORE")
            [ -x "$BIFROST_CORE" ] || : >"$T/missing-core"
            ;;
    esac
    command mv "$@"
}
act_core_update
bg_drain
unset -f mv
eq prev-finalize-fail 'true false' "$(jq -r '"\(.ok) \(.data.kept_prev)"' "$JF")"
ok prev-no-mixed-pair [ ! -e "$T/mixed-pair" ]
ok swap-no-missing-core [ ! -e "$T/missing-core" ]
ok prev-finalize-no-gz [ ! -e "$BIFROST_BIN/bifrostd.prev.gz" ]
ok prev-finalize-no-json [ ! -e "$BIFROST_BIN/bifrostd.prev.json" ]
eq prev-finalize-no-tmp "" "$(find "$BIFROST_BIN" -name '*.tmp.*')"

# A legacy arm64 rollback retains the installed architecture and the channel
# floor even when the old release is correctly signed or the cache is lost.
printf 'aarch64\n' >"$MOCK_STATE/uname_m"
curl_map_reset
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-arm64only.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-arm64only.json.sig"
curl_map_set "$BIFROST_RELEASE_BASE/core-1.105.0-1/bifrost-core-1.105.0-1-linux-arm64.gz" "file:$FIX/v2.gz"
act_core_arch arm64
bg_drain
eq floor-arm64-installed arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"
cp "$FIX/v0.gz" "$BIFROST_BIN/bifrostd.prev.gz"
rm -f "$BIFROST_BIN/bifrostd.prev.json"
act_core_rollback
bg_drain
eq floor-legacy-arch arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"
eq floor-legacy-version 1.103.0 "$(core_version)"
eq floor-after-rollback 6 "$(cat "$BIFROST_HOME/core-channel.serial")"
# Older plugin versions wrote this legacy installed manifest without .arch.
jq 'del(.arch)' "$BIFROST_MANIFEST" >"$T/legacy.json"
cp "$T/legacy.json" "$BIFROST_MANIFEST"
eq floor-old-format-kernel-arch arm64 "$(_upd_installed_arch)"
rm -f "$BIFROST_RUN/core_latest.json"
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m1.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m1.json.sig"
act_core_update
bg_drain
eq floor-replay-rejected old_serial "$(jq -r .code "$JF")"
curl_map_set "$BIFROST_CHANNEL_URL" "file:$FIX/m-arm64only.json"
curl_map_set "${BIFROST_CHANNEL_URL}.sig" "file:$FIX/m-arm64only.json.sig"
act_core_update
bg_drain
eq floor-latest-reinstalled true "$(jq -r .ok "$JF")"
eq floor-latest-arch arm64 "$(jq -r .arch "$BIFROST_MANIFEST")"

ok final-stop daemon_stop
# P5 has explicitly stopped the daemon to install a package. An unfinished
# update must restore files while respecting the installer's stopped state.
mkdir "$journal"
echo stopping >"$journal/phase"
echo Running >"$journal/running"
ok package-recovery core_install_file "$FIX/v2.gz" "$FIX/m-arm64only.json" arm64
no package-recovery-stopped daemon_running
ok package-recovery-clean [ ! -e "$journal" ]
t_done
