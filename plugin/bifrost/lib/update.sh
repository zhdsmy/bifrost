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
: "${BIFROST_UPDATE_METADATA_BYTES:=65536}"
# Free space kept beyond one spare core before a rollback archive is kept: the
# software center refuses upgrades with less than 2 MB free (PLAN 2.4 item 5).
: "${BIFROST_PREV_MARGIN_KB:=2048}"

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
    case "$(_upd_kernel_arch)" in
        aarch64) printf 'arm64\n' ;;
        *) printf 'arm\n' ;;
    esac
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

_upd_installed_variant() {
    if [ -r "$BIFROST_MANIFEST" ]; then
        _uiv_v=$(jq -r '.variant // "normal"' "$BIFROST_MANIFEST" 2>/dev/null)
        case "$_uiv_v" in normal | upx) printf '%s\n' "$_uiv_v"; return 0 ;; esac
    fi
    printf 'normal\n'
}

# Installed serial describes the actual core. The channel floor survives
# rollbacks and can also record a checked release before the user installs it.
_upd_channel_floor() {
    _cf_file="$BIFROST_HOME/core-channel.serial"
    _cf_seen=0
    if [ -e "$_cf_file" ]; then
        _cf_seen=$(cat "$_cf_file") && valid_uint "$_cf_seen" || return 1
    elif [ -s "$BIFROST_RUN/core_latest.json" ]; then
        # Upgrade from installations that only kept a verified channel cache.
        _cf_seen=$(jq -er '.serial' "$BIFROST_RUN/core_latest.json") && valid_uint "$_cf_seen" || return 1
    fi
    _cf_inst=$(_upd_installed_serial)
    [ "$_cf_inst" -le "$_cf_seen" ] || _cf_seen=$_cf_inst
    printf '%s\n' "$_cf_seen"
}

_upd_remember_serial() {
    _rs_floor=$(_upd_channel_floor) || { fail internal; return 1; }
    [ "$1" -le "$_rs_floor" ] || _rs_floor=$1
    _rs_file="$BIFROST_HOME/core-channel.serial"
    [ "$(cat "$_rs_file" 2>/dev/null)" != "$_rs_floor" ] || return 0
    if ! atomic_write "$_rs_file" 600 <<EOF
$_rs_floor
EOF
    then
        fail internal
        return 1
    fi
    sync
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

_upd_plugin_channel_url() {
    case "$BIFROST_CHANNEL_URL" in
        */core.json) printf '%splugin.json\n' "${BIFROST_CHANNEL_URL%core.json}" ;;
        *) printf '%s/plugin.json\n' "${BIFROST_CHANNEL_URL%/}" ;;
    esac
}

_upd_parse_plugin_manifest() {
    _upp_json=$1
    _upp_fields=$(jq -ers '
        select(length == 1) | .[0] |
        select(type == "object" and .schema == 1 and
            (.version | type == "string" and test("^(0|[1-9][0-9]{0,9})(\\.(0|[1-9][0-9]{0,9})){2}\\z")) and
            (.tag == ("v" + .version)) and
            (.url | type == "string" and startswith("https://"))) |
        [.version, .tag, .url] | @tsv
    ' "$_upp_json" 2>/dev/null) || return 1
    IFS='	' read -r _UP_VERSION _UP_TAG _UP_URL <<EOF
$_upp_fields
EOF
    _upd_valid_semver "$_UP_VERSION"
}

_upd_plugin_check() {
    _UP_STATUS=unknown
    _UP_UPDATE_JSON=null
    _UP_JSON="$_jc_dir/plugin.json"
    _UP_SIG="$_jc_dir/plugin.json.sig"
    if ! _upd_download "$(_upd_plugin_channel_url)" "$_UP_JSON" ||
        ! _upd_download "$(_upd_plugin_channel_url).sig" "$_UP_SIG"; then
        _UP_ERROR=download_failed
        return 0
    fi
    if ! manifest_verify "$_UP_JSON" "$_UP_SIG" || ! _upd_parse_plugin_manifest "$_UP_JSON"; then
        _UP_ERROR=bad_manifest
        return 0
    fi
    _UP_CURRENT=$(_upd_plugin_version 2>/dev/null || echo "")
    if ! _upd_valid_semver "$_UP_CURRENT"; then
        _UP_ERROR=internal
        return 0
    fi
    _UP_STATUS=ok
    _UP_ERROR=""
    if ! _upd_ver_ge "$_UP_CURRENT" "$_UP_VERSION"; then
        _UP_UPDATE_JSON=$(jq -cn --arg v "$_UP_VERSION" --arg t "$_UP_TAG" --arg u "$_UP_URL" \
            '{version:$v,tag:$t,url:$u}')
    fi
}

_upd_record_check() {
    _urc_time=$1
    _urc_core_status=$2
    _urc_core_error=$3
    _urc_core_latest=${4:-null}
    _urc_plugin_status=${5:-unknown}
    _urc_plugin_error=${6:-}
    _urc_plugin_update=${7:-null}
    _urc_file="$BIFROST_HOME/core-check.json"
    mkdir -p "$BIFROST_HOME" || return 1
    jq -cn \
        --argjson checked "$_urc_time" \
        --arg core_status "$_urc_core_status" \
        --arg core_error "$_urc_core_error" \
        --argjson core_latest "$_urc_core_latest" \
        --arg plugin_status "$_urc_plugin_status" \
        --arg plugin_error "$_urc_plugin_error" \
        --argjson plugin_update "$_urc_plugin_update" \
        '{schema:1, checked:$checked,
          core:{status:$core_status,error:(if $core_error == "" then null else $core_error end),latest:$core_latest},
          plugin:{status:$plugin_status,error:(if $plugin_error == "" then null else $plugin_error end),update:$plugin_update}}' |
        json_write "$_urc_file"
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

# core_storage: describe the filesystem that holds $BIFROST_BIN in _CS_KIND,
# _CS_FS, _CS_TOTAL_KB and _CS_FREE_KB. _CS_KIND is "internal" for router flash
# (jffs2, ubifs, yaffs, or an mtd/ubi device), "external" for a USB disk
# (/dev/sd*, also when USB2JFFS mounts it on /jffs), and "unknown" otherwise.
# Returns 1 with empty numbers when df gives nothing usable.
core_storage() {
    _CS_KIND=unknown
    _CS_FS=""
    _CS_TOTAL_KB=""
    _CS_FREE_KB=""
    _cs_d=$BIFROST_BIN
    [ -d "$_cs_d" ] || _cs_d=$BIFROST_HOME
    [ -d "$_cs_d" ] || _cs_d=$BIFROST_KSROOT
    # BusyBox df prints a long device name on its own line, so join the fields
    # and count from the front: device, total, used, available.
    _cs_df=$(df -k "$_cs_d" 2>/dev/null |
        awk 'NR > 1 { for (i = 1; i <= NF; i++) f[++n] = $i } END { if (n >= 4) print f[1], f[2], f[4] }')
    [ -n "$_cs_df" ] || return 1
    _cs_dev=${_cs_df%% *}
    _cs_df=${_cs_df#* }
    _cs_total=${_cs_df%% *}
    _cs_free=${_cs_df#* }
    valid_uint "$_cs_total" && _CS_TOTAL_KB=$_cs_total
    valid_uint "$_cs_free" && _CS_FREE_KB=$_cs_free
    _CS_FS=$(awk -v d="$_cs_dev" '$1 == d { print $3; exit }' "$BIFROST_MOUNTS" 2>/dev/null)
    case "$_CS_FS" in
        jffs2 | ubifs | yaffs | yaffs2) _CS_KIND=internal ;;
        *)
            case "$_cs_dev" in
                /dev/mtd* | mtd:* | ubi*) _CS_KIND=internal ;;
                /dev/sd*) _CS_KIND=external ;;
            esac
            ;;
    esac
    [ -n "$_CS_FREE_KB" ]
}

# _upd_prev_fits <archive bytes>: 0 when the previous-core archive may be
# kept. Never on internal flash: it is small and the firmware and other
# plugins share it. Elsewhere the free space left after the archive must
# still hold one more copy of the current core (the next update unpacks a new
# core beside it) plus the 2 MB that the software center requires for
# upgrades. Sets _UPF_WHY to internal or space when it returns 1.
_upd_prev_fits() {
    _UPF_WHY=""
    core_storage || :
    if [ "$_CS_KIND" = internal ]; then
        _UPF_WHY=internal
        return 1
    fi
    [ -n "$_CS_FREE_KB" ] || return 0
    _upf_core=$(file_size "$BIFROST_CORE" 2>/dev/null) || _upf_core=0
    _upf_need=$(($(_upd_bytes_to_kb "$1") + $(_upd_bytes_to_kb "$_upf_core") + BIFROST_PREV_MARGIN_KB))
    [ "$_CS_FREE_KB" -ge "$_upf_need" ] && return 0
    _UPF_WHY=space
    return 1
}

# core_prev_drop: remove the previous-core archive. The archive is the
# availability flag (see _upd_publish_prev), so remove it before its metadata.
core_prev_drop() {
    if ! rm -f "$BIFROST_BIN/bifrostd.prev.gz" || ! rm -f "$BIFROST_BIN/bifrostd.prev.json"; then
        fail internal
        return 1
    fi
    sync
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
_upd_stash_prev() {
    _sp_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _sp_man="$BIFROST_BIN/bifrostd.prev.json"
    [ -f "$_sp_gz" ] || return 1
    cp "$_sp_gz" "$_ut_dir/stash.gz" &&
        { [ ! -e "$_sp_man" ] || cp "$_sp_man" "$_ut_dir/stash.json"; } &&
        rm -f "$_sp_gz" "$_sp_man"
}

_upd_unpack_candidate() {
    mkdir -p "$BIFROST_BIN" || { fail internal; return 1; }
    _uc_src=$1
    _uc_free=$(_upd_free_kb "$BIFROST_BIN") || _uc_free=""
    if [ -n "$_uc_free" ] && [ "$_uc_free" -lt "$(_upd_bytes_to_kb "$2")" ]; then
        _upd_stash_prev || :
    fi
    if [ "$1" = "$BIFROST_BIN/bifrostd.prev.gz" ] && [ ! -e "$1" ]; then _uc_src="$_ut_dir/stash.gz"; fi
    _upd_unpack_gz "$_uc_src" "$_ut_new" && return 0
    [ "$BIFROST_ERR" = no_space ] && _upd_stash_prev || return 1
    if [ "$1" = "$BIFROST_BIN/bifrostd.prev.gz" ]; then _uc_src="$_ut_dir/stash.gz"; fi
    BIFROST_ERR=""
    _upd_unpack_gz "$_uc_src" "$_ut_new"
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

# _upd_parse_manifest <json> <arch> <serial_mode: gt|ge|any> <check_plugin: 0|1> [variant]
# Sets _UM_SERIAL, _UM_TS, _UM_REV, _UM_TAG, _UM_MIN_PLUGIN,
# _UM_FILE, _UM_SIZE, _UM_SHA, _UM_RAW_SIZE, _UM_RAW_SHA, _UM_VARIANT,
# _UM_LATEST_JSON.
_upd_parse_manifest() {
    _pm_json=$1
    _pm_arch=$2
    _pm_smode=$3
    _pm_cplug=$4
    _pm_variant=${5:-auto}
    if [ "$_pm_variant" = auto ]; then
        _pm_variant=$(
            jq -r 'if .variant == "upx" then "upx" else "normal" end' "$_pm_json" 2>/dev/null
        ) || _pm_variant=normal
    fi
    case "$_pm_variant" in normal | upx) ;; *) fail bad_manifest; return 1 ;; esac

    # Validate every asset while the original JSON types and string boundaries
    # are available. Only the checked printable fields cross into the shell.
    _pm_fields=$(jq -ers --arg arch "$_pm_arch" --arg variant "$_pm_variant" '
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
        def asset_set:
            if $variant == "upx" then
                if (.upx_assets | type) == "object" then .upx_assets
                elif .variant == "upx" then .assets
                else {} end
            else .assets end;
        select(length == 1) | .[0] |
        select(type == "object" and .schema == 1 and (.serial | positive) and
            (.tailscale | version) and (.min_plugin | version) and (.revision | positive) and
            .tag == ("core-" + .tailscale + "-" + (.revision | tostring)) and
            (.assets | type == "object" and all(to_entries[]; asset)) and
            (asset_set | type == "object" and all(to_entries[]; asset))) |
        [.serial, .tailscale, .revision, .tag, .min_plugin, $variant,
         (asset_set[$arch] | .file // "-", .size // 0, .sha256 // "-", .raw_size // 0, .raw_sha256 // "-")] |
        @tsv
    ' "$_pm_json" 2>/dev/null) || { fail bad_manifest; return 1; }
    read -r _UM_SERIAL _UM_TS _UM_REV _UM_TAG _UM_MIN_PLUGIN _UM_VARIANT _UM_FILE _UM_SIZE _UM_SHA _UM_RAW_SIZE _UM_RAW_SHA <<EOF
$_pm_fields
EOF

    if [ "$_pm_smode" != any ]; then
        _pm_floor=$(_upd_channel_floor) || { fail internal; return 1; }
        [ "$_UM_SERIAL" -ge "$_pm_floor" ] || { fail old_serial; return 1; }
    fi
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
        --arg variant "$_UM_VARIANT" \
        '{tailscale:$ts, revision:$rev, serial:$ser, tag:$tag, variant:$variant}') || {
        fail internal
        return 1
    }
    return 0
}

# Write the installed representation to a staging file on its destination FS.
_upd_stage_manifest() {
    _usm_variant=${3:-normal}
    { jq -ec --arg arch "$2" --arg variant "$_usm_variant" '
        .arch = $arch |
        .variant = $variant |
        .assets = {($arch): (if $variant == "upx" and (.upx_assets | type) == "object"
                             then .upx_assets[$arch] else .assets[$arch] end)} |
        del(.upx_assets)
    ' "$1" >"$4" &&
        chmod 644 "$4"; } || { fail internal; return 1; }
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
    _dl_rc=0
    run_timeout "$((BIFROST_UPDATE_MAX_TIME + 15))" \
        curl -fsSL \
        --connect-timeout "$BIFROST_UPDATE_CONNECT_TIMEOUT" \
        --max-time "$BIFROST_UPDATE_MAX_TIME" \
        --retry "$BIFROST_UPDATE_RETRY" --max-filesize "${3:-$BIFROST_UPDATE_METADATA_BYTES}" \
        -o "$_dl_out" "$_dl_eff" 2>/dev/null || _dl_rc=$?
    if [ "$_dl_rc" -ne 0 ]; then
        rm -f "$_dl_out"
        if [ "$_dl_rc" = 63 ] && [ -n "${3:-}" ]; then fail hash_mismatch; return 1; fi
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
    daemon_running && { fail already_running; return 1; }
    core_recover stopped && _upd_transaction _upd_install_package "$@"
}

_upd_install_package() {
    _ci_gz=$1
    _ci_man=$2
    _ci_arch=$3
    _upd_arch_supported "$_ci_arch" || return 1
    [ -r "$_ci_gz" ] && [ -r "$_ci_man" ] || { fail bad_manifest; return 1; }
    _upd_parse_manifest "$_ci_man" "$_ci_arch" any 0 || return 1

    # The package core wins unless the installed one is newer or the same
    # file; an identical core is not rewritten to flash.
    if [ -x "$BIFROST_CORE" ] && {
        [ "$(_upd_installed_serial)" -gt "$_UM_SERIAL" ] ||
            [ "$(jq -r '[.assets[]][0].raw_sha256 // ""' "$BIFROST_MANIFEST" 2>/dev/null)" = "$_UM_RAW_SHA" ]
    }; then
        ln -sf bifrostd "$BIFROST_CLI" || { fail internal; return 1; }
        return 0
    fi
    _upd_unpack_candidate "$_ci_gz" "$_UM_RAW_SIZE" &&
        _upd_check_raw "$_ut_new" &&
        _upd_test_version "$_ut_new" &&
        _upd_stage_manifest "$_ci_man" "$_ci_arch" "$_UM_VARIANT" "$_ut_manifest" &&
        _upd_begin_swap package 0 && _upd_replace && _upd_mark committed
}

_upd_check_raw() {
    [ "$(file_size "$1")" = "$_UM_RAW_SIZE" ] &&
        [ "$(sha256_file "$1")" = "$_UM_RAW_SHA" ] || { fail hash_mismatch; return 1; }
}

_upd_test_version() {
    [ "$(_upd_bin_version "$1")" = "$_UM_TS" ] || { fail core_test_failed; return 1; }
}

# The caller holds the state lock. The phase and rollback inputs live on
# flash. Flush data before publishing each phase and before consuming backups.
_upd_mark() {
    sync
    if ! atomic_write "$_ut_j/phase" 600 <<EOF
$1
EOF
    then fail internal; return 1; fi
    sync
}

_upd_begin_swap() {
    printf '%s\n' "$1" >"$_ut_j/action" || { fail internal; return 1; }
    if [ -f "$BIFROST_MANIFEST" ]; then
        cp -p "$BIFROST_MANIFEST" "$_ut_j/installed.json" || { fail internal; return 1; }
    fi
    if [ -f "$BIFROST_CORE" ]; then _upd_backup_core_old || return 1; fi
    if [ "$2" = 1 ]; then
        printf '%s\n' "$_sv_state" >"$_ut_j/running" || { fail internal; return 1; }
        if [ -f "$BIFROST_STATE/tailscaled.state" ]; then
            (umask 077 && cat "$BIFROST_STATE/tailscaled.state" >"$_ut_j/state") || { fail internal; return 1; }
        fi
    fi
    _upd_mark stopping
}

_upd_replace() {
    _upd_mark replacing || return 1
    if ! ln -sf bifrostd "$BIFROST_CLI" || ! mv -f "$_ut_new" "$BIFROST_CORE" ||
        ! mv -f "$_ut_manifest" "$BIFROST_MANIFEST"; then
        fail internal
        return 1
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

# Never replace files after a stop error. A failed firewall/DNS cleanup can
# leave the daemon stopped, so restore its original availability in either case.
_upd_stop() {
    daemon_stop && return 0
    _us_error=${BIFROST_ERR:-internal}
    daemon_start || return 1
    fail "$_us_error"
}

_upd_restore_file() {
    if [ -f "$1" ]; then
        cmp -s "$1" "$2" || atomic_write "$2" "$3" <"$1"
    else
        rm -f "$2"
    fi
}

# Keep backup inputs until every restore has succeeded. A second recovery is
# safe after interruption even between restoring the executable and its metadata.
_upd_restore_swap() {
    _rr_error=""
    if daemon_running; then _upd_stop || return 1; fi
    if [ -f "$BIFROST_BIN/bifrostd.old" ]; then
        if [ ! "$BIFROST_BIN/bifrostd.old" -ef "$BIFROST_CORE" ]; then
            rm -f "$_ut_new"
            if ! { ln "$BIFROST_BIN/bifrostd.old" "$_ut_new" 2>/dev/null ||
                    cp -p "$BIFROST_BIN/bifrostd.old" "$_ut_new"; } ||
                ! mv -f "$_ut_new" "$BIFROST_CORE"; then _rr_error=internal; fi
        fi
    else
        rm -f "$BIFROST_CORE" || _rr_error=internal
    fi
    if [ -z "$_rr_error" ]; then
        _upd_restore_file "$_ut_j/installed.json" "$BIFROST_MANIFEST" 644 || _rr_error=internal
    fi
    if [ -f "$_ut_j/running" ]; then
        _upd_restore_file "$_ut_j/state" "$BIFROST_STATE/tailscaled.state" 600 || _rr_error=state_not_writable
        if [ "${1:-}" != stopped ]; then
            daemon_start || return 1
            _upd_verify_running "$(cat "$_ut_j/running")" || { fail start_failed; return 1; }
        fi
    fi
    [ -z "$_rr_error" ] || { fail "$_rr_error"; return 1; }
}

_upd_swap_and_verify() {
    job_phase update snapshot 75
    _sv_running=0
    if daemon_running; then
        _sv_running=1
        _sv_state=$(backend_state) || { fail cli_failed; return 1; }
    fi
    _upd_begin_swap "$1" "$_sv_running" || return 1
    job_phase update swap 80
    if [ "$_sv_running" = 1 ]; then daemon_stop || return 1; fi
    _upd_replace || return 1
    if [ "$_sv_running" = 1 ]; then
        job_phase update verify_running 85
        if ! daemon_start || ! _upd_verify_running "$_sv_state"; then
            job_phase update rollback 90
            fail update_verify_failed
            return 1
        fi
    fi
    job_phase update finalize 95
    _upd_mark committed
}

# A committed update may release the old inode and previous archive to make
# room. Re-read df after the obsolete archive has actually been unlinked.
_upd_finish_prev() {
    _fp_action=$(cat "$_ut_j/action") || return 1
    [ "$_fp_action" != package ] || return 0
    _fp_kept=false
    _fp_why=""
    _fp_gz="$BIFROST_BIN/bifrostd.prev.gz"
    _fp_man="$BIFROST_BIN/bifrostd.prev.json"
    core_storage || :
    if [ "$_fp_action" = keep ] && [ "$_CS_KIND" = internal ]; then
        # Never kept on internal flash, so do not spend time compressing one.
        _fp_why=internal
    elif [ "$_fp_action" = keep ] && [ -s "$_ut_j/installed.json" ] &&
        jq -e '.serial > 0' "$_ut_j/installed.json" >/dev/null; then
        if [ -f "$BIFROST_BIN/bifrostd.old" ]; then
            rm -f "$_ut_dir/previous.gz"
            if gzip -c "$BIFROST_BIN/bifrostd.old" >"$_ut_dir/previous.gz"; then
                rm -f "$_fp_gz" "$_fp_man" "$BIFROST_BIN/bifrostd.old" || return 1
            else
                rm -f "$_ut_dir/previous.gz"
            fi
        elif [ -s "$_fp_gz" ] && cmp -s "$_ut_j/installed.json" "$_fp_man"; then
            # Archive is published last. Replay after its rename preserves it.
            _fp_kept=true
        fi
        if [ "$_fp_kept" = false ] && [ -s "$_ut_dir/previous.gz" ]; then
            _fp_bytes=$(($(file_size "$_ut_dir/previous.gz") + $(file_size "$_ut_j/installed.json")))
            if ! _upd_prev_fits "$_fp_bytes"; then
                _fp_why=$_UPF_WHY
            elif _upd_publish_prev "$_ut_dir/previous.gz" "$_ut_j/installed.json"; then
                _fp_kept=true
            fi
        fi
    fi
    if [ "$_fp_kept" = false ]; then
        [ -z "$_fp_why" ] || log update "previous core not kept: $_fp_why"
        rm -f "$_fp_gz" "$_fp_man" || return 1
    fi
    if [ -f "$(job_file update)" ]; then job_data update "{\"kept_prev\":$_fp_kept}"; fi
    return 0
}

_upd_paths() {
    _ut_j="$BIFROST_HOME/.core-update"
    _ut_dir="$BIFROST_RUN/update-work"
    _ut_new="$BIFROST_BIN/bifrostd.new"
    _ut_manifest="$_ut_j/candidate.json"
}

# Public recovery entry for callers holding the state lock. Every core job and
# package install invokes it before selecting the installed arch or serial.
core_recover() {
    _upd_paths
    [ -d "$_ut_j" ] || [ -d "$_ut_dir" ] || return 0
    _cr_phase=""
    if [ -f "$_ut_j/phase" ]; then _cr_phase=$(cat "$_ut_j/phase") || { fail internal; return 1; }; fi
    case "$_cr_phase" in
        replacing) _upd_restore_swap "${1:-}" || return 1 ;;
        stopping)
            if [ -f "$_ut_j/running" ] && [ "${1:-}" != stopped ]; then daemon_start || return 1; fi
            ;;
        committed)
            { mkdir -p "$_ut_dir" && _upd_finish_prev; } || { fail internal; return 1; }
            ;;
        '') ;;
        *) fail internal; return 1 ;;
    esac
    rm -f "$_ut_new" || { fail internal; return 1; }
    if [ "$_cr_phase" != committed ] && [ -f "$_ut_dir/stash.gz" ] && [ ! -f "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        _upd_publish_prev "$_ut_dir/stash.gz" "$_ut_dir/stash.json" || { fail internal; return 1; }
    fi
    rm -f "$_ut_dir/stash.gz" "$_ut_dir/stash.json" || { fail internal; return 1; }
    # Disarm durably before deleting the inputs needed to replay the journal.
    if [ -f "$_ut_j/phase" ]; then sync; rm -f "$_ut_j/phase" || { fail internal; return 1; }; sync; fi
    rm -f "$BIFROST_BIN/bifrostd.old" "$BIFROST_BIN"/bifrostd.prev.*.tmp.[0-9]* \
        "$BIFROST_MANIFEST".tmp.[0-9]* "$BIFROST_STATE"/tailscaled.state.tmp.[0-9]* || { fail internal; return 1; }
    rm -rf "$_ut_dir" "$_ut_j" || { fail internal; return 1; }
}

_upd_transaction() {
    _upd_paths
    { mkdir -p "$BIFROST_RUN" "$BIFROST_HOME" &&
        (umask 077 && mkdir "$_ut_j" "$_ut_dir"); } || { fail internal; return 1; }
    _ut_error=""
    "$@" || _ut_error=${BIFROST_ERR:-internal}
    core_recover || { log update "core recovery pending: ${BIFROST_ERR:-internal}"; return 1; }
    [ -z "$_ut_error" ] || { fail "$_ut_error"; return 1; }
}

_upd_interrupted() {
    trap '' HUP INT TERM
    _ui_error=internal
    core_recover || _ui_error=${BIFROST_ERR:-internal}
    rm -rf "$BIFROST_RUN/update"
    job_end update fail "$_ui_error"
    if [ "$(cat "$BIFROST_RUN/lock.state/pid" 2>/dev/null)" = "$$" ]; then lock_release state; fi
    exit 1
}

# ---- Job body (contract section 4 & 6.2) ----

_upd_check_fail() {
    _ucf_code=${BIFROST_ERR:-internal}
    _upd_record_check "$_jc_now" error "$_ucf_code" null unknown "" null || :
    rm -rf "$_jc_dir"
    fail "$_ucf_code"
    return 1
}

_upd_job_check() {
    _jc_now=$(now)
    _jc_dir="$BIFROST_RUN/update"
    rm -rf "$_jc_dir"
    mkdir -p "$_jc_dir" || { fail internal; return 1; }

    job_data update '{"action":"check","latest":null,"up_to_date":false,"kept_prev":false}'
    _jc_arch=$(_upd_installed_arch)
    _jc_variant=$(_upd_installed_variant)
    _upd_arch_supported "$_jc_arch" || { _upd_check_fail; return 1; }

    job_phase update manifest 20
    _jc_json="$_jc_dir/core.json"
    _jc_sig="$_jc_dir/core.json.sig"
    if ! _upd_download "$BIFROST_CHANNEL_URL" "$_jc_json" ||
        ! _upd_download "${BIFROST_CHANNEL_URL}.sig" "$_jc_sig"; then
        _upd_check_fail
        return 1
    fi

    job_phase update verify_manifest 60
    if ! manifest_verify "$_jc_json" "$_jc_sig"; then
        _upd_check_fail
        return 1
    fi
    if ! _upd_parse_manifest "$_jc_json" "$_jc_arch" ge 1 "$_jc_variant"; then
        _upd_check_fail
        return 1
    fi

    _upd_plugin_check
    _jc_plugin_status=$_UP_STATUS
    _jc_plugin_error=$_UP_ERROR
    _jc_plugin_update=$_UP_UPDATE_JSON

    if ! _upd_remember_serial "$_UM_SERIAL"; then _upd_check_fail; return 1; fi
    if ! atomic_write "$BIFROST_RUN/core_latest.json" 644 <"$_jc_json"; then
        rm -f "$BIFROST_RUN/core_latest.json.tmp.$$"
        fail internal
        _upd_check_fail
        return 1
    fi

    _jc_cur_ser=$(_upd_installed_serial)
    if [ "$_UM_SERIAL" -gt "$_jc_cur_ser" ]; then
        _jc_utd=false
    else
        _jc_utd=true
    fi
    _jc_data=$(jq -cn --argjson latest "$_UM_LATEST_JSON" --argjson utd "$_jc_utd" \
        --argjson plugin_update "$_jc_plugin_update" \
        '{latest:$latest, up_to_date:$utd, plugin_update:$plugin_update}')
    job_data update "$_jc_data"
    _upd_record_check "$_jc_now" ok "" "$_UM_LATEST_JSON" "$_jc_plugin_status" "$_jc_plugin_error" "$_jc_plugin_update" || {
        rm -rf "$_jc_dir"
        fail internal
        return 1
    }
    rm -rf "$_jc_dir"
    log update "check complete: serial=$_UM_SERIAL installed=$_jc_cur_ser up_to_date=$_jc_utd"
    return 0
}

_upd_job_install_remote() {
    _jr_action=$1
    _jr_arch=$2
    _jr_variant=${3:-normal}
    job_data update "{\"action\":\"$_jr_action\",\"latest\":null,\"up_to_date\":false,\"kept_prev\":false,\"variant\":\"$_jr_variant\"}"
    _upd_arch_supported "$_jr_arch" || return 1

    _jr_cur_arch=$(_upd_installed_arch)
    if { [ "$_jr_action" = arch ] && [ "$_jr_arch" != "$_jr_cur_arch" ]; } ||
        { [ "$_jr_action" = type ] && [ "$_jr_variant" != "$(_upd_installed_variant)" ]; }; then
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
    if ! _upd_parse_manifest "$_jr_json" "$_jr_arch" "$_jr_smode" 1 "$_jr_variant"; then
        return 1
    fi

    _upd_remember_serial "$_UM_SERIAL" || return 1
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
    if ! _upd_download "$_jr_url" "$_jr_gz" "$_UM_SIZE"; then
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
    _upd_unpack_candidate "$_jr_gz" "$_UM_RAW_SIZE" &&
        _upd_check_raw "$_ut_new" || return 1

    job_phase update test 70
        _upd_test_version "$_ut_new" &&
        _upd_stage_manifest "$_jr_json" "$_jr_arch" "$_jr_variant" "$_ut_manifest" &&
        _upd_swap_and_verify keep || return 1
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
    _upd_remember_serial "$(_upd_installed_serial)" || return 1
    if [ -e "$_rb_man" ] || [ -L "$_rb_man" ]; then
        { _rb_arch=$(jq -er '.arch // (.assets | keys | select(length == 1) | first)' "$_rb_man" 2>/dev/null) &&
            valid_arch "$_rb_arch"; } || { fail bad_manifest; return 1; }
        _upd_parse_manifest "$_rb_man" "$_rb_arch" any 0 && _upd_arch_supported "$_rb_arch" &&
            _upd_stage_manifest "$_rb_man" "$_rb_arch" "$_UM_VARIANT" "$_ut_manifest" || return 1
        job_phase update unpack 50
        _upd_unpack_candidate "$_rb_gz" "$_UM_RAW_SIZE" && _upd_check_raw "$_ut_new" || return 1
        job_phase update test 65
        _upd_test_version "$_ut_new" || return 1
    else
        _rb_arch=$(_upd_installed_arch)
        _upd_arch_supported "$_rb_arch" || return 1
        job_phase update unpack 50
        _upd_unpack_candidate "$_rb_gz" 0 || return 1
        job_phase update test 65
        _rb_ver=$(_upd_bin_version "$_ut_new") || { fail core_test_failed; return 1; }
        { jq -cn --arg ts "$_rb_ver" --arg a "$_rb_arch" \
            '{schema:1, tailscale:$ts, arch:$a, serial:0, revision:0, assets:{}}' \
            >"$_ut_manifest" && chmod 644 "$_ut_manifest"; } || { fail internal; return 1; }
    fi
    _upd_swap_and_verify consume
}

job_update() {
    trap '_upd_interrupted' TERM INT HUP
    _ju_rc=0
    if core_recover; then
        case "${1:-}" in
            check) _upd_job_check || _ju_rc=1 ;;
            update) _upd_transaction _upd_job_install_remote update "$(_upd_installed_arch)" "$(_upd_installed_variant)" || _ju_rc=1 ;;
            arch) _upd_transaction _upd_job_install_remote arch "${2:-}" "$(_upd_installed_variant)" || _ju_rc=1 ;;
            type) _upd_transaction _upd_job_install_remote type "$(_upd_installed_arch)" "${2:-}" || _ju_rc=1 ;;
            rollback) _upd_transaction _upd_job_rollback || _ju_rc=1 ;;
            *) fail invalid_param; _ju_rc=1 ;;
        esac
    else
        _ju_rc=1
    fi
    trap - TERM INT HUP
    return "$_ju_rc"
}

# ---- Page actions (contract section 4) ----

act_core_check() {
    job_start update check
}

act_core_update() {
    job_start update update
}

act_core_rollback() {
    if [ ! -d "$BIFROST_HOME/.core-update" ] && [ ! -s "$BIFROST_BIN/bifrostd.prev.gz" ]; then
        fail no_prev
        return 1
    fi
    job_start update rollback
}

# Finish any interrupted core transaction first: its recovery may still need
# the archive (the stash is published back as bifrostd.prev.gz).
_upd_drop_prev_locked() {
    core_recover || return 1
    [ -e "$BIFROST_BIN/bifrostd.prev.gz" ] || [ -e "$BIFROST_BIN/bifrostd.prev.json" ] || return 0
    core_prev_drop || return 1
    log update "previous core deleted from the page"
}

act_core_drop_prev() {
    if job_running update; then
        fail busy
        return 1
    fi
    with_lock state "$BIFROST_LOCK_WAIT" _upd_drop_prev_locked
}

act_core_arch() {
    _upd_arch_supported "${1:-}" || return 1
    job_start update arch "$1" "$(_upd_installed_variant)"
}

act_core_type() {
    case "${1:-}" in
        normal | upx) ;;
        *) fail invalid_param; return 1 ;;
    esac
    job_start update type "$1"
}
