#!/bin/sh
# Tests for plugin/bifrost/bin/bifrost (SSH CLI wrapper).
# shellcheck disable=SC1091
. tests/shell/lib.sh

t_setup
cp "$T_SRC/plugin/bifrost/bin/bifrost" "$BIFROST_KSROOT/bin/bifrost"
chmod 755 "$BIFROST_KSROOT/bin/bifrost"
BIFROST_WRAPPER="$BIFROST_KSROOT/bin/bifrost"

# Without socket, status fails because --socket=$BIFROST_SOCK is passed
no bin-no-socket "$BIFROST_WRAPPER" status --json >/dev/null 2>&1

# With socket, forwards subcommand and output cleanly
sock_up
ts_out status '{"BackendState":"Running"}'
eq bin-status Running "$("$BIFROST_WRAPPER" status --json | jq -r .BackendState)"
has bin-tslog "status --json" "$(ts_log)"

# Argument preservation (spaces, empty arg, exit code) using a stub CLI
cat >"$BIFROST_KSROOT/bifrost/bin/argdump" <<'EOF'
#!/bin/sh
for a in "$@"; do
    printf '[%s]\n' "$a"
done
exit 7
EOF
chmod 755 "$BIFROST_KSROOT/bifrost/bin/argdump"

out=$(BIFROST_CLI="$BIFROST_KSROOT/bifrost/bin/argdump" "$BIFROST_WRAPPER" set "--hostname=my router" "" "two words")
rc=$?
eq bin-exit-code 7 "$rc"
eq bin-args-verbatim "[--socket=$T_SOCK]
[set]
[--hostname=my router]
[]
[two words]" "$out"

t_done
