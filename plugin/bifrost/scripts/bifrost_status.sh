#!/bin/sh
# Refresh /tmp/upload/bifrost_status.json for the page and answer the request.
# Contract file: see docs/dev/contract.md, section 6.1. Read only: no lock.

# shellcheck disable=SC1091
. "${BIFROST_KSROOT:-/koolshare}/scripts/base.sh"
# The software center runs scripts with umask 0, which would make every
# directory and file we create world-writable.
umask 022
: "${BIFROST_LIB:=${BIFROST_KSROOT:-/koolshare}/bifrost/lib}"
# shellcheck source=../lib/env.sh
. "$BIFROST_LIB/env.sh"
# shellcheck source=../lib/validate.sh
. "$BIFROST_LIB/validate.sh"
# shellcheck source=../lib/common.sh
. "$BIFROST_LIB/common.sh"
for _bs_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$BIFROST_LIB/$_bs_m.sh" ] && . "$BIFROST_LIB/$_bs_m.sh"
done

bifrost_status_main() {
    valid_req_id "${1:-}" && BIFROST_REQ_ID=$1
    if ! has_cmd status_refresh; then
        respond_err not_implemented
        return 1
    fi
    BIFROST_ERR=""
    job_reap
    if status_refresh; then
        respond_ok
    else
        respond_err "${BIFROST_ERR:-internal}"
        return 1
    fi
}

if [ "${BIFROST_NO_MAIN:-0}" != 1 ]; then
    bifrost_status_main "$@"
    exit $?
fi
