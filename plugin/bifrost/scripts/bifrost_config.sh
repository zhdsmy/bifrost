#!/bin/sh
# Bifrost entry point. Contract file: see docs/dev/contract.md, section 4.
#
#   bifrost_config.sh <request id> <action> [params...]   page request
#   bifrost_config.sh start | stop | start_nat              init.d hooks
#   bifrost_config.sh local watchdog | job <name> [args...] internal calls
#
# base.sh is sourced at the top level so that it sees $1 as the request ID.

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
for _bf_m in daemon fw dns status login settings migrate update diag; do
    # shellcheck disable=SC1090
    [ -f "$BIFROST_LIB/$_bf_m.sh" ] && . "$BIFROST_LIB/$_bf_m.sh"
done

# "-" stands for an empty parameter.
undash() {
    if [ "$1" = - ]; then echo ""; else printf '%s\n' "$1"; fi
}

# act_ui <lang> <mode>: the page's language and appearance (PLAN 13.8, 13.9).
act_ui() {
    if ! valid_lang "$1" || ! valid_mode "$2"; then
        fail invalid_param
        return 1
    fi
    cfg_set bifrost_ui_lang "$1" && cfg_set bifrost_ui_mode "$2"
}

# run_act <function> [args...]: call an act_* function and send exactly one
# response. The function returns 0 or 1 and may set BIFROST_RESULT to a JSON
# object whose fields are added to {"ok":true}.
run_act() {
    BIFROST_ERR=""
    BIFROST_RESULT=""
    if ! has_cmd "$1"; then
        respond_err not_implemented
        return 1
    fi
    if "$@"; then
        if [ -n "$BIFROST_RESULT" ]; then
            _ra_out=$(jq -cn --argjson r "$BIFROST_RESULT" '{ok:true} + $r' 2>/dev/null) || {
                respond_err internal
                return 1
            }
            respond "$_ra_out"
        else
            respond_ok
        fi
    else
        respond_err "${BIFROST_ERR:-internal}"
        return 1
    fi
}

# nargs <expected> <actual>
nargs() {
    [ "$1" = "$2" ] || fail invalid_param
}

page() {
    _pg_act=$1
    shift
    valid_name "$_pg_act" || {
        respond_err invalid_param
        return 1
    }
    for _pg_p in "$@"; do
        valid_param "$_pg_p" || {
            respond_err invalid_param
            return 1
        }
    done
    case "$_pg_act" in
        enable | disable | connect | relogin | logout | purge | migrate | \
            core-check | core-update | core-rollback | netcheck | logs)
            nargs 0 $# || {
                respond_err invalid_param
                return 1
            }
            ;;
        login | set | ui)
            nargs 2 $# || {
                respond_err invalid_param
                return 1
            }
            ;;
        core-arch | ping)
            nargs 1 $# || {
                respond_err invalid_param
                return 1
            }
            ;;
        *)
            respond_err unknown_action
            return 1
            ;;
    esac
    log page "action $_pg_act"
    case "$_pg_act" in
        enable) run_act act_enable ;;
        disable) run_act act_disable ;;
        connect) run_act act_connect ;;
        login) run_act act_login "$(undash "$1")" "$(undash "$2")" ;;
        relogin) run_act act_relogin ;;
        logout) run_act act_logout ;;
        purge) run_act act_purge ;;
        set) run_act act_set "$1" "$(undash "$2")" ;;
        migrate) run_act act_migrate ;;
        core-check) run_act act_core_check ;;
        core-update) run_act act_core_update ;;
        core-rollback) run_act act_core_rollback ;;
        core-arch) run_act act_core_arch "$1" ;;
        netcheck) run_act act_netcheck ;;
        ping) run_act act_ping "$1" ;;
        logs) run_act act_logs ;;
        ui) run_act act_ui "$1" "$2" ;;
    esac
}

hook() {
    log hook "$1"
    case "$1" in
        start) with_lock state 30 hook_start ;;
        stop) with_lock state 30 hook_stop ;;
        start_nat) with_lock state 30 hook_start_nat ;;
    esac
}

internal() {
    case "$1" in
        watchdog) with_lock state 0 watchdog_run ;;
        job)
            shift
            valid_name "${1:-}" || return 1
            for _in_p in "$@"; do
                valid_param "$_in_p" || return 1
            done
            job_run "$@"
            ;;
        *) return 1 ;;
    esac
}

bifrost_main() {
    case "${1:-}" in
        start | stop | start_nat) hook "$1" ;;
        local)
            shift
            internal "$@"
            ;;
        *)
            if valid_req_id "${1:-}"; then
                BIFROST_REQ_ID=$1
                shift
                [ $# -ge 1 ] || {
                    respond_err invalid_param
                    return 1
                }
                page "$@"
            else
                log main "rejected call"
                return 2
            fi
            ;;
    esac
}

# Tests source this file with BIFROST_NO_MAIN=1 to call the functions.
if [ "${BIFROST_NO_MAIN:-0}" != 1 ]; then
    bifrost_main "$@"
    exit $?
fi
