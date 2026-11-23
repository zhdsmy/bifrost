#!/bin/sh
# Generate an ECDSA P-256 key pair (PEM) for local development and tests.
# Never commit generated private keys or test public keys to the repository.
#
# Usage: tools/dev-keys.sh <dir> [name]
# Creates <dir>/<name>.key.pem (mode 600) and <dir>/<name>.pub.pem (mode 644).
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <dir> [name]" >&2
    exit 1
fi

dir=$1
name=${2:-dev}

case "$name" in
    '' | *[!A-Za-z0-9._-]*)
        echo "dev-keys.sh: invalid key name: $name" >&2
        exit 1
        ;;
esac

mkdir -p "$dir"
priv="$dir/$name.key.pem"
pub="$dir/$name.pub.pem"

(
    umask 077
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$priv" 2>/dev/null
)
chmod 600 "$priv"
openssl pkey -in "$priv" -pubout -out "$pub" 2>/dev/null
chmod 644 "$pub"
