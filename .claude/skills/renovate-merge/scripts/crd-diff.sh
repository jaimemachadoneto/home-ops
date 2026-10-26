#!/usr/bin/env bash
# Usage: crd-diff.sh <pr>
# Compare the CRDs of each chart that the PR upgrades (OCIRepository tag changes).
# Exit: 0 no CRD change, 3 CRDs change and the HelmRelease updates them,
#       4 CRDs change and the HelmRelease does not update them, 2 cannot tell.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pr=$1

gh pr diff "$pr" >"$TMP/pr.diff"
lib chart-bumps "$TMP/pr.diff" >"$TMP/bumps.json"
count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/bumps.json")
[ "$count" -gt 0 ] || { echo "no chart upgrade in PR #$pr"; exit 0; }

worst=0
rank() { case $1 in 0) echo 0 ;; 3) echo 1 ;; 2) echo 2 ;; 4) echo 3 ;; esac; }
while IFS=$'\t' read -r file old new; do
  src="$ROOT/$file"
  url=$(tool yq '.spec.url' "$src")
  name=$(tool yq '.metadata.name' "$src")
  echo "== $file: $name $old -> $new ($url)"
  if ! tool helm show crds "$url" --version "$old" >"$TMP/old.yaml" ||
    ! tool helm show crds "$url" --version "$new" >"$TMP/new.yaml"; then
    echo "cannot read the CRDs of $url"; code=2
  else
    # The HelmReleases that use this chart, in the same app directory.
    dir=$(dirname "$(dirname "$src")")
    grep -rl --include=helmrelease.yaml "kind: HelmRelease" "$dir" 2>/dev/null |
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
print(json.dumps([d for d in docs if d.get("spec", {}).get("chartRef", {}).get("name") == want]))' "$name" >"$TMP/hrs.json"
    set +e; lib crd-verdict "$TMP/old.yaml" "$TMP/new.yaml" "$TMP/hrs.json"; code=$?; set -e
    [ "$code" = 0 ] || diff <(grep -E '^\s+[a-zA-Z]+:$' "$TMP/old.yaml" | sort -u) \
      <(grep -E '^\s+[a-zA-Z]+:$' "$TMP/new.yaml" | sort -u) | grep '^[<>]' | head -20 || true
  fi
  [ "$(rank "$code")" -gt "$(rank "$worst")" ] && worst=$code
done < <(python3 -c 'import json,sys;[print(b["file"],b["old"],b["new"],sep="\t") for b in json.load(open(sys.argv[1]))]' "$TMP/bumps.json")
exit "$worst"
