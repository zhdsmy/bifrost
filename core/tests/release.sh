#!/bin/sh
# Offline channel recovery test. Run from the repository root.
set -eu
if [ "${0##*/}" = gh ]; then
    case "$1" in
        api)
            dir="$STORE/${2##*/}"
            if [ -n "${API_FAILURE:-}" ]; then echo 'gh: error (HTTP 502)' >&2; exit 1; fi
            if [ ! -d "$dir" ]; then echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
            (cd "$dir" && ls -1) | jq -Rn '{assets:[inputs | {name:.}]}'
            ;;
        release)
            action=$2
            dir="$STORE/$3"
            shift 3
            case "$action" in
                create)
                    mkdir "$dir"
                    for asset do
                        case "$asset" in --*) break ;; esac
                        cp "$asset" "$dir/"
                    done ;;
                download)
                    if [ "$1" = --dir ]; then cp "$dir"/* "$2/"; else cp "$dir/$2" "$4"; fi ;;
                delete-asset) rm "$dir/$1" ;;
                upload)
                    name=${1##*/}
                    [ "$name" != "${UPLOAD_FAILURE:-}" ] || exit 1
                    if [ "$name" = core.json.sig ]; then [ ! -f "$dir/core.json" ]; fi
                    [ ! -e "$dir/$name" ] || [ "${2:-}" = --clobber ]
                    cp "$1" "$dir/" ;;
                *) exit 2 ;;
            esac ;;
        *) exit 2 ;;
    esac
    exit 0
fi

repo=$(pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
export STORE="$tmp/store" PATH="$tmp/bin:$PATH" GITHUB_SHA=test
mkdir -p "$STORE" bin plugin/bifrost/keys
ln -s "$repo/core/tests/release.sh" bin/gh
release="$repo/core/release.sh"
"$repo/tools/dev-keys.sh" keys

bundle() {
    mkdir "$1"
    jq -n --arg t "$1" --argjson n "$2" \
        '{tag:$t,serial:$n,tailscale:"1.104.7",build:{go:"1.27.4",commit:"test"}}' >"$1/core.json"
    printf 'test payload' >"$1/core.gz"
    (cd "$1" && openssl dgst -sha256 -r core.gz core.json) >"$1/SHA256SUMS"
    "$repo/tools/sign.sh" keys/dev.key.pem "$1/core.json" "$1/SHA256SUMS"
}
reject() { if "$@" >/dev/null 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi; }
first=core-1.104.7-1
second=core-1.104.7-2
third=core-1.104.7-3
channel="$STORE/channel-stable"
bundle "$first" 1
bundle "$second" 2
[ "$("$release" serial "$first")" = 1 ]
reject env API_FAILURE=1 "$release" serial "$first"
reject "$release" publish "$first" "$first"
[ ! -d "$channel" ]
cp keys/dev.pub.pem plugin/bifrost/keys/test.pub.pem
"$release" publish "$first" "$first"
"$release" publish "$first" "$first"
[ "$("$release" serial "$second")" = 2 ]

for asset in core.json.sig core.json; do
    reject env UPLOAD_FAILURE="$asset" "$release" publish "$second" "$second"
    [ ! -f "$channel/core.json" ]
    cmp "$second/core.json" "$channel/pending-core.json"
    reject "$release" serial "$third"
    [ "$("$release" serial "$second")" = 2 ]
done

"$repo/tools/sign.sh" keys/dev.key.pem "$second/core.json" "$second/SHA256SUMS"
"$release" publish "$second" "$second"
cmp "$STORE/$second/core.json.sig" "$channel/core.json.sig"
[ ! -f "$channel/pending-core.json" ]
"$release" publish "$first" "$first"
[ "$("$release" serial "$third")" = 3 ]
echo changed >>"$STORE/$second/core.gz"
reject "$release" publish "$second" "$second"
rm "$channel/core.json"
reject "$release" serial "$third"
echo 'core release recovery: OK'
