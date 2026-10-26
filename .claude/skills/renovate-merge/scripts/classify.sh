#!/usr/bin/env bash
# Usage: classify.sh
# Print each open Renovate PR with its phase, risk class and pair, in merge sequence.
# Exit: 0 done, 1 the PR list is possibly cut at the limit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=500

gh pr list --state open --author app/jmnhomeopsbot --limit "$limit" --json number,title,files >"$TMP/prs.json"
count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/prs.json")
lib classify "$TMP/prs.json"
log "$count open Renovate PRs"
[ "$count" -lt "$limit" ] || { echo "the list has $limit PRs: it can be cut, raise the limit"; exit 1; }
