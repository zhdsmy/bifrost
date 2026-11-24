# Extracted from the v0.1.0 tag's plugin/bifrost/lib/update.sh parser.
# Keep this compatibility fixture limited to the manifest validation contract.
_upd_parse_manifest_v010() {
    _pm_json=$1
    _pm_arch=$2
    _pm_smode=$3
    _pm_cplug=$4
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
    [ "$_UM_FILE" != - ] || { fail no_arch; return 1; }
    return 0
}
