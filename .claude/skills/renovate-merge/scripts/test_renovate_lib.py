"""Tests for renovate_lib. Run: python3 -m unittest discover -s .claude/skills/renovate-merge/scripts"""

import unittest

import renovate_lib as lib


def run(name, conclusion="SUCCESS", status="COMPLETED"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion}


def context(name, state):
    return {"__typename": "StatusContext", "context": name, "state": state}


class ClassifyChecks(unittest.TestCase):
    def test_all_green_is_ok(self):
        status, _ = lib.classify_checks([run("yamllint"), run("Flux Local Diff (helmrelease)")], {})
        self.assertEqual(status, "ok")

    def test_skipped_and_neutral_are_ok(self):
        status, _ = lib.classify_checks([run("a", "SKIPPED"), run("b", "NEUTRAL")], {})
        self.assertEqual(status, "ok")

    def test_running_check_is_pending(self):
        status, _ = lib.classify_checks([run("a"), run("b", "", "IN_PROGRESS")], {})
        self.assertEqual(status, "pending")

    def test_pending_status_context_is_pending(self):
        status, _ = lib.classify_checks([context("renovate/stability-days", "PENDING")], {})
        self.assertEqual(status, "pending")

    def test_lint_failure_is_ignored(self):
        checks = [run("yamllint", "FAILURE"), run("Lint successful", "FAILURE"), run("x")]
        status, reasons = lib.classify_checks(checks, {})
        self.assertEqual(status, "ok")
        self.assertTrue(any("yamllint" in r for r in reasons))

    def test_flux_local_comment_failure_is_ignored(self):
        checks = [run("Flux Local Diff (helmrelease)", "FAILURE"), run("Flux Local successful", "FAILURE")]
        failed_steps = {"Flux Local Diff (helmrelease)": ["Add Comment"]}
        status, _ = lib.classify_checks(checks, failed_steps)
        self.assertEqual(status, "ok")

    def test_flux_local_render_failure_fails(self):
        checks = [run("Flux Local Diff (helmrelease)", "FAILURE"), run("Flux Local successful", "FAILURE")]
        failed_steps = {"Flux Local Diff (helmrelease)": ["Diff Resources"]}
        status, reasons = lib.classify_checks(checks, failed_steps)
        self.assertEqual(status, "failing")
        self.assertTrue(any("Diff Resources" in r for r in reasons))

    def test_flux_local_failure_with_unknown_steps_fails(self):
        checks = [run("Flux Local Diff (kustomization)", "FAILURE")]
        status, _ = lib.classify_checks(checks, {})
        self.assertEqual(status, "failing")

    def test_flux_local_successful_alone_fails_when_no_diff_job_explains_it(self):
        status, _ = lib.classify_checks([run("Flux Local successful", "FAILURE")], {})
        self.assertEqual(status, "failing")

    def test_other_failure_fails(self):
        status, reasons = lib.classify_checks([run("Extract Images (default)", "FAILURE")], {})
        self.assertEqual(status, "failing")
        self.assertIn("Extract Images (default)", reasons[0])

    def test_failure_beats_pending(self):
        status, _ = lib.classify_checks([run("a", "FAILURE"), run("b", "", "QUEUED")], {})
        self.assertEqual(status, "failing")


DIFF_OCI = """diff --git a/kubernetes/apps/x/app/ocirepository.yaml b/kubernetes/apps/x/app/ocirepository.yaml
--- a/kubernetes/apps/x/app/ocirepository.yaml
+++ b/kubernetes/apps/x/app/ocirepository.yaml
@@ -8,5 +8,5 @@ spec:
   ref:
-    tag: 0.14.2
+    tag: 0.15.1
   url: oci://ghcr.io/actions/charts/gha-runner-scale-set-controller
"""

DIFF_IMAGE = """diff --git a/kubernetes/apps/y/app/helmrelease.yaml b/kubernetes/apps/y/app/helmrelease.yaml
--- a/kubernetes/apps/y/app/helmrelease.yaml
+++ b/kubernetes/apps/y/app/helmrelease.yaml
@@ -20,7 +20,7 @@ spec:
               repository: ghcr.io/foo/bar
-              tag: 1.0.0
+              tag: 1.1.0
"""


class ChartBumps(unittest.TestCase):
    def test_ocirepository_tag_change_is_a_chart_bump(self):
        bumps = lib.chart_bumps(DIFF_OCI)
        self.assertEqual(bumps, [{"file": "kubernetes/apps/x/app/ocirepository.yaml", "old": "0.14.2", "new": "0.15.1"}])

    def test_image_tag_in_helmrelease_is_not_a_chart_bump(self):
        self.assertEqual(lib.chart_bumps(DIFF_IMAGE), [])

    def test_two_files_give_two_bumps(self):
        diff = DIFF_OCI + DIFF_OCI.replace("/x/", "/z/")
        self.assertEqual(len(lib.chart_bumps(diff)), 2)


def helmrelease(chartref, crds_upgrade=None):
    spec = {"chartRef": {"kind": "OCIRepository", "name": chartref}}
    if crds_upgrade:
        spec["upgrade"] = {"crds": crds_upgrade}
    return {"kind": "HelmRelease", "metadata": {"name": chartref}, "spec": spec}


class CrdVerdict(unittest.TestCase):
    def test_same_crds_is_no_change(self):
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 1\n", []), "no-change")

    def test_no_crds_in_either_is_no_change(self):
        self.assertEqual(lib.crd_verdict("", "", []), "no-change")

    def test_changed_crds_with_createreplace(self):
        hrs = [helmrelease("ctrl", "CreateReplace")]
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 2\n", hrs), "change-handled")

    def test_changed_crds_without_createreplace(self):
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 2\n", [helmrelease("ctrl")]), "change-unhandled")

    def test_changed_crds_with_skip_is_unhandled(self):
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 2\n", [helmrelease("ctrl", "Skip")]), "change-unhandled")

    def test_changed_crds_without_any_helmrelease_is_unhandled(self):
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 2\n", []), "change-unhandled")


def ks(name, ready="True", reason="ReconciliationSucceeded", rev="main@sha1:abc123", suspend=False):
    return {
        "metadata": {"namespace": "ns", "name": name},
        "spec": {"suspend": suspend},
        "status": {"lastAppliedRevision": rev, "conditions": [{"type": "Ready", "status": ready, "reason": reason, "message": ""}]},
    }


def hr(name, ready="True", reason="UpgradeSucceeded"):
    return {"metadata": {"namespace": "ns", "name": name}, "spec": {},
            "status": {"conditions": [{"type": "Ready", "status": ready, "reason": reason, "message": ""}]}}


def pod(name, created="2026-10-26T10:00:00Z", phase="Running", waiting=None, restarts=0):
    state = {"waiting": {"reason": waiting}} if waiting else {"running": {}}
    return {"metadata": {"namespace": "ns", "name": name, "creationTimestamp": created},
            "status": {"phase": phase, "containerStatuses": [{"state": state, "restartCount": restarts}]}}


MERGED_AT = 1793006400  # 2026-10-26T09:20:00Z


class AssessHealth(unittest.TestCase):
    def assess(self, kss=(), hrs=(), pods=()):
        return lib.assess_health(list(kss), list(hrs), list(pods), "abc123", MERGED_AT)

    def test_all_ready_on_sha(self):
        state, problems = self.assess([ks("a")], [hr("a")], [pod("a")])
        self.assertEqual((state, problems), ("ready", []))

    def test_kustomization_on_old_revision_is_progressing(self):
        state, _ = self.assess([ks("a", rev="main@sha1:old999")])
        self.assertEqual(state, "progressing")

    def test_suspended_kustomization_is_ignored(self):
        state, _ = self.assess([ks("a", ready="False", reason="BuildFailed", rev="x", suspend=True)])
        self.assertEqual(state, "ready")

    def test_reconciling_is_progressing(self):
        state, _ = self.assess([ks("a", ready="Unknown", reason="Progressing")])
        self.assertEqual(state, "progressing")

    def test_dependency_not_ready_is_progressing(self):
        state, _ = self.assess([ks("a", ready="False", reason="DependencyNotReady")])
        self.assertEqual(state, "progressing")

    def test_build_failed_is_failed(self):
        state, problems = self.assess([ks("a", ready="False", reason="BuildFailed")])
        self.assertEqual(state, "failed")
        self.assertIn("ns/a", problems[0])

    def test_helmrelease_upgrade_failed_is_failed(self):
        state, _ = self.assess([ks("a")], [hr("a", ready="False", reason="UpgradeFailed")])
        self.assertEqual(state, "failed")

    def test_helmrelease_upgrading_is_progressing(self):
        state, _ = self.assess([ks("a")], [hr("a", ready="Unknown", reason="Progressing")])
        self.assertEqual(state, "progressing")

    def test_new_pod_in_crash_loop_after_three_restarts_is_failed(self):
        state, problems = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", waiting="CrashLoopBackOff", restarts=3)])
        self.assertEqual(state, "failed")
        self.assertIn("ns/p", problems[0])

    def test_new_pod_crashing_once_is_progressing(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", waiting="CrashLoopBackOff", restarts=1)])
        self.assertEqual(state, "progressing")

    def test_old_crashing_pod_is_not_caused_by_the_merge(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T08:00:00Z", waiting="CrashLoopBackOff", restarts=9)])
        self.assertEqual(state, "ready")

    def test_new_pod_with_image_pull_error_is_failed(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", waiting="ImagePullBackOff")])
        self.assertEqual(state, "failed")

    def test_completed_pod_is_fine(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", phase="Succeeded")])
        self.assertEqual(state, "ready")

    def test_failure_beats_progressing(self):
        state, _ = self.assess([ks("a", ready="False", reason="BuildFailed"), ks("b", rev="main@sha1:old")])
        self.assertEqual(state, "failed")


def classify(title, *files):
    return lib.classify_pr(title, list(files))


APP = "kubernetes/apps/selfhosted/homepage/app/helmrelease.yaml"


class ClassifyPr(unittest.TestCase):
    def test_patch_of_a_leaf_app_is_low(self):
        c = classify("fix(container): update ghcr.io/x/frigate ( 0.18.0 ➔ 0.18.2 )", APP)
        self.assertEqual((c["update"], c["category"], c["class"], c["always_ask"]), ("patch", "leaf", "low", False))

    def test_digest_is_low(self):
        c = classify("chore(container): update mirror.gcr.io/library/python ( f6a589d ➔ 601e99e )", APP)
        self.assertEqual((c["update"], c["class"]), ("digest", "low"))

    def test_minor_of_a_leaf_app_is_medium(self):
        c = classify("feat(container): update ghcr.io/x/homepage ( v2.3.0 ➔ v2.7.0 )", APP)
        self.assertEqual((c["update"], c["class"]), ("minor", "medium"))

    def test_bang_marks_a_major(self):
        c = classify("feat(container)!: Update ghcr.io/x/booklore ( v1.18.5 ➔ v2.4.0 )", APP)
        self.assertEqual((c["update"], c["class"]), ("major", "review"))

    def test_major_number_change_without_bang_is_major(self):
        c = classify("feat(container): update x ( 0.3.7 ➔ 2.2.0 )", APP)
        self.assertEqual(c["update"], "major")

    def test_calendar_year_change_is_review(self):
        c = classify("feat(container): update ghcr.io/goauthentik/server ( 2025.12.4 ➔ 2026.8.5 )",
                     "kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml")
        self.assertEqual((c["update"], c["class"]), ("calendar", "review"))

    def test_calendar_month_change_is_minor(self):
        c = classify("feat(container): update x ( 2026.8.2 ➔ 2026.10.3 )", APP)
        self.assertEqual(c["update"], "minor")

    def test_title_without_versions_is_review(self):
        c = classify("feat(container): update flux operator group", "kubernetes/apps/flux-system/x/ocirepository.yaml")
        self.assertEqual((c["update"], c["class"]), ("unknown", "high"))

    def test_patch_of_infrastructure_is_medium(self):
        c = classify("fix(container): update multus ( 1.3.3 ➔ 1.3.6 )", "kubernetes/apps/network/multus/app/ocirepository.yaml")
        self.assertEqual((c["category"], c["class"]), ("infra", "medium"))

    def test_ci_patch_is_low(self):
        c = classify("ci(github-action): update actions/checkout ( v6.1.0 ➔ v6.1.1 )", ".github/workflows/lint.yaml")
        self.assertEqual((c["category"], c["class"]), ("ci", "low"))

    def test_bootstrap_file_does_not_decide_the_category(self):
        c = classify("feat(container): update cert-manager ( v1.19.3 ➔ v1.21.3 )",
                     "kubernetes/apps/cert-manager/cert-manager/app/ocirepository.yaml",
                     "kubernetes/bootstrap/helmfile.d/01-apps.yaml")
        self.assertEqual(c["category"], "infra")

    def test_major_of_a_data_store_is_high_and_always_ask(self):
        c = classify("feat(container)!: Update ghcr.io/dragonflydb/dragonfly ( v1.30.1 ➔ v2.0.2 )",
                     "kubernetes/apps/database/dragonfly/cluster/cluster.yaml")
        self.assertEqual((c["category"], c["class"], c["always_ask"]), ("data", "high", True))

    def test_minor_of_a_data_store_is_review(self):
        c = classify("feat(container): update dragonfly ( v1.30.1 ➔ v1.40.2 )", "kubernetes/apps/database/dragonfly/cluster/cluster.yaml")
        self.assertEqual((c["class"], c["always_ask"]), ("review", False))

    def test_patch_of_a_data_store_is_medium(self):
        c = classify("fix(container): update volsync ( 0.17.7 ➔ v0.17.11 )", "kubernetes/apps/system/volsync/app/helmrelease.yaml")
        self.assertEqual((c["category"], c["class"]), ("data", "medium"))

    def test_secrets_are_always_ask(self):
        c = classify("fix(container): update 1password connect group ( 1.8.2 ➔ 1.8.4 )",
                     "kubernetes/apps/external-secrets/onepassword-connect/app/helmrelease.yaml")
        self.assertEqual((c["category"], c["class"], c["always_ask"]), ("secrets", "high", True))

    def test_talos_is_platform_and_always_ask(self):
        c = classify("feat(container): update ghcr.io/siderolabs/installer ( v1.12.0 ➔ v1.12.2 )", "talos/nodes/home-ops-00.yaml")
        self.assertEqual((c["category"], c["class"], c["always_ask"]), ("platform", "high", True))

    def test_riskiest_file_decides_the_category(self):
        c = classify("feat(container): update x ( 1.0.0 ➔ 1.0.1 )", APP, "kubernetes/apps/database/x/app/helmrelease.yaml")
        self.assertEqual(c["category"], "data")

    def test_package_name_is_kept_for_pairs(self):
        c = classify("feat(container)!: Update ghcr.io/dragonflydb/dragonfly ( v1.30.1 ➔ v2.0.2 )", APP)
        self.assertEqual(c["package"], "ghcr.io/dragonflydb/dragonfly")

    def test_phase_puts_majors_last(self):
        low = classify("fix(container): update a ( 1.0.0 ➔ 1.0.1 )", APP)
        major = classify("feat(container)!: Update b ( 1.0.0 ➔ 2.0.0 )", APP)
        self.assertLess(low["phase"], major["phase"])


class ClassifyAll(unittest.TestCase):
    PRS = [
        {"number": 267, "title": "feat(container)!: Update ghcr.io/dragonflydb/dragonfly ( v1.30.1 ➔ v2.0.2 )",
         "files": [{"path": "kubernetes/apps/database/dragonfly/cluster/cluster.yaml"}]},
        {"number": 249, "title": "feat(container): update ghcr.io/dragonflydb/dragonfly ( v1.30.1 ➔ v1.40.2 )",
         "files": [{"path": "kubernetes/apps/database/dragonfly/cluster/cluster.yaml"}]},
        {"number": 353, "title": "fix(container): update ghcr.io/blakeblackshear/frigate ( 0.18.0 ➔ 0.18.2 )",
         "files": [{"path": "kubernetes/apps/home-automation/frigate/app/helmrelease.yaml"}]},
    ]

    def test_rows_are_sorted_by_phase_then_number(self):
        self.assertEqual([r["number"] for r in lib.classify_all(self.PRS)], [353, 249, 267])

    def test_two_prs_for_one_package_name_each_other(self):
        rows = {r["number"]: r for r in lib.classify_all(self.PRS)}
        self.assertEqual(rows[267]["pair"], [249])
        self.assertEqual(rows[249]["pair"], [267])
        self.assertEqual(rows[353]["pair"], [])


if __name__ == "__main__":
    unittest.main()
