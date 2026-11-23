#!/bin/sh
# Run the Bifrost install/upgrade/uninstall test suite in the BusyBox 1.25
# test image (offline, router applets only). Needs docker.
#
# Usage:
#   tests/install/run.sh                      # full install/upgrade/uninstall suite
#   tests/install/run.sh --package <tar.gz>   # also smoke-test a built package tarball
#
# Streams sources via tar instead of bind-mounting (same pattern as tests/shell/run.sh).
set -eu
cd "$(dirname "$0")/../.."

pkg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --package)
            [ $# -ge 2 ] || { echo "missing path after --package" >&2; exit 2; }
            pkg=$2
            shift 2
            ;;
        -h | --help)
            echo "Usage: tests/install/run.sh [--package <bifrost.tar.gz>]"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -n "$pkg" ] && [ ! -f "$pkg" ]; then
    echo "package not found: $pkg" >&2
    exit 1
fi

img=bifrost-shtest:1
docker build -q -t "$img" tests/shell >/dev/null

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/src"
COPYFILE_DISABLE=1 tar -cf - --exclude node_modules --exclude .git plugin tests tools |
    tar -xf - -C "$stage/src"

if [ -n "$pkg" ]; then
    cp "$pkg" "$stage/src/tests/install/.test-package.tar.gz"
fi

COPYFILE_DISABLE=1 tar -cf - -C "$stage/src" . |
    docker run --rm -i --network none "$img" /bin/sh -c \
        'mkdir -p /src && tar -xf - -C /src && cd /src && exec /bin/sh tests/install/inner.sh "$@"' \
        inner ${pkg:+--package /src/tests/install/.test-package.tar.gz}
