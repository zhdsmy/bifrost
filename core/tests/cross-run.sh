#!/bin/sh
# cross-run.sh <dir> <version>: run every bifrost-core-*.gz in <dir> (arm and
# arm64, normal and UPX) under qemu-user and check that `--version` prints
# <version>. Needs qemu-arm-static and qemu-aarch64-static.
set -eu

dir=$1
want=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

n=0
for asset in "$dir"/bifrost-core-*.gz; do
    [ -f "$asset" ] || continue
    case "$asset" in
        *-linux-arm.gz) qemu="qemu-arm-static" ;;
        *-linux-arm64.gz) qemu="qemu-aarch64-static" ;;
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
