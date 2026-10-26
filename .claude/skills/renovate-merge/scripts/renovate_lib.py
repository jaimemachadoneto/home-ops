"""Decisions of the renovate-merge skill, as pure functions over the JSON of gh and kubectl.

The shell scripts collect the data and call the CLI at the bottom. Each decision is
here, so the unit tests can examine it without GitHub or a cluster.
"""

import json
import re
import sys
from datetime import datetime

OK_CONCLUSIONS = {"SUCCESS", "SKIPPED", "NEUTRAL"}
PENDING_STATES = {"PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"}

# The user decided on 2026-10-25 to ignore these: the errors are already on main, and
# the lint job examines only the files that a PR changes.
IGNORED_CHECKS = {"yamllint", "Lint successful"}

# flux-local renders correctly, but a large diff is too long for a PR comment.
IGNORED_FLUX_LOCAL_STEPS = {"Add Comment"}
FLUX_LOCAL_DIFF = "Flux Local Diff"
FLUX_LOCAL_SUMMARY = "Flux Local successful"


def _check_name(check):
    return check.get("name") or check.get("context") or "?"


def _check_state(check):
    """Return SUCCESS, PENDING or FAILURE for a CheckRun or a StatusContext."""
    if check.get("__typename") == "StatusContext" or "state" in check:
        state = check.get("state", "")
        if state == "SUCCESS":
            return "SUCCESS"
        return "PENDING" if state in PENDING_STATES else "FAILURE"
    if check.get("status") and check["status"] != "COMPLETED":
        return "PENDING"
    conclusion = check.get("conclusion") or ""
    if conclusion in OK_CONCLUSIONS:
        return "SUCCESS"
    # A completed run without a conclusion has no result yet that a merge can trust.
    return "PENDING" if conclusion == "" else "FAILURE"


def classify_checks(checks, failed_steps):
    """Return ("ok" | "pending" | "failing", reasons).

    failed_steps maps a failed flux-local job name to the names of its failed steps.
    """
    reasons, failing, pending = [], [], False
    explained_flux_local = True
    for check in checks:
        name, state = _check_name(check), _check_state(check)
        if state == "PENDING":
            pending = True
            continue
        if state == "SUCCESS":
            continue
        if name in IGNORED_CHECKS:
            reasons.append(f"ignored: {name} fails (lint errors already on main)")
        elif name.startswith(FLUX_LOCAL_DIFF):
            steps = failed_steps.get(name, [])
            if steps and set(steps) <= IGNORED_FLUX_LOCAL_STEPS:
                reasons.append(f"ignored: {name} fails only at 'Add Comment' (diff too long)")
            else:
                explained_flux_local = False
                failing.append(f"{name} fails at: {', '.join(steps) or 'unknown step'}")
        elif name == FLUX_LOCAL_SUMMARY:
            continue  # judged below, from the diff jobs
        else:
            failing.append(f"{name} fails")
    summary_failed = any(_check_name(c) == FLUX_LOCAL_SUMMARY and _check_state(c) == "FAILURE" for c in checks)
    any_diff_failed = any(_check_name(c).startswith(FLUX_LOCAL_DIFF) and _check_state(c) == "FAILURE" for c in checks)
    if summary_failed and not (any_diff_failed and explained_flux_local):
        failing.append(f"{FLUX_LOCAL_SUMMARY} fails without an ignored diff job")
    if failing:
        return "failing", failing + reasons
    return ("pending" if pending else "ok"), reasons


_FILE = re.compile(r"^\+\+\+ b/(.+)$")
_TAG = re.compile(r"^([-+])\s+tag:\s*(\S+)")


def chart_bumps(diff_text):
    """Return the chart version changes in a PR diff: OCIRepository files with a new tag."""
    bumps, current, old = [], None, None
    for line in diff_text.splitlines():
        match = _FILE.match(line)
        if match:
            current, old = match.group(1), None
            continue
        if not current or not current.endswith("ocirepository.yaml"):
            continue
        match = _TAG.match(line)
        if not match:
            continue
        sign, value = match.groups()
        if sign == "-":
            old = value
        elif old is not None:
            bumps.append({"file": current, "old": old, "new": value})
            old = None
    return bumps


def crd_verdict(old_crds, new_crds, helmreleases):
    """Return "no-change", "change-handled" or "change-unhandled".

    Helm does not update CRDs on an upgrade unless the HelmRelease asks for it.
    """
    if old_crds.strip() == new_crds.strip():
        return "no-change"
    handled = any(h.get("spec", {}).get("upgrade", {}).get("crds") == "CreateReplace" for h in helmreleases)
    return "change-handled" if handled and helmreleases else "change-unhandled"


TRANSIENT_REASONS = {"Progressing", "DependencyNotReady", "ProgressingWithRetry", "ReconciliationInProgress"}
BAD_POD_WAITING = {"ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "InvalidImageName"}
CRASH_RESTARTS = 3


def _ready(obj):
    for cond in obj.get("status", {}).get("conditions", []):
        if cond.get("type") == "Ready":
            return cond
    return {"status": "Unknown", "reason": "NoCondition", "message": ""}


def _epoch(timestamp):
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()


def assess_health(kustomizations, helmreleases, pods, sha, merged_at):
    """Return ("ready" | "progressing" | "failed", problems) for the cluster after a merge."""
    failed, waiting = [], []
    for kind, items in (("Kustomization", kustomizations), ("HelmRelease", helmreleases)):
        for obj in items:
            if obj.get("spec", {}).get("suspend"):
                continue
            ref = f"{kind} {obj['metadata']['namespace']}/{obj['metadata']['name']}"
            cond = _ready(obj)
            if cond["status"] == "True":
                if kind == "Kustomization" and sha not in obj.get("status", {}).get("lastAppliedRevision", ""):
                    waiting.append(f"{ref} not yet on {sha[:7]}")
                continue
            line = f"{ref}: {cond.get('reason')} {cond.get('message', '')[:200]}".rstrip()
            (waiting if cond["status"] == "Unknown" or cond.get("reason") in TRANSIENT_REASONS else failed).append(line)
    for pod in pods:
        meta = pod["metadata"]
        if _epoch(meta["creationTimestamp"]) < merged_at or pod.get("status", {}).get("phase") == "Succeeded":
            continue
        ref = f"Pod {meta['namespace']}/{meta['name']}"
        if pod["status"].get("phase") == "Failed":
            failed.append(f"{ref}: phase Failed")
        for status in pod["status"].get("containerStatuses", []) + pod["status"].get("initContainerStatuses", []):
            reason = status.get("state", {}).get("waiting", {}).get("reason")
            if reason in BAD_POD_WAITING:
                failed.append(f"{ref}: {reason}")
            elif reason == "CrashLoopBackOff":
                (failed if status.get("restartCount", 0) >= CRASH_RESTARTS else waiting).append(
                    f"{ref}: CrashLoopBackOff, {status.get('restartCount', 0)} restarts")
    if failed:
        return "failed", failed + waiting
    return ("progressing" if waiting else "ready"), waiting


_TITLE = re.compile(r"^(?P<type>[a-z]+)(\([^)]*\))?(?P<bang>!)?:\s*[Uu]pdate (?P<package>.+?)(?: \( ?(?P<old>\S+) ➔ (?P<new>\S+) ?\))?\s*$")
_DIGEST = re.compile(r"^[0-9a-f]{7,}$")

# The first rule that matches a changed file gives its category. The order is the order of risk.
CATEGORY_RULES = (
    ("platform", ("talos/", "kubernetes/apps/flux-system/", "kubernetes/apps/system-upgrade/")),
    ("secrets", ("kubernetes/apps/external-secrets/",)),
    ("data", ("kubernetes/apps/database/", "kubernetes/apps/rook-ceph/", "kubernetes/apps/openebs/",
              "kubernetes/apps/system/volsync/", "kubernetes/apps/system/kopia/")),
    ("infra", ("kubernetes/apps/", "hosts/")),
    ("ci", (".github/",)),
)
LEAF_NAMESPACES = ("selfhosted", "downloads", "media", "home-automation")
CATEGORY_RISK = ("ci", "leaf", "ai", "infra", "data", "secrets", "platform")
# Only a change to these categories needs the user, whatever Opus thinks.
ALWAYS_ASK_CATEGORIES = {"platform", "secrets"}
# The merge sequence: CI, leaf apps, the AI stack, infrastructure, then majors and high risk.
PHASES = {"ci": 1, "leaf": 2, "ai": 3, "infra": 4, "data": 4, "secrets": 4, "platform": 4}


def _file_category(path):
    if path.startswith("kubernetes/bootstrap/"):
        return None  # used only when the cluster is built again
    for category, prefixes in CATEGORY_RULES:
        if path.startswith(prefixes):
            if category == "infra" and path.startswith("kubernetes/apps/"):
                namespace = path.split("/")[2]
                if namespace in LEAF_NAMESPACES:
                    return "leaf"
                if namespace == "ai":
                    return "ai"
            return category
    return "infra"


def _numbers(version):
    parts = re.findall(r"\d+", version)
    return [int(p) for p in parts[:3]] + [0] * (3 - len(parts[:3]))


def _update_type(match):
    if not match or not match.group("old"):
        return "unknown"
    old, new = match.group("old"), match.group("new")
    if _DIGEST.match(old) and _DIGEST.match(new):
        return "digest"
    if match.group("bang"):
        return "major"
    a, b = _numbers(old), _numbers(new)
    if a[0] >= 2000 and a[0] != b[0]:
        return "calendar"  # a new year of a calendar version can need sequential upgrades
    if a[0] != b[0]:
        return "major"
    return "minor" if a[1] != b[1] else "patch"


def classify_pr(title, files):
    """Return the risk class of a Renovate PR from its title and changed files.

    A script decides this, not a model: the facts are in the title and the paths.
    """
    match = _TITLE.match(title)
    update = _update_type(match)
    categories = [c for c in (_file_category(f) for f in files) if c] or ["infra"]
    category = max(categories, key=CATEGORY_RISK.index)
    always_ask = category in ALWAYS_ASK_CATEGORIES or (category == "data" and update in ("major", "calendar"))
    if always_ask:
        risk = "high"
    elif update in ("unknown", "major", "calendar"):
        risk = "high" if category == "data" else "review"
    elif category == "data":
        risk = "review" if update == "minor" else "medium"
    elif update == "minor" or category == "infra":
        risk = "medium"
    else:
        risk = "low"
    phase = 5 if risk in ("review", "high") and update in ("major", "calendar", "unknown") else PHASES[category]
    return {"package": match.group("package") if match else title, "update": update, "category": category,
            "class": risk, "always_ask": always_ask, "phase": phase}


def classify_all(prs):
    """Classify the PRs of `gh pr list --json number,title,files`, in merge sequence.

    Two PRs for one package (a minor and a major) name each other in "pair".
    """
    rows = []
    for pr in prs:
        row = classify_pr(pr["title"], [f["path"] for f in pr.get("files", [])])
        row.update(number=pr["number"], title=pr["title"])
        rows.append(row)
    for row in rows:
        row["pair"] = sorted(r["number"] for r in rows if r["package"] == row["package"] and r is not row)
    return sorted(rows, key=lambda r: (r["phase"], r["number"]))


def _load(path):
    with open(path) as handle:
        return json.load(handle)


def main(argv):
    """CLI for the shell scripts. Exit codes are the contract; see SKILL.md."""
    command = argv[1] if len(argv) > 1 else ""
    if command == "checks":  # checks <checks.json> <failed_steps.json>
        status, reasons = classify_checks(_load(argv[2]), _load(argv[3]))
        print(status)
        print("\n".join(reasons))
        return {"ok": 0, "pending": 10, "failing": 30}[status]
    if command == "chart-bumps":  # chart-bumps <diff file>
        with open(argv[2]) as handle:
            print(json.dumps(chart_bumps(handle.read())))
        return 0
    if command == "crd-verdict":  # crd-verdict <old crds> <new crds> <helmreleases.json>
        with open(argv[2]) as old, open(argv[3]) as new:
            verdict = crd_verdict(old.read(), new.read(), _load(argv[4]))
        print(verdict)
        return {"no-change": 0, "change-handled": 3, "change-unhandled": 4}[verdict]
    if command == "health":  # health <ks.json> <hr.json> <pods.json> <sha> <merged-at epoch>
        state, problems = assess_health(_load(argv[2])["items"], _load(argv[3])["items"],
                                        _load(argv[4])["items"], argv[5], float(argv[6]))
        print(state)
        print("\n".join(problems))
        return {"ready": 0, "progressing": 10, "failed": 1}[state]
    if command == "classify":  # classify <prs.json>
        print("number\tphase\tclass\tupdate\tcategory\task\tpair\ttitle")
        for r in classify_all(_load(argv[2])):
            pair = ",".join(f"#{n}" for n in r["pair"]) or "-"
            print(f"#{r['number']}\t{r['phase']}\t{r['class']}\t{r['update']}\t{r['category']}\t"
                  f"{'ASK' if r['always_ask'] else '-'}\t{pair}\t{r['title']}")
        return 0
    print(f"usage: {argv[0]} checks|chart-bumps|crd-verdict|health|classify ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
