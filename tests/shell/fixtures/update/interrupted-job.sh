#!/bin/sh
# Run in a separate foreground worker so $$ owns its signal and state lock.
signal=$1
BIFROST_NO_MAIN=1
# shellcheck disable=SC1091
. "$BIFROST_KSROOT/scripts/bifrost_config.sh"
# shellcheck disable=SC2329
mv() {
    command mv "$@" || return 1
    if [ "${2:-}" = "$BIFROST_BIN/bifrostd.new" ] && [ "${3:-}" = "$BIFROST_CORE" ] &&
        [ ! -e "$MOCK_STATE/signal-fired" ]; then
        : >"$MOCK_STATE/signal-fired"
        kill "-$signal" "$$"
    fi
}
job_run update update
