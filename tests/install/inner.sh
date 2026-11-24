#!/bin/sh
# Runs inside the BusyBox 1.25 test image (see tests/install/run.sh).
# Uses the repository's shared mock bin directory (includes curl, df, iptables, etc.).
set -u
cd /src || exit 1

export PATH="/src/tests/shell/mock/bin:/opt/bb125/bin:/opt/tools/bin"

pkg=""
if [ "${1:-}" = --package ] && [ -n "${2:-}" ]; then
    pkg=$2
fi

failed=0
total=0

if [ -n "$pkg" ]; then
    total=$((total + 1))
    if ! /bin/sh tests/install/t_package_smoke.sh "$pkg"; then
        failed=$((failed + 1))
        echo "FAILED FILE: tests/install/t_package_smoke.sh"
    fi
else
    total=$((total + 1))
    if ! /bin/sh tests/install/t_install.sh; then
        failed=$((failed + 1))
        echo "FAILED FILE: tests/install/t_install.sh"
    fi
fi

echo "install test files: $total, failed: $failed"
[ "$failed" -eq 0 ]
