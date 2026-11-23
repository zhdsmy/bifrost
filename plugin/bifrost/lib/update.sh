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

_upd_valid_sha256() {
    case "$1" in '' | *[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -eq 64 ]
}

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

_upd_valid_tag() {
    case "$1" in '' | .* | -* | *..* | *[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 64 ]
}

_upd_valid_asset_file() {
    case "$1" in '' | .* | -* | *..* | *[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$1" in *.gz) ;; *) return 1 ;; esac
    [ "${#1}" -le 128 ]
}

# ---- Architecture and filesystem helpers ----

_upd_kernel_arch() {
    _uk_m=$(uname -m 2>/dev/null)
    case "$_uk_m" in
        armv7l | armv7*) printf 'arm\n' ;;
        aarch64 | arm64) printf 'aarch64\n' ;;
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

# Check space in $BIFROST_BIN for raw_size bytes; drop prev.gz if needed (PLAN 12.6).
# When $2 is "keep_prev", never delete prev.gz (used by rollback).
_upd_check_bin_space() {
    _ub_need_kb=$(_upd_bytes_to_kb "$1")
    _ub_mode=${2:-allow_drop}
    [ -d "$BIFROST_BIN" ] || mkdir -p "$BIFROST_BIN" 2>/dev/null || {
        fail no_space
        return 1
    }
    _ub_avail=$(_upd_free_kb "$BIFROST_BIN") || return 0
    if [ "$_ub_avail" -lt "$_ub_need_kb" ]; then
        if [ "$_ub_mode" = allow_drop ] && [ -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then
            log update "low space in bin (${_ub_avail}KB < ${_ub_need_kb}KB), removing previous core"
            rm -f "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
            _ub_avail=$(_upd_free_kb "$BIFROST_BIN") || return 0
        fi
        if [ "$_ub_avail" -lt "$_ub_need_kb" ]; then
            log update "not enough space in bin: avail=${_ub_avail}KB need=${_ub_need_kb}KB"
            fail no_space
            return 1
        fi
    fi
    return 0
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

# ---- Cross-package functions (contract section 7) ----

# manifest_verify <json> <sig>: 0 when any *.pub.pem in $BIFROST_KEYS verifies.
manifest_verify() {
    _mv_json=$1
    _mv_sig=$2
    if [ ! -r "$_mv_json" ] || [ ! -s "$_mv_json" ] || [ ! -r "$_mv_sig" ] || [ ! -s "$_mv_sig" ]; then
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

# ---- Manifest parsing and validation ----

# _upd_parse_manifest <json> <arch> <serial_mode: gt|ge|any> <check_plugin: 0|1>
# Sets _UM_SERIAL, _UM_TS, _UM_REV, _UM_TAG, _UM_MIN_PLUGIN,
# _UM_FILE, _UM_SIZE, _UM_SHA, _UM_RAW_SIZE, _UM_RAW_SHA, _UM_LATEST_JSON.
_upd_parse_manifest() {
    _pm_json=$1
    _pm_arch=$2
    _pm_smode=$3
    _pm_cplug=$4

    jq -e 'type == "object" and .schema == 1 and (.assets | type == "object")' "$_pm_json" >/dev/null 2>&1 || {
        fail bad_manifest
        return 1
    }

    _UM_SERIAL=$(jq -r 'if (.serial | type == "number") and (.serial == (.serial | floor)) then .serial else "" end' "$_pm_json" 2>/dev/null)
    _UM_TS=$(jq -r 'if (.tailscale | type == "string") then .tailscale else "" end' "$_pm_json" 2>/dev/null)
    _UM_REV=$(jq -r 'if (.revision | type == "number") and (.revision == (.revision | floor)) then .revision else "" end' "$_pm_json" 2>/dev/null)
    _UM_TAG=$(jq -r 'if (.tag | type == "string") then .tag else "" end' "$_pm_json" 2>/dev/null)
    _UM_MIN_PLUGIN=$(jq -r 'if (.min_plugin | type == "string") then .min_plugin else "" end' "$_pm_json" 2>/dev/null)

    valid_uint "$_UM_SERIAL" && [ "$_UM_SERIAL" -ge 1 ] || { fail bad_manifest; return 1; }
    _upd_valid_semver "$_UM_TS" || { fail bad_manifest; return 1; }
    valid_uint "$_UM_REV" && [ "$_UM_REV" -ge 1 ] || { fail bad_manifest; return 1; }
    _upd_valid_tag "$_UM_TAG" || { fail bad_manifest; return 1; }
    _upd_valid_semver "$_UM_MIN_PLUGIN" || { fail bad_manifest; return 1; }

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

    jq -e --arg a "$_pm_arch" '(.assets | has($a)) and (.assets[$a] | type == "object")' "$_pm_json" >/dev/null 2>&1 || {
        fail no_arch
        return 1
    }

    _UM_FILE=$(jq -r --arg a "$_pm_arch" 'if (.assets[$a].file | type == "string") then .assets[$a].file else "" end' "$_pm_json" 2>/dev/null)
    _UM_SIZE=$(jq -r --arg a "$_pm_arch" 'if (.assets[$a].size | type == "number") and (.assets[$a].size == (.assets[$a].size | floor)) then .assets[$a].size else "" end' "$_pm_json" 2>/dev/null)
    _UM_SHA=$(jq -r --arg a "$_pm_arch" 'if (.assets[$a].sha256 | type == "string") then .assets[$a].sha256 else "" end' "$_pm_json" 2>/dev/null)
    _UM_RAW_SIZE=$(jq -r --arg a "$_pm_arch" 'if (.assets[$a].raw_size | type == "number") and (.assets[$a].raw_size == (.assets[$a].raw_size | floor)) then .assets[$a].raw_size else "" end' "$_pm_json" 2>/dev/null)
    _UM_RAW_SHA=$(jq -r --arg a "$_pm_arch" 'if (.assets[$a].raw_sha256 | type == "string") then .assets[$a].raw_sha256 else "" end' "$_pm_json" 2>/dev/null)

    _upd_valid_asset_file "$_UM_FILE" || { fail bad_manifest; return 1; }
    valid_uint "$_UM_SIZE" && [ "$_UM_SIZE" -gt 0 ] || { fail bad_manifest; return 1; }
    _upd_valid_sha256 "$_UM_SHA" || { fail bad_manifest; return 1; }
    valid_uint "$_UM_RAW_SIZE" && [ "$_UM_RAW_SIZE" -gt 0 ] || { fail bad_manifest; return 1; }
    _upd_valid_sha256 "$_UM_RAW_SHA" || { fail bad_manifest; return 1; }

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

_upd_write_installed_manifest() {
    _wm_src=$1
    _wm_arch=$2
    jq --arg arch "$_wm_arch" '.arch = $arch | .assets = {($arch): .assets[$arch]}' "$_wm_src" |
        json_write "$BIFROST_MANIFEST"
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
    _ci_gz=$1
    _ci_man=$2
    _ci_arch=$3

    if daemon_running; then
        fail already_running
        return 1
    fi
    _upd_arch_supported "$_ci_arch" || return 1
    if [ ! -r "$_ci_gz" ] || [ ! -r "$_ci_man" ]; then
        fail bad_manifest
        return 1
    fi

    _upd_parse_manifest "$_ci_man" "$_ci_arch" any 0 || return 1

    # Upgrade: do not downgrade if installed core has a strictly higher serial.
    if [ -x "$BIFROST_CORE" ] && [ -r "$BIFROST_MANIFEST" ]; then
        _ci_cur_ser=$(_upd_installed_serial)
        if [ "$_ci_cur_ser" -gt "$_UM_SERIAL" ]; then
            log update "keeping newer installed core (serial $_ci_cur_ser > $_UM_SERIAL)"
            return 0
        fi
    fi

    _upd_check_bin_space "$_UM_RAW_SIZE" allow_drop || return 1

    _ci_new="$BIFROST_BIN/bifrostd.new"
    rm -f "$_ci_new"
    if ! gunzip -c "$_ci_gz" >"$_ci_new" 2>/dev/null; then
        rm -f "$_ci_new"
        fail no_space
        return 1
    fi
    chmod 755 "$_ci_new"

    _ci_size=$(file_size "$_ci_new" 2>/dev/null || echo 0)
    _ci_sha=$(sha256_file "$_ci_new" 2>/dev/null || echo "")
    if [ "$_ci_size" != "$_UM_RAW_SIZE" ] || [ "$_ci_sha" != "$_UM_RAW_SHA" ]; then
        rm -f "$_ci_new"
        fail hash_mismatch
        return 1
    fi

    _ci_ver=$(_upd_bin_version "$_ci_new" 2>/dev/null || echo "")
    if [ "$_ci_ver" != "$_UM_TS" ]; then
        rm -f "$_ci_new"
        fail core_test_failed
        return 1
    fi

    if ! mv -f "$_ci_new" "$BIFROST_CORE"; then
        rm -f "$_ci_new"
        fail internal
        return 1
    fi
    ln -sf bifrostd "$BIFROST_CLI"
    _upd_write_installed_manifest "$_ci_man" "$_ci_arch" || return 1
    log update "installed core $_UM_TS (serial=$_UM_SERIAL arch=$_ci_arch)"
    return 0
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

# _upd_swap_and_verify <new_bin> <upd_dir> <save_prev: 0|1> <new_manifest_src> <new_arch>
_upd_swap_and_verify() {
    _sv_new=$1
    _sv_dir=$2
    _sv_save_prev=$3
    _sv_new_man=$4
    _sv_new_arch=$5

    job_phase update snapshot 75
    _sv_was_running=0
    _sv_prev_bstate=""
    if daemon_running; then
        _sv_was_running=1
        _sv_prev_bstate=$(backend_state 2>/dev/null || echo "")
    fi

    _sv_snap=""
    if [ -f "$BIFROST_STATE/tailscaled.state" ]; then
        _sv_snap="$_sv_dir/tailscaled.state.snap"
        if ! cp "$BIFROST_STATE/tailscaled.state" "$_sv_snap"; then
            rm -f "$_sv_new"
            fail internal
            return 1
        fi
        chmod 600 "$_sv_snap"
    fi

    _sv_old_man=""
    if [ -r "$BIFROST_MANIFEST" ]; then
        _sv_old_man="$_sv_dir/old_manifest.json"
        cp "$BIFROST_MANIFEST" "$_sv_old_man"
    fi

    job_phase update swap 80
    if [ "$_sv_was_running" = 1 ]; then
        if ! daemon_stop; then
            rm -f "$_sv_new"
            fail internal
            return 1
        fi
    fi

    _sv_had_old=0
    if [ -f "$BIFROST_CORE" ]; then
        _sv_had_old=1
        if ! mv -f "$BIFROST_CORE" "$BIFROST_BIN/bifrostd.old"; then
            rm -f "$_sv_new"
            [ "$_sv_was_running" = 1 ] && daemon_start
            fail internal
            return 1
        fi
    fi

    if ! mv -f "$_sv_new" "$BIFROST_CORE"; then
        [ "$_sv_had_old" = 1 ] && mv -f "$BIFROST_BIN/bifrostd.old" "$BIFROST_CORE"
        rm -f "$_sv_new"
        [ "$_sv_was_running" = 1 ] && daemon_start
        fail internal
        return 1
    fi
    ln -sf bifrostd "$BIFROST_CLI"

    if [ "$_sv_was_running" = 1 ]; then
        job_phase update verify_running 85
        _sv_ok=0
        if daemon_start && _upd_verify_running "$_sv_prev_bstate"; then
            _sv_ok=1
        fi
        if [ "$_sv_ok" != 1 ]; then
            log update "new core failed post-swap verification, reverting"
            job_phase update rollback 90
            daemon_stop
            if [ "$_sv_had_old" = 1 ]; then
                mv -f "$BIFROST_BIN/bifrostd.old" "$BIFROST_CORE"
            else
                rm -f "$BIFROST_CORE"
            fi
            if [ -n "$_sv_snap" ] && [ -f "$_sv_snap" ]; then
                cp -f "$_sv_snap" "$BIFROST_STATE/tailscaled.state"
                chmod 600 "$BIFROST_STATE/tailscaled.state"
            fi
            daemon_start
            fail update_verify_failed
            return 1
        fi
    fi

    job_phase update finalize 95
    if [ -n "$_sv_new_man" ] && [ -r "$_sv_new_man" ]; then
        _upd_write_installed_manifest "$_sv_new_man" "$_sv_new_arch" || return 1
    fi

    _sv_kept_prev=false
    if [ "$_sv_save_prev" = 1 ] && [ "$_sv_had_old" = 1 ] && [ -f "$BIFROST_BIN/bifrostd.old" ]; then
        if gzip -c "$BIFROST_BIN/bifrostd.old" >"$_sv_dir/bifrostd.prev.gz" 2>/dev/null; then
            rm -f "$BIFROST_BIN/bifrostd.old"
            _sv_pgz_size=$(file_size "$_sv_dir/bifrostd.prev.gz" 2>/dev/null || echo 0)
            _sv_pgz_kb=$(_upd_bytes_to_kb "$_sv_pgz_size")
            _sv_avail=$(_upd_free_kb "$BIFROST_BIN" 2>/dev/null || echo "")
            if [ -z "$_sv_avail" ] || [ "$_sv_avail" -ge "$_sv_pgz_kb" ]; then
                if cp "$_sv_dir/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.gz.tmp.$$" 2>/dev/null &&
                    mv -f "$BIFROST_BIN/bifrostd.prev.gz.tmp.$$" "$BIFROST_BIN/bifrostd.prev.gz"; then
                    if [ -n "$_sv_old_man" ] && [ -r "$_sv_old_man" ]; then
                        cp "$_sv_old_man" "$BIFROST_BIN/bifrostd.prev.json.tmp.$$" 2>/dev/null &&
                            mv -f "$BIFROST_BIN/bifrostd.prev.json.tmp.$$" "$BIFROST_BIN/bifrostd.prev.json"
                    else
                        rm -f "$BIFROST_BIN/bifrostd.prev.json"
                    fi
                    _sv_kept_prev=true
                else
                    rm -f "$BIFROST_BIN/bifrostd.prev.gz.tmp.$$"
                fi
            else
                log update "not enough space to keep prev.gz (avail=${_sv_avail}KB need=${_sv_pgz_kb}KB)"
                rm -f "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
            fi
        else
            rm -f "$BIFROST_BIN/bifrostd.old" "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
        fi
    else
        rm -f "$BIFROST_BIN/bifrostd.old"
        if [ "$_sv_save_prev" = 0 ]; then
            rm -f "$BIFROST_BIN/bifrostd.prev.gz" "$BIFROST_BIN/bifrostd.prev.json"
        fi
    fi

    job_data update "{\"kept_prev\":$_sv_kept_prev}"
    return 0
}

# ---- Job body (contract section 4 & 6.2) ----

_upd_job_check() {
    _jc_dir="$BIFROST_RUN/update"
    rm -rf "$_jc_dir"
    mkdir -p "$_jc_dir" || { fail internal; return 1; }

    job_data update '{"action":"check","latest":null,"kept_prev":false}'
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

    atomic_write "$BIFROST_RUN/core_latest.json" 644 <"$_jc_json" || {
        rm -rf "$_jc_dir"
        fail internal
        return 1
    }

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
    _jr_dir="$BIFROST_RUN/update"
    rm -rf "$_jr_dir"
    mkdir -p "$_jr_dir" || { fail internal; return 1; }

    job_data update "{\"action\":\"$_jr_action\",\"latest\":null,\"kept_prev\":false}"
    _upd_arch_supported "$_jr_arch" || { rm -rf "$_jr_dir"; return 1; }

    _jr_cur_arch=$(_upd_installed_arch)
    if [ "$_jr_action" = arch ] && [ "$_jr_arch" != "$_jr_cur_arch" ]; then
        _jr_smode=ge
    else
        _jr_smode=gt
    fi

    job_phase update manifest 5
    _jr_json="$_jr_dir/core.json"
    _jr_sig="$_jr_dir/core.json.sig"
    if ! _upd_download "$BIFROST_CHANNEL_URL" "$_jr_json" ||
        ! _upd_download "${BIFROST_CHANNEL_URL}.sig" "$_jr_sig"; then
        rm -rf "$_jr_dir"
        return 1
    fi

    job_phase update verify_manifest 15
    if ! manifest_verify "$_jr_json" "$_jr_sig"; then
        rm -rf "$_jr_dir"
        return 1
    fi
    if ! _upd_parse_manifest "$_jr_json" "$_jr_arch" "$_jr_smode" 1; then
        rm -rf "$_jr_dir"
        return 1
    fi

    atomic_write "$BIFROST_RUN/core_latest.json" 644 <"$_jr_json"
    _jr_ldata=$(jq -cn --argjson latest "$_UM_LATEST_JSON" '{latest:$latest}')
    job_data update "$_jr_ldata"

    job_phase update space 20
    if ! _upd_check_tmp_space "$_UM_SIZE" || ! _upd_check_bin_space "$_UM_RAW_SIZE" allow_drop; then
        rm -rf "$_jr_dir"
        return 1
    fi

    job_phase update download 30
    _jr_gz="$_jr_dir/core.gz"
    _jr_url="$BIFROST_RELEASE_BASE/$_UM_TAG/$_UM_FILE"
    if ! _upd_download "$_jr_url" "$_jr_gz"; then
        rm -rf "$_jr_dir"
        return 1
    fi

    job_phase update verify 50
    _jr_got_size=$(file_size "$_jr_gz" 2>/dev/null || echo 0)
    _jr_got_sha=$(sha256_file "$_jr_gz" 2>/dev/null || echo "")
    if [ "$_jr_got_size" != "$_UM_SIZE" ] || [ "$_jr_got_sha" != "$_UM_SHA" ]; then
        log update "gz hash/size mismatch: size=$_jr_got_size/$_UM_SIZE"
        rm -rf "$_jr_dir"
        fail hash_mismatch
        return 1
    fi

    job_phase update unpack 60
    _jr_new="$BIFROST_BIN/bifrostd.new"
    rm -f "$_jr_new"
    if ! gunzip -c "$_jr_gz" >"$_jr_new" 2>/dev/null; then
        rm -f "$_jr_new"
        rm -rf "$_jr_dir"
        fail no_space
        return 1
    fi
    chmod 755 "$_jr_new"

    _jr_raw_size=$(file_size "$_jr_new" 2>/dev/null || echo 0)
    _jr_raw_sha=$(sha256_file "$_jr_new" 2>/dev/null || echo "")
    if [ "$_jr_raw_size" != "$_UM_RAW_SIZE" ] || [ "$_jr_raw_sha" != "$_UM_RAW_SHA" ]; then
        rm -f "$_jr_new"
        rm -rf "$_jr_dir"
        fail hash_mismatch
        return 1
    fi

    job_phase update test 70
    _jr_ver=$(_upd_bin_version "$_jr_new" 2>/dev/null || echo "")
    if [ "$_jr_ver" != "$_UM_TS" ]; then
        rm -f "$_jr_new"
        rm -rf "$_jr_dir"
        fail core_test_failed
        return 1
    fi

    if ! _upd_swap_and_verify "$_jr_new" "$_jr_dir" 1 "$_jr_json" "$_jr_arch"; then
        rm -f "$_jr_new"
        rm -rf "$_jr_dir"
        return 1
    fi

    rm -rf "$_jr_dir"
    log update "$_jr_action complete: $_UM_TS (serial=$_UM_SERIAL arch=$_jr_arch)"
    return 0
}

_upd_job_rollback() {
    _rb_dir="$BIFROST_RUN/update"
    rm -rf "$_rb_dir"
    mkdir -p "$_rb_dir" || { fail internal; return 1; }

    job_data update '{"action":"rollback","latest":null,"kept_prev":false}'
    _rb_prev_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _rb_prev_man="$BIFROST_BIN/bifrostd.prev.json"
    if [ ! -r "$_rb_prev_gz" ] || [ ! -s "$_rb_prev_gz" ]; then
        rm -rf "$_rb_dir"
        fail no_prev
        return 1
    fi

    _rb_has_man=0
    _rb_arch=$(_upd_installed_arch)
    _rb_need_bytes=0
    if [ -r "$_rb_prev_man" ]; then
        _rb_arch_m=$(jq -r 'if (.arch | type == "string") then .arch elif (.assets | type == "object") and ((.assets | length) == 1) then (.assets | keys[0]) else "" end' "$_rb_prev_man" 2>/dev/null)
        valid_arch "$_rb_arch_m" && _rb_arch=$_rb_arch_m
        if _upd_parse_manifest "$_rb_prev_man" "$_rb_arch" any 0; then
            _rb_has_man=1
            _rb_need_bytes=$_UM_RAW_SIZE
        fi
    fi
    if [ "$_rb_need_bytes" -eq 0 ]; then
        _rb_gz_sz=$(file_size "$_rb_prev_gz" 2>/dev/null || echo 0)
        _rb_need_bytes=$((_rb_gz_sz * 3))
    fi

    job_phase update space 20
    if ! _upd_check_bin_space "$_rb_need_bytes" keep_prev; then
        rm -rf "$_rb_dir"
        return 1
    fi

    job_phase update unpack 50
    _rb_new="$BIFROST_BIN/bifrostd.new"
    rm -f "$_rb_new"
    if ! gunzip -c "$_rb_prev_gz" >"$_rb_new" 2>/dev/null; then
        rm -f "$_rb_new"
        rm -rf "$_rb_dir"
        fail no_space
        return 1
    fi
    chmod 755 "$_rb_new"

    if [ "$_rb_has_man" = 1 ]; then
        _rb_raw_size=$(file_size "$_rb_new" 2>/dev/null || echo 0)
        _rb_raw_sha=$(sha256_file "$_rb_new" 2>/dev/null || echo "")
        if [ "$_rb_raw_size" != "$_UM_RAW_SIZE" ] || [ "$_rb_raw_sha" != "$_UM_RAW_SHA" ]; then
            rm -f "$_rb_new"
            rm -rf "$_rb_dir"
            fail hash_mismatch
            return 1
        fi
    fi

    job_phase update test 65
    _rb_ver=$(_upd_bin_version "$_rb_new" 2>/dev/null || echo "")
    if [ -z "$_rb_ver" ]; then
        rm -f "$_rb_new"
        rm -rf "$_rb_dir"
        fail core_test_failed
        return 1
    fi
    if [ "$_rb_has_man" = 1 ] && [ "$_rb_ver" != "$_UM_TS" ]; then
        rm -f "$_rb_new"
        rm -rf "$_rb_dir"
        fail core_test_failed
        return 1
    fi

    _rb_man_arg=""
    [ "$_rb_has_man" = 1 ] && _rb_man_arg=$_rb_prev_man
    if ! _upd_swap_and_verify "$_rb_new" "$_rb_dir" 0 "$_rb_man_arg" "$_rb_arch"; then
        rm -f "$_rb_new"
        rm -rf "$_rb_dir"
        return 1
    fi

    rm -rf "$_rb_dir"
    log update "rollback complete: $_rb_ver"
    return 0
}

job_update() {
    case "${1:-}" in
        check) _upd_job_check ;;
        update) _upd_job_install_remote update "$(_upd_installed_arch)" ;;
        arch) _upd_job_install_remote arch "${2:-}" ;;
        rollback) _upd_job_rollback ;;
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
