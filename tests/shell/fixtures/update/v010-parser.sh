# Verbatim copy of _upd_parse_manifest from the v0.1.0 tag
# (plugin/bifrost/lib/update.sh), renamed. Do not edit: it stands for routers
# that still run v0.1.0 and read the new channel manifest.
_upd_parse_manifest_v010() {
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
        '{tailscale:$ts, revision:$rev, serial:$ser, tag:$tag}') || {
        fail internal
        return 1
    }
    return 0
}
