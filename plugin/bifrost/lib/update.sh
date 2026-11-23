# shellcheck shell=sh
# Core verification, update, rollback, arch switching and local install.
# Contract file: see docs/dev/contract.md (sections 4, 5, 6.2, 7, 8).
# PLAN sections 12 and 15.1 step 4.
# No "local" in POSIX sh: function variables use unique _<abbr>_ prefixes.

: "${BIFROST_UPDATE_CONNECT_TIMEOUT:=10}"
: "${BIFROST_UPDATE_MAX_TIME:=300}"
: "${BIFROST_UPDATE_RETRY:=2}"
: "${BIFROST_UPDATE_VERIFY_SECS:=60}"
: "${BIFROST_UPDATE_VERSION_TIMEOUT:=10}"

# ---- Format validators (manifest fields and versions) ----

_upd_valid_semver() (
    case "$1" in *.*.*) ;; *) exit 1 ;; esac
    _us_a=${1%%.*}
    _us_r=${1#*.}
    _us_b=${_us_r%%.*}
    _us_c=${_us_r#*.}
    case "$_us_c" in *.*) exit 1 ;; esac
    valid_uint "$_us_a" && valid_uint "$_us_b" && valid_uint "$_us_c"
)

# _upd_ver_ge <cur> <min>: 0 when cur >= min (x.y.z integers only).
_upd_ver_ge() (
    _upd_valid_semver "$1" && _upd_valid_semver "$2" || exit 1
    _ug_a1=${1%%.*}
    _ug_r1=${1#*.}
    _ug_b1=${_ug_r1%%.*}
    _ug_c1=${_ug_r1#*.}
    _ug_a2=${2%%.*}
    _ug_r2=${2#*.}
    _ug_b2=${_ug_r2%%.*}
    _ug_c2=${_ug_r2#*.}
    [ "$_ug_a1" -gt "$_ug_a2" ] && exit 0
    [ "$_ug_a1" -lt "$_ug_a2" ] && exit 1
    [ "$_ug_b1" -gt "$_ug_b2" ] && exit 0
    [ "$_ug_b1" -lt "$_ug_b2" ] && exit 1
    [ "$_ug_c1" -ge "$_ug_c2" ]
)

# ---- Architecture and filesystem helpers ----

_upd_kernel_arch() {
    _uk_m=$(uname -m 2>/dev/null)
    case "$_uk_m" in
        armv7*) printf 'arm\n' ;;
        aarch64) printf 'aarch64\n' ;;
        *) printf '%s\n' "$_uk_m" ;;
    esac
}

_upd_arch_supported() {
    valid_arch "$1" || {
        fail invalid_param
        return 1
    }
    _ua_k=$(_upd_kernel_arch)
    case "$1:$_ua_k" in
        arm:arm | arm:aarch64 | arm64:aarch64) return 0 ;;
        *)
            fail arch_unsupported
            return 1
            ;;
    esac
}

_upd_installed_arch() {
    if [ -r "$BIFROST_MANIFEST" ]; then
        _ui_a=$(jq -r '
            if (.arch | type == "string") then .arch
            elif (.assets | type == "object") and ((.assets | length) == 1) then (.assets | keys[0])
            else "" end
        ' "$BIFROST_MANIFEST" 2>/dev/null)
        if valid_arch "$_ui_a"; then
            printf '%s\n' "$_ui_a"
            return 0
        fi
    fi
    printf 'arm\n'
}

_upd_installed_serial() {
    if [ -r "$BIFROST_MANIFEST" ]; then
        _ul_s=$(jq -r 'if (.serial | type == "number") and (.serial == (.serial | floor)) then .serial else "" end' "$BIFROST_MANIFEST" 2>/dev/null)
        if valid_uint "$_ul_s"; then
            printf '%s\n' "$_ul_s"
            return 0
        fi
    fi
    printf '0\n'
}

_upd_plugin_version() {
    if [ -r "$BIFROST_VERSION_FILE" ]; then
        _up_v=$(head -n 1 "$BIFROST_VERSION_FILE" 2>/dev/null | tr -d ' \t\r\n')
        if _upd_valid_semver "$_up_v"; then
            printf '%s\n' "$_up_v"
            return 0
        fi
    fi
    return 1
}

# _upd_free_kb <dir>: print available 1K blocks on the filesystem containing dir.
_upd_free_kb() {
    _uf_d=$1
    [ -d "$_uf_d" ] || _uf_d=$(dirname "$_uf_d")
    _uf_kb=$(df -k "$_uf_d" 2>/dev/null | awk 'NR > 1 { avail = $(NF - 2) } END { print avail }')
    valid_uint "$_uf_kb" || return 1
    printf '%s\n' "$_uf_kb"
}

_upd_bytes_to_kb() {
    printf '%s\n' $((($1 + 1023) / 1024))
}

# The archive is the availability flag used by status and rollback. Withdraw it
# before changing its metadata, and publish it last on the same filesystem.
_upd_publish_prev() {
    _pp_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _pp_man="$BIFROST_BIN/bifrostd.prev.json"
    cp "$1" "$_pp_gz.tmp.$$" || return 1
    if [ -f "$2" ]; then
        cp "$2" "$_pp_man.tmp.$$" || return 1
    fi
    rm -f "$_pp_gz" || return 1
    if [ -f "$2" ]; then
        mv -f "$_pp_man.tmp.$$" "$_pp_man" || return 1
    else
        rm -f "$_pp_man" || return 1
    fi
    mv -f "$_pp_gz.tmp.$$" "$_pp_gz" || { rm -f "$_pp_man"; return 1; }
}

# JFFS2's df is only a hint. If space looks tight, keep a recoverable
# tmpfs copy before reclaiming the rollback archive. Always try the write.
_upd_prepare_unpack() {
    mkdir -p "$BIFROST_BIN" || { fail internal; return 1; }
    _pu_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _pu_man="$BIFROST_BIN/bifrostd.prev.json"
    [ -f "$_pu_gz" ] || return 0
    _pu_free=$(_upd_free_kb "$BIFROST_BIN") || return 0
    [ "$_pu_free" -lt "$(_upd_bytes_to_kb "$1")" ] || return 0
    if cp "$_pu_gz" "$_ut_dir/stash.gz" &&
        { [ ! -f "$_pu_man" ] || cp "$_pu_man" "$_ut_dir/stash.json"; }; then
        rm -f "$_pu_gz" "$_pu_man" || { fail internal; return 1; }
    else
        rm -f "$_ut_dir/stash.gz" "$_ut_dir/stash.json"
    fi
}

_upd_check_tmp_space() {
    _ut_need_kb=$(_upd_bytes_to_kb "$1")
    [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN" 2>/dev/null || {
        fail no_space
        return 1
    }
    _ut_avail=$(_upd_free_kb "$BIFROST_RUN") || return 0
    if [ "$_ut_avail" -lt "$_ut_need_kb" ]; then
        log update "not enough space in runtime dir: avail=${_ut_avail}KB need=${_ut_need_kb}KB"
        fail no_space
        return 1
    fi
    return 0
}

# _upd_unpack_gz <gz> <dst>: unpack to dst; distinguish ENOSPC from corrupt gzip.
_upd_unpack_gz() {
    _ugz_src=$1
    _ugz_dst=$2
    if LC_ALL=C gunzip -c "$_ugz_src" 2>"$_ut_dir/unpack.err" >"$_ugz_dst"; then
        chmod 755 "$_ugz_dst" && return 0
        fail internal
    elif grep -qi 'No space left on device' "$_ut_dir/unpack.err"; then
        fail no_space
    elif ! gunzip -c "$_ugz_src" >/dev/null 2>&1; then
        fail hash_mismatch
    else
        fail internal
    fi
    rm -f "$_ugz_dst"
    return 1
}

# ---- Cross-package functions (contract section 7) ----

# manifest_verify <json> <sig>: 0 when any *.pub.pem in $BIFROST_KEYS verifies.
# Checks strict DER SEQUENCE framing first because OpenSSL dgst caps signature
# reads at EVP_PKEY_size (72 bytes for P-256), ignoring trailing bytes past 72.
manifest_verify() {
    _mv_json=$1
    _mv_sig=$2
    if [ ! -r "$_mv_json" ] || [ ! -s "$_mv_json" ] || [ ! -r "$_mv_sig" ] || [ ! -s "$_mv_sig" ]; then
        fail bad_signature
        return 1
    fi
    _mv_sz=$(file_size "$_mv_sig" 2>/dev/null || echo 0)
    if ! valid_uint "$_mv_sz" || [ "$_mv_sz" -lt 8 ] || [ "$_mv_sz" -gt 72 ]; then
        fail bad_signature
        return 1
    fi
    _mv_hdr=$(hexdump -n 2 -e '2/1 "%u "' "$_mv_sig" 2>/dev/null)
    # shellcheck disable=SC2086
    set -- $_mv_hdr
    if [ $# -lt 2 ] || [ "${1:-}" != 48 ] || ! valid_uint "${2:-}" || [ "$2" -ge 128 ] || [ "$(($2 + 2))" -ne "$_mv_sz" ]; then
        fail bad_signature
        return 1
    fi
    for _mv_key in "$BIFROST_KEYS"/*.pub.pem; do
        [ -r "$_mv_key" ] || continue
        if openssl dgst -sha256 -verify "$_mv_key" -signature "$_mv_sig" "$_mv_json" >/dev/null 2>&1; then
            return 0
        fi
    done
    fail bad_signature
    return 1
}

_upd_bin_version() {
    _uv_bin=$1
    [ -x "$_uv_bin" ] || return 1
    _uv_out=$(run_timeout "$BIFROST_UPDATE_VERSION_TIMEOUT" "$_uv_bin" --version 2>/dev/null) || return 1
    _uv_line=$(printf '%s\n' "$_uv_out" | head -n 1 | tr -d '\r')
    _upd_valid_semver "$_uv_line" || return 1
    printf '%s\n' "$_uv_line"
}

# core_version: print the installed core's Tailscale version (first line of --version).
core_version() {
    _upd_bin_version "$BIFROST_CORE" || {
        fail core_missing
        return 1
    }
}

# ---- Manifest parsing, validation and staging ----

# _upd_parse_manifest <json> <arch> <serial_mode: gt|ge|any> <check_plugin: 0|1>
# Sets _UM_SERIAL, _UM_TS, _UM_REV, _UM_TAG, _UM_MIN_PLUGIN,
# _UM_FILE, _UM_SIZE, _UM_SHA, _UM_RAW_SIZE, _UM_RAW_SHA, _UM_LATEST_JSON.
_upd_parse_manifest() {
    _pm_json=$1
    _pm_arch=$2
    _pm_smode=$3
    _pm_cplug=$4

    # Validate every asset while the original JSON types and string boundaries
    # are available. Only the checked printable fields cross into the shell.
    _pm_fields=$(jq -ers --arg arch "$_pm_arch" '
        def positive: type == "number" and floor == . and . >= 1 and . <= 9999999999;
        def version: type == "string" and test("^(0|[1-9][0-9]{0,9})(\\.(0|[1-9][0-9]{0,9})){2}\\z");
        def digest: type == "string" and test("^[0-9a-f]{64}\\z");
        def asset:
            .key as $a | ($a == "arm" or $a == "arm64") and
            (.value | (.file | type == "string" and length <= 128 and
                test("^[A-Za-z0-9_][A-Za-z0-9._-]*\\z") and
                (contains("..") | not) and endswith("-linux-" + $a + ".gz")) and
                (.size | positive) and (.raw_size | positive) and
                (.sha256 | digest) and (.raw_sha256 | digest));
        select(length == 1) | .[0] |
        select(type == "object" and .schema == 1 and (.serial | positive) and
            (.tailscale | version) and (.min_plugin | version) and (.revision | positive) and
            .tag == ("core-" + .tailscale + "-" + (.revision | tostring)) and
            (.assets | type == "object" and all(to_entries[]; asset))) |
        [.serial, .tailscale, .revision, .tag, .min_plugin,
         (.assets[$arch] | .file // "-", .size // 0, .sha256 // "-", .raw_size // 0, .raw_sha256 // "-")] |
        @tsv
    ' "$_pm_json" 2>/dev/null) || { fail bad_manifest; return 1; }
    read -r _UM_SERIAL _UM_TS _UM_REV _UM_TAG _UM_MIN_PLUGIN _UM_FILE _UM_SIZE _UM_SHA _UM_RAW_SIZE _UM_RAW_SHA <<EOF
$_pm_fields
EOF

    _pm_cur_serial=$(_upd_installed_serial)
    case "$_pm_smode" in
        gt)
            if [ "$_UM_SERIAL" -le "$_pm_cur_serial" ]; then
                fail old_serial
                return 1
            fi
            ;;
        ge)
            if [ "$_UM_SERIAL" -lt "$_pm_cur_serial" ]; then
                fail old_serial
                return 1
            fi
            ;;
        any) ;;
        *) fail internal; return 1 ;;
    esac

    if [ "$_pm_cplug" = 1 ]; then
        _pm_pver=$(_upd_plugin_version) || {
            fail internal
            return 1
        }
        if ! _upd_ver_ge "$_pm_pver" "$_UM_MIN_PLUGIN"; then
            fail plugin_too_old
            return 1
        fi
    fi

    [ "$_UM_FILE" != - ] || { fail no_arch; return 1; }

    _UM_LATEST_JSON=$(jq -cn \
        --arg ts "$_UM_TS" \
        --argjson rev "$_UM_REV" \
        --argjson ser "$_UM_SERIAL" \
        --arg tag "$_UM_TAG" \
        '{tailscale:$ts, revision:$rev, serial:$ser, tag:$tag}') || {
        fail internal
        return 1
    }
    return 0
}

# Write the installed representation to a staging file on its destination FS.
_upd_stage_manifest() {
    { jq -ec --arg arch "$2" '.arch = $arch | .assets = {($arch): .assets[$arch]}' "$1" >"$3" &&
        chmod 644 "$3"; } || { fail internal; return 1; }
}

# Back up $BIFROST_CORE to bifrostd.old without removing $BIFROST_CORE so a
# power loss never leaves the router without a core binary.
_upd_backup_core_old() {
    rm -f "$BIFROST_BIN/bifrostd.old"
    if ln "$BIFROST_CORE" "$BIFROST_BIN/bifrostd.old" 2>/dev/null; then
        return 0
    fi
    if cp -p "$BIFROST_CORE" "$BIFROST_BIN/bifrostd.old" 2>/dev/null; then
        return 0
    fi
    rm -f "$BIFROST_BIN/bifrostd.old"
    fail internal
    return 1
}

# ---- Download helper (PLAN 12.7) ----

_upd_download() {
    _dl_url=$1
    _dl_out=$2
    _dl_mir=$(cfg bifrost_mirror)
    _dl_eff="${_dl_mir}${_dl_url}"
    rm -f "$_dl_out"
    if ! run_timeout "$((BIFROST_UPDATE_MAX_TIME + 15))" \
        curl -fsSL \
        --connect-timeout "$BIFROST_UPDATE_CONNECT_TIMEOUT" \
        --max-time "$BIFROST_UPDATE_MAX_TIME" \
        --retry "$BIFROST_UPDATE_RETRY" \
        -o "$_dl_out" "$_dl_eff" 2>/dev/null; then
        rm -f "$_dl_out"
        log update "download failed: $_dl_eff"
        fail download_failed
        return 1
    fi
    if [ ! -s "$_dl_out" ]; then
        rm -f "$_dl_out"
        log update "downloaded empty file: $_dl_eff"
        fail download_failed
        return 1
    fi
    return 0
}

# ---- Local core installation for install.sh (PLAN 15.1 step 4) ----

# core_install_file <gz> <manifest json> <arch>:
# Unpack, verify raw_size/raw_sha256, test --version, swap into $BIFROST_CORE.
# Caller must have stopped the daemon. Never starts or stops the daemon.
core_install_file() {
    _upd_transaction _upd_install_package "$@"
}

_upd_install_package() {
    _ci_gz=$1
    _ci_man=$2
    _ci_arch=$3
    daemon_running && { fail already_running; return 1; }
    _upd_arch_supported "$_ci_arch" || return 1
    [ -r "$_ci_gz" ] && [ -r "$_ci_man" ] || { fail bad_manifest; return 1; }
    _upd_parse_manifest "$_ci_man" "$_ci_arch" any 0 || return 1

    if [ -x "$BIFROST_CORE" ] && [ "$(_upd_installed_serial)" -ge "$_UM_SERIAL" ]; then
        ln -sf bifrostd "$BIFROST_CLI" || { fail internal; return 1; }
        return 0
    fi
    _upd_prepare_unpack "$_UM_RAW_SIZE" &&
        _upd_unpack_gz "$_ci_gz" "$_ut_new" &&
        _upd_check_raw "$_ut_new" &&
        _upd_test_version "$_ut_new" &&
        _upd_stage_manifest "$_ci_man" "$_ci_arch" "$_ut_manifest" &&
        _upd_replace
}

_upd_check_raw() {
    [ "$(file_size "$1")" = "$_UM_RAW_SIZE" ] &&
        [ "$(sha256_file "$1")" = "$_UM_RAW_SHA" ] || { fail hash_mismatch; return 1; }
}

_upd_test_version() {
    [ "$(_upd_bin_version "$1")" = "$_UM_TS" ] || { fail core_test_failed; return 1; }
}

# Both renames are on the destination filesystem. Keep the old inode linked
# until metadata commits; a failed rename of either file leaves the old pair.
_upd_replace() {
    if [ -f "$BIFROST_CORE" ]; then
        _upd_backup_core_old || return 1
    fi
    if ! ln -sf bifrostd "$BIFROST_CLI" || ! mv -f "$_ut_new" "$BIFROST_CORE"; then
        fail internal
        return 1
    fi
    if ! mv -f "$_ut_manifest" "$BIFROST_MANIFEST"; then
        _upd_restore_core || return 1
        fail internal
        return 1
    fi
}

_upd_restore_core() {
    if [ -f "$BIFROST_BIN/bifrostd.old" ]; then
        mv -f "$BIFROST_BIN/bifrostd.old" "$BIFROST_CORE" || {
            _ut_keep=1
            fail internal
            return 1
        }
    else
        rm -f "$BIFROST_CORE" || { fail internal; return 1; }
    fi
}

# ---- Shared swap + verify + auto-revert flow (PLAN 12.4 steps 7-11) ----

_upd_verify_running() {
    _vr_want=$1
    _vr_deadline=$(($(now) + BIFROST_UPDATE_VERIFY_SECS))
    daemon_wait_ready "$BIFROST_UPDATE_VERIFY_SECS" || return 1
    while :; do
        daemon_running || return 1
        _vr_got=$(backend_state 2>/dev/null || echo "")
        if [ -z "$_vr_want" ]; then
            [ -n "$_vr_got" ] && return 0
        elif [ "$_vr_got" = "$_vr_want" ]; then
            return 0
        fi
        [ "$(now)" -ge "$_vr_deadline" ] && return 1
        sleep 1
    done
}

# The committed candidate and its manifest stay paired even if its daemon
# cannot be stopped for rollback. Retain recovery files in that case.
_upd_swap_and_verify() {
    _sv_save_prev=$1
    job_phase update snapshot 75
    _sv_running=0
    if daemon_running; then
        _sv_running=1
        _sv_state=$(backend_state) || { fail cli_failed; return 1; }
    fi

    if [ -f "$BIFROST_MANIFEST" ]; then
        cp -p "$BIFROST_MANIFEST" "$_ut_dir/installed.json" || { fail internal; return 1; }
    fi
    _sv_snap="$_ut_dir/tailscaled.state.snap"
    if [ -f "$BIFROST_STATE/tailscaled.state" ]; then
        (umask 077 && cat "$BIFROST_STATE/tailscaled.state" >"$_sv_snap") || { fail internal; return 1; }
    fi
    job_phase update swap 80
    if [ "$_sv_running" = 1 ]; then
        daemon_stop || return 1
    fi
    if ! _upd_replace; then
        _sv_error=${BIFROST_ERR:-internal}
        if [ "$_sv_running" = 1 ] && [ "$_ut_keep" = 0 ]; then
            daemon_start || return 1
        fi
        fail "$_sv_error"
        return 1
    fi

    if [ "$_sv_running" = 1 ]; then
        job_phase update verify_running 85
        if ! daemon_start || ! _upd_verify_running "$_sv_state"; then
            job_phase update rollback 90
            _ut_keep=1
            daemon_stop || return 1
            _upd_restore_core || return 1
            if [ -f "$_ut_dir/installed.json" ]; then
                atomic_write "$BIFROST_MANIFEST" 644 <"$_ut_dir/installed.json" || { fail internal; return 1; }
            else
                rm -f "$BIFROST_MANIFEST" || { fail internal; return 1; }
            fi
            if [ -f "$_sv_snap" ]; then
                atomic_write "$BIFROST_STATE/tailscaled.state" 600 <"$_sv_snap" || { fail internal; return 1; }
            fi
            _ut_keep=0
            BIFROST_ERR=""
            daemon_start || return 1
            _upd_verify_running "$_sv_state" || { fail start_failed; return 1; }
            fail update_verify_failed
            return 1
        fi
    fi

    job_phase update finalize 95
    _sv_kept=false
    if [ "$_sv_save_prev" = 1 ] && [ -f "$BIFROST_BIN/bifrostd.old" ] &&
        [ -f "$_ut_dir/installed.json" ] &&
        gzip -c "$BIFROST_BIN/bifrostd.old" >"$_ut_dir/previous.gz"; then
        rm -f "$BIFROST_BIN/bifrostd.old"
        _sv_free=$(_upd_free_kb "$BIFROST_BIN") || _sv_free=""
        _sv_bytes=$(($(file_size "$_ut_dir/previous.gz") + $(file_size "$_ut_dir/installed.json")))
        if { [ -z "$_sv_free" ] || [ "$_sv_free" -ge "$(_upd_bytes_to_kb "$_sv_bytes")" ]; } &&
            _upd_publish_prev "$_ut_dir/previous.gz" "$_ut_dir/installed.json"; then
            _sv_kept=true
        fi
    fi
    if [ "$_sv_kept" = false ]; then
        rm -f "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
    fi
    job_data update "{\"kept_prev\":$_sv_kept}"
    return 0
}

# The dispatcher or install.sh holds the state lock. Each operation owns a
# private directory, including any rollback state or archive moved to tmpfs.
_upd_transaction() {
    _ut_dir="$BIFROST_RUN/update.$$"
    _ut_new="$BIFROST_BIN/bifrostd.new"
    _ut_manifest="$BIFROST_MANIFEST.tmp.$$"
    _ut_keep=0
    { mkdir -p "$BIFROST_RUN" && (umask 077 && mkdir "$_ut_dir"); } || { fail internal; return 1; }
    _ut_rc=0
    "$@" || _ut_rc=$?
    rm -f "$_ut_new" "$_ut_manifest"
    if [ "$_ut_rc" != 0 ] && [ -f "$_ut_dir/stash.gz" ] && [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        if ! _upd_publish_prev "$_ut_dir/stash.gz" "$_ut_dir/stash.json"; then
            _ut_keep=1
            BIFROST_ERR=internal
        fi
    fi
    rm -f "$BIFROST_BIN/bifrostd.prev.gz.tmp.$$" "$BIFROST_BIN/bifrostd.prev.json.tmp.$$"
    if [ "$_ut_keep" = 1 ]; then
        log update "recovery files retained in $_ut_dir"
    else
        rm -f "$BIFROST_BIN/bifrostd.old"
        rm -rf "$_ut_dir"
    fi
    return "$_ut_rc"
}

# ---- Job body (contract section 4 & 6.2) ----

_upd_job_check() {
    _jc_dir="$BIFROST_RUN/update"
    rm -rf "$_jc_dir"
    mkdir -p "$_jc_dir" || { fail internal; return 1; }

    job_data update '{"action":"check","latest":null,"up_to_date":false,"kept_prev":false}'
    _jc_arch=$(_upd_installed_arch)
    _upd_arch_supported "$_jc_arch" || { rm -rf "$_jc_dir"; return 1; }

    job_phase update manifest 20
    _jc_json="$_jc_dir/core.json"
    _jc_sig="$_jc_dir/core.json.sig"
    if ! _upd_download "$BIFROST_CHANNEL_URL" "$_jc_json" ||
        ! _upd_download "${BIFROST_CHANNEL_URL}.sig" "$_jc_sig"; then
        rm -rf "$_jc_dir"
        return 1
    fi

    job_phase update verify_manifest 60
    if ! manifest_verify "$_jc_json" "$_jc_sig"; then
        rm -rf "$_jc_dir"
        return 1
    fi
    if ! _upd_parse_manifest "$_jc_json" "$_jc_arch" ge 1; then
        rm -rf "$_jc_dir"
        return 1
    fi

    if ! atomic_write "$BIFROST_RUN/core_latest.json" 644 <"$_jc_json"; then
        rm -f "$BIFROST_RUN/core_latest.json.tmp.$$"
        rm -rf "$_jc_dir"
        fail internal
        return 1
    fi

    _jc_cur_ser=$(_upd_installed_serial)
    if [ "$_UM_SERIAL" -gt "$_jc_cur_ser" ]; then
        _jc_utd=false
    else
        _jc_utd=true
    fi
    _jc_data=$(jq -cn --argjson latest "$_UM_LATEST_JSON" --argjson utd "$_jc_utd" \
        '{latest:$latest, up_to_date:$utd}')
    job_data update "$_jc_data"
    rm -rf "$_jc_dir"
    log update "check complete: serial=$_UM_SERIAL installed=$_jc_cur_ser up_to_date=$_jc_utd"
    return 0
}

_upd_job_install_remote() {
    _jr_action=$1
    _jr_arch=$2
    job_data update "{\"action\":\"$_jr_action\",\"latest\":null,\"up_to_date\":false,\"kept_prev\":false}"
    _upd_arch_supported "$_jr_arch" || return 1

    _jr_cur_arch=$(_upd_installed_arch)
    if [ "$_jr_action" = arch ] && [ "$_jr_arch" != "$_jr_cur_arch" ]; then
        _jr_smode=ge
    else
        _jr_smode=gt
    fi

    job_phase update manifest 5
    _jr_json="$_ut_dir/core.json"
    _jr_sig="$_ut_dir/core.json.sig"
    if ! _upd_download "$BIFROST_CHANNEL_URL" "$_jr_json" ||
        ! _upd_download "${BIFROST_CHANNEL_URL}.sig" "$_jr_sig"; then
        return 1
    fi

    job_phase update verify_manifest 15
    if ! manifest_verify "$_jr_json" "$_jr_sig"; then
        return 1
    fi
    if ! _upd_parse_manifest "$_jr_json" "$_jr_arch" "$_jr_smode" 1; then
        return 1
    fi

    _jr_ldata=$(jq -cn --argjson latest "$_UM_LATEST_JSON" '{latest:$latest}')
    job_data update "$_jr_ldata"

    # Space phase: verify runtime dir fits .gz; never delete prev.gz before
    # download and hash verification succeed (PLAN 12.6).
    job_phase update space 20
    if ! _upd_check_tmp_space "$_UM_SIZE"; then
        return 1
    fi

    job_phase update download 30
    _jr_gz="$_ut_dir/core.gz"
    _jr_url="$BIFROST_RELEASE_BASE/$_UM_TAG/$_UM_FILE"
    if ! _upd_download "$_jr_url" "$_jr_gz"; then
        return 1
    fi

    job_phase update verify 50
    _jr_got_size=$(file_size "$_jr_gz" 2>/dev/null || echo 0)
    _jr_got_sha=$(sha256_file "$_jr_gz" 2>/dev/null || echo "")
    if [ "$_jr_got_size" != "$_UM_SIZE" ] || [ "$_jr_got_sha" != "$_UM_SHA" ]; then
        log update "gz hash/size mismatch: size=$_jr_got_size/$_UM_SIZE"
        fail hash_mismatch
        return 1
    fi

    job_phase update unpack 60
    _upd_prepare_unpack "$_UM_RAW_SIZE" &&
        _upd_unpack_gz "$_jr_gz" "$_ut_new" &&
        _upd_check_raw "$_ut_new" || return 1

    job_phase update test 70
    _upd_test_version "$_ut_new" &&
        _upd_stage_manifest "$_jr_json" "$_jr_arch" "$_ut_manifest" &&
        _upd_swap_and_verify 1 || return 1
    if ! atomic_write "$BIFROST_RUN/core_latest.json" 644 <"$_jr_json"; then
        log update "core installed; latest manifest cache write failed"
        rm -f "$BIFROST_RUN/core_latest.json.tmp.$$"
    fi
    return 0
}

_upd_job_rollback() {
    job_data update '{"action":"rollback","latest":null,"up_to_date":false,"kept_prev":false}'
    _rb_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _rb_man="$BIFROST_BIN/bifrostd.prev.json"
    [ -s "$_rb_gz" ] || { fail no_prev; return 1; }
    job_phase update unpack 50
    _upd_unpack_gz "$_rb_gz" "$_ut_new" || return 1
    job_phase update test 65
    _rb_arch=$(jq -er '.arch // (.assets | keys | select(length == 1) | first)' "$_rb_man" 2>/dev/null) || _rb_arch=""
    if valid_arch "$_rb_arch" && _upd_parse_manifest "$_rb_man" "$_rb_arch" any 0; then
        _upd_arch_supported "$_rb_arch" && _upd_check_raw "$_ut_new" &&
            _upd_test_version "$_ut_new" &&
            _upd_stage_manifest "$_rb_man" "$_rb_arch" "$_ut_manifest" || return 1
    else
        # Legacy backup without metadata. Only the version can be observed.
        BIFROST_ERR=""
        _rb_ver=$(_upd_bin_version "$_ut_new") || { fail core_test_failed; return 1; }
        { jq -cn --arg ts "$_rb_ver" '{schema:1, tailscale:$ts, serial:0, revision:0, assets:{}}' \
            >"$_ut_manifest" && chmod 644 "$_ut_manifest"; } || { fail internal; return 1; }
    fi
    _upd_swap_and_verify 0
}

job_update() {
    case "${1:-}" in
        check) _upd_job_check ;;
        update) _upd_transaction _upd_job_install_remote update "$(_upd_installed_arch)" ;;
        arch) _upd_transaction _upd_job_install_remote arch "${2:-}" ;;
        rollback) _upd_transaction _upd_job_rollback ;;
        *) fail invalid_param ;;
    esac
}

# ---- Page actions (contract section 4) ----

act_core_check() {
    job_start update check
}

act_core_update() {
    job_start update update
}

act_core_rollback() {
    if [ ! -r "$BIFROST_BIN/bifrostd.prev.gz" ] || [ ! -s "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        fail no_prev
        return 1
    fi
    job_start update rollback
}

act_core_arch() {
    _upd_arch_supported "${1:-}" || return 1
    job_start update arch "$1"
}
