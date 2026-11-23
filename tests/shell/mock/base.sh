# shellcheck shell=sh
# Test stand-in for the software center's /koolshare/scripts/base.sh.
# Written for Bifrost; records responses instead of posting them.
# shellcheck disable=SC2034
ID=$1
http_response() { printf '%s\n' "$*" >>"$MOCK_STATE/resp.log"; }
echo_date() { echo "$@"; }
