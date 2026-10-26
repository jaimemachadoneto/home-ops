"""Tests for renovate_lib. Run: python3 -m unittest discover -s .claude/skills/renovate-merge/scripts"""

import json
import os
import tempfile
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
        self.assertEqual(bumps, [{"file": "kubernetes/apps/x/app/ocirepository.yaml", "old": "0.14.2", "new": "0.15.1",
                                  "source": "oci"}])

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

    def test_title_without_versions_in_platform_is_high(self):
        c = classify("feat(container): update flux operator group", "kubernetes/apps/flux-system/x/ocirepository.yaml")
        self.assertEqual((c["update"], c["class"]), ("unknown", "high"))

    def test_patch_of_infrastructure_is_medium(self):
        c = classify("fix(container): update multus ( 1.3.3 ➔ 1.3.6 )", "kubernetes/apps/network/multus/app/ocirepository.yaml")
        self.assertEqual((c["category"], c["class"]), ("infra", "medium"))

    def test_ci_patch_is_medium(self):
        # The workflows hold an app key, and a compromised action merges at once if it is low.
        c = classify("ci(github-action): update actions/checkout ( v6.1.0 ➔ v6.1.1 )", ".github/workflows/lint.yaml")
        self.assertEqual((c["category"], c["class"], c["phase"]), ("ci", "medium", 1))

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
        c = classify("feat(container): update ghcr.io/siderolabs/installer ( v1.12.0 ➔ v1.12.2 )", "kubernetes/talos/nodes/home-ops-00.yaml")
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
        self.assertEqual((low["phase"], major["phase"]), (2, 5))


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


class MoreChecks(unittest.TestCase):
    def test_no_checks_is_pending(self):
        self.assertEqual(lib.classify_checks([], {})[0], "pending")

    def test_successful_status_context_is_ok(self):
        self.assertEqual(lib.classify_checks([context("x", "SUCCESS")], {})[0], "ok")

    def test_failed_or_error_status_context_fails(self):
        for state in ("FAILURE", "ERROR"):
            self.assertEqual(lib.classify_checks([context("x", state)], {})[0], "failing", state)

    def test_completed_run_without_conclusion_is_pending(self):
        self.assertEqual(lib.classify_checks([run("a", None)], {})[0], "pending")

    def test_flux_local_comment_and_render_failure_fails(self):
        checks = [run("Flux Local Diff (helmrelease)", "FAILURE")]
        steps = {"Flux Local Diff (helmrelease)": ["Add Comment", "Diff Resources"]}
        self.assertEqual(lib.classify_checks(checks, steps)[0], "failing")

    def test_one_unexplained_flux_local_diff_job_fails(self):
        checks = [run("Flux Local Diff (helmrelease)", "FAILURE"), run("Flux Local Diff (kustomization)", "FAILURE"),
                  run("Flux Local successful", "FAILURE")]
        steps = {"Flux Local Diff (helmrelease)": ["Add Comment"], "Flux Local Diff (kustomization)": ["Diff Resources"]}
        self.assertEqual(lib.classify_checks(checks, steps)[0], "failing")


class MoreHealth(unittest.TestCase):
    def assess(self, kss=(), hrs=(), pods=()):
        return lib.assess_health(list(kss), list(hrs), list(pods), "abc123", MERGED_AT)

    def test_new_pod_in_phase_failed_is_failed(self):
        state, problems = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", phase="Failed")])
        self.assertEqual(state, "failed")
        self.assertIn("phase Failed", problems[0])

    def test_new_pod_crashing_twice_is_progressing(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:25:00Z", waiting="CrashLoopBackOff", restarts=2)])
        self.assertEqual(state, "progressing")

    def test_pod_created_at_merge_time_counts_as_new(self):
        state, _ = self.assess([ks("a")], [], [pod("p", "2026-10-26T09:20:00Z", waiting="CrashLoopBackOff", restarts=3)])
        self.assertEqual(state, "failed")

    def test_init_container_image_pull_error_is_failed(self):
        p = pod("p", "2026-10-26T09:25:00Z")
        p["status"]["initContainerStatuses"] = [{"state": {"waiting": {"reason": "ImagePullBackOff"}}, "restartCount": 0}]
        self.assertEqual(self.assess([ks("a")], [], [p])[0], "failed")

    def test_object_without_ready_condition_is_progressing(self):
        k = ks("a")
        k["status"]["conditions"] = []
        self.assertEqual(self.assess([k])[0], "progressing")

    def test_no_kustomizations_is_failed(self):
        # kubectl on the wrong context gives empty lists; that is not a healthy cluster.
        state, problems = self.assess([], [], [])
        self.assertEqual(state, "failed")
        self.assertIn("no Kustomizations", problems[0])


class MoreClassify(unittest.TestCase):
    def test_numeric_calendar_version_is_not_a_digest(self):
        self.assertEqual(classify("feat(container): update x ( 20250101 ➔ 20260101 )", APP)["update"], "calendar")

    def test_calendar_year_change_of_a_data_store_is_always_ask(self):
        c = classify("feat(container): update x ( 2025.1.0 ➔ 2026.1.0 )", "kubernetes/apps/database/x/app/helmrelease.yaml")
        self.assertEqual((c["always_ask"], c["phase"]), (True, 5))

    def test_ai_namespace_is_ai_category(self):
        c = classify("fix(container): update x ( 1.0.0 ➔ 1.0.1 )", "kubernetes/apps/ai/x/app/helmrelease.yaml")
        self.assertEqual((c["category"], c["phase"], c["class"]), ("ai", 3, "low"))

    def test_no_files_is_infra(self):
        self.assertEqual(lib.classify_pr("fix(container): update x ( 1.0.0 ➔ 1.0.1 )", [])["category"], "infra")

    def test_unparsed_title_keeps_title_as_package(self):
        title = "chore(deps): lock file maintenance"
        c = classify(title, APP)
        self.assertEqual((c["package"], c["update"], c["class"]), (title, "unknown", "review"))

    def test_digest_of_infrastructure_is_medium(self):
        c = classify("chore(container): update x ( f6a589d ➔ 601e99e )", "kubernetes/apps/network/x/app/helmrelease.yaml")
        self.assertEqual((c["update"], c["class"]), ("digest", "medium"))


class MoreCrds(unittest.TestCase):
    def test_changed_crds_with_create_is_unhandled(self):
        self.assertEqual(lib.crd_verdict("a: 1\n", "a: 2\n", [helmrelease("ctrl", "Create")]), "change-unhandled")

    def test_worst_crd_code_ranks_unhandled_highest(self):
        self.assertEqual(lib.worst_crd_code([3, 2, 4, 0]), 4)
        self.assertEqual(lib.worst_crd_code([3, 2]), 2)
        self.assertEqual(lib.worst_crd_code([0, 3]), 3)
        self.assertEqual(lib.worst_crd_code([]), 0)


class MoreChartBumps(unittest.TestCase):
    def test_empty_diff_has_no_bump(self):
        self.assertEqual(lib.chart_bumps(""), [])

    def test_new_ocirepository_file_is_not_a_bump(self):
        diff = DIFF_OCI.replace("-    tag: 0.14.2\n", "")
        self.assertEqual(lib.chart_bumps(diff), [])


class Cli(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def file(self, name, data):
        path = os.path.join(self.dir.name, name)
        with open(path, "w") as handle:
            handle.write(data if isinstance(data, str) else json.dumps(data))
        return path

    def test_checks_exit_codes(self):
        steps = self.file("steps.json", {})
        for checks, code in (([run("a")], 0), ([run("a", "", "QUEUED")], 10), ([run("a", "FAILURE")], 30)):
            self.assertEqual(lib.main(["x", "checks", self.file("c.json", checks), steps]), code)

    def test_health_exit_codes(self):
        empty = self.file("e.json", {"items": []})
        ready = self.file("r.json", {"items": [ks("a")]})
        busy = self.file("b.json", {"items": [ks("a", rev="main@sha1:old")]})
        for kss, code in ((ready, 0), (busy, 10), (empty, 1)):
            self.assertEqual(lib.main(["x", "health", kss, empty, empty, "abc123", str(MERGED_AT)]), code)

    def test_crd_verdict_exit_codes(self):
        one, two = self.file("1.yaml", "a: 1\n"), self.file("2.yaml", "a: 2\n")
        handled = self.file("h.json", [helmrelease("c", "CreateReplace")])
        none = self.file("n.json", [])
        self.assertEqual(lib.main(["x", "crd-verdict", one, one, none]), 0)
        self.assertEqual(lib.main(["x", "crd-verdict", one, two, handled]), 3)
        self.assertEqual(lib.main(["x", "crd-verdict", one, two, none]), 4)


class Security(unittest.TestCase):
    def test_flux_root_is_platform(self):
        c = classify("feat(container): update x ( 1.0.0 ➔ 1.0.1 )", "kubernetes/flux/cluster/ks.yaml")
        self.assertEqual((c["category"], c["always_ask"]), ("platform", True))

    def test_talos_template_is_platform(self):
        c = classify("feat(container): update x ( 1.0.0 ➔ 1.0.1 )", "kubernetes/talos/machineconfig.yaml.j2")
        self.assertEqual(c["category"], "platform")

    def test_a_pr_with_a_full_file_list_is_review(self):
        files = [f"kubernetes/apps/selfhosted/a{i}/app/helmrelease.yaml" for i in range(100)]
        c = lib.classify_pr("fix(container): update x ( 1.0.0 ➔ 1.0.1 )", files)
        self.assertEqual(c["class"], "review")


VERSION_DIFF = """diff --git a/kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml b/kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml
--- a/kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml
+++ b/kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml
@@ -20,7 +20,7 @@ spec:
               repository: ghcr.io/goauthentik/server
-              tag: 2025.12.4@sha256:aaa
+              tag: 2026.2.3@sha256:bbb
"""

CRD_DIFF = """diff --git a/x/helmrelease.yaml b/x/helmrelease.yaml
--- a/x/helmrelease.yaml
+++ b/x/helmrelease.yaml
@@ -10,7 +10,13 @@ spec:
+  # Helm skips the CRDs on an upgrade.
+  install:
+    crds: CreateReplace
+  upgrade:
+    crds: CreateReplace
"""


class OwnPrScope(unittest.TestCase):
    def test_version_change_is_allowed(self):
        self.assertTrue(lib.own_pr_scope_ok(VERSION_DIFF)[0])

    def test_crd_policy_change_is_allowed(self):
        self.assertTrue(lib.own_pr_scope_ok(CRD_DIFF)[0])

    def test_chart_version_change_is_allowed(self):
        diff = VERSION_DIFF.replace("tag: 2025.12.4@sha256:aaa", "version: 1.2.3").replace("tag: 2026.2.3@sha256:bbb", "version: 1.2.4")
        self.assertTrue(lib.own_pr_scope_ok(diff)[0])

    def test_any_other_line_is_refused(self):
        diff = CRD_DIFF + "+    hostPath:\n+      path: /\n"
        ok, lines = lib.own_pr_scope_ok(diff)
        self.assertFalse(ok)
        self.assertIn("hostPath:", lines[0])

    def test_a_new_file_is_refused(self):
        diff = "diff --git a/new.yaml b/new.yaml\nnew file mode 100644\n--- /dev/null\n+++ b/new.yaml\n+  tag: 1.0.0\n"
        self.assertFalse(lib.own_pr_scope_ok(diff)[0])

    def test_an_empty_diff_is_refused(self):
        self.assertFalse(lib.own_pr_scope_ok("")[0])

    def test_a_workflow_change_is_refused(self):
        diff = VERSION_DIFF.replace("kubernetes/apps/selfhosted/authentik/app/helmrelease.yaml", ".github/workflows/x.yaml")
        self.assertFalse(lib.own_pr_scope_ok(diff)[0])


BOT, ME = "app/jmnhomeopsbot", "jaimemachadoneto"


def pr_json(author=BOT, title="fix(container): update x ( 1.0.0 ➔ 1.0.1 )", files=(APP,)):
    return {"author": {"login": author}, "title": title, "files": [{"path": f} for f in files]}


class MergeGate(unittest.TestCase):
    def gate(self, pr, diff=VERSION_DIFF, own=False, approved=False):
        return lib.merge_gate(pr, diff, own, approved, BOT, ME)

    def test_renovate_pr_of_low_risk_is_allowed(self):
        self.assertTrue(self.gate(pr_json())[0])

    def test_pr_of_another_author_is_refused(self):
        ok, reason = self.gate(pr_json(author="someone"))
        self.assertFalse(ok)
        self.assertIn("someone", reason)

    def test_always_ask_pr_without_approval_is_refused(self):
        pr = pr_json(title="fix(container): update 1password connect group ( 1.8.2 ➔ 1.8.4 )",
                     files=["kubernetes/apps/external-secrets/onepassword-connect/app/helmrelease.yaml"])
        self.assertFalse(self.gate(pr)[0])
        self.assertTrue(self.gate(pr, approved=True)[0])

    def test_own_pr_with_versions_only_is_allowed(self):
        self.assertTrue(self.gate(pr_json(author=ME, title="feat: authentik 2026.2.3 first"), own=True)[0])

    def test_own_pr_with_other_lines_is_refused(self):
        ok, reason = self.gate(pr_json(author=ME), diff=CRD_DIFF + "+    hostPath: /\n", own=True)
        self.assertFalse(ok)
        self.assertIn("hostPath", reason)

    def test_own_flag_on_a_renovate_pr_is_refused(self):
        self.assertFalse(self.gate(pr_json(), own=True)[0])

    def test_own_pr_of_a_data_store_needs_approval(self):
        pr = pr_json(author=ME, title="feat: dragonfly v1.40 first", files=["kubernetes/apps/database/dragonfly/cluster/cluster.yaml"])
        self.assertFalse(self.gate(pr, own=True)[0])
        self.assertTrue(self.gate(pr, own=True, approved=True)[0])


DIFF_HELMREPO = """diff --git a/kubernetes/apps/network/ingress-nginx/internal/helmrelease.yaml b/kubernetes/apps/network/ingress-nginx/internal/helmrelease.yaml
--- a/kubernetes/apps/network/ingress-nginx/internal/helmrelease.yaml
+++ b/kubernetes/apps/network/ingress-nginx/internal/helmrelease.yaml
@@ -10,7 +10,7 @@ spec:
       chart: ingress-nginx
-      version: 4.14.3
+      version: 4.15.1
"""


class ReviewFixes(unittest.TestCase):
    def test_helmrelease_chart_version_is_a_bump_from_a_helmrepository(self):
        bumps = lib.chart_bumps(DIFF_HELMREPO)
        self.assertEqual([(b["old"], b["new"], b["source"]) for b in bumps], [("4.14.3", "4.15.1", "helmrepository")])

    def test_unknown_crd_code_counts_as_cannot_tell(self):
        self.assertEqual(lib.worst_crd_code([0, 1]), 2)
        self.assertEqual(lib.worst_crd_code([3, 1, 4]), 4)

    def test_newer_commit_on_main_counts_as_applied(self):
        k = ks("a", rev="main@sha1:def456")
        state, _ = lib.assess_health([k], [], [], "abc123,def456", MERGED_AT)
        self.assertEqual(state, "ready")

    def test_helmrelease_not_yet_observed_is_progressing(self):
        h = hr("a")
        h["metadata"]["generation"] = 3
        h["status"]["observedGeneration"] = 2
        state, problems = lib.assess_health([ks("a")], [h], [], "abc123", MERGED_AT)
        self.assertEqual(state, "progressing")
        self.assertIn("generation", problems[0])

    def test_zero_major_minor_change_is_major(self):
        self.assertEqual(classify("feat(container): update x ( 0.9.0 ➔ 0.10.0 )", APP)["update"], "major")

    def test_zero_major_patch_change_is_patch(self):
        self.assertEqual(classify("fix(container): update x ( 0.9.0 ➔ 0.9.1 )", APP)["update"], "patch")


if __name__ == "__main__":
    unittest.main()
