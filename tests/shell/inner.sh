# shellcheck shell=sh
# Runs inside the test image (see run.sh). Each test file runs in its own sh.
export PATH=/src/tests/shell/mock/bin:/opt/bb125/bin:/opt/tools/bin
cd /src || exit 1
[ $# -gt 0 ] || set -- tests/shell/t_*.sh
total=0
failed=0
for f in "$@"; do
    case "$f" in */*) ;; *) f=tests/shell/$f ;; esac
    total=$((total + 1))
    if ! /bin/sh "$f"; then
        failed=$((failed + 1))
        echo "FAILED FILE: $f"
    fi
done
echo "test files: $total, failed: $failed"
[ "$failed" -eq 0 ]
