# shellcheck shell=sh
# Migration from the original Koolshare tailscale plugin.
# Contract: docs/dev/contract.md, sections 4, 5, 6.2.
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

# Re-enable and start the original plugin on rollback (unverified on router;
# PLAN 11.2 step 9). Only invoked when BIFROST_MIGRATE_AUTOSTOP=1.
migrate_orig_restore() {
    dbus set tailscale_enable=1 >/dev/null 2>&1 # check-sh: allow
    if [ -x "$BIFROST_ORIG_CONFIG" ]; then
        run_timeout "$BIFROST_MIGRATE_ORIG_STOP_TIMEOUT" "$BIFROST_ORIG_CONFIG" start >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

# Roll back a failed migration (PLAN 11.2 step 9).
# Args: <backup_dir_or_empty> <orig_was_running:0|1>
migrate_rollback() {
    _mrb_bak=$1
    _mrb_was_orig=$2
    job_phase migrate rollback 90
    log migrate "rolling back failed migration"

    _mrb_ok=1
    daemon_stop || _mrb_ok=0
    cfg_set bifrost_enable 0 || _mrb_ok=0

    if [ -n "$BIFROST_STATE" ] && [ -d "$BIFROST_STATE" ]; then
        rm -rf "${BIFROST_STATE:?}"/* "${BIFROST_STATE:?}"/.[!.]* "${BIFROST_STATE:?}"/..?* 2>/dev/null || _mrb_ok=0
    fi

    if [ -n "$_mrb_bak" ]; then
        if [ -d "$_mrb_bak" ]; then
            rm -rf "$BIFROST_STATE" 2>/dev/null || _mrb_ok=0
            mv "$_mrb_bak" "$BIFROST_STATE" 2>/dev/null || _mrb_ok=0
        else
            log migrate "rollback backup missing: $_mrb_bak"
            _mrb_ok=0
        fi
    fi

    if [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ] && [ "$_mrb_was_orig" = 1 ]; then
        migrate_orig_restore || {
            log migrate "failed to restart original plugin during rollback"
            _mrb_ok=0
        }
    fi

    daemon_err_clear
    status_refresh || true

    if [ "$_mrb_ok" = 1 ]; then
        job_data migrate '{"rolled_back":true}'
        fail migrate_verify_failed
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

# job_migrate: PLAN 11.2 steps 1-9, contract 6.2.
job_migrate() {
    _jm_manual="true"
    [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ] && _jm_manual="false"
    job_data migrate "{\"manual_stop\":$_jm_manual,\"rolled_back\":false}"

    # 1. Pre-check
    job_phase migrate precheck 5
    if [ ! -f "$BIFROST_ORIG_STATE/tailscaled.state" ]; then
        log migrate "precheck failed: original state missing"
        fail orig_missing
        return 1
    fi
    if [ ! -x "$BIFROST_CORE" ]; then
        log migrate "precheck failed: core missing"
        fail core_missing
        return 1
    fi
    _jm_ver=$(run_timeout 5 "$BIFROST_CORE" --version 2>/dev/null | head -n 1)
    if [ -z "$_jm_ver" ]; then
        log migrate "precheck failed: core --version failed"
        fail core_missing
        return 1
    fi
    if daemon_running; then
        log migrate "precheck failed: bifrostd already running"
        fail already_running
        return 1
    fi

    # 2. Record original identity (read-only)
    job_phase migrate record 15
    mkdir -p "$BIFROST_RUN/migrate" 2>/dev/null || true
    chmod 700 "$BIFROST_RUN/migrate" 2>/dev/null || true
    _jm_orig_was_running=0
    _jm_want_state=""
    _jm_want_id=""
    _jm_want_key=""

    if orig_running; then
        _jm_orig_was_running=1
        _jm_ocli=$(migrate_orig_cli)
        if [ -x "$_jm_ocli" ]; then
            _jm_ost=$(run_timeout 10 "$_jm_ocli" status --json 2>/dev/null)
            if [ -n "$_jm_ost" ] && printf '%s\n' "$_jm_ost" | jq -e 'type == "object"' >/dev/null 2>&1; then
                _jm_want_state=$(printf '%s\n' "$_jm_ost" | jq -r '.BackendState // ""' 2>/dev/null)
                _jm_want_id=$(printf '%s\n' "$_jm_ost" | jq -r '.Self.ID // ""' 2>/dev/null)
                _jm_want_key=$(printf '%s\n' "$_jm_ost" | jq -r '.Self.PublicKey // ""' 2>/dev/null)
                jq -n --arg s "$_jm_want_state" --arg id "$_jm_want_id" --arg pk "$_jm_want_key" \
                    '{state:$s, id:$id, public_key:$pk}' |
                    json_write "$BIFROST_RUN/migrate/record.json" || true
            else
                log migrate "could not read original status; will verify state only"
            fi
        else
            log migrate "original CLI not found; will verify state only"
        fi
    fi

    # 3/4. Wait for or stop original BEFORE touching Bifrost state
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
    else
        if orig_running || tun_exists; then
            job_phase migrate stop_original 25
            log migrate "stopping original plugin (autostop=1)"
            migrate_orig_disable_autostart || true
            if ! migrate_orig_stop; then
                log migrate "failed to stop original plugin"
                [ "$_jm_orig_was_running" = 1 ] && { migrate_orig_restore || true; }
                fail orig_still_running
                return 1
            fi
        else
            migrate_orig_disable_autostart || true
        fi
    fi

    # 3. Backup existing Bifrost state if non-empty
    job_phase migrate backup 40
    _jm_bak=""
    if [ -d "$BIFROST_STATE" ] && [ -n "$(ls -A "$BIFROST_STATE" 2>/dev/null)" ]; then
        _jm_bak="${BIFROST_STATE}.bak.$(now).$$"
        if ! mv "$BIFROST_STATE" "$_jm_bak"; then
            log migrate "failed to back up existing state"
            [ "${BIFROST_MIGRATE_AUTOSTOP:-0}" = 1 ] && [ "$_jm_orig_was_running" = 1 ] && {
                migrate_orig_restore || { fail migrate_rollback_failed; return 1; }
            }
            fail state_not_writable
            return 1
        fi
    fi
    if ! mkdir -p "$BIFROST_STATE" 2>/dev/null; then
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running"
        return 1
    fi
    chmod 700 "$BIFROST_STATE" 2>/dev/null || true

    # 5. Copy original state files (read-only on original, mode 600 on copy)
    job_phase migrate copy 55
    if ! cp "$BIFROST_ORIG_STATE/tailscaled.state" "$BIFROST_STATE/tailscaled.state" ||
        ! chmod 600 "$BIFROST_STATE/tailscaled.state"; then
        log migrate "failed to copy tailscaled.state"
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running"
        return 1
    fi
    if [ -f "$BIFROST_ORIG_STATE/derpmap.cached.json" ]; then
        if ! cp "$BIFROST_ORIG_STATE/derpmap.cached.json" "$BIFROST_STATE/derpmap.cached.json" ||
            ! chmod 600 "$BIFROST_STATE/derpmap.cached.json"; then
            log migrate "failed to copy derpmap.cached.json"
            migrate_rollback "$_jm_bak" "$_jm_orig_was_running"
            return 1
        fi
    fi

    # 6. Enable and start Bifrost
    job_phase migrate starting 70
    if ! cfg_set bifrost_enable 1 || ! daemon_start; then
        log migrate "bifrostd failed to start during migration"
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running"
        return 1
    fi

    # 7. Verify state and identity within BIFROST_MIGRATE_VERIFY_TIMEOUT
    job_phase migrate verify 85
    _jm_vdead=$(($(now) + BIFROST_MIGRATE_VERIFY_TIMEOUT))
    _jm_verified=0
    while :; do
        _jm_nst=$(ts_cli status --json 2>/dev/null)
        if [ -n "$_jm_nst" ] && printf '%s\n' "$_jm_nst" | jq -e 'type == "object"' >/dev/null 2>&1; then
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
        migrate_rollback "$_jm_bak" "$_jm_orig_was_running"
        return 1
    fi

    # 8. Success
    status_refresh || true
    log migrate "migration succeeded"
    return 0
}
