#!/usr/bin/env bash
# Usage: classify.sh
# Print each open Renovate PR in merge sequence, with its phase, risk class, update type,
# category, "always ask" mark and pair.
# Exit: 0 done, 1 the PR list can be incomplete, because it has the maximum number of PRs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=500

gh pr list --state open --author app/jmnhomeopsbot --limit "$limit" --json number,title,files >"$TMP/prs.json"
count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/prs.json")
lib classify "$TMP/prs.json"
log "$count open Renovate PRs"
[ "$count" -lt "$limit" ] || { echo "the list has $limit PRs: it can be incomplete, increase the limit"; exit 1; }
