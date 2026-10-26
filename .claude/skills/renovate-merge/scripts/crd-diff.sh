#!/usr/bin/env bash
# Usage: crd-diff.sh <pr>
# Compare the CRDs of each chart that the PR upgrades (OCIRepository tag changes).
# Exit: 0 no CRD change, 3 CRDs change and the HelmRelease updates them,
#       4 CRDs change and the HelmRelease does not update them, 2 the CRDs cannot be read,
#       64 wrong arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_args $# 1 "crd-diff.sh <pr>"
pr=$1

gh pr diff "$pr" >"$TMP/pr.diff"
lib chart-bumps "$TMP/pr.diff" >"$TMP/bumps.json"
count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/bumps.json")
[ "$count" -gt 0 ] || { echo "no chart upgrade in PR #$pr"; exit 0; }

codes=()
while IFS=$'\t' read -r file old new source; do
  src="$ROOT/$file"
  if [ "$source" != oci ]; then
    # TODO: Compare the CRDs of a chart from a HelmRepository too.
    echo "== $file: chart from a HelmRepository, $old -> $new: the script cannot compare its CRDs"
    codes+=(2)
    continue
  fi
  url=$(tool yq '.spec.url' "$src")
  name=$(tool yq '.metadata.name' "$src")
  echo "== $file: $name $old -> $new ($url)"
  if ! tool helm show crds "$url" --version "$old" >"$TMP/old.yaml" ||
    ! tool helm show crds "$url" --version "$new" >"$TMP/new.yaml"; then
    echo "cannot read the CRDs of $url"; code=2
  else
    # Only a HelmRelease in the app directory of this OCIRepository uses the chart.
    dir=$(dirname "$(dirname "$src")")
    { grep -rl --include=helmrelease.yaml "kind: HelmRelease" "$dir" 2>/dev/null || true; } |
      while read -r f; do tool yq -o json '.' "$f"; done |
      python3 -c '
import json, sys
docs, buf = [], ""
for line in sys.stdin:
    buf += line
    try:
        docs.append(json.loads(buf)); buf = ""
    except json.JSONDecodeError:
        pass
want = sys.argv[1]
docs = [d for d in docs if isinstance(d, dict)]
print(json.dumps([d for d in docs if d.get("spec", {}).get("chartRef", {}).get("name") == want]))' "$name" >"$TMP/hrs.json"
    set +e; lib crd-verdict "$TMP/old.yaml" "$TMP/new.yaml" "$TMP/hrs.json"; code=$?; set -e
    [ "$code" = 0 ] || diff <(grep -E '^\s+[a-zA-Z]+:$' "$TMP/old.yaml" | sort -u) \
      <(grep -E '^\s+[a-zA-Z]+:$' "$TMP/new.yaml" | sort -u) | grep '^[<>]' | head -20 || true
  fi
  codes+=("$code")
done < <(python3 -c 'import json,sys;[print(b["file"],b["old"],b["new"],b["source"],sep="\t") for b in json.load(open(sys.argv[1]))]' "$TMP/bumps.json")
# One chart that Flux does not update is enough to stop the PR.
exit "$(lib worst-crd "${codes[@]}")"
