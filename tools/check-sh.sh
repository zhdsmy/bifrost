#!/bin/sh
# Static checks for every shell script in the repository (PLAN section 14).
#   1. shellcheck -s sh on all shell scripts.
#   2. BusyBox 1.25 "sh -n" on the router scripts (in the test image; docker).
#   3. Forbidden patterns in the router scripts (plugin/bifrost/).
# A line that really needs a forbidden pattern ends with "# check-sh: allow".
# Usage: tools/check-sh.sh [--no-docker]
set -u
cd "$(dirname "$0")/.." || exit 1

is_sh() {
    case "$1" in
        *.sh) return 0 ;;
    esac
    head -n 1 "$1" 2>/dev/null | grep -q '^#!/bin/sh'
}

router=""
other=""
for f in $(find plugin core packaging tools tests web/test -type f 2>/dev/null |
    grep -v -e node_modules -e '/dist/' -e '^core/out/' | sort); do
    is_sh "$f" || continue
    case "$f" in
        plugin/bifrost/*) router="$router $f" ;;
        *) other="$other $f" ;;
    esac
done

rc=0

# 1. shellcheck
# shellcheck disable=SC2086
if ! shellcheck -s sh -x $router $other; then
    echo "check-sh: shellcheck failed"
    rc=1
fi

# 2. BusyBox 1.25 syntax check
if [ "${1:-}" != --no-docker ]; then
    img=bifrost-shtest:1
    docker build -q -t "$img" tests/shell >/dev/null || rc=1
    # shellcheck disable=SC2086
    if ! COPYFILE_DISABLE=1 tar -cf - $router |
        docker run --rm -i --network none "$img" /bin/sh -c '
            mkdir -p /src && tar -xf - -C /src && cd /src || exit 1
            bad=0
            for f in "$@"; do
                /opt/bb125/busybox sh -n "$f" || { echo "sh -n failed: $f"; bad=1; }
            done
            exit $bad' inner $router; then
        echo "check-sh: busybox sh -n failed"
        rc=1
    fi
fi

# 3. Forbidden patterns in router scripts. Comment lines are skipped.
cmd='(^|[;&|(`{]|\$\(|[[:space:]]then|[[:space:]]do|[[:space:]]else)[[:space:]]*'
forbid() {
    _fb_re=$1
    _fb_why=$2
    # shellcheck disable=SC2086
    _fb_hits=$(grep -nE "$_fb_re" $router /dev/null | grep -v '# check-sh: allow' |
        grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
    if [ -n "$_fb_hits" ]; then
        echo "check-sh: $_fb_why"
        echo "$_fb_hits" | sed 's/^/  /'
        rc=1
    fi
}
forbid "${cmd}local[[:space:]]" 'no "local" in POSIX sh'
forbid 'command -v' 'use "type", the router has no "command -v"'
forbid "${cmd}eval[[:space:]]" 'no eval'
forbid 'dbus export' 'no "dbus export": read keys one by one with "dbus get"'
forbid "${cmd}(sha256sum|xz|od|mktemp|timeout|setsid|stat|start-stop-daemon|seq|tac|mkfifo|realpath|bash)([[:space:]]|\$|;|\))" \
    'command missing on the router (PLAN 2.3, 14)'
forbid 'ip6?tables[^#]*[[:space:]]-w([[:space:]]|$)' 'iptables on the router has no -w'
forbid 'grep[[:space:]]+-[A-Za-z]*P' 'BusyBox grep has no -P'
forbid '\[\[' 'no [[ ]] in POSIX sh'
forbid "${cmd}source[[:space:]]" 'use "." instead of "source"'
forbid '/koolshare/scripts/tailscale|configs/tailscale/|tailscale_[a-z]+=' \
    "do not touch the original plugin's files or keys outside env.sh"

# shellcheck disable=SC2086
[ "$rc" = 0 ] && echo "check-sh: OK ($(echo $router | wc -w | tr -d ' ') router scripts, $(echo $other | wc -w | tr -d ' ') other)"
exit "$rc"
