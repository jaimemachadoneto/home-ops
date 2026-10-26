#!/usr/bin/env bash
# Usage: wait.sh <sha> <merged_at epoch> [timeout seconds, default 540]
# Wait until all Kustomizations are Ready on <sha> or a newer commit of main, all
# HelmReleases are Ready on their new generation, and no new pod fails.
# Before a merge, run it with the SHA of origin/main and merged_at 0.
# The default timeout stays under the 600-second limit of the Claude Code Bash tool.
# Exit: 0 healthy, 1 a failure in the cluster, 2 still not ready at the timeout,
#       3 the script cannot read the cluster, 64 wrong arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_args $# 2 "wait.sh <sha> <merged_at> [timeout]"
sha=$1 merged_at=$2 timeout=${3:-540}

end=$((SECONDS + timeout))
while :; do
  # Renovate merges other PRs by itself, so Flux can show a newer commit than ours.
  git -C "$ROOT" fetch -q origin main 2>/dev/null || true
  shas="$sha"
  if git -C "$ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
    shas="$sha,$(git -C "$ROOT" rev-list "$sha..origin/main" | paste -sd, -)"
  fi
  if ! kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json >"$TMP/ks.json" ||
    ! kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json >"$TMP/hr.json" ||
    ! kubectl get pods -A -o json >"$TMP/pods.json"; then
    echo "kubectl cannot read the cluster"
    exit 3
  fi
  set +e
  out=$(lib health "$TMP/ks.json" "$TMP/hr.json" "$TMP/pods.json" "$shas" "$merged_at")
  code=$?
  set -e
  case $code in
    0) echo "$out"; exit 0 ;;
    1) echo "$out"; exit 1 ;;
    10) ;;
    *) echo "renovate_lib.py health failed with $code:"; echo "$out"; exit 3 ;;
  esac
  if [ $SECONDS -ge $end ]; then
    echo "timeout after ${timeout}s:"
    echo "$out"
    exit 2
  fi
  sleep 15
done
