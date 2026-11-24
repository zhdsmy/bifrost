#!/bin/sh
# Run the shell tests in the BusyBox 1.25 test image. Needs docker.
# Usage: tests/shell/run.sh [t_name.sh ...]   (default: every tests/shell/t_*.sh)
# The sources are streamed into the container with tar, not bind-mounted:
# some macOS Docker runtimes hang on mounts from protected folders.
# Each file runs in its own container, as many at a time as the Docker VM has
# CPUs (BIFROST_TEST_JOBS overrides). Files cannot share one shell as
# background jobs: those start with SIGINT ignored, which breaks the INT tests.
set -eu
cd "$(dirname "$0")/../.."
img=bifrost-shtest:1
docker build -q -t "$img" tests/shell >/dev/null
[ $# -gt 0 ] || set -- tests/shell/t_*.sh
lanes=${BIFROST_TEST_JOBS:-$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 2)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
COPYFILE_DISABLE=1 tar -cf "$work/src.tar" --exclude node_modules --exclude .git plugin tests tools
mkdir "$work/claim"

# Claim the slowest files first, so a late start does not set the end time.
# A name here that is not being run is skipped.
order=""
for n in t_fw.sh t_daemon.sh t_migrate.sh t_update_failures.sh t_login.sh; do
    for f do [ "${f##*/}" = "$n" ] && order="$order $n"; done
done
for f do
    case "$order " in *" ${f##*/} "*) ;; *) order="$order ${f##*/}" ;; esac
done

# lane FILE...: run every file that no other lane has claimed yet.
lane() {
    for _l_n do
        mkdir "$work/claim/$_l_n" 2>/dev/null || continue
        _l_rc=0
        docker run --rm -i --network none "$img" /bin/sh -c \
            'mkdir -p /src && tar -xf - -C /src && cd /src && exec /bin/sh tests/shell/inner.sh "$1"' \
            inner "$_l_n" <"$work/src.tar" >"$work/$_l_n.log" 2>&1 || _l_rc=$?
        echo "$_l_rc" >"$work/$_l_n.rc"
    done
}
i=0
while [ "$i" -lt "$lanes" ]; do
    # shellcheck disable=SC2086
    lane $order &
    i=$((i + 1))
done
wait

total=0
failed=0
for f do
    n=${f##*/}
    total=$((total + 1))
    sed '/^test files: /d' "$work/$n.log"
    [ "$(cat "$work/$n.rc" 2>/dev/null)" = 0 ] || failed=$((failed + 1))
done
echo "test files: $total, failed: $failed"
[ "$failed" -eq 0 ]
