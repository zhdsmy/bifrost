# shellcheck shell=sh
# Shared helpers. Contract file: see docs/dev/contract.md.
# Load order: env.sh, validate.sh, common.sh, then the other lib files.
# No "local" in POSIX sh: function variables use a _<prefix>_ name.

BIFROST_ERR=""

# fail <code>: remember an error code (docs/dev/contract.md, section 5).
fail() {
    BIFROST_ERR=$1
    return 1
}

has_cmd() { type "$1" >/dev/null 2>&1; }

now() { date +%s; }

# log <tag> <message...>: one line in the script log. Never log secrets.
log() {
    _lg_tag=$1
    shift
    [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN" 2>/dev/null
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_lg_tag" "$*" >>"$BIFROST_LOG" 2>/dev/null
    return 0
}

# cfg <key>: dbus value of a Bifrost key, or its default when unset or invalid.
cfg() {
    _cf_v=$(dbus get "$1" 2>/dev/null)
    if [ -n "$_cf_v" ] && valid_setting "$1" "$_cf_v"; then
        printf '%s\n' "$_cf_v"
    else
        bifrost_default "$1"
    fi
}

# cfg_set <key> <value>: validated dbus write. Empty value removes the key.
cfg_set() {
    valid_setting "$1" "$2" || {
        fail invalid_param
        return 1
    }
    if [ -z "$2" ]; then
        dbus remove "$1" >/dev/null 2>&1
    else
        dbus set "$1=$2" >/dev/null 2>&1
    fi
}

# atomic_write <path> [mode]: write stdin to path through a temporary file.
atomic_write() {
    _aw_tmp="$1.tmp.$$"
    if ! cat >"$_aw_tmp"; then
        rm -f "$_aw_tmp"
        return 1
    fi
    [ -n "${2:-}" ] && chmod "$2" "$_aw_tmp"
    mv -f "$_aw_tmp" "$1"
}

# json_write <path>: validate JSON from stdin, write it compact and atomically.
json_write() {
    _jw_tmp="$1.tmp.$$"
    if ! jq -c . >"$_jw_tmp" 2>/dev/null || [ ! -s "$_jw_tmp" ]; then
        rm -f "$_jw_tmp"
        fail internal
        return 1
    fi
    chmod 644 "$_jw_tmp"
    mv -f "$_jw_tmp" "$1"
}

# run_timeout <seconds> <command...>: run a command, stop it after the limit.
# Returns the command's status, or 124 when it was stopped.
run_timeout() {
    _rt_secs=$1
    shift
    "$@" &
    _rt_pid=$!
    (
        _rt_i=0
        while [ "$_rt_i" -lt "$_rt_secs" ]; do
            sleep 1
            kill -0 "$_rt_pid" 2>/dev/null || exit 0
            _rt_i=$((_rt_i + 1))
        done
        kill -TERM "$_rt_pid" 2>/dev/null
        sleep 2
        kill -KILL "$_rt_pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    _rt_watch=$!
    wait "$_rt_pid"
    _rt_rc=$?
    kill "$_rt_watch" 2>/dev/null
    wait "$_rt_watch" 2>/dev/null
    case "$_rt_rc" in 143 | 137) return 124 ;; esac
    return "$_rt_rc"
}

# ts_cli_t <seconds> <args...> / ts_cli <args...>: the Tailscale CLI on
# Bifrost's socket. ts_cli uses a 10 second limit.
ts_cli_t() {
    _tc_secs=$1
    shift
    run_timeout "$_tc_secs" "$BIFROST_CLI" --socket="$BIFROST_SOCK" "$@"
}
ts_cli() { ts_cli_t 10 "$@"; }

# lock_acquire <name> [wait seconds]: mkdir lock under $BIFROST_RUN.
# A lock whose owner PID is gone is removed. Fails with code "busy".
lock_acquire() {
    _la_dir="$BIFROST_RUN/lock.$1"
    _la_wait=${2:-0}
    _la_i=0
    _la_nopid=0
    _la_stale=0
    while :; do
        [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN" 2>/dev/null
        mkdir "$_la_dir" 2>/dev/null && break
        _la_pid=$(cat "$_la_dir/pid" 2>/dev/null)
        if [ -n "$_la_pid" ]; then
            _la_nopid=0
            kill -0 "$_la_pid" 2>/dev/null || _la_nopid=3
        else
            _la_nopid=$((_la_nopid + 1))
        fi
        # The owner is gone, or wrote no pid within 3 tries. Retaking is
        # bounded so a directory that cannot be created never spins.
        if [ "$_la_nopid" -ge 3 ] && [ "$_la_stale" -lt 3 ]; then
            rm -rf "$_la_dir"
            _la_nopid=0
            _la_stale=$((_la_stale + 1))
            continue
        fi
        if [ "$_la_i" -ge "$_la_wait" ]; then
            fail busy
            return 1
        fi
        sleep 1
        _la_i=$((_la_i + 1))
    done
    echo "$$" >"$_la_dir/pid"
}

lock_release() { rm -rf "$BIFROST_RUN/lock.$1"; }

# with_lock <name> <wait seconds> <command...>: run a command under a lock.
# Do not nest with_lock calls.
with_lock() {
    _wl_name=$1
    _wl_wait=$2
    shift 2
    lock_acquire "$_wl_name" "$_wl_wait" || return 1
    "$@"
    _wl_rc=$?
    lock_release "$_wl_name"
    return "$_wl_rc"
}

# bg_job <name> [args...]: run job_<name> in a detached process through
# "bifrost_config.sh local job <name> ...", which calls job_run.
# With BIFROST_BG_SYNC=1 (tests) the call is queued in $BIFROST_RUN/bg_queue;
# bg_drain runs the queue in the current shell.
bg_job() {
    valid_name "$1" || {
        fail internal
        return 1
    }
    [ -d "$BIFROST_RUN" ] || mkdir -p "$BIFROST_RUN"
    if [ "${BIFROST_BG_SYNC:-0}" = 1 ]; then
        printf '%s\n' "$*" >>"$BIFROST_RUN/bg_queue"
        return 0
    fi
    nohup sh "$BIFROST_SCRIPTS/bifrost_config.sh" local job "$@" </dev/null >/dev/null 2>&1 &
}

bg_drain() {
    while [ -s "$BIFROST_RUN/bg_queue" ]; do
        _bd_line=$(head -n 1 "$BIFROST_RUN/bg_queue")
        sed 1d "$BIFROST_RUN/bg_queue" >"$BIFROST_RUN/bg_queue.t"
        mv -f "$BIFROST_RUN/bg_queue.t" "$BIFROST_RUN/bg_queue"
        # shellcheck disable=SC2086
        set -- $_bd_line
        job_run "$@"
    done
}

# respond <json>: answer a page request (http_response from base.sh), or
# print the JSON for internal calls. base.sh posts the text with "curl -d",
# so a response that contains & + % or = is replaced by an "internal" error.
respond() {
    _rs_body=$1
    case "$_rs_body" in
        *[\&+%=]*)
            log respond "unsafe response replaced"
            _rs_body='{"ok":false,"code":"internal"}'
            ;;
    esac
    if [ -n "${BIFROST_REQ_ID:-}" ] && has_cmd http_response; then
        http_response "$_rs_body"
    else
        printf '%s\n' "$_rs_body"
    fi
}
respond_ok() { respond '{"ok":true}'; }
respond_err() { respond "{\"ok\":false,\"code\":\"${1:-internal}\"}"; }

# Job progress files: $BIFROST_UPLOAD/bifrost_<job>.json (contract section 6.2).
job_file() { printf '%s/bifrost_%s.json\n' "$BIFROST_UPLOAD" "$1"; }

# job_begin <job>: called by the act_* function before bg_job. The file
# says "queued" and holds the requesting process ID until job_run takes over.
job_begin() {
    [ -d "$BIFROST_UPLOAD" ] || mkdir -p "$BIFROST_UPLOAD"
    jq -n --arg job "$1" --argjson t "$(now)" --argjson pid "$$" \
        '{schema:1, job:$job, running:true, phase:"queued", progress:null,
          ok:null, code:null, started:$t, finished:null, pid:$pid, data:{}}' |
        json_write "$(job_file "$1")"
}

# job_run <job> [args...]: body of "bifrost_config.sh local job". Takes over
# the job file, runs job_<job> under the state lock and records the result.
job_run() {
    _jn_job=$1
    shift
    valid_name "$_jn_job" || return 1
    [ -f "$(job_file "$_jn_job")" ] || job_begin "$_jn_job"
    jq --argjson pid "$$" '.pid=$pid | .phase="start"' "$(job_file "$_jn_job")" |
        json_write "$(job_file "$_jn_job")"
    BIFROST_ERR=""
    if ! has_cmd "job_$_jn_job"; then
        job_end "$_jn_job" fail not_implemented
        return 1
    fi
    # These jobs wait for a user, the original plugin or the network. They
    # take the state lock themselves, only around the steps that change state.
    case "$_jn_job" in
        login | migrate | netcheck) set -- "job_$_jn_job" "$@" ;;
        *) set -- with_lock state 60 "job_$_jn_job" "$@" ;;
    esac
    if "$@"; then
        job_end "$_jn_job" ok
    else
        job_end "$_jn_job" fail "${BIFROST_ERR:-internal}"
        return 1
    fi
}

# job_phase <job> <phase> [progress 0-100]
job_phase() {
    _jp_f=$(job_file "$1")
    _jp_p=${3:-null}
    jq --arg ph "$2" --argjson p "$_jp_p" '.phase=$ph | .progress=$p' "$_jp_f" |
        json_write "$_jp_f"
}

# job_data <job> <json object>: merge fields into .data
job_data() {
    _jd_f=$(job_file "$1")
    jq --argjson d "$2" '.data += $d' "$_jd_f" | json_write "$_jd_f"
}

# job_end <job> ok|fail [code]
job_end() {
    _je_f=$(job_file "$1")
    if [ "$2" = ok ]; then
        jq --argjson t "$(now)" '.running=false | .ok=true | .code=null | .phase="done" | .progress=100 | .finished=$t' "$_je_f" |
            json_write "$_je_f"
    else
        jq --argjson t "$(now)" --arg c "${3:-internal}" '.running=false | .ok=false | .code=$c | .finished=$t' "$_je_f" |
            json_write "$_je_f"
    fi
}

# job_running <job>: 0 when the job file says running and its process exists.
job_running() {
    _jr_f=$(job_file "$1")
    [ -f "$_jr_f" ] || return 1
    _jr_pid=$(jq -r 'if .running then .pid else empty end' "$_jr_f" 2>/dev/null)
    [ -n "$_jr_pid" ] && kill -0 "$_jr_pid" 2>/dev/null
}

# job_reap: a job file that says running while its process is gone (the job
# was killed) is marked failed with `internal`, so the page stops waiting.
# A queued file younger than 60 s is skipped: its pid is the requester until
# job_run takes over.
job_reap() {
    for _jp_job in daemon login migrate update netcheck; do
        _jp_f=$(job_file "$_jp_job")
        [ -f "$_jp_f" ] || continue
        _jp_pid=$(jq -r --argjson t "$(now)" \
            'if .running == true and (.phase != "queued" or ($t - (.started // 0)) > 60)
             then (.pid // empty) else empty end' "$_jp_f" 2>/dev/null)
        valid_uint "$_jp_pid" || continue
        kill -0 "$_jp_pid" 2>/dev/null && continue
        jq --argjson t "$(now)" --argjson pid "$_jp_pid" \
            'if .running == true and .pid == $pid
             then .running=false | .ok=false | .code="internal" | .finished=$t else . end' "$_jp_f" |
            json_write "$_jp_f"
    done
}

# job_start <job> [args...]: for act_* functions. Refuses a job that is already
# running, writes the queued job file, starts the job and sets the response.
job_start() {
    if job_running "$1"; then
        fail busy
        return 1
    fi
    job_begin "$1" || return 1
    bg_job "$@" || return 1
    BIFROST_RESULT="{\"job\":\"$1\"}"
}

# Process probes shared by all packages.

# daemon_pid: print the PID of Bifrost's daemon, or return 1. The PID file
# must name a live process whose command line contains $BIFROST_CORE.
daemon_pid() {
    _dp_pid=$(cat "$BIFROST_PIDFILE" 2>/dev/null)
    valid_uint "$_dp_pid" || return 1
    [ -r "/proc/$_dp_pid/cmdline" ] || return 1
    tr '\000' '\n' <"/proc/$_dp_pid/cmdline" | grep -Fqx "$BIFROST_CORE" || return 1
    printf '%s\n' "$_dp_pid"
}
daemon_running() { daemon_pid >/dev/null; }

# orig_running: another tailscaled (the original plugin or the user's own) runs.
orig_running() { pidof tailscaled >/dev/null 2>&1; }

# orig_installed: the original Koolshare plugin is installed or left its state.
orig_installed() {
    [ -f "$BIFROST_ORIG_STATE/tailscaled.state" ] && return 0
    [ -n "$(dbus get softcenter_module_tailscale_install 2>/dev/null)" ]
}

tun_exists() { ip link show "$BIFROST_TUN" >/dev/null 2>&1; }

# sha256_file <file>: lower-case hex digest (the router has no sha256sum).
sha256_file() {
    _sf_out=$(openssl dgst -sha256 -r "$1" 2>/dev/null) || return 1
    _sf_out=${_sf_out%% *}
    [ "${#_sf_out}" -eq 64 ] || return 1
    printf '%s\n' "$_sf_out"
}

# file_size <file>: size in bytes (the router has no stat).
file_size() {
    [ -f "$1" ] || return 1
    wc -c <"$1" | tr -d ' '
}
