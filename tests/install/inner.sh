#!/bin/sh
# Runs inside the BusyBox 1.25 test image (see tests/install/run.sh).
set -u
cd /src || exit 1

# Add a minimal curl mock in a writable temp bin dir (router has curl; the
# baseline shell image only installs jq and openssl; P1 owns mock/bin/curl).
mock_extra=/tmp/install-mock-bin.$$
trap 'rm -rf "$mock_extra"' EXIT
mkdir -p "$mock_extra"
cat >"$mock_extra/curl" <<'EOF'
#!/bin/sh
echo "mock curl: $*" >>"${MOCK_STATE:-/tmp}/curl.log"
exit 0
EOF
chmod 755 "$mock_extra/curl"

export INSTALL_MOCK_EXTRA="$mock_extra"
export PATH="/src/tests/shell/mock/bin:$mock_extra:/opt/bb125/bin:/opt/tools/bin"

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
