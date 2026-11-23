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
        run_timeout "$BIFROST_MIGRATE_ORIG_STOP_TIMEOUT" "$BIFROST_ORIG_CONFIG" stop >/dev/null 2>&1 || true
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
    if [ -n "$_mor_en" ]; then
        dbus set "tailscale_enable=$_mor_en" >/dev/null 2>&1 || return 1 # check-sh: allow
    else
        dbus remove tailscale_enable >/dev/null 2>&1 || return 1 # check-sh: allow
    fi
    if [ "$_mor_was" = 1 ] && ! orig_running; then
        if [ -x "$BIFROST_ORIG_CONFIG" ]; then
            run_timeout "$BIFROST_MIGRATE_ORIG_STOP_TIMEOUT" "$BIFROST_ORIG_CONFIG" start >/dev/null 2>&1 || return 1
        else
            return 1
        fi
    fi
    return 0
}

# Roll back a failed migration (PLAN 11.2 step 9). Caller holds state lock.
# Args: <backup_dir_or_empty> <orig_was_running:0|1> <orig_enable_val> <fail_code>
migrate_rollback() {
    _mrb_bak=$1
    _mrb_was_orig=$2
    _mrb_orig_en=$3
    _mrb_code=$4
    job_phase migrate rollback 90
    log migrate "rolling back failed migration (reason=$_mrb_code)"

    _mrb_ok=1
    if ! daemon_deactivate disable; then
        log migrate "stop or network cleanup failed; preserving state and backup"
        job_data migrate '{"rolled_back":false}'
        fail migrate_rollback_failed
        return 1
    fi
    daemon_clear_state_dir || _mrb_ok=0

    if [ -n "$_mrb_bak" ]; then
        if [ -d "$_mrb_bak" ]; then
            rm -rf "$BIFROST_STATE" 2>/dev/null || _mrb_ok=0
            mv "$_mrb_bak" "$BIFROST_STATE" 2>/dev/null || _mrb_ok=0
        else
            log migrate "rollback backup missing: $_mrb_bak"
            _mrb_ok=0
        fi
    fi

    if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ]; then
        migrate_orig_restore "$_mrb_orig_en" "$_mrb_was_orig" || {
            log migrate "failed to restore original plugin during rollback"
            _mrb_ok=0
        }
    fi

    daemon_err_clear
    status_refresh || true

    if [ "$_mrb_ok" = 1 ]; then
        job_data migrate '{"rolled_back":true}'
        fail "$_mrb_code"
    else
        job_data migrate '{"rolled_back":false}'
        fail migrate_rollback_failed
    fi
    return 1
}

# act_migrate: start the background migration job.
act_migrate() {
    job_start migrate
}

# Locked step 1 & 2: precheck and record original identity/autostart.
migrate_prepare_locked() {
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
    if daemon_running; then
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
    if daemon_running; then
        log migrate "bifrostd started concurrently while waiting"
        fail already_running
        return 1
    fi

    if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ]; then
        migrate_orig_disable_autostart || { fail internal; return 1; }
        if orig_running || tun_exists; then
            job_phase migrate stop_original 25
            log migrate "stopping original plugin (autostop=1)"
            if ! migrate_orig_stop; then
                log migrate "failed to stop original plugin"
                migrate_orig_restore "$_jm_orig_enable" "$_jm_orig_was_running" || {
                    fail migrate_rollback_failed
                    return 1
                }
                fail orig_still_running
                return 1
            fi
        fi
    elif orig_running || tun_exists; then
        fail orig_still_running
        return 1
    fi

    # 3. Backup existing Bifrost state if non-empty
    job_phase migrate backup 40
    _jm_bak=""
    if [ -d "$BIFROST_STATE" ] && [ -n "$(ls -A "$BIFROST_STATE" 2>/dev/null)" ]; then
        _jm_bak="${BIFROST_STATE}.bak.$(now).$$"
        if [ -e "$_jm_bak" ] || ! mv "$BIFROST_STATE" "$_jm_bak"; then
            log migrate "failed to back up existing state"
            if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ]; then
                migrate_orig_restore "$_jm_orig_enable" "$_jm_orig_was_running" || {
                    fail migrate_rollback_failed
                    return 1
                }
            fi
            fail state_not_writable
            return 1
        fi
    fi
    if ! mkdir -p "$BIFROST_STATE" || ! chmod 700 "$BIFROST_STATE"; then
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" state_not_writable
        return 1
    fi

    # 5. Copy original state files (read-only on original, mode 600 on copy)
    job_phase migrate copy 55
    if ! cp "$BIFROST_ORIG_STATE/tailscaled.state" "$BIFROST_STATE/tailscaled.state" ||
        ! chmod 600 "$BIFROST_STATE/tailscaled.state"; then
        log migrate "failed to copy tailscaled.state"
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" state_not_writable
        return 1
    fi
    if [ -f "$BIFROST_ORIG_STATE/derpmap.cached.json" ]; then
        if ! cp "$BIFROST_ORIG_STATE/derpmap.cached.json" "$BIFROST_STATE/derpmap.cached.json" ||
            ! chmod 600 "$BIFROST_STATE/derpmap.cached.json"; then
            log migrate "failed to copy derpmap.cached.json"
            migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" state_not_writable
            return 1
        fi
    fi

    # 6. Enable and start Bifrost
    job_phase migrate starting 70
    if ! cfg_set bifrost_enable 1 || ! daemon_start; then
        _jm_start_err=${BIFROST_ERR:-start_failed}
        log migrate "bifrostd failed to start during migration ($_jm_start_err)"
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" "$_jm_start_err"
        return 1
    fi

    # PLAN 7.4: if migrated state uses a custom control server and daemon
    # started without --no-logs-no-support, restart with it before verifying.
    if daemon_should_disable_logs && ! daemon_running_has_nologs; then
        log migrate "restarting daemon to enforce --no-logs-no-support for custom control server"
        if ! daemon_restart; then
            _jm_start_err=${BIFROST_ERR:-start_failed}
            migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" "$_jm_start_err"
            return 1
        fi
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
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running" "$_jm_orig_enable" "$_jm_verify_err"
        return 1
    fi

    # 8. Success: delete backup containing old node private keys.
    if [ -n "$_jm_bak" ] && ! rm -rf "$_jm_bak"; then
        log migrate "could not remove old state backup"
        fail state_not_writable
        return 1
    fi
    status_refresh || true
    log migrate "migration succeeded"
    return 0
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

    with_lock state 60 migrate_apply_locked
}
