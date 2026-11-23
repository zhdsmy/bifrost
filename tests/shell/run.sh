#!/bin/sh
# Run the shell tests in the BusyBox 1.25 test image. Needs docker.
# Usage: tests/shell/run.sh [t_name.sh ...]   (default: every tests/shell/t_*.sh)
# The sources are streamed into the container with tar, not bind-mounted:
# some macOS Docker runtimes hang on mounts from protected folders.
set -eu
cd "$(dirname "$0")/../.."
img=bifrost-shtest:1
docker build -q -t "$img" tests/shell >/dev/null
COPYFILE_DISABLE=1 tar -cf - --exclude node_modules --exclude .git plugin tests tools |
    docker run --rm -i --network none "$img" /bin/sh -c \
        'mkdir -p /src && tar -xf - -C /src && cd /src && exec /bin/sh tests/shell/inner.sh "$@"' \
        inner "$@"
