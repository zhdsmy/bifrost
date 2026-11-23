# shellcheck shell=sh
# Migration from the original Koolshare tailscale plugin.
# Contract: docs/dev/contract.md, sections 2, 4, 5, 6.2.
# PLAN: section 11.
# Load order: env.sh, validate.sh, common.sh, daemon.sh, ..., migrate.sh.

: "${BIFROST_ORIG_CLI:=}"
: "${BIFROST_MIGRATE_WAIT_POLL:=2}"
: "${BIFROST_MIGRATE_WAIT_TIMEOUT:=600}"
: "${BIFROST_MIGRATE_VERIFY_TIMEOUT:=60}"
: "${BIFROST_MIGRATE_VERIFY_POLL:=2}"
: "${BIFROST_MIGRATE_ORIG_STOP_TIMEOUT:=15}"

# The journal and its private backup survive a reboot. Uninstall removes
# BIFROST_HOME; purge and the next migration also retry committed cleanup.
_BIFROST_MIGRATION="$BIFROST_HOME/.migration"

migrate_orig_cli() {
    printf '%s\n' "${BIFROST_ORIG_CLI:-$BIFROST_KSBIN/tailscale}"
}

# Read the original plugin's autostart key (unverified on router; PLAN 11.2 step 4).
migrate_orig_get_enable() {
    dbus get tailscale_enable 2>/dev/null # check-sh: allow
}

# Stop the original plugin via its own script (unverified on router;
# PLAN 11.2 step 4). Only invoked when BIFROST_MIGRATE_AUTOSTOP=1.
migrate_orig_stop() {
    if [ -x "$BIFROST_ORIG_CONFIG" ]; then
        # The parent handles signals after the bounded stop script completes.
        (run_timeout "$BIFROST_MIGRATE_ORIG_STOP_TIMEOUT" "$BIFROST_ORIG_CONFIG" stop) >/dev/null 2>&1 || true
    fi
    _mos_deadline=$(($(now) + BIFROST_MIGRATE_ORIG_STOP_TIMEOUT))
    while orig_running || tun_exists; do
        [ "$(now)" -ge "$_mos_deadline" ] && return 1
        sleep 1
    done
    return 0
}

# Disable the original plugin's autostart (unverified on router;
# PLAN 11.2 step 4). Only invoked when BIFROST_MIGRATE_AUTOSTOP=1.
migrate_orig_disable_autostart() {
    dbus set tailscale_enable=0 >/dev/null 2>&1 # check-sh: allow
}

# Restore the original plugin's autostart value and optionally restart it
# (unverified on router; PLAN 11.2 step 9). Only invoked when BIFROST_MIGRATE_AUTOSTOP=1.
# Args: <orig_enable_val> <orig_was_running:0|1>
migrate_orig_restore() {
    _mor_en=$1
    _mor_was=$2
    _mor_rc=0
    if [ -n "$_mor_en" ]; then
        dbus set "tailscale_enable=$_mor_en" >/dev/null 2>&1 || _mor_rc=1 # check-sh: allow
    else
        dbus remove tailscale_enable >/dev/null 2>&1 || _mor_rc=1 # check-sh: allow
    fi
    if [ "$_mor_was" = 1 ] && ! orig_running; then
        if [ -x "$BIFROST_ORIG_CONFIG" ]; then
            (run_timeout "$BIFROST_MIGRATE_ORIG_STOP_TIMEOUT" "$BIFROST_ORIG_CONFIG" start) >/dev/null 2>&1 || return 1
            _mor_until=$(($(now) + BIFROST_MIGRATE_ORIG_STOP_TIMEOUT))
            until orig_running; do
                [ "$(now)" -lt "$_mor_until" ] || return 1
                sleep 1
            done
        else
            return 1
        fi
    fi
    return "$_mor_rc"
}

# Publish the phase and its original settings together before side effects.
# Keep a complete snapshot until rollback and original service restoration finish.
migrate_mark() {
    sync
    printf '%s %s %s %s %s\n' "$1" "$_jm_auto" "$_jm_orig_was_running" "${_jm_orig_enable:--}" "$_jm_saved" |
        atomic_write "$_BIFROST_MIGRATION/record" 600 || { fail state_not_writable; return 1; }
    sync
}

migrate_data() {
    [ ! -f "$(job_file migrate)" ] || job_data migrate "$1"
}

migrate_cleanup() {
    if ! rm -rf "$_BIFROST_MIGRATION/backup" || ! rm -rf "$_BIFROST_MIGRATION"; then
        log migrate "migration backup cleanup pending"
        migrate_data '{"backup_cleanup_pending":true}'
        return 1
    fi
    migrate_data '{"backup_cleanup_pending":false}'
}

# Called under the state lock on rollback, boot, and before a new migration.
migrate_recover() {
    [ -d "$_BIFROST_MIGRATION" ] || return 0
    if [ ! -e "$_BIFROST_MIGRATION/record" ]; then
        # Preparation was interrupted before any live state was changed.
        migrate_cleanup || { fail state_not_writable; return 1; }
        return 0
    fi
    if ! read -r _mr_phase _jm_auto _jm_orig_was_running _jm_orig_enable _jm_saved <"$_BIFROST_MIGRATION/record" ||
        ! valid_bool01 "$_jm_auto" || ! valid_bool01 "$_jm_orig_was_running" || ! valid_bool01 "$_jm_saved" ||
        { [ "$_jm_orig_enable" != - ] && ! valid_bool01 "$_jm_orig_enable"; }; then
        fail migrate_rollback_failed
        return 1
    fi
    [ "$_jm_orig_enable" != - ] || _jm_orig_enable=""
    case "$_mr_phase" in
        committed | restored) migrate_cleanup || true; return 0 ;;
        stopping | replacing) ;;
        *) fail migrate_rollback_failed; return 1 ;;
    esac

    _mr_ok=1
    if [ "$_mr_phase" = replacing ]; then
        [ ! -f "$(job_file migrate)" ] || job_phase migrate rollback 90
        if ! daemon_stop; then
            _mr_cleanup=${BIFROST_ERR:-internal}
            if daemon_find_pid >/dev/null; then
                log migrate "daemon still running; retaining backup and original service settings"
                fail migrate_rollback_failed
                return 1
            fi
            log migrate "daemon stopped with cleanup error: $_mr_cleanup"
            migrate_data "$(jq -cn --arg code "$_mr_cleanup" '{cleanup_error:$code}')"
        fi
        daemon_unschedule disable || _mr_ok=0
        if [ "$_jm_saved" = 1 ] && [ ! -d "$_BIFROST_MIGRATION/backup" ]; then
            _mr_ok=0
        elif ! daemon_clear_state_dir; then
            _mr_ok=0
        elif [ "$_jm_saved" = 1 ]; then
            mkdir -p "$BIFROST_STATE" &&
                cp -pR "$_BIFROST_MIGRATION/backup/." "$BIFROST_STATE/" || _mr_ok=0
        fi
    elif daemon_find_pid >/dev/null; then
        fail migrate_rollback_failed
        return 1
    fi

    if [ "$_jm_auto" = 1 ]; then
        migrate_orig_restore "$_jm_orig_enable" "$_jm_orig_was_running" || _mr_ok=0
    fi
    if [ "$_mr_ok" != 1 ] || ! migrate_mark restored; then
        log migrate "migration rollback incomplete; retaining journal"
        fail migrate_rollback_failed
        return 1
    fi
    if [ "$_mr_phase" = replacing ]; then migrate_data '{"rolled_back":true}'; fi
    migrate_cleanup || true
    daemon_err_clear
    status_refresh || true
    return 0
}

migrate_interrupted() {
    trap '' HUP INT TERM
    _mi_code=internal
    _mi_phase=""
    if [ -r "$_BIFROST_MIGRATION/record" ]; then
        read -r _mi_phase _mi_rest <"$_BIFROST_MIGRATION/record"
    fi
    migrate_recover || _mi_code=${BIFROST_ERR:-migrate_rollback_failed}
    if [ "$_mi_phase" = committed ] || [ "${_jm_committed:-0}" = 1 ]; then
        job_end migrate ok
        lock_release state
        exit 0
    else
        job_end migrate fail "$_mi_code"
    fi
    lock_release state
    exit 1
}

# act_migrate: start the background migration job.
act_migrate() {
    job_start migrate
}

# Locked step 1 & 2: precheck and record original identity/autostart.
migrate_prepare_locked() {
    migrate_recover || return 1
    [ ! -d "$_BIFROST_MIGRATION" ] || { fail state_not_writable; return 1; }
    migrate_data '{"rolled_back":false,"backup_cleanup_pending":false}'
    job_phase migrate precheck 5
    if [ ! -f "$BIFROST_ORIG_STATE/tailscaled.state" ]; then
        log migrate "precheck failed: original state missing"
        fail orig_missing
        return 1
    fi
    if ! core_version >/dev/null; then
        log migrate "precheck failed: core missing"
        fail core_missing
        return 1
    fi
    if daemon_find_pid >/dev/null; then
        log migrate "precheck failed: bifrostd already running"
        fail already_running
        return 1
    fi

    job_phase migrate record 15
    if ! mkdir -p "$BIFROST_RUN/migrate" || ! chmod 700 "$BIFROST_RUN/migrate" ||
        ! rm -f "$BIFROST_RUN/migrate/record.json"; then
        fail internal
        return 1
    fi
    _jm_orig_was_running=0
    _jm_orig_enable=""
    _jm_want_state=""
    _jm_want_id=""
    _jm_want_key=""

    if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ]; then
        _jm_orig_enable=$(migrate_orig_get_enable) || { fail internal; return 1; }
        [ -z "$_jm_orig_enable" ] || valid_bool01 "$_jm_orig_enable" || { fail invalid_param; return 1; }
    fi

    if orig_running; then
        _jm_orig_was_running=1
        _jm_ocli=$(migrate_orig_cli)
        if [ -x "$_jm_ocli" ]; then
            if _jm_ost=$(run_timeout 10 "$_jm_ocli" status --json 2>/dev/null) &&
                printf '%s\n' "$_jm_ost" | jq -e 'type == "object"' >/dev/null 2>&1; then
                _jm_want_state=$(printf '%s\n' "$_jm_ost" | jq -r '.BackendState // ""' 2>/dev/null)
                _jm_want_id=$(printf '%s\n' "$_jm_ost" | jq -r '.Self.ID // ""' 2>/dev/null)
                _jm_want_key=$(printf '%s\n' "$_jm_ost" | jq -r '.Self.PublicKey // ""' 2>/dev/null)
                jq -n --arg s "$_jm_want_state" --arg id "$_jm_want_id" --arg pk "$_jm_want_key" \
                    '{state:$s, id:$id, public_key:$pk}' |
                    json_write "$BIFROST_RUN/migrate/record.json" || { fail internal; return 1; }
            else
                log migrate "could not read original status; will verify state only"
            fi
        else
            log migrate "original CLI not found; will verify state only"
        fi
    fi
    return 0
}

# Locked steps 3-9: stop original (if AUTOSTOP=1), backup, copy, start,
# enforce --no-logs-no-support if custom control server, verify, cleanup or rollback.
migrate_apply_locked() {
    # Re-check after wait_original in case daemon started concurrently.
    if daemon_find_pid >/dev/null; then
        log migrate "bifrostd started concurrently while waiting"
        fail already_running
        return 1
    fi

    if [ "$_jm_auto" != 1 ] && { orig_running || tun_exists; }; then
        fail orig_still_running
        return 1
    fi
    job_phase migrate backup 40
    (umask 077 && mkdir "$_BIFROST_MIGRATION") || { fail state_not_writable; return 1; }
    _jm_saved=0
    if [ -d "$BIFROST_STATE" ]; then
        cp -pR "$BIFROST_STATE" "$_BIFROST_MIGRATION/backup" || { fail state_not_writable; return 1; }
        _jm_saved=1
    fi
    migrate_mark stopping || return 1
    if [ "$_jm_auto" = 1 ]; then
        migrate_orig_disable_autostart || { fail internal; return 1; }
        if orig_running || tun_exists; then
            job_phase migrate stop_original 25
            log migrate "stopping original plugin (autostop=1)"
            migrate_orig_stop || { fail orig_still_running; return 1; }
        fi
    fi

    migrate_mark replacing || return 1
    daemon_clear_state_dir || { fail state_not_writable; return 1; }
    if ! mkdir -p "$BIFROST_STATE" || ! chmod 700 "$BIFROST_STATE"; then
        fail state_not_writable
        return 1
    fi

    # 5. Copy original state files (read-only on original, mode 600 on copy)
    job_phase migrate copy 55
    if ! cp "$BIFROST_ORIG_STATE/tailscaled.state" "$BIFROST_STATE/tailscaled.state" ||
        ! chmod 600 "$BIFROST_STATE/tailscaled.state"; then
        log migrate "failed to copy tailscaled.state"
        fail state_not_writable
        return 1
    fi
    if [ -f "$BIFROST_ORIG_STATE/derpmap.cached.json" ]; then
        if ! cp "$BIFROST_ORIG_STATE/derpmap.cached.json" "$BIFROST_STATE/derpmap.cached.json" ||
            ! chmod 600 "$BIFROST_STATE/derpmap.cached.json"; then
            log migrate "failed to copy derpmap.cached.json"
            fail state_not_writable
            return 1
        fi
    fi

    # 6. Enable and start Bifrost
    job_phase migrate starting 70
    if ! cfg_set bifrost_enable 1 || ! daemon_start; then
        _jm_start_err=${BIFROST_ERR:-start_failed}
        log migrate "bifrostd failed to start during migration ($_jm_start_err)"
        fail "$_jm_start_err"
        return 1
    fi

    # 7. Verify state and identity within BIFROST_MIGRATE_VERIFY_TIMEOUT
    job_phase migrate verify 85
    _jm_vdead=$(($(now) + BIFROST_MIGRATE_VERIFY_TIMEOUT))
    _jm_verified=0
    while :; do
        _jm_remaining=$((_jm_vdead - $(now)))
        [ "$_jm_remaining" -gt 0 ] || _jm_remaining=1
        _jm_nst=$(ts_cli_t "$_jm_remaining" status --json 2>/dev/null)
        _jm_rc=$?
        _jm_verify_err=cli_failed
        [ "$_jm_rc" -ne 124 ] || _jm_verify_err=timeout
        if [ "$_jm_rc" -eq 0 ] && printf '%s\n' "$_jm_nst" |
            jq -e '.BackendState | strings | length > 0' >/dev/null 2>&1; then
            _jm_verify_err=migrate_verify_failed
            _jm_gs=$(printf '%s\n' "$_jm_nst" | jq -r '.BackendState // ""' 2>/dev/null)
            _jm_gid=$(printf '%s\n' "$_jm_nst" | jq -r '.Self.ID // ""' 2>/dev/null)
            _jm_gpk=$(printf '%s\n' "$_jm_nst" | jq -r '.Self.PublicKey // ""' 2>/dev/null)
            if [ -n "$_jm_want_state" ]; then
                _jm_match=1
                [ "$_jm_gs" = "$_jm_want_state" ] || _jm_match=0
                [ -z "$_jm_want_id" ] || [ "$_jm_gid" = "$_jm_want_id" ] || _jm_match=0
                [ -z "$_jm_want_key" ] || [ "$_jm_gpk" = "$_jm_want_key" ] || _jm_match=0
                if [ "$_jm_match" = 1 ]; then
                    _jm_verified=1
                    break
                fi
            else
                case "$_jm_gs" in
                    Running | NeedsMachineAuth | Stopped)
                        _jm_verified=1
                        break
                        ;;
                esac
            fi
        fi
        [ "$(now)" -ge "$_jm_vdead" ] && break
        sleep "$BIFROST_MIGRATE_VERIFY_POLL"
    done

    if [ "$_jm_verified" != 1 ]; then
        log migrate "verification failed (want state=$_jm_want_state)"
        fail "$_jm_verify_err"
        return 1
    fi

    migrate_mark committed || return 1
    _jm_committed=1
    migrate_cleanup || true
    status_refresh || true
    log migrate "migration succeeded"
    return 0
}

migrate_transaction() {
    _jm_committed=0
    _jm_auto=${BIFROST_MIGRATE_AUTOSTOP:-0}
    trap 'migrate_interrupted' HUP INT TERM
    _mt_err=""
    migrate_apply_locked || _mt_err=${BIFROST_ERR:-internal}
    if [ -n "$_mt_err" ]; then
        migrate_recover || _mt_err=${BIFROST_ERR:-migrate_rollback_failed}
    fi
    trap - HUP INT TERM
    [ -z "$_mt_err" ] || { fail "$_mt_err"; return 1; }
}

# job_migrate: PLAN 11.2 steps 1-9, contract 2 & 6.2.
# Runs without holding state lock during wait_original.
job_migrate() {
    _jm_manual="true"
    [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ] && _jm_manual="false"
    job_data migrate "{\"manual_stop\":$_jm_manual,\"rolled_back\":false}"

    with_lock state 60 migrate_prepare_locked || return 1

    # Wait for user to stop original WITHOUT holding state lock.
    if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" != 1 ]; then
        if orig_running || tun_exists; then
            job_phase migrate wait_original 25
            log migrate "waiting for user to stop original plugin"
            _jm_wdead=$(($(now) + BIFROST_MIGRATE_WAIT_TIMEOUT))
            while orig_running || tun_exists; do
                if [ "$(now)" -ge "$_jm_wdead" ]; then
                    log migrate "timed out waiting for original plugin to stop"
                    fail orig_still_running
                    return 1
                fi
                sleep "$BIFROST_MIGRATE_WAIT_POLL"
            done
        fi
    fi

    with_lock state 60 migrate_transaction
}
