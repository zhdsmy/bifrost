#!/bin/sh
# Tests for plugin/bifrost/lib/login.sh (integrated with real P1/P3 libs).
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

fresh() {
    t_setup
    t_load
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=1
    BIFROST_FW_RETRY_SLEEP=0
    BIFROST_LOGIN_TIMEOUT=10m
    BIFROST_LOGIN_CLI_TIMEOUT=10
    BIFROST_CONNECT_TIMEOUT=5
    BIFROST_LOGOUT_TIMEOUT=5
    BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"
    printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
    nvram_seed lan_ipaddr=192.168.1.1 lan_netmask=255.255.255.0 sw_mode=1 http_enable=0 http_lanport=80
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

start_mock() {
    daemon_start || return 1
    : >"$MOCK_STATE/ts.log"
    : >"$MOCK_STATE/iptables.log"
}

# --- 1. Validation, not_running, and stale authkey cleanup ---

fresh
mkdir -p "$BIFROST_RUN"
echo "stale_secret_key_1234567890" >"$BIFROST_RUN/authkey"
no login-not-running act_login "" ""
eq login-not-running-err not_running "$BIFROST_ERR"
no login-stale-key-cleaned [ -f "$BIFROST_RUN/authkey" ]
no relogin-not-running act_relogin
eq relogin-not-running-err not_running "$BIFROST_ERR"
no connect-not-running act_connect
eq connect-not-running-err not_running "$BIFROST_ERR"
no logout-not-running act_logout
eq logout-not-running-err not_running "$BIFROST_ERR"

start_mock
no login-bad-server act_login "ftp://bad.example.com" ""
eq login-bad-server-err bad_server "$BIFROST_ERR"
no login-bad-key act_login "" "short"
eq login-bad-key-err bad_authkey "$BIFROST_ERR"
no login-bad-key-chars act_login "" "invalid!key@1234567890"
eq login-bad-key-chars-err bad_authkey "$BIFROST_ERR"

# --- 2. First login (empty ControlURL) ---

ts_out debug-prefs '{}'
ok login-first act_login "" ""
eq login-first-res '{"job":"login"}' "$BIFROST_RESULT"
bg_drain
jf=$(job_file login)
eq login-first-job "false true done login true" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.data.action) \(.data.official)"' "$jf")"
line=$(grep '^up ' "$MOCK_STATE/ts.log" | tail -n 1)
eq login-first-args "up --reset --accept-dns=false --netfilter-mode=off --accept-routes=false --advertise-routes= --advertise-exit-node=false --hostname= --timeout=10m" "$line"
ok login-first-fw-applied fw_check

# --- 3. Existing prefs preserved on official re-up ---

: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_drifted.json"
ok login-existing act_login "" ""
bg_drain
line=$(grep '^up ' "$MOCK_STATE/ts.log" | tail -n 1)
eq login-existing-args "up --reset --accept-dns=false --netfilter-mode=off --accept-routes=true --advertise-routes=192.168.1.0/24 --advertise-exit-node=true --hostname=home-router --timeout=10m" "$line"

# --- 4. Switch control server uses "tailscale login" (no --reset, no --force-reauth) ---

: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
ok login-switch act_login "https://headscale.example.com" ""
bg_drain
eq login-switch-job "true false" "$(jq -r '"\(.ok) \(.data.official)"' "$jf")"
line=$(grep '^login ' "$MOCK_STATE/ts.log" | tail -n 1)
eq login-switch-args "login --accept-dns=false --netfilter-mode=off --accept-routes=false --advertise-routes= --advertise-exit-node=false --hostname= --login-server=https://headscale.example.com --timeout=10m" "$line"
eq login-switch-recorded "https://headscale.example.com" "$(daemon_control_server)"

# Switch back from custom server to official uses "tailscale login" without --login-server
: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_custom.json"
ok login-back-official act_login "" ""
bg_drain
eq login-back-job "true true" "$(jq -r '"\(.ok) \(.data.official)"' "$jf")"
line=$(grep '^login ' "$MOCK_STATE/ts.log" | tail -n 1)
eq login-back-args "login --accept-dns=false --netfilter-mode=off --accept-routes=true --advertise-routes=192.168.1.0/24,198.51.100.0/24 --advertise-exit-node=false --hostname=edge-router --timeout=10m" "$line"
eq login-back-cleared "" "$(daemon_control_server)"

# http:// control server is accepted by scripts (page warns)
: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
ok login-http act_login "http://headscale.example.com:8080" ""
bg_drain
eq login-http-ok true "$(jq -r .ok "$jf")"
has login-http-arg "--login-server=http://headscale.example.com:8080" "$(ts_log)"

# --- 5. Non-official login when bifrost_no_logs=0 restarts daemon with --no-logs-no-support ---

daemon_stop
dbus_seed bifrost_no_logs=0
daemon_set_control_server ""
ts_out_file debug-prefs "$FIX/prefs_ok.json"
ok login-nologs-start daemon_start
no login-nologs-initially-off daemon_running_has_nologs
p_before=$(daemon_pid)
ok login-nologs-custom act_login "https://headscale.example.com" ""
bg_drain
eq login-nologs-ok true "$(jq -r .ok "$jf")"
ok login-nologs-restarted [ "$p_before" != "$(daemon_pid)" ]
ok login-nologs-enforced daemon_running_has_nologs
dbus_seed bifrost_no_logs=1

# --- 6. Pre-auth key handling: mode 600, deleted on ok/fail/start-fail, never leaked ---

secret="fake_preauth_key_0123456789abcdef"
: >"$MOCK_STATE/ts.log"
: >"$BIFROST_LOG"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
# Exercise the real nohup/dispatcher boundary. The fake CLI verifies the
# inherited file as Tailscale would, recording only the mode and comparison.
cat >"$T/key-cli" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --auth-key=file:*)
            keyfile=${arg#--auth-key=file:}
            # shellcheck disable=SC2012
            ls -lL "$keyfile" | cut -c1-10 >"$MOCK_STATE/key.mode"
            [ "$(cat "$keyfile")" = "fake_preauth_key_0123456789abcdef" ] || exit 1
            echo yes >"$MOCK_STATE/key.read"
            ;;
    esac
done
exec "$BIFROST_KSROOT/bifrost/bin/tailscale" "$@"
EOF
chmod 755 "$T/key-cli"
async_key() {
    env BIFROST_CLI="$T/key-cli" BIFROST_BG_SYNC=0 sh "$BIFROST_SCRIPTS/bifrost_config.sh" 1 login "https://headscale.example.com" "$secret" || return 1
    _ak_i=0
    while [ "$_ak_i" -lt 60 ]; do
        [ "$(jq -r .running "$jf")" = false ] && return 0
        sleep 1
        _ak_i=$((_ak_i + 1))
    done
    return 1
}
ok login-authkey async_key
eq authkey-job-ok true "$(jq -r .ok "$jf")"
eq authkey-mode "-rw-------" "$(cat "$MOCK_STATE/key.mode")"
eq authkey-read yes "$(cat "$MOCK_STATE/key.read")"
no authkey-deleted-ok [ -e "$BIFROST_RUN/authkey" ]
has authkey-file-arg "--auth-key=file:/proc/self/fd/3" "$(ts_log)"
no authkey-not-in-tslog grep -Fq "$secret" "$MOCK_STATE/ts.log"
no authkey-not-in-log grep -Fq "$secret" "$BIFROST_LOG"
no authkey-not-in-jobfile grep -Fq "$secret" "$jf"
# A queue request exposes only a descriptor indicator, even in a test queue.
ok authkey-queue act_login "" "$secret"
ok authkey-queue-exists [ -s "$BIFROST_RUN/bg_queue" ]
eq authkey-queue-args "login login - 1" "$(cat "$BIFROST_RUN/bg_queue")"
no authkey-before-worker [ -e "$BIFROST_RUN/authkey" ]
bg_drain
eq authkey-worker-without-descriptor bad_authkey "$(jq -r .code "$jf")"

ts_rc login 1
ok login-authkey-fail async_key
eq authkey-fail-code cli_failed "$(jq -r .code "$jf")"
no authkey-deleted-fail [ -e "$BIFROST_RUN/authkey" ]
rm -f "$MOCK_STATE/ts/login.rc"

# Kill just the isolated request process at the handoff, before worker exec.
# shellcheck disable=SC2016
no authkey-killed-before-launch sh -c '
    BIFROST_NO_MAIN=1
    . "$BIFROST_KSROOT/scripts/bifrost_config.sh"
    bg_job() { : >"$MOCK_STATE/at-handoff"; kill -KILL "$$"; }
    act_login "" fake_preauth_key_0123456789abcdef
' 2>/dev/null
ok authkey-kill-reached-handoff [ -f "$MOCK_STATE/at-handoff" ]
no authkey-no-orphan-after-kill [ -e "$BIFROST_RUN/authkey" ]
no authkey-no-live-job-after-kill job_running login

# Auth key deleted when job_start fails (fault stub)
job_start() { fail internal; return 1; }
no login-jobstart-fail act_login "https://headscale.example.com" "$secret"
no authkey-deleted-start-fail [ -f "$BIFROST_RUN/authkey" ]
t_load
BIFROST_FW_RETRY_SLEEP=0
BIFROST_LOGIN_CLI_TIMEOUT=10
BIFROST_CONNECT_TIMEOUT=5
BIFROST_LOGOUT_TIMEOUT=5

# job_login when daemon stopped before job runs -> not_running + key deleted
ok login-stop-before-job act_login "" "$secret"
daemon_stop
bg_drain
eq login-stopped-code not_running "$(jq -r .code "$jf")"
no authkey-deleted-not-running [ -f "$BIFROST_RUN/authkey" ]

# --- 7. Relogin (--force-reauth) & unreadable prefs safety ---

start_mock
: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_custom.json"
ok relogin-ok act_relogin
bg_drain
eq relogin-job "true relogin false" "$(jq -r '"\(.ok) \(.data.action) \(.data.official)"' "$jf")"
line=$(grep '^up ' "$MOCK_STATE/ts.log" | tail -n 1)
has relogin-reset "--reset" "$line"
has relogin-force "--force-reauth" "$line"
has relogin-srv "--login-server=https://headscale.example.com" "$line"

# Relogin when prefs fail AND no recorded control_url -> fails (never defaults to official!)
daemon_set_control_server ""
ts_rc debug-prefs 1
: >"$MOCK_STATE/ts.log"
ok relogin-noprefs-start act_relogin
bg_drain
eq relogin-noprefs-fail "false cli_failed" "$(jq -r '"\(.ok) \(.code)"' "$jf")"
no relogin-noprefs-no-up grep -q '^up ' "$MOCK_STATE/ts.log"

# Relogin when prefs fail BUT control_url IS recorded -> uses recorded custom server
daemon_set_control_server "https://headscale.example.com"
: >"$MOCK_STATE/ts.log"
ok relogin-recorded-start act_relogin
bg_drain
eq relogin-recorded-ok "true false" "$(jq -r '"\(.ok) \(.data.official)"' "$jf")"
no relogin-recorded-no-reset grep -E -- '--reset|--hostname=|--advertise-routes=' "$MOCK_STATE/ts.log"
has relogin-recorded-srv "--login-server=https://headscale.example.com" "$(grep '^up ' "$MOCK_STATE/ts.log")"
rm -f "$MOCK_STATE/ts/debug-prefs.rc"

# Relogin when prefs have empty ControlURL and no recorded control_url -> not_logged_in
daemon_set_control_server ""
ts_out debug-prefs '{}'
ok relogin-empty-ctrl act_relogin
bg_drain
eq relogin-empty-ctrl-err "false not_logged_in" "$(jq -r '"\(.ok) \(.code)"' "$jf")"

# --- 8. Login wait does NOT hold state lock: act_set & disable work while waiting ---

ts_out_file debug-prefs "$FIX/prefs_ok.json"
cat >"$T/wait-for-disable" <<'EOF'
#!/bin/sh
case "$2" in
    up)
        : >"$MOCK_STATE/up.waiting"
        while [ -e "$BIFROST_SOCK_DIR/tailscaled.sock" ]; do sleep 1; done
        exit 1 ;;
esac
exec "$BIFROST_KSROOT/bifrost/bin/tailscale" "$@"
EOF
chmod 755 "$T/wait-for-disable"
job_begin login
env BIFROST_CLI="$T/wait-for-disable" BIFROST_LOGIN_CLI_TIMEOUT=90 sh "$BIFROST_SCRIPTS/bifrost_config.sh" local job login login - 0 &
login_bg_pid=$!
i=0
while [ "$i" -lt 30 ] && [ ! -f "$MOCK_STATE/up.waiting" ]; do
    sleep 1
    i=$((i + 1))
done
ok login-wait-entered [ -f "$MOCK_STATE/up.waiting" ]
eq login-wait-phase running "$(jq -r .phase "$jf")"
no login-wait-no-lock [ -d "$BIFROST_RUN/lock.state" ]
ok login-wait-set-works act_set mirror "https://mirror.example.com/"
eq login-wait-set-val '{"value":"https://mirror.example.com/"}' "$BIFROST_RESULT"
eq login-wait-still-running true "$(jq -r .running "$jf")"
ok login-wait-disable-works act_disable
bg_drain
no login-wait-daemon-stopped daemon_running
wait "$login_bg_pid" 2>/dev/null
eq login-wait-ended-fail "false cli_failed" "$(jq -r '"\(.running) \(.code)"' "$jf")"

# --- 9. Timeouts (tailscale --timeout msg, 124, AND SIGTERM-catching exit 1) ---

start_mock
: >"$BIFROST_LOG"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
printf '\nTo authenticate, visit:\n\n\thttps://login.example.com/a/secret_auth_token\n\ntimeout waiting for Tailscale service to enter a Running state\n' >"$MOCK_STATE/ts/up.err"
ts_rc up 1
ok login-expire-start act_login "" ""
bg_drain
eq login-expire-code login_expired "$(jq -r .code "$jf")"
no login-authurl-not-logged grep -Fq "secret_auth_token" "$BIFROST_LOG"
rm -f "$MOCK_STATE/ts/up.err" "$MOCK_STATE/ts/up.rc"

# Simulate real tailscale up catching SIGTERM and exiting 1 (not 143/124)
cat >"$T/sigterm_cli" <<'EOF'
#!/bin/sh
[ "$2" = up ] || exec "$BIFROST_KSROOT/bifrost/bin/tailscale" "$@"
trap 'exit 1' TERM
while :; do sleep 1; done
EOF
chmod 755 "$T/sigterm_cli"
SAVED_CLI=$BIFROST_CLI
BIFROST_CLI="$T/sigterm_cli"
BIFROST_LOGIN_CLI_TIMEOUT=1
ok login-sigterm-start act_login "" ""
bg_drain
eq login-sigterm-expired login_expired "$(jq -r .code "$jf")"
BIFROST_CLI=$SAVED_CLI
BIFROST_LOGIN_CLI_TIMEOUT=10

# Busy when login job already running
job_begin login
no login-busy act_login "" ""
eq login-busy-err busy "$BIFROST_ERR"
job_end login ok

# --- 10. act_connect (NeedsLogin, backend_state err, Stopped, fallback, cli_failed, timeout) ---

ts_out_file status "$FIX/status_needs_login.json"
no connect-needs-login act_connect
eq connect-needs-login-err not_logged_in "$BIFROST_ERR"

# Real error code from backend_state preserved (not lost as internal!)
ts_rc status 1
no connect-status-fail act_connect
eq connect-status-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/status.rc"

ts_out_file status "$FIX/status_stopped.json"
: >"$MOCK_STATE/ts.log"
ok connect-stopped act_connect
eq connect-bare-up "up" "$(grep '^up' "$MOCK_STATE/ts.log" | head -n 1)"

# Plain cli_failed on up
ts_rc up 1
no connect-cli-fail act_connect
eq connect-cli-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/up.rc"

# Fallback when bare "up" hits accidental-revert error
: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_custom.json"
echo "Error: changing settings via 'tailscale up' requires mentioning all non-default flags" >"$MOCK_STATE/ts/up.err"
ts_rc up 1
no connect-fallback-tried act_connect
has connect-fallback-flags "--netfilter-mode=off" "$(ts_log)"
has connect-fallback-routes "--advertise-routes=192.168.1.0/24,198.51.100.0/24" "$(ts_log)"
no connect-fallback-no-reset grep -Fq -- '--reset' "$MOCK_STATE/ts.log"
rm -f "$MOCK_STATE/ts/up.err" "$MOCK_STATE/ts/up.rc"

# Timeout when up catches SIGTERM and exits 1 -> timeout
# Intercept only "up" while letting status succeed
cat >"$T/sigterm_up_cli" <<EOF
#!/bin/sh
for _a in "\$@"; do
    if [ "\$_a" = up ]; then
        trap 'echo "context canceled" >&2; exit 1' TERM
        sleep 10 &
        wait \$!
    fi
done
exec "$SAVED_CLI" "\$@"
EOF
chmod 755 "$T/sigterm_up_cli"
BIFROST_CLI="$T/sigterm_up_cli"
BIFROST_CONNECT_TIMEOUT=1
no connect-sigterm-timeout act_connect
eq connect-sigterm-timeout-err timeout "$BIFROST_ERR"
BIFROST_CLI=$SAVED_CLI
BIFROST_CONNECT_TIMEOUT=5

# Already Running -> succeeds without running up
ts_out_file status "$FIX/status_running.json"
: >"$MOCK_STATE/ts.log"
ok connect-already-running act_connect
no connect-already-no-up grep -q '^up' "$MOCK_STATE/ts.log"

# --- 11. act_logout (ok, cli_failed, timeout) ---

dbus_seed bifrost_magicdns=1
dns_apply
ok logout-dns-existed [ -f "$BIFROST_DNSMASQ_CONF" ]
: >"$MOCK_STATE/ts.log"
ok logout-ok act_logout
has logout-called "logout" "$(ts_log)"
no logout-dns-cleared [ -f "$BIFROST_DNSMASQ_CONF" ]

ts_rc logout 1
no logout-fail act_logout
eq logout-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/logout.rc"

BIFROST_LOGOUT_TIMEOUT=1
echo 5 >"$MOCK_STATE/ts/logout.sleep"
no logout-timeout act_logout
eq logout-timeout-err timeout "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/logout.sleep"

daemon_stop
fresh
dbus_seed bifrost_enable=1 bifrost_no_logs=0
ok login-post-start start_mock
ts_rc debug-prefs 1
ts_out_file status "$FIX/status_needs_login.json"
echo existing >"$BIFROST_STATE/tailscaled.state"
ok login-unknown-queued act_login "" ""
bg_drain
eq login-unknown-preserves-error cli_failed "$(jq -r .code "$jf")"
no login-unknown-no-up grep -Eq '^(login|up) ' "$MOCK_STATE/ts.log"
rm "$BIFROST_STATE/tailscaled.state"
daemon_set_control_server https://headscale.example.com
ok login-record-only-queued act_login "" ""
bg_drain
eq login-record-only-error cli_failed "$(jq -r .code "$jf")"
no login-record-only-no-reset grep -q -- --reset "$MOCK_STATE/ts.log"
daemon_set_control_server ""
ts_out_file status "$FIX/status_running.json"
ok login-live-identity-queued act_login "" ""
bg_drain
eq login-live-identity-error cli_failed "$(jq -r .code "$jf")"
ts_out_file status "$FIX/status_needs_login.json"
echo '{"_machinekey":"fixture"}' >"$BIFROST_STATE/tailscaled.state"
ok login-confirmed-new act_login "" ""
bg_drain
eq login-confirmed-new-ok true "$(jq -r .ok "$jf")"
has login-confirmed-new-up "up --reset" "$(ts_log)"
rm "$MOCK_STATE/ts/debug-prefs.rc"
ts_out_file status "$FIX/status_running.json"

dbus_seed bifrost_magicdns=1
: >"$BIFROST_DNSMASQ_MAIN"
ok login-dns-queued act_login "" ""
bg_drain
eq login-dns-authenticated true "$(jq -r .ok "$jf")"
eq login-dns-page-error no_conf_dir "$(jq -r .error "$BIFROST_UPLOAD/bifrost_status.json")"
ok login-dns-retry watchdog_run
eq login-dns-keeps-code no_conf_dir "$(cat "$BIFROST_DAEMON_ERR")"
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
ok login-dns-repaired watchdog_run
no login-dns-cleared [ -e "$BIFROST_DAEMON_ERR" ]
ok login-dns-forwarding dns_check

iptables -t filter -D INPUT -j BIFROST_INPUT
echo 4 >"$MOCK_STATE/iptables.fail_count"
echo '-A BIFROST_INPUT' >"$MOCK_STATE/iptables.fail_match"
ok login-fw-queued act_login "" ""
bg_drain
eq login-fw-visible fw_failed "$(cat "$BIFROST_DAEMON_ERR")"
ok login-fw-repaired watchdog_run
no login-fw-cleared [ -e "$BIFROST_DAEMON_ERR" ]
ok login-fw-complete fw_check

: >"$MOCK_STATE/daemon.fail"
ok login-restart-error-queued act_login https://headscale.example.com ""
bg_drain
eq login-restart-error-code start_failed "$(jq -r .code "$jf")"
no login-restart-error-stopped daemon_running
t_done
