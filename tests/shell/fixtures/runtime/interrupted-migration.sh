#!/bin/sh
# Deliver a real signal to the locked worker at a chosen filesystem boundary.
signal=$1
point=$2
BIFROST_NO_MAIN=1
# shellcheck disable=SC1091
. "$BIFROST_KSROOT/scripts/bifrost_config.sh"
fire() {
    [ ! -e "$MOCK_STATE/interrupted" ] || return 0
    : >"$MOCK_STATE/interrupted"
    kill "-$signal" "$$"
}
# shellcheck disable=SC2329
cp() {
    command cp "$@" || return 1
    if [ "$point" = copying ] && [ "$1" = "$BIFROST_ORIG_STATE/tailscaled.state" ]; then fire; fi
}
# shellcheck disable=SC2329
rm() {
    if [ "${2:-}" = "$_BIFROST_MIGRATION/backup" ] && [ "$point" = committed ]; then fire; fi
    command rm "$@"
}
# job_phase publishes its JSON through a pipeline; $$ is the locked worker.
# shellcheck disable=SC2329
mv() {
    command mv "$@" || return 1
    if [ "$point" = verifying ] && [ "${3:-}" = "$(job_file migrate)" ] &&
        [ "$(jq -r .phase "$3")" = verify ]; then fire; fi
}
job_run migrate
