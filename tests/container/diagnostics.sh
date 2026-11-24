#!/bin/sh
# Bounded failure diagnostics for the isolated integration containers.
# Use the same redactor as the router's diagnostics view.
BIFROST_KSROOT=""
# shellcheck source=plugin/bifrost/lib/diag.sh
. "$(dirname "$0")/../../plugin/bifrost/lib/diag.sh"

{
    for ctr do
        docker inspect --format '{{.Name}} state={{.State.Status}} exit={{.State.ExitCode}}' "$ctr"
    done
    echo 'headscale log:'
    docker logs --tail 40 "$1" 2>&1
    if [ -n "${2:-}" ]; then
        docker exec "$2" sh -c '
            jq -c "{state,error}" /tmp/upload/bifrost_status.json
            jq -c "{ok,code,phase}" /tmp/upload/bifrost_login.json
            for f in /tmp/bifrost-run/bifrost.log /tmp/bifrost-run/bifrostd.log; do
                echo "$f"; tail -n 25 "$f"
            done
        ' 2>&1
    fi
} | awk 'length(ENVIRON["AUTHKEY"]) && index($0, ENVIRON["AUTHKEY"]) {print "[credential omitted]"; next} {print}' |
    redact | sed -E 's@https?://[^[:space:]"<>]+@[url]@g'
