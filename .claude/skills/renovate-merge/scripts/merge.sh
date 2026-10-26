#!/usr/bin/env bash
# Usage: merge.sh <pr>
# Squash-merge the PR and wait until Flux fetches the merge commit.
# Prints "sha=<sha> merged_at=<epoch>" for wait.sh.
# Exit: 0 merged and fetched, 1 merge failed, 2 Flux did not fetch the commit in 2 minutes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pr=$1

merged_at=$(date +%s)
gh pr merge "$pr" --squash >/dev/null || { echo "merge of #$pr failed"; exit 1; }
for _ in $(seq 1 20); do
  [ "$(gh pr view "$pr" --json state -q .state)" = MERGED ] && break
  sleep 3
done
sha=$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid)
[ -n "$sha" ] || { echo "#$pr has no merge commit"; exit 1; }

flux reconcile source git flux-system -n flux-system >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  rev=$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')
  if [[ "$rev" == *"$sha"* ]]; then
    echo "sha=$sha merged_at=$merged_at"
    exit 0
  fi
  sleep 3
done
echo "sha=$sha merged_at=$merged_at"
echo "Flux did not fetch $sha in 2 minutes"
exit 2
