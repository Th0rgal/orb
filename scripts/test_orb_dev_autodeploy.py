"""Exercise real decisions/arguments without a network, systemd or deployments."""
import importlib.machinery
import importlib.util
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("orb_dev_autodeploy", str(Path(__file__).parent / "ops/orb-dev-autodeploy"))
spec = importlib.util.spec_from_loader(loader.name, loader)
auto = importlib.util.module_from_spec(spec)
loader.exec_module(auto)
SHA = "a" * 40


class AutoDeployTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(patch.stopall)
        self.active = patch.object(auto.subprocess, "run", return_value=subprocess.CompletedProcess([], 3)).start()
        self.cmd = patch.object(auto, "command", side_effect=["https://github.com/Th0rgal/orb.git", "", SHA, ""]).start()
        self.health = patch.object(auto, "dev_build", return_value="b" * 40).start()

    def test_only_master_exact_commit_and_dev_only_reach_deployer(self):
        self.assertIn(SHA, auto.tick())
        self.assertEqual(self.cmd.call_args_list[-1].args, (auto.DEPLOY, "--detach", SHA, "--dev-only"))
        self.assertEqual(self.cmd.call_args_list[1].args, ("git", "fetch", "--quiet", "origin", "+refs/heads/master:refs/remotes/origin/master"))
        self.assertEqual(self.cmd.call_args_list[2].args, ("git", "rev-parse", "--verify", "refs/remotes/origin/master^{commit}"))

    def test_current_full_or_legacy_short_build_does_not_deploy(self):
        for live in [SHA, SHA[:9]]:
            with self.subTest(live=live):
                self.cmd.reset_mock(side_effect=True)
                self.cmd.side_effect = ["https://github.com/Th0rgal/orb.git", "", SHA]
                self.health.return_value = live
                self.assertEqual(auto.tick(), "dev is current")
                self.assertEqual(self.cmd.call_count, 3)

    def test_pending_manual_or_automatic_deploy_does_not_touch_build_tree(self):
        self.active.return_value.returncode = 0
        self.assertEqual(auto.tick(), "deployment already running")
        self.cmd.assert_not_called()
        self.health.assert_not_called()

    def test_unhealthy_dev_is_retried(self):
        self.health.return_value = ""
        self.assertIn("submitted", auto.tick())
        self.assertEqual(self.cmd.call_args_list[-1].args[-1], "--dev-only")

    def test_wrong_repository_malformed_sha_or_failed_fetch_never_deploy(self):
        for outputs in [["https://example.invalid/repo"],
                        ["https://github.com/Th0rgal/orb.git", "", "master; id"],
                        ["https://github.com/Th0rgal/orb.git", subprocess.CalledProcessError(1, ["git"])]]:
            with self.subTest(outputs=outputs):
                self.cmd.reset_mock(side_effect=True)
                self.cmd.side_effect = outputs
                with self.assertRaises((RuntimeError, subprocess.SubprocessError)):
                    auto.tick()
                self.assertFalse(any(call.args[0] == auto.DEPLOY for call in self.cmd.call_args_list))


class DeployGateTests(unittest.TestCase):
    def test_malformed_or_extra_arguments_fail_before_detach_or_host_effects(self):
        script = Path(__file__).parent / "ops/orb-deploy"
        for args in [[], ["--help"], ["master", "--prod"], [SHA, "--dev-only", "--prod"],
                     ["--detach", SHA, "--dev-only", "--prod"], ["master; id"]]:
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 64)
                self.assertIn("usage:", result.stderr)

    def test_health_gate_requires_exact_build_not_only_healthy_status(self):
        import os
        import tempfile
        script = (Path(__file__).parent / "ops/orb-deploy").read_text()
        function = script[script.index("healthy() {"):script.index("\nset_build()")]
        # Exercise the actual shell health gate, with a fake curl and no delay.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {"curl": '#!/bin/sh\nprintf "%s" "$SYNTHETIC_HEALTH"\n',
                               "sleep": "#!/bin/sh\nexit 0\n"}.items():
                path = root / name
                path.write_text(body)
                path.chmod(0o755)
            env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]}
            for health, expected in [('{"status":"ok","build":"' + SHA + '"}', 0),
                                     ('{"status":"ok","build":"old"}', 1),
                                     ('{"status":"ok"}', 1), ('not json', 1),
                                     ('{"status":"failed","build":"' + SHA + '"}', 1)]:
                with self.subTest(health=health):
                    result = subprocess.run(["bash", "-c", function + '\nhealthy 3002 1 "$1"', "test", SHA],
                                            env={**env, "SYNTHETIC_HEALTH": health}, capture_output=True)
                    self.assertEqual(result.returncode, expected)

    def _run_staged_deploy(self, root: Path, dev_ok: bool = True, prod_ok: bool = True, dev_only: bool = False):
        import os
        script = (Path(__file__).parent / "ops/orb-deploy").read_text()
        for prefix in ("/usr/local", "/etc/systemd", "/run/lock"):
            script = script.replace(prefix, str(root) + prefix)
        fake_script = root / "orb-deploy-test"
        fake_script.write_text(script)
        fake_script.chmod(0o755)

        tree = root / "tree"
        (tree / "lean/OrbCore/.lake/build/bin").mkdir(parents=True, exist_ok=True)
        (tree / "lean/OrbNode/.lake/build/bin").mkdir(parents=True, exist_ok=True)
        (tree / "lean/OrbBin/.lake/build/bin").mkdir(parents=True, exist_ok=True)
        (tree / "catalog/snapshots").mkdir(parents=True, exist_ok=True)
        (tree / "scripts/ops").mkdir(parents=True, exist_ok=True)
        (tree / "catalog/providers.json").write_text("{}\n")
        for rel, content in {
            "lean/OrbCore/.lake/build/bin/orb-core": "new-orb-core\n",
            "lean/OrbCore/.lake/build/bin/orb-core-test": "#!/bin/sh\necho ok\n",
            "lean/OrbNode/.lake/build/bin/orb-node": "new-orb-node\n",
            "lean/OrbNode/.lake/build/bin/orb-node-test": "#!/bin/sh\necho ok\n",
            "lean/OrbBin/.lake/build/bin/sandboxed-mcp": "new-sandboxed-mcp\n",
            "lean/OrbBin/.lake/build/bin/orb-privd": "new-orb-privd\n",
            "scripts/orb-node-provision.sh": "new-provision\n",
            "scripts/ops/orb-monitor": "new-orb-monitor\n",
            "scripts/ops/orb-sidecar-guard": "new-orb-sidecar-guard\n",
            "scripts/ops/orb-dev-autodeploy": "new-orb-dev-autodeploy\n",
            "scripts/ops/orb-env": "new-orb-env\n",
            "scripts/ops/env-migration.json": '{"new": true}\n',
        }.items():
            target = tree / rel
            target.write_text(content)
            if "test" in rel:
                target.chmod(0o755)

        bin_dir = root / "fake-bin"
        bin_dir.mkdir(exist_ok=True)
        (root / "run/lock").mkdir(parents=True, exist_ok=True)
        dev_health = f'{{"status":"ok","build":"{SHA}"}}' if dev_ok else '{"status":"failed"}'
        prod_health = f'{{"status":"ok","build":"{SHA}"}}' if prod_ok else '{"status":"failed"}'
        stubs = {
            "pgrep": "#!/bin/sh\nexit 1\n",
            "git": f'#!/bin/sh\nif [ "$1" = "rev-parse" ]; then echo "{SHA}"; fi\nexit 0\n',
            "lake": "#!/bin/sh\necho built\n",
            "systemctl": "#!/bin/sh\nexit 0\n",
            "sleep": "#!/bin/sh\nexit 0\n",
            "date": '#!/bin/sh\necho "20261115T120000Z"\n',
            "curl": (
                "#!/bin/sh\n"
                'case "$*" in\n'
                f'  *127.0.0.1:3002*) printf "%s" \'{dev_health}\' ;;\n'
                f'  *127.0.0.1:3000*) printf "%s" \'{prod_health}\' ;;\n'
                "  *) exit 1 ;;\n"
                "esac\n"
            ),
        }
        for name, body in stubs.items():
            p = bin_dir / name
            p.write_text(body)
            p.chmod(0o755)

        env = {
            **os.environ,
            "ORB_DEPLOY_TREE": str(tree),
            "ORB_DEPLOY_LOG": str(root / "deploy.log"),
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        }
        args = [SHA, "--dev-only"] if dev_only else [SHA]
        return subprocess.run(["bash", str(fake_script), *args], env=env, capture_output=True, text=True)

    def _seed_existing_targets(self, root: Path):
        targets = {
            "usr/local/bin/orb-core": ("old-orb-core\n", 0o755),
            "usr/local/bin/sandboxed-node": ("old-orb-node\n", 0o755),
            "usr/local/bin/sandboxed-mcp": ("old-sandboxed-mcp\n", 0o755),
            "usr/local/sbin/orb-privd": ("old-orb-privd\n", 0o755),
            "usr/local/lib/orb/orb-node-provision.sh": ("old-provision\n", 0o644),
            "usr/local/sbin/orb-monitor": ("old-orb-monitor\n", 0o755),
            "usr/local/sbin/orb-sidecar-guard": ("old-orb-sidecar-guard\n", 0o755),
            "usr/local/sbin/orb-dev-autodeploy": ("old-orb-dev-autodeploy\n", 0o755),
            "usr/local/libexec/orb-env": ("old-orb-env\n", 0o755),
            "usr/local/libexec/env-migration.json": ('{"old": true}\n', 0o644),
        }
        for rel, (content, mode) in targets.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
            p.chmod(mode)
        return targets

    def test_deploy_stages_ops_scripts_with_modes_backups_and_pruning(self):
        import os
        import stat
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = self._seed_existing_targets(root)
            for rel in targets:
                p = root / rel
                for idx in range(6):
                    b = Path(f"{p}.pre-deploy-20261110T00000{idx}Z")
                    b.write_text(f"old-{idx}\n")
                    ts = 1_700_000_000 + idx * 60
                    os.utime(b, (ts, ts))

            res = self._run_staged_deploy(root, dev_ok=True, prod_ok=True)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

            expected = {
                "usr/local/bin/sandboxed-node": ("new-orb-node\n", "old-orb-node\n", 0o755),
                "usr/local/bin/sandboxed-mcp": ("new-sandboxed-mcp\n", "old-sandboxed-mcp\n", 0o755),
                "usr/local/sbin/orb-privd": ("new-orb-privd\n", "old-orb-privd\n", 0o755),
                "usr/local/sbin/orb-monitor": ("new-orb-monitor\n", "old-orb-monitor\n", 0o755),
                "usr/local/sbin/orb-sidecar-guard": ("new-orb-sidecar-guard\n", "old-orb-sidecar-guard\n", 0o755),
                "usr/local/sbin/orb-dev-autodeploy": ("new-orb-dev-autodeploy\n", "old-orb-dev-autodeploy\n", 0o755),
                "usr/local/libexec/orb-env": ("new-orb-env\n", "old-orb-env\n", 0o755),
                "usr/local/libexec/env-migration.json": ('{"new": true}\n', '{"old": true}\n', 0o644),
            }
            for rel, (new_text, old_text, mode) in expected.items():
                staged = root / rel
                self.assertEqual(staged.read_text(), new_text)
                self.assertEqual(stat.S_IMODE(staged.stat().st_mode), mode)
                backup = Path(f"{staged}.pre-deploy-20261115T120000Z")
                self.assertTrue(backup.is_file(), f"missing backup {backup}")
                self.assertEqual(backup.read_text(), old_text)
                backups = list(staged.parent.glob(f"{staged.name}.pre-deploy-*"))
                self.assertEqual(len(backups), 5, f"expected 5 pruned backups for {rel}, got {backups}")
            rel_bin = root / f"usr/local/share/orb/releases/{SHA}/bin"
            self.assertEqual((rel_bin / "sandboxed-node").read_text(), "new-orb-node\n")
            self.assertEqual((rel_bin / "sandboxed-mcp").read_text(), "new-sandboxed-mcp\n")
            self.assertEqual((rel_bin / "orb-privd").read_text(), "new-orb-privd\n")

    def test_deploy_nodes_status_and_dry_run_invoke_rolling_upgrade_controller(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = (Path(__file__).parent / "ops/orb-deploy").read_text()
            for prefix in ("/usr/local", "/etc/systemd", "/run/lock"):
                script = script.replace(prefix, str(root) + prefix)
            fake_script = root / "orb-deploy-test"
            fake_script.write_text(script)
            fake_script.chmod(0o755)

            tree = root / "tree"
            (tree / "scripts").mkdir(parents=True, exist_ok=True)
            (tree / "scripts/rolling_upgrade_nodes.py").write_text(
                "import sys, json\nprint(json.dumps({'argv': sys.argv[1:]}))\n"
            )
            rel_bin = root / f"usr/local/share/orb/releases/{SHA}/bin"
            rel_bin.mkdir(parents=True, exist_ok=True)
            for name in ("sandboxed-node", "sandboxed-mcp", "orb-privd"):
                (rel_bin / name).write_text(f"bin-{name}\n")

            env = {
                **os.environ,
                "ORB_DEPLOY_TREE": str(tree),
                "ORB_DEPLOY_LOG": str(root / "deploy.log"),
            }
            for flag, expected_mode in [("--nodes-status", "--status"), ("--nodes-dry-run", "--dry-run")]:
                res = subprocess.run(
                    ["bash", str(fake_script), SHA, flag],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                import json
                payload = json.loads(res.stdout.strip())
                self.assertIn(expected_mode, payload["argv"])
                self.assertIn("--expected-build-sha", payload["argv"])
                self.assertIn(SHA, payload["argv"])
                self.assertIn("--stage-from-dir", payload["argv"])
                self.assertIn(str(rel_bin), payload["argv"])

    def test_deploy_rolls_back_staged_ops_scripts_on_dev_or_prod_health_failure(self):
        import tempfile
        for dev_ok, prod_ok in [(False, True), (True, False)]:
            with self.subTest(dev_ok=dev_ok, prod_ok=prod_ok), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                targets = self._seed_existing_targets(root)
                res = self._run_staged_deploy(root, dev_ok=dev_ok, prod_ok=prod_ok)
                self.assertEqual(res.returncode, 1)
                for rel, (old_text, _) in targets.items():
                    self.assertEqual((root / rel).read_text(), old_text, f"{rel} was not rolled back")


if __name__ == "__main__":
    unittest.main()
