#!/bin/sh
# cross-run.sh <dir> <version>: run every bifrost-core-*.gz in <dir> (arm and
# arm64, normal and UPX) under qemu-user and check that `--version` prints
# <version>. Needs qemu-user: qemu-arm-static and qemu-aarch64-static on
# older Ubuntu, plain qemu-arm and qemu-aarch64 where qemu-user is static.
set -eu

dir=$1
want=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# pick <name>: print <name>-static or <name>, whichever is installed.
pick() {
    for _c in "$1-static" "$1"; do
        if command -v "$_c" >/dev/null 2>&1; then
            echo "$_c"
            return 0
        fi
    done
    echo "neither $1-static nor $1 is installed" >&2
    return 1
}

n=0
for asset in "$dir"/bifrost-core-*.gz; do
    [ -f "$asset" ] || continue
    case "$asset" in
        *-linux-arm.gz) qemu=$(pick qemu-arm) ;;
        *-linux-arm64.gz) qemu=$(pick qemu-aarch64) ;;
        *) echo "unexpected asset: $asset" >&2; exit 1 ;;
    esac
    gzip -cd "$asset" >"$tmp/bifrostd"
    chmod 755 "$tmp/bifrostd"
    got=$("$qemu" "$tmp/bifrostd" --version | head -n 1)
    if [ "$got" != "$want" ]; then
        echo "$asset: version '$got', want '$want'" >&2
        exit 1
    fi
    echo "${asset##*/}: $got"
    n=$((n + 1))
done
[ "$n" -eq 4 ] || { echo "expected 4 core assets, found $n" >&2; exit 1; }
