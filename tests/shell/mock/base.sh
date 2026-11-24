# shellcheck shell=sh
# Test stand-in for the software center's /koolshare/scripts/base.sh.
# Written for Bifrost; records responses instead of posting them.
# shellcheck disable=SC2034
ID=$1
http_response() { printf '%s\n' "$*" >>"$MOCK_STATE/resp.log"; }
# Same definition as the router's base.sh: an alias, not a function.
alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'
