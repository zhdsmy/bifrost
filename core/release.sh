#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# Called under core.yml's global concurrency group. Both commands run at repo root.
#   core/release.sh verify FILE...
#   core/release.sh serial TAG
#   core/release.sh publish TAG DIST
set -eu
mode=$1
tag=$2
channel='channel-stable'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
die() { echo "core release: $*" >&2; exit 1; }

# An API error must never reset the serial. A missing asset on an existing
# release is also a hard error, except during our recorded channel transition.
metadata() {
    if ! gh api "repos/{owner}/{repo}/releases/tags/$1" >"$2" 2>"$tmp/api.err"; then
        grep -Eq '\(HTTP 404\)$' "$tmp/api.err" || { cat "$tmp/api.err" >&2; exit 1; }
        printf 'null\n' >"$2"
    fi
}
has_asset() { jq -e --arg n "$2" 'any(.assets[]?; .name == $n)' "$1" >/dev/null; }
serial() { jq -er '.serial | select(type == "number" and floor == . and . > 0 and . < 10000000000)' "$1"; }
download() { gh release download "$1" --pattern "$2" --output "$3"; }
# The CI publisher and the router check the same signature format and keys.
lib=$(dirname "$0")/../plugin/bifrost/lib
BIFROST_KEYS=plugin/bifrost/keys
# shellcheck source=../plugin/bifrost/lib/validate.sh
. "$lib/validate.sh"
# shellcheck source=../plugin/bifrost/lib/common.sh
. "$lib/common.sh"
# shellcheck source=../plugin/bifrost/lib/update.sh
. "$lib/update.sh"
verify() { manifest_verify "$1" "$1.sig" || die "no bundled public key verifies ${1##*/}"; }
if [ "$mode" = verify ]; then
    shift
    for file do verify "$file"; done
    exit 0
fi

metadata "$tag" "$tmp/tag"
metadata "$channel" "$tmp/channel"
stable=0
if has_asset "$tmp/channel" core.json; then
    download "$channel" core.json "$tmp/stable.json"
    stable=$(serial "$tmp/stable.json")
fi
pending=false
if has_asset "$tmp/channel" pending-core.json; then
    download "$channel" pending-core.json "$tmp/pending-core.json"
    jq -e --arg t "$tag" '.tag == $t' "$tmp/pending-core.json" >/dev/null ||
        die "another core release must finish its pending channel publication"
    pending=true
elif jq -e '. != null' "$tmp/channel" >/dev/null && [ "$stable" = 0 ]; then
    die "channel exists without a manifest or a pending publication"
fi

if jq -e '. != null' "$tmp/tag" >/dev/null; then
    download "$tag" core.json "$tmp/tag.json"
    next=$(serial "$tmp/tag.json")
elif [ "$pending" = true ]; then
    next=$(serial "$tmp/pending-core.json")
else
    if [ "$stable" != 0 ]; then
        download "$channel" core.json.sig "$tmp/stable.json.sig"
        verify "$tmp/stable.json"
    fi
    next=$((stable + 1))
    [ "$next" -lt 10000000000 ] || die "serial out of range"
fi
case "$mode" in
    serial) echo "$next"; exit 0 ;;
    publish) dist=$3 ;;
    *) die "expected serial or publish" ;;
esac

if [ "$(serial "$dist/core.json")" != "$next" ] ||
    ! jq -e --arg t "$tag" '.tag == $t' "$dist/core.json" >/dev/null; then
    die "release manifest does not match the reserved tag and serial"
fi
verify "$dist/core.json"
verify "$dist/SHA256SUMS"

if [ -f "$tmp/tag.json" ]; then
    # ECDSA signatures may differ for identical inputs. Verify the published
    # signatures, then use those exact bytes for comparison and channel repair.
    mkdir "$tmp/published"
    gh release download "$tag" --dir "$tmp/published"
    for name in core.json SHA256SUMS; do
        verify "$tmp/published/$name"
        cp "$tmp/published/$name.sig" "$dist/$name.sig"
    done
    diff -qr "$dist" "$tmp/published" || die "existing tag release differs"
fi

if [ "$stable" -gt "$next" ]; then
    [ -f "$tmp/tag.json" ] && [ "$pending" = false ] || die "channel serial moved ahead"
    download "$channel" core.json.sig "$tmp/stable.json.sig"
    verify "$tmp/stable.json"
    echo "Existing release verified. Channel already at serial $stable."
    exit 0
fi
if [ "$stable" = "$next" ]; then
    cmp "$tmp/stable.json" "$dist/core.json" || die "serial belongs to a different manifest"
    if has_asset "$tmp/channel" core.json.sig; then
        download "$channel" core.json.sig "$tmp/stable.json.sig"
        if [ -f "$tmp/tag.json" ] && cmp -s "$dist/core.json.sig" "$tmp/stable.json.sig"; then
            verify "$tmp/stable.json"
            if [ "$pending" = true ]; then gh release delete-asset "$channel" pending-core.json --yes; fi
            exit 0
        fi
    fi
fi

# Reserve the serial before publishing an immutable tag. If the job stops,
# only a rebuild of this exact manifest may finish this channel transition.
if [ "$pending" = true ]; then
    cmp "$dist/core.json" "$tmp/pending-core.json" || die "pending manifest differs"
else
    cp "$dist/core.json" "$tmp/pending-core.json"
    if jq -e '. == null' "$tmp/channel" >/dev/null; then
        gh release create "$channel" "$tmp/pending-core.json" --target "$GITHUB_SHA" \
            --title "Stable Core Channel" --notes "Latest verified stable Bifrost core manifest."
    else
        gh release upload "$channel" "$tmp/pending-core.json"
    fi
fi
if [ ! -f "$tmp/tag.json" ]; then
    gh release create "$tag" "$dist"/* --verify-tag --title "Bifrost Core $tag" \
        --notes "Tailscale $(jq -r .tailscale "$dist/core.json"), commit $(jq -r .build.commit "$dist/core.json"), Go $(jq -r .build.go "$dist/core.json"), manifest serial $next."
fi

# GitHub replaces assets individually. Withdraw the manifest before replacing
# its signature. Publishing the manifest last keeps a mixed pair off the channel.
if [ "$stable" != 0 ]; then gh release delete-asset "$channel" core.json --yes; fi
gh release upload "$channel" "$dist/core.json.sig" --clobber
gh release upload "$channel" "$dist/core.json"
download "$channel" core.json "$tmp/readback.json"
download "$channel" core.json.sig "$tmp/readback.json.sig"
cmp "$dist/core.json" "$tmp/readback.json"
cmp "$dist/core.json.sig" "$tmp/readback.json.sig"
verify "$tmp/readback.json"
gh release delete-asset "$channel" pending-core.json --yes
