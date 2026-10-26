#!/usr/bin/env bash
# Usage: wait.sh <sha> <merged_at epoch> [timeout seconds, default 600]
# Wait until all Kustomizations and HelmReleases are Ready on <sha>, with no new failing pods.
# Before a merge, run it with the current main SHA and merged_at 0 to examine the cluster.
# Exit: 0 healthy, 1 a failure, 2 still not ready at the timeout.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sha=$1 merged_at=$2 timeout=${3:-600}

end=$((SECONDS + timeout))
while :; do
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json >"$TMP/ks.json"
  kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json >"$TMP/hr.json"
  kubectl get pods -A -o json >"$TMP/pods.json"
  set +e
  out=$(lib health "$TMP/ks.json" "$TMP/hr.json" "$TMP/pods.json" "$sha" "$merged_at")
  code=$?
  set -e
  case $code in
    0) echo "$out"; exit 0 ;;
    1) echo "$out"; exit 1 ;;
  esac
  if [ $SECONDS -ge $end ]; then
    echo "timeout after ${timeout}s:"
    echo "$out"
    exit 2
  fi
  sleep 15
done
