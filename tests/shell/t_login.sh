#!/bin/sh
# Tests for plugin/bifrost/lib/login.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh

FIX="$T_SRC/tests/shell/fixtures/runtime"

p3_stubs() {
    fw_apply() { echo "fw_apply" >>"$MOCK_STATE/p3.log"; return 0; }
    fw_clear() { echo "fw_clear" >>"$MOCK_STATE/p3.log"; return 0; }
    fw_check() { return 0; }
    dns_apply() { echo "dns_apply" >>"$MOCK_STATE/p3.log"; return 0; }
    dns_clear() { echo "dns_clear" >>"$MOCK_STATE/p3.log"; return 0; }
    dns_check() { return 0; }
    status_refresh() { echo "status_refresh" >>"$MOCK_STATE/p3.log"; return 0; }
}

fresh() {
    t_setup
    t_load
    p3_stubs
    BIFROST_WAIT_READY=5
    BIFROST_STOP_TIMEOUT=1
    BIFROST_LOGIN_TIMEOUT=10m
    BIFROST_LOGIN_CLI_TIMEOUT=10
    BIFROST_CONNECT_TIMEOUT=5
    BIFROST_LOGOUT_TIMEOUT=5
    ts_out_file status "$FIX/status_running.json"
    ts_out_file debug-prefs "$FIX/prefs_ok.json"
}

start_mock() {
    daemon_start || return 1
    : >"$MOCK_STATE/ts.log"
    : >"$MOCK_STATE/p3.log"
}

# --- 1. Validation & not_running ---

fresh
no login-not-running act_login "" ""
eq login-not-running-err not_running "$BIFROST_ERR"
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
has login-first-fw "fw_apply" "$(cat "$MOCK_STATE/p3.log")"

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

# --- 5. Pre-auth key handling: mode 600, deleted after job, never leaked ---

secret="fake_preauth_key_0123456789abcdef"
: >"$MOCK_STATE/ts.log"
: >"$BIFROST_LOG"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
ok login-authkey act_login "https://headscale.example.com" "$secret"
ok authkey-file-exists [ -f "$BIFROST_RUN/authkey" ]
# shellcheck disable=SC2012
eq authkey-mode "-rw-------" "$(ls -l "$BIFROST_RUN/authkey" | cut -c1-10)"
no authkey-not-in-queue grep -Fq "$secret" "$BIFROST_RUN/bg_queue"
no authkey-not-in-jobfile grep -Fq "$secret" "$jf"
bg_drain
eq authkey-job-ok true "$(jq -r .ok "$jf")"
no authkey-deleted-ok [ -f "$BIFROST_RUN/authkey" ]
has authkey-file-arg "--auth-key=file:$BIFROST_RUN/authkey" "$(ts_log)"
no authkey-not-in-tslog grep -Fq "$secret" "$MOCK_STATE/ts.log"
no authkey-not-in-log grep -Fq "$secret" "$BIFROST_LOG"
no authkey-not-in-jobfile-after grep -Fq "$secret" "$jf"

# Auth key deleted on failure too
ts_rc login 1
ok login-authkey-fail act_login "https://headscale.example.com" "$secret"
ok authkey-exists-before-fail [ -f "$BIFROST_RUN/authkey" ]
bg_drain
eq authkey-fail-code cli_failed "$(jq -r .code "$jf")"
no authkey-deleted-fail [ -f "$BIFROST_RUN/authkey" ]
rm -f "$MOCK_STATE/ts/login.rc"

# --- 6. Relogin (--force-reauth) ---

: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_custom.json"
ok relogin-ok act_relogin
bg_drain
eq relogin-job "true relogin false" "$(jq -r '"\(.ok) \(.data.action) \(.data.official)"' "$jf")"
line=$(grep '^up ' "$MOCK_STATE/ts.log" | tail -n 1)
has relogin-reset "--reset" "$line"
has relogin-force "--force-reauth" "$line"
has relogin-srv "--login-server=https://headscale.example.com" "$line"

# --- 7. Login timeout -> login_expired, AuthURL never logged ---

: >"$BIFROST_LOG"
ts_out_file debug-prefs "$FIX/prefs_ok.json"
printf '\nTo authenticate, visit:\n\n\thttps://login.example.com/a/secret_auth_token\n\ntimeout waiting for Tailscale service to enter a Running state\n' >"$MOCK_STATE/ts/up.err"
ts_rc up 1
ok login-expire-start act_login "" ""
bg_drain
eq login-expire-code login_expired "$(jq -r .code "$jf")"
no login-authurl-not-logged grep -Fq "secret_auth_token" "$BIFROST_LOG"
rm -f "$MOCK_STATE/ts/up.err" "$MOCK_STATE/ts/up.rc"

# Outer timeout (124) also yields login_expired
BIFROST_LOGIN_CLI_TIMEOUT=1
echo 5 >"$MOCK_STATE/ts/up.sleep"
ok login-outer-timeout act_login "" ""
bg_drain
eq login-outer-timeout-code login_expired "$(jq -r .code "$jf")"
rm -f "$MOCK_STATE/ts/up.sleep"
BIFROST_LOGIN_CLI_TIMEOUT=10

# Busy when login job already running
job_begin login
no login-busy act_login "" ""
eq login-busy-err busy "$BIFROST_ERR"
job_end login ok

# --- 8. act_connect ---

ts_out_file status "$FIX/status_needs_login.json"
no connect-needs-login act_connect
eq connect-needs-login-err not_logged_in "$BIFROST_ERR"

ts_out_file status "$FIX/status_stopped.json"
: >"$MOCK_STATE/ts.log"
ok connect-stopped act_connect
eq connect-bare-up "up" "$(grep '^up' "$MOCK_STATE/ts.log" | head -n 1)"

# Fallback when bare "up" hits accidental-revert error
: >"$MOCK_STATE/ts.log"
ts_out_file debug-prefs "$FIX/prefs_custom.json"
echo "Error: changing settings via 'tailscale up' requires mentioning all non-default flags" >"$MOCK_STATE/ts/up.err"
ts_rc up 1
no connect-fallback-tried act_connect
# Both bare "up" and the full-flags retry (without --reset) were attempted
has connect-fallback-flags "--netfilter-mode=off" "$(ts_log)"
has connect-fallback-routes "--advertise-routes=192.168.1.0/24,198.51.100.0/24" "$(ts_log)"
no connect-fallback-no-reset grep -Fq -- '--reset' "$MOCK_STATE/ts.log"
rm -f "$MOCK_STATE/ts/up.err" "$MOCK_STATE/ts/up.rc"

# Already Running -> succeeds without running up
ts_out_file status "$FIX/status_running.json"
: >"$MOCK_STATE/ts.log"
ok connect-already-running act_connect
no connect-already-no-up grep -q '^up' "$MOCK_STATE/ts.log"

# --- 9. act_logout ---

: >"$MOCK_STATE/ts.log"
: >"$MOCK_STATE/p3.log"
ok logout-ok act_logout
has logout-called "logout" "$(ts_log)"
has logout-dns-clear "dns_clear" "$(cat "$MOCK_STATE/p3.log")"

ts_rc logout 1
no logout-fail act_logout
eq logout-fail-err cli_failed "$BIFROST_ERR"
rm -f "$MOCK_STATE/ts/logout.rc"

daemon_stop
t_done
