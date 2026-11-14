"""Replays real change shapes through scripts/ci_plan.py (stdlib unittest)."""
import fnmatch
import io
import json
import os
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_plan  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DOMAINS = ci_plan.load_domains()


def jobs(paths, **kw):
    return set(ci_plan.plan(paths, DOMAINS, **kw)["jobs"])


def _push_block(workflow: Path) -> str:
    text = workflow.read_text()
    m = re.search(r"(?ms)^on:\s*\n(.*?)(?=^[a-zA-Z0-9_-]+:|\Z)", text)
    if not m:
        return ""
    pm = re.search(r"(?ms)^  push:\s*\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)", m.group(1))
    return pm.group(1) if pm else ""


def push_paths(workflow: Path) -> list[str]:
    block = _push_block(workflow)
    if "paths-ignore" in block:
        raise AssertionError(f"{workflow.name} push block still uses paths-ignore")
    m = re.search(r"(?ms)^\s+paths:\s*\n((?:\s+-\s*[^\n]+\n?)+)", block)
    if not m:
        return []
    return [
        re.sub(r"^\s*-\s*", "", line).strip().strip("'\"")
        for line in m.group(1).splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def matches_push_paths(path: str, patterns: list[str]) -> bool:
    """Mirror GitHub's ordered paths: later matching pattern wins, `!` negates."""
    matched = False
    for pat in patterns:
        neg = pat.startswith("!")
        g = pat[1:] if neg else pat
        if g == "**":
            hit = True
        elif g.endswith("/**"):
            hit = path.startswith(g[:-2])
        else:
            hit = fnmatch.fnmatchcase(path, g)
        if hit:
            matched = not neg
    return matched


def script_docs_inputs() -> dict[str, list[str]]:
    """docs/ files the scripts themselves read: {script: [rel paths]}.

    Derived from the source, so a new input cannot be forgotten silently.
    """
    out: dict[str, list[str]] = {}
    for script in sorted((ROOT / "scripts").glob("*.py")):
        if script.name == "test_ci_plan.py":
            continue
        refs = re.findall(r"""['"](docs/[A-Za-z0-9_./-]+)['"]""", script.read_text(encoding="utf-8"))
        if refs:
            out[script.name] = sorted(set(refs))
    return out


class PlanTest(unittest.TestCase):
    def test_docs_only_runs_only_fmt(self):
        self.assertEqual(jobs(["docs/ci/refactor-proposal.md", "README.md"]), {"fmt"})

    def test_orb_src_does_not_build_lean_or_mobile(self):
        got = jobs(["orb/src/Sidebar.tsx"])
        self.assertEqual(got, {"fmt", "orb-unit", "orb-browser"})

    def test_mission_view_runs_performance(self):
        self.assertIn("orb-performance", jobs(["orb/src/mission/VirtualTurns.tsx"]))

    def test_kernel_change_reaches_every_client(self):
        got = jobs(["lean/Orb/Kernel.lean"])
        for j in ("test", "orb-browser", "wf:kernel-abi", "wf:ios-build", "wf:android-apk"):
            self.assertIn(j, got)

    def test_fixture_change_reaches_mobile(self):
        got = jobs(["shared/orb-spec/fixtures/stream-commit.json"])
        self.assertTrue({"wf:ios-build", "wf:android-apk", "test", "orb-unit"} <= got)
        self.assertNotIn("orb-macos-shell", got)

    def test_lean_package_skips_web_and_kernel(self):
        got = jobs(["lean/OrbCore/OrbCore/Managed.lean"])
        self.assertIn("test", got)
        self.assertIn("docker", got)
        self.assertIn("wf:kernel-abi", got)  # package specs are audited there
        self.assertFalse({"orb-unit", "orb-browser", "orb-macos-shell"} & got)

    def test_package_spec_runs_kernel_audit(self):
        for p in ("lean/OrbCore/OrbCore/Spec.lean", "lean/OrbClient/OrbClient/Reducers.lean"):
            self.assertIn("wf:kernel-abi", jobs([p]), p)

    def test_android_jni_runs_kernel_abi(self):
        for p in ("android_dashboard/app/src/main/jni/orb_kernel_jni.c",
                  "android_dashboard/app/src/main/jni/liborb_kernel.so.sha256"):
            self.assertTrue({"wf:kernel-abi", "wf:android-apk"} <= jobs([p]), p)
        self.assertNotIn("wf:kernel-abi", jobs(["android_dashboard/app/build.gradle.kts"]))

    def test_kernel_workflow_scripts_select_kernel_abi(self):
        wf = (ROOT / ".github/workflows/kernel-abi.yml").read_text()
        refs = set(re.findall(r"scripts/[A-Za-z0-9_./-]+\.(?:py|sh|lean|mjs)", wf))
        self.assertTrue(refs)
        for r in sorted(refs):
            d = ci_plan.claim(r, DOMAINS)
            self.assertTrue(d and (d.get("full") or "wf:kernel-abi" in d["jobs"]), r)

    def test_generated_bindings_select_kernel_abi(self):
        import gen_kernel_bindings as g
        for out in g.outputs(g.load_manifest()):
            rel = str(out.relative_to(g.ROOT))
            self.assertIn("wf:kernel-abi", jobs([rel]), rel)

    def test_performance_specs_and_virtualization_run_performance(self):
        for p in ("orb/tests/performance.browser.spec.ts",
                  "orb/tests/sidebar-performance.tsx",
                  "orb/src/VirtualTurns.tsx"):
            self.assertIn("orb-performance", jobs([p]), p)

    def test_wakeup_mcp_runs_desktop_shell(self):
        for p in ("scripts/wakeup_mcp.py", "orb/tests/wakeup_mcp_test.py"):
            self.assertIn("orb-desktop-shell", jobs([p]), p)

    def test_macos_shell_only_on_macos_inputs(self):
        self.assertNotIn("orb-macos-shell", jobs(["linux_shell/main.c"]))
        self.assertIn("orb-macos-shell", jobs(["macos_shell/main.swift"]))

    def test_ios_only(self):
        self.assertEqual(jobs(["ios_dashboard/project.yml"]), {"fmt", "wf:ios-build"})

    def test_skill_markdown_is_not_docs(self):
        self.assertIn("policy-lint", jobs(["skills/foo/SKILL.md"]))

    def test_script_docs_inputs_trigger_push_and_select_running_jobs(self):
        by_script = script_docs_inputs()
        self.assertTrue(by_script)
        ci_patterns = push_paths(ROOT / ".github/workflows/ci.yml")
        kabi_wf = (ROOT / ".github/workflows/kernel-abi.yml").read_text(encoding="utf-8")
        kabi_patterns = push_paths(ROOT / ".github/workflows/kernel-abi.yml")
        self.assertEqual(ci_patterns[0], "**")
        self.assertEqual(kabi_patterns[0], "**")
        for script_name, doc_paths in sorted(by_script.items()):
            runs_in_kernel_abi = script_name in kabi_wf
            for doc in doc_paths:
                self.assertTrue((ROOT / doc).is_file(), f"{script_name}: missing {doc}")
                self.assertTrue(
                    matches_push_paths(doc, ci_patterns),
                    f"{doc} (read by {script_name}) is excluded by ci.yml push.paths",
                )
                planned = jobs([doc])
                self.assertIn(
                    "policy-lint",
                    planned,
                    f"{doc} (read by {script_name}) must run policy-lint",
                )
                if runs_in_kernel_abi:
                    self.assertTrue(
                        matches_push_paths(doc, kabi_patterns),
                        f"{doc} (read by {script_name}) is excluded by kernel-abi.yml push.paths",
                    )
                    self.assertIn(
                        "wf:kernel-abi",
                        planned,
                        f"{doc} (read by {script_name}) must run wf:kernel-abi",
                    )
        self.assertIn("policy-lint", jobs(["plan.md"]))

    def test_push_paths_only_exclude_always_only_files(self):
        tracked = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).split()
        always = set(ci_plan.ALWAYS)
        for wf_name in ("ci.yml", "kernel-abi.yml"):
            patterns = push_paths(ROOT / ".github" / "workflows" / wf_name)
            self.assertTrue(patterns and patterns[0] == "**", wf_name)
            mismatched = []
            for p in tracked:
                if not matches_push_paths(p, patterns):
                    extra = sorted(jobs([p]) - always)
                    if extra:
                        mismatched.append((p, extra))
            self.assertEqual(
                mismatched,
                [],
                f"{wf_name} push paths filter excludes files with non-always jobs",
            )

    def test_ci_inputs_force_full(self):
        for p in (".github/workflows/ci.yml", "lean/lean-toolchain",
                  "lean/turbo-lean-revision", "lean/turbo-lean-hash", "ci/domains.toml"):
            r = ci_plan.plan([p], DOMAINS)
            self.assertTrue(r["full"], p)
            self.assertEqual(r["skipped"], [], p)

    def test_unknown_path_fails_closed(self):
        r = ci_plan.plan(["brand-new-dir/thing.bin"], DOMAINS)
        self.assertTrue(r["full"])
        self.assertEqual(r["unclaimed"], ["brand-new-dir/thing.bin"])

    def test_master_push_schedule_dispatch_force_full(self):
        for kw in ({"event": "push", "ref": "refs/heads/master"},
                   {"event": "schedule"}, {"event": "workflow_dispatch"}):
            self.assertTrue(ci_plan.plan(["README.md"], DOMAINS, **kw)["full"], kw)
        self.assertFalse(ci_plan.plan(["README.md"], DOMAINS, event="push",
                                      ref="refs/heads/feature")["full"])

    def test_missing_base_forces_full(self):
        self.assertIsNone(ci_plan.changed_paths(ci_plan.NULL_SHA, "HEAD"))
        self.assertIsNone(ci_plan.changed_paths(None, "HEAD"))

    def test_every_tracked_file_is_claimed(self):
        tracked = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).split()
        unclaimed = [p for p in tracked if ci_plan.claim(p, DOMAINS) is None]
        self.assertEqual(unclaimed, [], "add these paths to ci/domains.toml")

    def test_domain_jobs_exist_in_workflows(self):
        wf = ROOT / ".github" / "workflows"
        ci = (wf / "ci.yml").read_text()
        for j in ci_plan.all_jobs(DOMAINS):
            if j.startswith("wf:"):
                self.assertTrue((wf / f"{j[3:]}.yml").exists(), j)
            else:
                self.assertRegex(ci, rf"(?m)^  {re.escape(j)}:$", j)

    def test_ci_jobs_are_gated_or_always(self):
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        ids = re.findall(r"(?m)^  ([a-z0-9-]+):$", ci.split("\njobs:\n", 1)[1])
        known = set(ci_plan.all_jobs(DOMAINS)) | {"plan", "ci-ok", "orb-build"}
        self.assertEqual(sorted(set(ids) - known), [], "ci.yml job missing from domains")

    def test_github_output(self):
        with tempfile.TemporaryDirectory() as d:
            paths, out = Path(d, "p.txt"), Path(d, "o.txt")
            paths.write_text("orb/src/App.tsx\n")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci_plan.py"),
                            "--paths-file", str(paths), "--github-output", str(out)],
                           check=True, capture_output=True)
            kv = dict(l.split("=", 1) for l in out.read_text().splitlines())
        self.assertEqual(kv["full"], "false")
        self.assertEqual(kv["run_orb_unit"], "true")
        self.assertEqual(kv["run_test"], "false")
        self.assertEqual(kv["run_wf_kernel_abi"], "false")
        self.assertIn("orb-unit", json.loads(kv["jobs"]))

REPOSITORY = "Th0rgal/orb"
INPUTS = {"tree_hash": "a" * 40, "orb_build_hash": "b" * 64, "domain_hashes": {"orb_web": "c" * 64}, "desktop_build_hash": "f" * 64}


def receipt(workflow="ci", **overrides):
    return {"version": ci_plan.RECEIPT_VERSION, "workflow": workflow,
            "repository": REPOSITORY, "run_id": "10", "run_attempt": 1,
            "jobs": ["orb-unit", "orb-browser"], "unaffected": [],
            "dist_run_id": "10", **INPUTS, **overrides}


def archive_receipt(value, name="verified.json"):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr(name, json.dumps(value))
    return stream.getvalue()


class TreeInputsTest(unittest.TestCase):
    def test_git_inputs_are_content_based_and_detect_names_modes_and_deletions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
            git("init", "-q")
            git("config", "user.email", "ci-test@example.invalid")
            git("config", "user.name", "CI test")
            for path in ("orb/src/a.ts", "orb/native.symlink", "linux_shell/a.c", "docs/a.md", "ci/domains.toml", "unknown.input"):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                if path.endswith("symlink"):
                    target.symlink_to("src/a.ts")
                else:
                    target.write_text("initial\n")
            def commit():
                git("add", "-A")
                git("commit", "-qm", "snapshot")
                return ci_plan.tree_inputs(root=root)
            before = commit()
            self.assertEqual(before["tree_hash"], git("rev-parse", "HEAD^{tree}"))
            git("commit", "--allow-empty", "-qm", "different SHA, identical tree")
            self.assertEqual(before, ci_plan.tree_inputs(root=root))
            (root / "orb/src/a.ts").write_text("dirty\n")
            self.assertEqual(before, ci_plan.tree_inputs(root=root))
            changed = commit()
            self.assertNotEqual(before["orb_build_hash"], changed["orb_build_hash"])
            self.assertEqual(before["domain_hashes"]["desktop_native"], changed["domain_hashes"]["desktop_native"])
            (root / "docs/a.md").write_text("new docs\n")
            docs = commit()
            self.assertNotEqual(docs["tree_hash"], changed["tree_hash"])
            self.assertEqual(docs["orb_build_hash"], changed["orb_build_hash"])
            self.assertEqual(docs["desktop_build_hash"], changed["desktop_build_hash"])
            self.assertEqual(changed["desktop_build_hash"], before["desktop_build_hash"])
            (root / "orb/src/a.ts").rename(root / "orb/src/b.ts")
            renamed = commit()
            self.assertNotEqual(renamed["orb_build_hash"], docs["orb_build_hash"])
            (root / "orb/src/b.ts").chmod(0o755)
            mode = commit()
            self.assertNotEqual(mode["orb_build_hash"], renamed["orb_build_hash"])
            (root / "orb/src/b.ts").unlink()
            deleted = commit()
            self.assertNotEqual(deleted["orb_build_hash"], mode["orb_build_hash"])
            (root / "ci/domains.toml").write_text("different workflow inputs\n")
            self.assertNotEqual(commit()["orb_build_hash"], deleted["orb_build_hash"])

    def test_native_only_domains_are_exact(self):
        for path in ("linux_shell/main.c", "linux_shell/gtk_chrome.c", "lean/OrbDesktop/Main.lean"):
            self.assertEqual(jobs([path]), {"fmt", "orb-desktop-shell"}, path)
        self.assertEqual(jobs(["macos_shell/main.swift"]),
                         {"fmt", "orb-desktop-shell", "orb-macos-shell"})


class VerificationTest(unittest.TestCase):
    def apply(self, receipts, workflow="ci"):
        result = ci_plan.plan(["orb/src/App.tsx"], DOMAINS, event="push", ref="master")
        return ci_plan.reuse_verified(result, INPUTS, receipts, workflow, REPOSITORY)

    def test_same_tree_reuses_only_recorded_workflow_checks(self):
        result = self.apply([receipt(jobs=["orb-unit", "wf:kernel-abi", "fmt"])])
        self.assertEqual(result["reused"], ["orb-unit"])
        self.assertIn("fmt", result["jobs"])
        self.assertIn("wf:kernel-abi", result["jobs"])
        self.assertNotIn("orb-unit", result["jobs"])
        self.assertEqual(result["dist_run_id"], "10")

    def test_unrelated_checks_preserve_the_green_pr_impact_plan(self):
        result = self.apply([receipt(unaffected=["orb-performance", "docker"])])
        self.assertEqual(result["unaffected"], ["docker", "orb-performance"])
        self.assertNotIn("docker", result["jobs"])
        self.assertIn("test", result["jobs"])

    def test_other_tree_can_reuse_build_but_never_checks(self):
        result = self.apply([receipt(tree_hash="d" * 40)])
        self.assertEqual(result["reused"], [])
        self.assertEqual(result["dist_run_id"], "10")
        result = self.apply([receipt(tree_hash="d" * 40, orb_build_hash="e" * 64)])
        self.assertEqual(result["dist_run_id"], "")

    def test_native_binary_artifacts_follow_input_hash_without_reusing_checks(self):
        evidence = receipt(tree_hash="d" * 40, desktop_run_id="25")
        result = self.apply([evidence])
        self.assertEqual(result["desktop_run_id"], "25")
        self.assertEqual(result["reused"], [])
        self.assertEqual(self.apply([receipt(desktop_build_hash="0" * 64, desktop_run_id="25")])["desktop_run_id"], "")
        self.assertFalse(ci_plan.valid_receipt(receipt(desktop_run_id="not-a-run"), "ci", REPOSITORY))
        needs = {j: {"result": "success"} for j in result["jobs"]}
        needs["plan"] = {"result": "success"}
        promoted = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 30, 1, True)
        self.assertEqual(promoted["desktop_run_id"], "30")
        needs["orb-desktop-shell"] = {"result": "skipped"}
        result["jobs"].remove("orb-desktop-shell")
        inherited = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 30, 1, True)
        self.assertEqual(inherited["desktop_run_id"], "25")

    def test_corrupt_foreign_and_wrong_workflow_receipts_are_misses(self):
        for value in (None, [], {}, receipt(version=0), receipt(repository="fork/orb"),
                      receipt(workflow="kernel-abi"), receipt(jobs=[None]),
                      receipt(unaffected=[None]), receipt(unaffected={}), receipt(tree_hash=None)):
            with self.subTest(value=value):
                self.assertEqual(self.apply([value])["reused"], [])
                self.assertEqual(self.apply([value])["dist_run_id"], "")
        self.assertEqual(self.apply([receipt()], "kernel-abi")["reused"], [])
        self.assertEqual(self.apply([receipt("kernel-abi", jobs=["wf:kernel-abi"])],
                                    "kernel-abi")["reused"], ["wf:kernel-abi"])

    def test_receipt_records_real_successes_and_unaffected_jobs_separately(self):
        result = {**ci_plan.plan(["orb/src/Sidebar.tsx"], DOMAINS), **INPUTS}
        needs = {j: {"result": "success"} for j in result["jobs"]}
        needs.update({"plan": {"result": "success"}, "orb-build": {"result": "success"},
                      "test": {"result": "skipped"}})
        evidence = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 10, 1)
        self.assertEqual(evidence["jobs"], ["fmt", "orb-browser", "orb-unit"])
        self.assertIn("test", evidence["unaffected"])
        self.assertNotIn("orb-browser", evidence["unaffected"])
        self.assertEqual(evidence["dist_run_id"], "10")

    def test_skipped_required_job_or_failed_plan_cannot_be_certified(self):
        result = {**ci_plan.plan(["orb/src/Sidebar.tsx"], DOMAINS), **INPUTS}
        needs = {j: {"result": "success"} for j in [*result["jobs"], "plan"]}
        for failed in ("plan", "orb-browser"):
            with self.subTest(failed=failed), self.assertRaises(ValueError):
                ci_plan.verification_receipt(result, {**needs, failed: {"result": "skipped"}},
                                              "ci", REPOSITORY, 10, 1)

    def test_report_only_performance_failure_is_never_a_master_pass(self):
        result = {**ci_plan.plan(["orb/src/App.tsx"], DOMAINS), **INPUTS}
        needs = {j: {"result": "success"} for j in [*result["jobs"], "plan"]}
        for verified in (True, False):
            evidence = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 10, 1, verified)
            self.assertEqual("orb-performance" in evidence["jobs"], verified)
            self.assertNotIn("orb-performance", evidence["unaffected"])
            self.assertEqual("orb-performance" in self.apply([evidence])["jobs"], not verified)

    def test_kernel_workflow_cannot_be_certified_by_ci(self):
        result = {**ci_plan.plan(["lean/Orb/Kernel.lean"], DOMAINS), **INPUTS}
        evidence = ci_plan.verification_receipt(
            result, {"plan": {"result": "success"}, "kernel-abi": {"result": "success"}},
            "kernel-abi", REPOSITORY, 10, 1)
        self.assertEqual(evidence["jobs"], ["wf:kernel-abi"])
        self.assertEqual(evidence["dist_run_id"], "")
        self.assertIn("wf:kernel-abi", self.apply([evidence])["jobs"])

    def test_green_pr_tree_completes_master_without_repeating_covered_work(self):
        result = {**ci_plan.plan(["orb/src/Sidebar.tsx"], DOMAINS), **INPUTS}
        needs = {j: {"result": "success"} for j in result["jobs"]}
        needs.update({"plan": {"result": "success"}, "orb-build": {"result": "success"}})
        evidence = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 10, 1)
        master = self.apply([evidence])
        self.assertEqual(set(master["jobs"]) & ci_plan.workflow_jobs(DOMAINS, "ci"), {"fmt"})
        self.assertEqual(master["dist_run_id"], "10")
        kernel = ci_plan.verification_receipt(result, {"plan": {"result": "success"}},
                                               "kernel-abi", REPOSITORY, 11, 1)
        self.assertNotIn("wf:kernel-abi", self.apply([kernel], "kernel-abi")["jobs"])

    def test_reused_evidence_survives_master_cache_promotion(self):
        result = self.apply([receipt()])
        needs = {j: {"result": "success"} for j in result["jobs"] if not j.startswith("wf:")}
        needs["plan"] = {"result": "success"}
        evidence = ci_plan.verification_receipt(result, needs, "ci", REPOSITORY, 11, 1, True)
        self.assertTrue({"orb-unit", "orb-browser"} <= set(evidence["jobs"]))
        self.assertEqual(evidence["dist_run_id"], "10")


class ActionsApiTest(unittest.TestCase):
    def runs(self, payload=None, runs=None, artifacts=None, **kw):
        run = {"id": 10, "status": "completed", "conclusion": "success",
               "event": "pull_request", "run_attempt": 1, "head_sha": "not-the-merge-tree"}
        artifact = {"id": 20, "name": "ci-verification", "expired": False}
        responses = {
            "actions/workflows/ci.yml/runs?status=success&per_page=20": {"workflow_runs": [run] if runs is None else runs},
            "actions/runs/10/artifacts?per_page=100": {"artifacts": [artifact] if artifacts is None else artifacts},
            "actions/artifacts/20/zip": archive_receipt(receipt()) if payload is None else payload,
        }
        def get(path, binary=False):
            value = responses[path]
            if isinstance(value, Exception):
                raise value
            return value
        with mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "999"}):
            return ci_plan.green_receipts(REPOSITORY, "secret", "ci", get=get, **kw)

    def test_successful_pr_receipt_uses_actual_merge_tree_and_attempt(self):
        self.assertEqual(self.runs()[0]["tree_hash"], INPUTS["tree_hash"])
        self.assertEqual(self.runs(payload=archive_receipt(receipt(run_attempt=2))), [])
        self.assertEqual(self.runs(payload=archive_receipt(receipt(run_id="other"))), [])
        self.assertEqual(self.runs(payload=archive_receipt(receipt(repository="fork/orb"))), [])

    def test_failed_pending_cancelled_manual_and_current_runs_are_ignored(self):
        base = {"id": 10, "status": "completed", "conclusion": "success", "event": "push"}
        for changes in ({"status": "in_progress"}, {"conclusion": "failure"},
                        {"conclusion": "cancelled"}, {"event": "workflow_dispatch"}, {"id": 999}):
            self.assertEqual(self.runs(runs=[{**base, **changes}]), [])

    def test_absent_expired_oversized_and_bad_artifacts_are_misses(self):
        self.assertEqual(self.runs(artifacts=[]), [])
        self.assertEqual(self.runs(artifacts=[{"name": "ci-verification", "expired": True}]), [])
        self.assertEqual(self.runs(artifacts=[{"name": "unrelated"}]), [])
        for payload in (b"not a zip", archive_receipt(None),
                        archive_receipt(receipt(), "other.json"),
                        archive_receipt({"oversized": "x" * (1024 * 1024)}), OSError("API down")):
            self.assertEqual(self.runs(payload=payload), [])

    def test_api_lookup_is_bounded(self):
        with mock.patch.object(ci_plan.time, "monotonic", side_effect=[0, 26]):
            self.assertEqual(self.runs(), [])

    def test_default_client_uses_scoped_actions_api(self):
        with mock.patch.object(ci_plan, "github_get", return_value={"workflow_runs": []}) as get:
            self.assertEqual(ci_plan.green_receipts(REPOSITORY, "token", "kernel-abi"), [])
        self.assertIn("kernel-abi.yml", get.call_args.args[2])

    def test_http_request_limits_bytes_and_does_not_forward_token_on_redirect(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"ok":true}'
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(ci_plan.urllib.request, "build_opener", return_value=opener) as build:
            self.assertEqual(ci_plan.github_get(REPOSITORY, "secret", "actions/runs"), {"ok": True})
            req = opener.open.call_args.args[0]
            self.assertEqual(req.full_url, "https://api.github.com/repos/Th0rgal/orb/actions/runs")
            self.assertEqual(req.get_header("Authorization"), "Bearer secret")
            redirected = build.call_args.args[0].redirect_request(req, None, 302, "Found", {}, "https://blob.example.invalid/a")
            self.assertIsNone(redirected.get_header("Authorization"))
            self.assertEqual(ci_plan.github_get(REPOSITORY, "secret", "actions/runs", True), b'{"ok":true}')
            response.__enter__.return_value.read.return_value = b"x" * (1024 * 1024 + 1)
            with self.assertRaises(ValueError):
                ci_plan.github_get(REPOSITORY, "secret", "actions/runs")


class PlannerCliVerificationTest(unittest.TestCase):
    def invoke(self, *args, env=None):
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": ""}), \
             mock.patch.dict(os.environ, env or {}), \
             mock.patch.object(ci_plan, "tree_inputs", return_value=INPUTS), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            ci_plan.main(args)
            return json.loads(stdout.getvalue()) if stdout.getvalue() else None

    def test_cli_cache_receipt_and_api_reuse_with_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            cached, paths, output, summary = [Path(directory, n) for n in ("r.json", "p.txt", "o.txt", "s.md")]
            cached.write_text(json.dumps(receipt()))
            paths.write_text("orb/src/Sidebar.tsx\n")
            result = self.invoke("--paths-file", str(paths), "--event", "push", "--ref", "master",
                                 "--receipt", str(cached), "--github-output", str(output), "--summary", str(summary))
            self.assertEqual(result["reused"], ["orb-browser", "orb-unit"])
            self.assertIn(INPUTS["tree_hash"], output.read_text())
            self.assertIn("Previously passed", summary.read_text())
            cached.write_text("invalid JSON")
            with mock.patch.object(ci_plan, "green_receipts", return_value=[receipt()]) as api:
                result = self.invoke("--paths-file", str(paths), "--event", "push", "--ref", "main",
                                     "--receipt", str(cached), env={"GITHUB_TOKEN": "test"})
                self.assertEqual(result["reused"], ["orb-browser", "orb-unit"])
                api.assert_called_once()

    def test_cli_api_failure_missing_token_or_no_proof_runs_everything(self):
        with mock.patch.object(ci_plan, "green_receipts", side_effect=OSError("rate limited")), \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            result = self.invoke("--event", "push", "--ref", "master", env={"GITHUB_TOKEN": "test"})
            self.assertEqual(result["jobs"], ci_plan.all_jobs(DOMAINS))
            self.assertIn("unavailable", stderr.getvalue())
        with mock.patch.object(ci_plan, "green_receipts") as api:
            result = self.invoke("--event", "push", "--ref", "master", "--receipt", "/nonexistent/receipt")
            self.assertEqual(result["reused"], [])
            api.assert_not_called()

    def test_pr_schedule_dispatch_release_and_report_only_do_not_reuse(self):
        with mock.patch.object(ci_plan, "green_receipts") as api:
            for event, ref, extra in [("pull_request", "master", []), ("schedule", "master", []),
                                      ("workflow_dispatch", "main", []), ("push", "release/v1", []),
                                      ("push", "master", ["--report-only"])]:
                result = self.invoke("--event", event, "--ref", ref, *extra, env={"GITHUB_TOKEN": "test"})
                self.assertEqual(result["reused"], [])
            api.assert_not_called()

    def test_hash_only_and_receipt_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            out, evidence = Path(directory, "out"), Path(directory, "receipt.json")
            self.assertEqual(self.invoke("--hashes-only", "--github-output", str(out)), INPUTS)
            self.assertEqual(self.invoke("--hashes-only"), INPUTS)
            self.assertIn("tree_hash=", out.read_text())
            result = {**ci_plan.plan(["README.md"], DOMAINS), **INPUTS}
            needs = {"plan": {"result": "success"}, "fmt": {"result": "success"}}
            self.invoke("--write-receipt", str(evidence), env={"CI_PLAN": json.dumps(result),
                        "CI_NEEDS": json.dumps(needs), "GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1"})
            self.assertTrue(ci_plan.valid_receipt(json.loads(evidence.read_text()), "ci", REPOSITORY))

class PlannerCoverageTest(unittest.TestCase):
    def test_invalid_domain_requires_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "domains.toml")
            path.write_text('[[domain]]\nname="broken"\npaths=["*"]\n')
            with self.assertRaisesRegex(ValueError, "needs `jobs`"):
                ci_plan.load_domains(path)

    def test_diff_success_and_failure_are_conservative(self):
        with mock.patch.object(ci_plan.subprocess, "check_output", side_effect=["base\n", "a\0b\0"]):
            self.assertEqual(ci_plan.changed_paths("base", "head"), ["a", "b"])
        with mock.patch.object(ci_plan.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertIsNone(ci_plan.changed_paths("bad", "head"))

    def test_all_summary_modes_include_the_evidence_and_unknown_paths(self):
        result = ci_plan.plan(["README.md"], DOMAINS)
        self.assertIn("1 changed path", ci_plan.summary_markdown(result, False))
        result = {**ci_plan.plan(["unknown.bin"], DOMAINS), **INPUTS,
                  "unaffected": ["docker"], "reused": ["orb-unit"]}
        text = ci_plan.summary_markdown(result, True)
        self.assertIn("report only", text)
        self.assertIn("Previously certified unrelated", text)
        self.assertIn("unknown.bin", text)

    def test_cli_successful_diff_and_missing_repository_do_not_query_api(self):
        with mock.patch.object(ci_plan, "changed_paths", return_value=[]), \
             mock.patch.object(ci_plan, "green_receipts") as api, \
             mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "", "GITHUB_TOKEN": "token"}), \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            ci_plan.main(["--event", "push", "--ref", "master"])
            api.assert_not_called()

    def test_schema_rejects_malformed_hashes_and_run_identifiers(self):
        for changes in ({"tree_hash": "x" * 40}, {"orb_build_hash": "short"},
                        {"run_id": "abc"}, {"run_attempt": 0}, {"run_attempt": None},
                        {"dist_run_id": "not-a-run"}):
            self.assertFalse(ci_plan.valid_receipt(receipt(**changes), "ci", REPOSITORY))

    def test_script_entry_point(self):
        with mock.patch.object(sys, "argv", ["ci_plan.py", "--hashes-only"]), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            runpy.run_path(str(ROOT / "scripts/ci_plan.py"), run_name="__main__")
        self.assertIn("tree_hash", json.loads(output.getvalue()))

    def test_workflow_graph_preserves_browser_coverage_and_build_once(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        browser = workflow.split("  orb-browser:\n", 1)[1].split("  orb-performance:\n", 1)[0]
        build = workflow.split("  orb-build:\n", 1)[1].split("  orb-unit:\n", 1)[0]
        self.assertEqual(workflow.count("run: pnpm build"), 1)
        self.assertIn("run: pnpm build", build)
        self.assertIn("needs: [plan, orb-build]", browser)
        self.assertIn("if: matrix.shard == 1", browser)
        self.assertIn("if: matrix.shard == 2", browser)
        self.assertEqual(browser.count("playwright.kernel.config.ts"), 2)
        self.assertNotIn("install --with-deps", browser)
        self.assertNotIn("ci_harden_ubuntu_apt", browser)
        pinned = json.loads((ROOT / "orb/package.json").read_text())["devDependencies"]["@playwright/test"]
        self.assertIn(f"mcr.microsoft.com/playwright:v{pinned}-noble", browser)
        self.assertIn("include-hidden-files: true", build)


if __name__ == "__main__":
    unittest.main()
