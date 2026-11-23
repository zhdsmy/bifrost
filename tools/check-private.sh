#!/bin/sh
# Fail when tracked or new files contain private details (AGENTS.md rules):
# local absolute paths, real-looking auth keys, tailnet names. Extra exact
# strings (router address, user names, ...) can be listed one per line in
# .private-patterns, which is gitignored and never committed.
# A line that must keep a match ends with "check-private: allow".
set -u
cd "$(dirname "$0")/.." || exit 1
files=$(git ls-files -co --exclude-standard | grep -v -e '^web/package-lock.json$' -e '\.png$' -e '^\.private-patterns$')
rc=0
scan() {
    # shellcheck disable=SC2086
    _sc_hits=$(printf '%s\n' "$files" | xargs grep -nE "$1" /dev/null 2>/dev/null | grep -v 'check-private: allow')
    if [ -n "$_sc_hits" ]; then
        echo "check-private: $2"
        echo "$_sc_hits" | sed 's/^/  /' | head -n 20
        rc=1
    fi
}
scan '/Users/[A-Za-z]|/home/[a-z][a-z0-9_-]*/' 'local absolute path'
scan 'tskey-(auth|client|api)-[A-Za-z0-9]{8,}-[A-Za-z0-9]{8,}' 'real-looking Tailscale key'
# Tailnet names: only *example.ts.net may appear.
_tn_hits=$(printf '%s\n' "$files" | xargs grep -noE '[A-Za-z0-9.-]+\.ts\.net' /dev/null 2>/dev/null |
    grep -vE '[Ee]xample\.ts\.net$')
if [ -n "$_tn_hits" ]; then
    echo "check-private: tailnet name (use example.ts.net)"
    echo "$_tn_hits" | sed 's/^/  /' | head -n 20
    rc=1
fi
if [ -f .private-patterns ]; then
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in '#'*) continue ;; esac
        _cp_hits=$(printf '%s\n' "$files" | xargs grep -nF -- "$p" /dev/null 2>/dev/null)
        if [ -n "$_cp_hits" ]; then
            echo "check-private: a pattern from .private-patterns matches"
            echo "$_cp_hits" | cut -d: -f1,2 | sed 's/^/  /' | head -n 20
            rc=1
        fi
    done <.private-patterns
fi
[ "$rc" = 0 ] && echo "check-private: OK"
exit "$rc"
