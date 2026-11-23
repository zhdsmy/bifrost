# shellcheck shell=sh
# The framing check must reject this file before consulting a key.
reject_before_crypto() (
    marker=$3
    # shellcheck disable=SC2329
    openssl() { : >"$marker"; return 1; }
    if manifest_verify "$1" "$2"; then return 1; fi
    [ "$BIFROST_ERR" = bad_signature ] && [ ! -f "$marker" ]
)
