#!/usr/bin/env bash
# Usage: precheck.sh <pr>
# Exit: 0 ready to merge, 10 checks still run, 20 not open or not mergeable, 30 checks fail.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pr=$1

gh pr view "$pr" --json state,mergeable,statusCheckRollup >"$TMP/pr.json"
state=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$TMP/pr.json")
mergeable=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mergeable"])' "$TMP/pr.json")
[ "$state" = OPEN ] || { echo "PR #$pr is $state"; exit 20; }
case "$mergeable" in
  MERGEABLE) ;;
  UNKNOWN) echo "GitHub still computes mergeability"; exit 10 ;;
  *) echo "PR #$pr is $mergeable"; exit 20 ;;
esac
python3 -c 'import json,sys;json.dump(json.load(open(sys.argv[1]))["statusCheckRollup"],open(sys.argv[2],"w"))' \
  "$TMP/pr.json" "$TMP/checks.json"

# For each failed flux-local diff job, find which steps failed: only "Add Comment" is harmless.
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo '{}' >"$TMP/steps.json"
python3 - "$TMP/checks.json" <<'EOF' >"$TMP/jobs.txt"
import json, re, sys
for c in json.load(open(sys.argv[1])):
    if (c.get("name") or "").startswith("Flux Local Diff") and c.get("conclusion") == "FAILURE":
        m = re.search(r"/job/(\d+)", c.get("detailsUrl", ""))
        if m:
            print(m.group(1), c["name"], sep="\t")
EOF
while IFS=$'\t' read -r job name; do
  steps=$(gh api "repos/$repo/actions/jobs/$job" --jq '[.steps[]|select(.conclusion=="failure")|.name]')
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d[sys.argv[2]]=json.loads(sys.argv[3]);json.dump(d,open(sys.argv[1],"w"))' \
    "$TMP/steps.json" "$name" "$steps"
done <"$TMP/jobs.txt"

lib checks "$TMP/checks.json" "$TMP/steps.json"
