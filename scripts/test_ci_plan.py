"""Replays real change shapes through scripts/ci_plan.py (stdlib unittest)."""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_plan  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DOMAINS = ci_plan.load_domains()


def jobs(paths, **kw):
    return set(ci_plan.plan(paths, DOMAINS, **kw)["jobs"])


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
        known = set(ci_plan.all_jobs(DOMAINS)) | {"plan", "ci-ok"}
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


if __name__ == "__main__":
    unittest.main()
