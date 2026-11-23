#!/bin/sh
# Sign one or more files with an ECDSA P-256 private key (PLAN 12.3).
# Writes <file>.sig next to each input file.
#
# Usage: tools/sign.sh <private-key.pem> <file> [file...]
set -eu

if [ $# -lt 2 ]; then
    echo "Usage: $0 <private-key.pem> <file> [file...]" >&2
    exit 1
fi

key=$1
shift

[ -r "$key" ] || {
    echo "sign.sh: private key not readable: $key" >&2
    exit 1
}

for f in "$@"; do
    [ -r "$f" ] || {
        echo "sign.sh: file not readable: $f" >&2
        exit 1
    }
    tmp="$f.sig.tmp.$$"
    if ! openssl dgst -sha256 -sign "$key" -out "$tmp" "$f"; then
        rm -f "$tmp"
        exit 1
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$f.sig"
done
