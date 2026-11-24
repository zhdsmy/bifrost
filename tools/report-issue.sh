#!/bin/sh
# report-issue.sh <title> <body file>: comment on the open issue with exactly
# this title, or open a new one. Used by the release workflows; needs GH_TOKEN
# and GITHUB_REPOSITORY. Bodies must not mention users.
set -eu

title=$1
body_file=$2
repo=${GITHUB_REPOSITORY:?}

number=$(gh issue list -R "$repo" --state open --limit 100 --search "\"$title\" in:title" \
    --json number,title | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty')
if [ -n "$number" ]; then
    gh issue comment "$number" -R "$repo" --body-file "$body_file"
else
    gh issue create -R "$repo" --title "$title" --body-file "$body_file"
fi
