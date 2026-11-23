#!/bin/sh
# Offline channel recovery test. Run from the repository root.
set -eu
if [ "${0##*/}" = gh ]; then
    case "$1" in
        api)
            if [ -n "${API_FAILURE:-}" ]; then echo 'gh: error (HTTP 502)' >&2; exit 1; fi
            describe() {
                (cd "$1" && ls -1) | jq -Rn --arg t "${1##*/}" --arg s "$(cat "$1/.starter" 2>/dev/null)" \
                    --argjson d "$([ -f "$1/.draft" ] && echo true || echo false)" \
                    '{tag_name:$t, draft:$d, assets:[inputs | {name:., state:(if . == $s then "starter" else "uploaded" end)}]}'
            }
            if [ "$2" = --paginate ]; then
                for dir in "$STORE"/*; do [ ! -d "$dir" ] || describe "$dir"; done | jq -s '[.]'
            else
                dir="$STORE/${2##*/}"
                if [ ! -d "$dir" ] || [ -f "$dir/.draft" ]; then echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
                describe "$dir"
            fi
            ;;
        release)
            action=$2
            dir="$STORE/$3"
            shift 3
            case "$action" in
                create)
                    mkdir "$dir"
                    case " $* " in *" --draft "*) touch "$dir/.draft" ;; esac
                    for asset do
                        case "$asset" in --*) break ;; esac
                        cp "$asset" "$dir/"
                    done ;;
                download)
                    if [ "$1" = --dir ]; then cp "$dir"/* "$2/"; else cp "$dir/$2" "$4"; fi ;;
                edit) [ "$1" = --draft=false ] && rm "$dir/.draft" ;;
                delete-asset)
                    if [ "$(cat "$dir/.starter" 2>/dev/null)" = "$1" ]; then rm "$dir/.starter"; fi
                    rm "$dir/$1" ;;
                upload)
                    name=${1##*/}
                    if [ "${dir##*/}" = channel-stable ]; then
                        [ "$name" != "${UPLOAD_FAILURE:-}" ] || exit 1
                        if [ "$name" = core.json.sig ]; then [ ! -f "$dir/core.json" ]; fi
                    elif [ "$name" = "${TAG_UPLOAD_FAILURE:-}" ]; then
                        : >"$dir/$name"
                        echo "$name" >"$dir/.starter"
                        exit 1
                    fi
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

# First asset fails, then a later asset fails. Existing bytes are immutable
# and signing the same inputs again may yield different DER signatures.
reject env TAG_UPLOAD_FAILURE=SHA256SUMS "$release" publish "$second" "$second"
[ -f "$STORE/$second/.draft" ]
[ ! -f "$STORE/$second/core.json" ]
cmp "$channel/core.json" "$first/core.json"
[ "$("$release" serial "$second")" = 2 ]
reject env TAG_UPLOAD_FAILURE=core.gz "$release" publish "$second" "$second"
cp "$STORE/$second/SHA256SUMS.sig" "$tmp/original.sig"
# An uploaded signature may survive even when its corresponding input is missing.
rm "$STORE/$second/SHA256SUMS"
"$repo/tools/sign.sh" keys/dev.key.pem "$second/core.json" "$second/SHA256SUMS"
printf 'conflict' >"$STORE/$second/SHA256SUMS.sig"
reject "$release" publish "$second" "$second"
[ ! -e "$STORE/$second/SHA256SUMS" ]
cp "$tmp/original.sig" "$STORE/$second/SHA256SUMS.sig"
reject "$release" serial "$third"

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
cmp "$STORE/$second/SHA256SUMS.sig" "$tmp/original.sig"
[ ! -e "$STORE/$second/.draft" ]
diff -qr "$second" "$STORE/$second"
[ ! -f "$channel/pending-core.json" ]
"$release" publish "$first" "$first"
[ "$("$release" serial "$third")" = 3 ]
echo changed >>"$STORE/$second/core.gz"
reject "$release" publish "$second" "$second"
rm "$channel/core.json"
reject "$release" serial "$third"
echo 'core release recovery: OK'
