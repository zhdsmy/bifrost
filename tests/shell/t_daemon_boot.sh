#!/bin/sh
# Enter through the WAN-up dispatcher with only the durable update journal.
# shellcheck disable=SC1091
. tests/shell/lib.sh

for enabled in 0 1; do
    t_setup
    t_load
    dbus_seed "bifrost_enable=$enabled"
    ts_out_file status "$T_SRC/tests/shell/fixtures/runtime/status_running.json"
    ts_out_file debug-prefs "$T_SRC/tests/shell/fixtures/runtime/prefs_ok.json"
    journal="$BIFROST_HOME/.core-update"
    mkdir "$journal"
    echo replacing >"$journal/phase"
    echo Running >"$journal/running"
    echo saved-state >"$journal/state"
    echo candidate-state >"$BIFROST_STATE/tailscaled.state"
    old_sha=$(sha256_file "$BIFROST_CORE")
    old_version=$(core_version)
    jq -n --arg sha "$old_sha" --arg v "$old_version" \
        '{arch:"arm",serial:5,tailscale:$v,assets:{arm:{raw_sha256:$sha}}}' >"$journal/installed.json"
    mv "$BIFROST_CORE" "$BIFROST_CORE.old"
    printf '#!/bin/sh\nexit 1\n' >"$BIFROST_CORE"
    chmod 755 "$BIFROST_CORE"
    echo '{"serial":6}' >"$BIFROST_MANIFEST"

    ok "boot-$enabled-hook" t_call start
    eq "boot-$enabled-old-core" "$old_sha" "$(sha256_file "$BIFROST_CORE")"
    eq "boot-$enabled-core-manifest" "$(sha256_file "$BIFROST_CORE")" \
        "$(jq -r '.assets[.arch].raw_sha256' "$BIFROST_MANIFEST")"
    eq "boot-$enabled-version-manifest" "$(core_version)" "$(jq -r .tailscale "$BIFROST_MANIFEST")"
    eq "boot-$enabled-state" saved-state "$(cat "$BIFROST_STATE/tailscaled.state")"
    no "boot-$enabled-recovery-complete" [ -e "$journal" ]
    if [ "$enabled" = 1 ]; then
        ok boot-enabled-running daemon_running
        ok boot-enabled-stop t_call stop
    else
        no boot-disabled-running daemon_running
        no boot-disabled-even-briefly-started [ -e "$MOCK_STATE/daemon.args" ]
    fi
done

# An unrecognized phase leaves the journal for retry and reports its error.
mkdir "$journal"
echo invalid >"$journal/phase"
ok boot-recovery-error-continues t_call start
has boot-recovery-error-logged 'core recovery failed: internal' "$(cat "$BIFROST_LOG")"
ok boot-recovery-error-running daemon_running
eq boot-recovery-error-journal invalid "$(cat "$journal/phase")"
ok boot-recovery-error-stop t_call stop
t_done
