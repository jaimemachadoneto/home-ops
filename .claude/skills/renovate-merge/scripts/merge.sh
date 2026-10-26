#!/usr/bin/env bash
# Usage: merge.sh <pr> [--own] [--user-approved]
# Squash-merge the PR and wait until Flux fetches the merge commit.
#  --own            the PR is a PR of the skill (a version or the CRD policy only)
#  --user-approved  the user approved this PR in the conversation
# Prints "sha=<sha> merged_at=<epoch>" for wait.sh.
# Exit: 0 merged and fetched, 1 the merge did not occur, 2 Flux did not fetch the commit
#       in 2 minutes, 3 merged but the script cannot find the merge commit,
#       5 a guard refused the merge, or precheck.sh did not give 0, 64 wrong arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_args $# 1 "merge.sh <pr> [--own] [--user-approved]"
pr=$1
shift
own=0 approved=0
for arg in "$@"; do
  case $arg in
    --own) own=1 ;;
    --user-approved) approved=1 ;;
    *) log "unknown option $arg"; exit 5 ;;
  esac
done

# The guards are code, not text: a model cannot argue with them.
gh pr view "$pr" --json author,title,files,headRefOid >"$TMP/pr.json"
gh pr diff "$pr" >"$TMP/pr.diff"
me=$(gh api user -q .login)
set +e
reason=$(lib merge-gate "$TMP/pr.json" "$TMP/pr.diff" "$own" "$approved" "app/jmnhomeopsbot" "$me")
gate=$?
set -e
[ "$gate" = 0 ] || { echo "refused: $reason"; exit 5; }

# Merge exactly the commit that the checks approved.
head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefOid"])' "$TMP/pr.json")
set +e
bash "$SCRIPTS/precheck.sh" "$pr"
pre=$?
set -e
[ "$pre" = 0 ] || { echo "refused: precheck.sh gave $pre"; exit 5; }

merged_at=$(date +%s)
gh pr merge "$pr" --squash --match-head-commit "$head" >/dev/null || { echo "merge of #$pr failed"; exit 1; }

# From here the merge occurred. A failed lookup must not look like a failed merge,
# else the skill skips wait.sh for a change that is already on main.
set +e
sha=""
for _ in $(seq 1 20); do
  sha=$(gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null)
  [ -n "$sha" ] && break
  sleep 3
done
[ -n "$sha" ] || { echo "merged, but the merge commit of #$pr is unknown: find it, then run wait.sh"; exit 3; }

flux reconcile source git flux-system -n flux-system >/dev/null 2>&1
for _ in $(seq 1 40); do
  rev=$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}' 2>/dev/null)
  rev=${rev##*:}
  git -C "$ROOT" fetch -q origin main 2>/dev/null
  # Renovate can merge a newer commit first; a revision that contains ours is good too.
  if [ -n "$rev" ] && { [ "$rev" = "$sha" ] || git -C "$ROOT" merge-base --is-ancestor "$sha" "$rev" 2>/dev/null; }; then
    echo "sha=$sha merged_at=$merged_at"
    exit 0
  fi
  sleep 3
done
echo "sha=$sha merged_at=$merged_at"
echo "Flux did not fetch $sha in 2 minutes"
exit 2
