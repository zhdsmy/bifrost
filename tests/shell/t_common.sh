#!/bin/sh
# Tests for plugin/bifrost/lib/common.sh and lib/env.sh.
# shellcheck disable=SC1091
. tests/shell/lib.sh
t_setup
t_load

# env.sh: every path is inside the sandbox.
for val in "$BIFROST_HOME" "$BIFROST_CORE" "$BIFROST_CLI" "$BIFROST_STATE" "$BIFROST_RUN" \
    "$BIFROST_SOCK" "$BIFROST_UPLOAD" "$BIFROST_DNSMASQ_CONF" "$BIFROST_PIDFILE" "$BIFROST_TUN_DEV"; do
    has "path in sandbox" "$T/" "$val"
done
eq sock-path "$T/sock/tailscaled.sock" "$BIFROST_SOCK"

# cfg / cfg_set
eq cfg-default 41641 "$(cfg bifrost_port)"
dbus_seed bifrost_port=50000
eq cfg-set-value 50000 "$(cfg bifrost_port)"
dbus_seed 'bifrost_port=80;id'
eq cfg-invalid-falls-back 41641 "$(cfg bifrost_port)"
ok cfg_set-valid cfg_set bifrost_snat on
eq cfg_set-written on "$(dbus get bifrost_snat)"
no cfg_set-invalid cfg_set bifrost_snat maybe
eq cfg_set-code invalid_param "$BIFROST_ERR"
eq cfg_set-unchanged on "$(dbus get bifrost_snat)"
ok cfg_set-empty-mirror cfg_set bifrost_mirror ''
eq cfg-mirror-default "" "$(cfg bifrost_mirror)"
no cfg_set-unknown-key cfg_set bifrost_evil 1

# atomic_write / json_write
mkdir -p "$BIFROST_RUN"
printf 'hello\n' | atomic_write "$BIFROST_RUN/a.txt" 600
eq atomic-content hello "$(cat "$BIFROST_RUN/a.txt")"
# shellcheck disable=SC2012
eq atomic-mode "-rw-------" "$(ls -l "$BIFROST_RUN/a.txt" | cut -c1-10)"
echo '{"a": 1}' | json_write "$BIFROST_RUN/j.json"
eq json-compact '{"a":1}' "$(cat "$BIFROST_RUN/j.json")"
echo 'not json' >"$BIFROST_RUN/bad.txt"
BIFROST_ERR=""
json_write "$BIFROST_RUN/j.json" <"$BIFROST_RUN/bad.txt"
eq json-bad-keeps-old '{"a":1}' "$(cat "$BIFROST_RUN/j.json")"
eq json-bad-code internal "$BIFROST_ERR"
rm -f "$BIFROST_RUN/bad.txt"
eq json-no-temp "" "$(find "$BIFROST_RUN" -name '*tmp*')"

# run_timeout
run_timeout 5 sh -c 'exit 3'
eq timeout-rc 3 "$?"
start=$(date +%s)
run_timeout 1 sleep 30
eq timeout-124 124 "$?"
took=$(($(date +%s) - start))
ok timeout-fast [ "$took" -le 4 ]
eq timeout-output hi "$(run_timeout 5 echo hi)"

# locks
ok lock-take lock_acquire test 0
no lock-busy sh -c ". '$BIFROST_LIB/env.sh'; . '$BIFROST_LIB/validate.sh'; . '$BIFROST_LIB/common.sh'; lock_acquire test 0"
lock_release test
ok lock-again lock_acquire test 0
lock_release test
mkdir -p "$BIFROST_RUN/lock.stale"
echo 999999 >"$BIFROST_RUN/lock.stale/pid"
ok lock-stale-pid lock_acquire stale 0
lock_release stale
# a run directory that cannot be created ends in busy, not a busy loop
no lock-unwritable sh -c ". '$BIFROST_LIB/env.sh'; . '$BIFROST_LIB/validate.sh'; . '$BIFROST_LIB/common.sh'; : >'$T/notadir'; BIFROST_RUN='$T/notadir/run'; lock_acquire x 1"
ok with-lock with_lock test 0 true
no with-lock-rc with_lock test 0 false
ok with-lock-released lock_acquire test 0
lock_release test

# respond
BIFROST_REQ_ID=7
respond '{"ok":true}'
eq respond-resp '{"ok":true}' "$(t_resp)"
respond_err busy
eq respond-err '{"ok":false,"code":"busy"}' "$(t_resp)"
respond '{"ok":true,"x":"a=b"}'
eq respond-unsafe '{"ok":false,"code":"internal"}' "$(t_resp)"
unset BIFROST_REQ_ID
eq respond-stdout '{"ok":true}' "$(respond_ok)"

# jobs (BIFROST_BG_SYNC=1: queued, then bg_drain)
job_demo() {
    job_phase demo work 50
    job_data demo '{"n":1}'
    [ "${1:-}" = good ] || fail cli_failed
}
ok job-start job_start demo good
eq job-result '{"job":"demo"}' "$BIFROST_RESULT"
eq job-queued queued "$(jq -r .phase "$(job_file demo)")"
eq job-queued-running true "$(jq -r .running "$(job_file demo)")"
bg_drain
f=$(job_file demo)
eq job-done "false true done 100 1" "$(jq -r '"\(.running) \(.ok) \(.phase) \(.progress) \(.data.n)"' "$f")"
job_start demo bad
bg_drain
eq job-fail "false false cli_failed" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$f")"
job_start nosuchjob
bg_drain
eq job-missing not_implemented "$(jq -r .code "$(job_file nosuchjob)")"
no job-running-finished job_running demo
job_begin demo
ok job-running-live job_running demo
no job-start-busy job_start demo good
eq job-busy-code busy "$BIFROST_ERR"

# job_reap: a killed job is marked failed; live and young queued jobs stay
sleep 300 &
live=$!
sh -c 'exit 0' &
dead=$!
wait "$dead"
writejob() { # <job> <phase> <pid> <started>
    jq -n --arg j "$1" --arg ph "$2" --argjson pid "$3" --argjson s "$4" \
        '{schema:1, job:$j, running:true, phase:$ph, progress:null, ok:null,
          code:null, started:$s, finished:null, pid:$pid, data:{}}' >"$(job_file "$1")"
}
t0=$(now)
writejob update download "$dead" "$t0"
writejob migrate copy "$live" "$t0"
writejob login queued "$dead" "$t0"
writejob netcheck queued "$dead" $((t0 - 120))
jq -n '{schema:1, job:"daemon", running:false, ok:true, code:null, pid:1}' >"$(job_file daemon)"
job_reap
eq reap-dead "false false internal" "$(jq -r '"\(.running) \(.ok) \(.code)"' "$(job_file update)")"
eq reap-live "true" "$(jq -r .running "$(job_file migrate)")"
eq reap-young-queued "true" "$(jq -r .running "$(job_file login)")"
eq reap-old-queued "false internal" "$(jq -r '"\(.running) \(.code)"' "$(job_file netcheck)")"
eq reap-finished "true null" "$(jq -r '"\(.ok) \(.code)"' "$(job_file daemon)")"
kill "$live"
wait "$live" 2>/dev/null
rm -f "$(job_file update)" "$(job_file migrate)" "$(job_file login)" "$(job_file netcheck)" "$(job_file daemon)"
unset -f writejob

# job_run holds the state lock, except for the jobs that lock themselves
# shellcheck disable=SC2329 # called by job_run
job_lockprobe() { [ -d "$BIFROST_RUN/lock.state" ]; }
# shellcheck disable=SC2329 # called by job_run
job_netcheck() { [ ! -d "$BIFROST_RUN/lock.state" ]; }
ok job-run-locks job_run lockprobe
ok job-run-selflock job_run netcheck
unset -f job_lockprobe job_netcheck

# process probes
no daemon-none daemon_running
"$BIFROST_CORE" --statedir="$BIFROST_STATE" --socket="$BIFROST_SOCK" &
pid=$!
echo "$pid" >"$BIFROST_PIDFILE"
sleep 1
ok daemon-found daemon_running
eq daemon-pid "$pid" "$(daemon_pid)"
sleep 300 &
other=$!
echo "$other" >"$BIFROST_PIDFILE"
no daemon-other-process daemon_running
kill "$other"
kill "$pid"
wait "$pid" 2>/dev/null
echo "$pid" >"$BIFROST_PIDFILE"
no daemon-dead daemon_running

no orig-not-running orig_running
pidof_set tailscaled 1234
ok orig-running orig_running
no orig-not-installed orig_installed
mkdir -p "$BIFROST_ORIG_STATE"
: >"$BIFROST_ORIG_STATE/tailscaled.state"
ok orig-installed orig_installed

no tun-missing tun_exists
ip_out "link show tailscale0" "5: tailscale0: <POINTOPOINT,UP> mtu 1280"
ok tun-present tun_exists

# ts_cli goes to Bifrost's socket
no ts-no-socket ts_cli status --json 2>/dev/null
sock_up
ts_out status '{"BackendState":"Running"}'
eq ts-status Running "$(ts_cli status --json | jq -r .BackendState)"
has ts-log "status --json" "$(ts_log)"

# sha256_file / file_size
printf 'abc' >"$BIFROST_RUN/abc"
eq sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_file "$BIFROST_RUN/abc")"
no sha256-missing sha256_file "$BIFROST_RUN/nope"
eq size 3 "$(file_size "$BIFROST_RUN/abc")"

t_done
