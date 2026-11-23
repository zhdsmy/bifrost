#!/bin/sh
# Tests for plugin/bifrost/lib/dns.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh

service_count() {
    if [ -f "$MOCK_STATE/service.log" ]; then
        wc -l <"$MOCK_STATE/service.log" | tr -d ' '
    else
        echo 0
    fi
}

t_setup
t_load
"$BIFROST_CORE" --socket="$BIFROST_SOCK" &
_dns_pid=$!
mkdir -p "$BIFROST_RUN"
echo "$_dns_pid" >"$BIFROST_PIDFILE"
sock_up

export BIFROST_DNSMASQ_MAIN="$T/dnsmasq.conf"

# --- Missing conf-dir file or missing conf-dir directive ---
dbus_seed bifrost_magicdns=1
ts_out status '{"BackendState":"Running","MagicDNSSuffix":"example.ts.net"}'
no conf-dir-no-file dns_has_conf_dir
no check-missing-conf-dir dns_check
BIFROST_ERR=""
no apply-no-main-file dns_apply
eq apply-no-main-code no_conf_dir "$BIFROST_ERR"
eq no-restart-on-err 0 "$(service_count)"

printf '# conf-dir=%s\nconf-dir=/other/dir\nconf-dir=%s2\n' \
    "$BIFROST_DNSMASQ_DIR" "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
no conf-dir-commented-or-other dns_has_conf_dir
no check-bad-conf-dir dns_check
BIFROST_ERR=""
no apply-no-conf-dir dns_apply
eq apply-no-conf-dir-code no_conf_dir "$BIFROST_ERR"

# --- Valid conf-dir (also with trailing slash and filter) ---
printf 'conf-dir=%s/,*.conf\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
ok conf-dir-with-filter dns_has_conf_dir
printf 'conf-dir=%s\n' "$BIFROST_DNSMASQ_DIR" >"$BIFROST_DNSMASQ_MAIN"
ok conf-dir-exact dns_has_conf_dir

# --- dns_check when magicdns=1 and file does not exist -> fails (item 19) ---
no check-missing-file dns_check

# --- Enable MagicDNS: writes file, uses --peers=false, restarts dnsmasq ---
: >"$MOCK_STATE/ts.log"
# Observe the production write path: no intermediate file enters conf-dir.
_dns_assert_stage() (
    # shellcheck disable=SC2329 # inspect mv from _dns_install_line and atomic_write
    mv() {
        case "$2" in *"/dnsmasq.d/bifrost.conf.tmp."*) return 1 ;; esac
        if [ "$3" = "$BIFROST_DNSMASQ_CONF" ]; then
            [ "${2%/*}" = "$BIFROST_DNSMASQ_DIR/.." ] || return 1
        fi
        command mv "$@"
    }
    dns_apply
)
ok apply-on _dns_assert_stage
has dns-uses-peers-false "status --json --peers=false" "$(ts_log)"
eq conf-content "server=/example.ts.net/100.100.100.100" "$(cat "$BIFROST_DNSMASQ_CONF")"
eq restart-after-on 1 "$(service_count)"
eq restart-cmd "restart_dnsmasq" "$(tail -n 1 "$MOCK_STATE/service.log")"
ok check-after-on dns_check

# --- Unchanged content: does NOT restart dnsmasq ---
ok apply-unchanged dns_apply
eq no-restart-unchanged 1 "$(service_count)"
ok check-still-ok dns_check

# --- Suffix changes: updates file and restarts dnsmasq ---
ts_out status '{"BackendState":"Running","MagicDNSSuffix":"","CurrentTailnet":{"MagicDNSSuffix":"alt.example.ts.net"}}'
no check-stale dns_check
ok apply-suffix-change dns_apply
eq conf-updated "server=/alt.example.ts.net/100.100.100.100" "$(cat "$BIFROST_DNSMASQ_CONF")"
eq restart-after-change 2 "$(service_count)"
ok check-after-change dns_check
# Passing status JSON directly to dns_check avoids CLI call
ok check-with-arg dns_check '{"CurrentTailnet":{"MagicDNSSuffix":"alt.example.ts.net"}}'
no check-with-wrong-arg dns_check '{"MagicDNSSuffix":"example.ts.net"}'

# --- Distinct error codes for not_running / cli_failed / timeout vs no_magicdns (item 8) ---
mv "$BIFROST_DNSMASQ_CONF" "$T/saved.conf"
rm -f "$BIFROST_PIDFILE"
BIFROST_ERR=""
no apply-not-running dns_apply
eq apply-not-running-code not_running "$BIFROST_ERR"
echo "$_dns_pid" >"$BIFROST_PIDFILE"
mv "$T/saved.conf" "$BIFROST_DNSMASQ_CONF"

ts_rc status 1
BIFROST_ERR=""
no apply-cli-failed dns_apply
eq apply-cli-failed-code cli_failed "$BIFROST_ERR"

ts_rc status 124
BIFROST_ERR=""
no apply-timeout dns_apply
eq apply-timeout-code timeout "$BIFROST_ERR"
ts_rc status 0

# Corrupt non-JSON status output -> cli_failed (not no_magicdns)
ts_out status 'not-json'
BIFROST_ERR=""
no apply-bad-json dns_apply
eq apply-bad-json-code cli_failed "$BIFROST_ERR"

# --- Missing or invalid suffix fails with no_magicdns ---
ts_out status '{"BackendState":"Running","MagicDNSSuffix":""}'
BIFROST_ERR=""
no apply-empty-suffix dns_apply
eq apply-empty-code no_magicdns "$BIFROST_ERR"
no no-rule-without-suffix [ -e "$BIFROST_DNSMASQ_CONF" ]
eq removed-empty-suffix 3 "$(service_count)"

ts_out status '{"BackendState":"Running","MagicDNSSuffix":"bad;rm -rf /"}'
BIFROST_ERR=""
no apply-bad-suffix dns_apply
eq apply-bad-code cli_failed "$BIFROST_ERR"
eq no-restart-bad 3 "$(service_count)"

ts_out status '{"BackendState":"Running","MagicDNSSuffix":"Upper.Example.ts.net"}'
BIFROST_ERR=""
no apply-upper-suffix dns_apply
eq apply-upper-code cli_failed "$BIFROST_ERR"

ts_out status '{"BackendState":"Running","MagicDNSSuffix":".example.ts.net."}'
BIFROST_ERR=""
no apply-dot-suffix dns_apply
eq apply-dot-code cli_failed "$BIFROST_ERR"

ts_out status '{"BackendState":"NeedsLogin","MagicDNSSuffix":"example.ts.net"}'
printf 'server=/example.ts.net/100.100.100.100\n' >"$BIFROST_DNSMASQ_CONF"
no login-stale-check dns_check
no login-stale-apply dns_apply
eq login-stale-code not_running "$BIFROST_ERR"
ok login-clean-check dns_check
eq login-stale-removed 4 "$(service_count)"
ts_out status '{"BackendState":"Running","MagicDNSSuffix":"example.ts.net"}'
ok restore-active-rule dns_apply

# --- Disable MagicDNS: dns_apply equals dns_clear, removes file and restarts ---
dbus_seed bifrost_magicdns=0
no check-off-file-still-there dns_check
ok apply-off dns_apply
no file-removed [ -e "$BIFROST_DNSMASQ_CONF" ]
eq restart-after-off 6 "$(service_count)"
ok check-after-off dns_check

# --- Second dns_clear / dns_apply when already clean: no extra restart ---
ok clear-noop dns_clear
eq no-restart-clear-noop 6 "$(service_count)"
ok apply-off-noop dns_apply
eq no-restart-off-noop 6 "$(service_count)"

# --- Leftover .tmp.* file inside conf-dir is detected by dns_check and cleaned by dns_clear (item 9 & 19) ---
printf 'server=/example.ts.net/100.100.100.100\n' >"$BIFROST_DNSMASQ_CONF.tmp.99999"
no check-detects-tmp-leftover dns_check
touch "$BIFROST_DNSMASQ_DIR/../.bifrost-dns-stage.123.tmp.123"
ok clear-removes-tmp dns_clear
no external-temp-gone [ -e "$BIFROST_DNSMASQ_DIR/../.bifrost-dns-stage.123.tmp.123" ]
no tmp-leftover-gone [ -e "$BIFROST_DNSMASQ_CONF.tmp.99999" ]
eq restart-after-tmp-clear 7 "$(service_count)"
ok check-clean-after-tmp dns_check

# --- dns_clear failure path when rm fails (item 19): directory at conf path cannot be rm -f'd ---
mkdir -p "$BIFROST_DNSMASQ_CONF"
BIFROST_ERR=""
no clear-rm-fails dns_clear
eq clear-rm-fails-code internal "$BIFROST_ERR"
eq no-restart-on-rm-fail 7 "$(service_count)"
rmdir "$BIFROST_DNSMASQ_CONF"

# --- No temp files left behind in conf-dir or run dir ---
eq no-tmp-files "" "$(find "$BIFROST_DNSMASQ_DIR" -name '*tmp*')"
eq no-run-tmp-files "" "$(find "$BIFROST_RUN" -name 'dnsmasq.bifrost.tmp.*')"

kill "$_dns_pid"
wait "$_dns_pid" 2>/dev/null
t_done
