"""Exercise real decisions/arguments without a network, systemd or deployments."""
import importlib.machinery
import importlib.util
import hashlib
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

    def test_missing_node_binary_fails_before_install_or_systemctl(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            result = self._run_staged_deploy(Path(temp), include_node_binary=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required built binary missing or empty", result.stdout)
            self.assertNotIn("+ install ", result.stderr)
            self.assertNotIn("+ systemctl ", result.stderr)

    def test_empty_node_binary_fails_before_install_or_systemctl(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            result = self._run_staged_deploy(Path(temp), node_binary_content="")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required built binary missing or empty", result.stdout)
            self.assertNotIn("+ install ", result.stderr)
            self.assertNotIn("+ systemctl ", result.stderr)

    def test_plain_deploy_installs_node_and_logs_full_matching_hash(self):
        import re
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            content = "node-build-for-r25\n"
            self._seed_existing_targets(root)
            result = self._run_staged_deploy(root, node_binary_content=content)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            expected_hash = hashlib.sha256(content.encode()).hexdigest()
            self.assertEqual((root / "usr/local/lib/orb/guest/sandboxed-node").read_text(), content)
            match = re.search(r"sandboxed-node guest sha256 served=([0-9a-f]+) built=([0-9a-f]+) commit=", result.stdout)
            self.assertIsNotNone(match, result.stdout)
            self.assertEqual(match.groups(), (expected_hash, expected_hash))

    def test_plain_deploy_does_not_change_fleet_node_binary(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._seed_existing_targets(root)
            old = (root / "usr/local/bin/sandboxed-node").read_text()
            result = self._run_staged_deploy(root, dev_only=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "usr/local/bin/sandboxed-node").read_text(), old)

    def test_dev_only_does_not_change_guest_node_binary(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._seed_existing_targets(root)
            guest = root / "usr/local/lib/orb/guest/sandboxed-node"
            guest.parent.mkdir(parents=True, exist_ok=True)
            guest.write_text("old-guest\n")
            result = self._run_staged_deploy(root, dev_only=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(guest.read_text(), "old-guest\n")

    def test_prod_unhealthy_restores_previous_guest_node_binary(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._seed_existing_targets(root)
            guest = root / "usr/local/lib/orb/guest/sandboxed-node"
            guest.parent.mkdir(parents=True, exist_ok=True)
            guest.write_text("old-guest\n")
            result = self._run_staged_deploy(root, prod_ok=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(guest.read_text(), "old-guest\n")

    def _run_staged_deploy(
        self,
        root: Path,
        dev_ok: bool = True,
        prod_ok: bool = True,
        dev_only: bool = False,
        rollout_nodes: bool = False,
        fail_command: str = "",
        script_text=None,
        rollout_program=None,
        node_binary_content="new-sandboxed-node\n",
        include_node_binary=True,
    ):
        import os
        script = script_text or (Path(__file__).parent / "ops/orb-deploy").read_text()
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
        (root / "usr/local/bin").mkdir(parents=True, exist_ok=True)
        (root / "usr/local/lib/orb/guest").mkdir(parents=True, exist_ok=True)
        (tree / "catalog/providers.json").write_text("{}\n")
        (tree / "scripts/rolling_upgrade_nodes.py").write_text(
            rollout_program or "import sys, json\nprint(json.dumps({'rollout_argv': sys.argv[1:]}))\n"
        )
        for rel, content in {
            "lean/OrbCore/.lake/build/bin/orb-core": "new-orb-core\n",
            "lean/OrbCore/.lake/build/bin/orb-core-test": "#!/bin/sh\necho ok\n",
            "lean/OrbNode/.lake/build/bin/sandboxed-node": node_binary_content,
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
            if rel.endswith("/sandboxed-node") and not include_node_binary:
                continue
            target = tree / rel
            target.write_text(content)
            if "test" in rel:
                target.chmod(0o755)

        bin_dir = root / "fake-bin"
        bin_dir.mkdir(exist_ok=True)
        (root / "run/lock").mkdir(parents=True, exist_ok=True)
        lake_log = root / "lake-invocations.log"
        dev_health = f'{{"status":"ok","build":"{SHA}"}}' if dev_ok else '{"status":"failed"}'
        prod_health = f'{{"status":"ok","build":"{SHA}"}}' if prod_ok else '{"status":"failed"}'
        stubs = {
            "pgrep": "#!/bin/sh\nexit 1\n",
            "git": f'#!/bin/sh\nif [ "$1" = "rev-parse" ]; then echo "{SHA}"; fi\nexit 0\n',
            "lake": f'#!/bin/sh\necho "$PWD:$*" >> "{lake_log}"\necho built\n',
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

        # Fail once, then allow rollback commands to run. Record the binary
        # selected by each service restart, rather than just its invocation.
        systemctl = bin_dir / "systemctl"
        systemctl.write_text(
            '#!/bin/bash\n'
            f'root={str(root)!r}\n'
            'if [[ "$*" == "restart sandboxed-sh-dev" ]]; then bin=orb-core-dev; '
            'elif [[ "$*" == "restart sandboxed-sh-prod" ]]; then bin=orb-core; else exit 0; fi\n'
            'if [[ "$*" == "$FAIL_COMMAND" && ! -f "$root/failed" ]]; then '
            'touch "$root/failed"; echo stopped > "$root/$bin.running"; exit 42; fi\n'
            'cp "$root/usr/local/bin/$bin" "$root/$bin.running"\n'
        )
        systemctl.chmod(0o755)

        env = {
            **os.environ,
            "ORB_DEPLOY_TREE": str(tree),
            "ORB_DEPLOY_LOG": str(root / "deploy.log"),
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "FAIL_COMMAND": fail_command,
        }
        if dev_only:
            args = [SHA, "--dev-only"]
        elif rollout_nodes:
            args = [SHA, "--rollout-nodes"]
        else:
            args = [SHA]
        return subprocess.run(["bash", "-x", str(fake_script), *args], env=env, capture_output=True, text=True)

    def test_rollout_inherits_real_lock_without_self_contention(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._seed_existing_targets(root)
            module = str(Path(__file__).parent.resolve())
            program = f'''import os, sys
sys.path.insert(0, {module!r})
import rolling_upgrade_nodes as r
from unittest.mock import patch
class Api:
    def list_nodes(self): return []
class Ops:
    def recover_remote(self, node): return {{'healthy': False}}
with patch.object(r, 'discover_local_core_auth', return_value=('http://fake', 'fake')), patch.object(r, 'HttpCoreApi', return_value=Api()), patch.object(r, 'SshNodeOps', return_value=Ops()):
    sys.exit(r.main(['--recover-node', 'fake', '--lock-file', {str(root / 'run/lock/orb-deploy.lock')!r}]))
'''
            result = self._run_staged_deploy(root, rollout_nodes=True, rollout_program=program)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_plain_deploy_executed_commands_match_master(self):
        import tempfile
        import re
        baseline = subprocess.run(["git", "show", "HEAD^:scripts/ops/orb-deploy"], capture_output=True, text=True)
        if baseline.returncode:
            self.skipTest("parity requires origin/master; run in a full checkout")
        master = baseline.stdout
        traces = []
        for version in (master, None):
            with tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self._seed_existing_targets(root)
                result = self._run_staged_deploy(root, script_text=version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                # Only actual external commands; shell flag parsing and tests
                # differ because the PR adds opt-in modes.
                commands = []
                for line in result.stderr.splitlines():
                    line = re.sub(r'^\++ ', '', line).replace(temp, '<ROOT>')
                    if re.match(r'^(git |lake |install |cp |mv |rm |systemctl |curl |python3 |flock |mkdir |ls |tail |xargs |sha256sum )', line):
                        commands.append(line)
                traces.append(commands)
        baseline_trace, current_trace = traces
        self.assertEqual(
            [line.replace("/bin/orb-node", "/bin/sandboxed-node") for line in baseline_trace
             if "required built binary" not in line],
            [line for line in current_trace
             if "required built binary" not in line and "sandboxed-node sha256" not in line],
        )

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

    def test_rollout_failure_restores_selected_release_and_running_services(self):
        import tempfile
        for failure in ("restart sandboxed-sh-dev", "restart sandboxed-sh-prod"):
            for directory_pointer in (False, True):
                with self.subTest(failure=failure, directory=directory_pointer), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    targets = self._seed_existing_targets(root)
                    (root / "usr/local/bin/orb-core-dev").write_text("old-dev\n")
                    base = root / f"usr/local/share/orb/releases/{SHA}"
                    old = base / ("bin" if directory_pointer else "bin.old")
                    old.mkdir(parents=True)
                    (old / "sandboxed-node").write_text("old-release\n")
                    if not directory_pointer:
                        (base / "bin").symlink_to("bin.old")
                    result = self._run_staged_deploy(root, rollout_nodes=True, fail_command=failure)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((base / "bin/sandboxed-node").read_text(), "old-release\n")
                    self.assertEqual((root / "orb-core-dev.running").read_text(), "old-dev\n")
                    if failure.endswith("prod"):
                        self.assertEqual((root / "orb-core.running").read_text(), "old-orb-core\n")
                    for rel, (content, _) in targets.items():
                        self.assertEqual((root / rel).read_text(), content, rel)

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
                "usr/local/lib/orb/guest/sandboxed-node": ("new-sandboxed-node\n", None, 0o755),
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
                if old_text is not None:
                    self.assertTrue(backup.is_file(), f"missing backup {backup}")
                    self.assertEqual(backup.read_text(), old_text)
                else:
                    self.assertFalse(backup.exists(), f"unexpected backup {backup}")
                backups = list(staged.parent.glob(f"{staged.name}.pre-deploy-*"))
                expected_backup_count = 5 if old_text is not None else 0
                self.assertEqual(len(backups), expected_backup_count,
                                 f"expected {expected_backup_count} pruned backups for {rel}, got {backups}")

    def test_plain_deploy_does_not_build_or_stage_node_rollout_artifacts_while_rollout_nodes_does(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._seed_existing_targets(root)
            res = self._run_staged_deploy(root, dev_ok=True, prod_ok=True, rollout_nodes=False)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            lake_invocations = (root / "lake-invocations.log").read_text()
            self.assertNotIn("OrbBin", lake_invocations)
            self.assertEqual((root / "usr/local/bin/sandboxed-mcp").read_text(), "old-sandboxed-mcp\n")
            self.assertEqual((root / "usr/local/sbin/orb-privd").read_text(), "old-orb-privd\n")
            rel_bin = root / f"usr/local/share/orb/releases/{SHA}/bin"
            self.assertFalse(rel_bin.exists())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._seed_existing_targets(root)
            res = self._run_staged_deploy(root, dev_ok=True, prod_ok=True, rollout_nodes=True)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            lake_invocations = (root / "lake-invocations.log").read_text()
            self.assertIn("OrbBin", lake_invocations)
            self.assertEqual((root / "usr/local/bin/sandboxed-mcp").read_text(), "new-sandboxed-mcp\n")
            self.assertEqual((root / "usr/local/sbin/orb-privd").read_text(), "new-orb-privd\n")
            rel_bin = root / f"usr/local/share/orb/releases/{SHA}/bin"
            self.assertEqual((rel_bin / "sandboxed-node").read_text(), "new-sandboxed-node\n")
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

    def test_deploy_mid_install_failure_rolls_back_via_exit_trap_and_stages_release_dir_atomically(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = self._seed_existing_targets(root)
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
                "lean/OrbNode/.lake/build/bin/sandboxed-node": "new-sandboxed-node\n",
                "lean/OrbNode/.lake/build/bin/orb-node-test": "#!/bin/sh\necho ok\n",
                "lean/OrbBin/.lake/build/bin/sandboxed-mcp": "new-sandboxed-mcp\n",
                "lean/OrbBin/.lake/build/bin/orb-privd": "new-orb-privd\n",
                "scripts/orb-node-provision.sh": "new-provision\n",
                "scripts/ops/orb-monitor": "new-orb-monitor\n",
                # Omit orb-sidecar-guard source so `install` fails mid-way after
                # orb-node-provision.sh, sandboxed-node, sandboxed-mcp, orb-privd, and orb-monitor
                # have already been replaced.
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
            stubs = {
                "pgrep": "#!/bin/sh\nexit 1\n",
                "git": f'#!/bin/sh\nif [ "$1" = "rev-parse" ]; then echo "{SHA}"; fi\nexit 0\n',
                "lake": "#!/bin/sh\necho built\n",
                "systemctl": "#!/bin/sh\nexit 0\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "date": '#!/bin/sh\necho "20261115T120000Z"\n',
                "curl": f'#!/bin/sh\nprintf "%s" \'{{"status":"ok","build":"{SHA}"}}\'\n',
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
            res = subprocess.run(
                ["bash", str(fake_script), SHA, "--rollout-nodes"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            for rel, (old_text, _) in targets.items():
                if rel == "usr/local/bin/orb-core":
                    continue
                self.assertEqual((root / rel).read_text(), old_text, f"{rel} was left partially updated after mid-install failure")
            self.assertEqual((root / "usr/local/bin/orb-core").read_text(), "old-orb-core\n")

    def test_release_bin_dir_survives_kill_between_staging_and_switch(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._seed_existing_targets(root)
            rel_base = root / f"usr/local/share/orb/releases/{SHA}"
            prev_target = rel_base / "bin.20261114T000000Z-1"
            prev_target.mkdir(parents=True, exist_ok=True)
            for name in ("sandboxed-node", "sandboxed-mcp", "orb-privd"):
                (prev_target / name).write_text(f"prev-{name}\n")
            rel_bin = rel_base / "bin"
            rel_bin.symlink_to("bin.20261114T000000Z-1")

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
                "lean/OrbNode/.lake/build/bin/sandboxed-node": "new-sandboxed-node\n",
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
            # Simulate process death right before `ln -sfn` / `mv -T` switches the release pointer
            stubs = {
                "pgrep": "#!/bin/sh\nexit 1\n",
                "git": f'#!/bin/sh\nif [ "$1" = "rev-parse" ]; then echo "{SHA}"; fi\nexit 0\n',
                "lake": "#!/bin/sh\necho built\n",
                "systemctl": "#!/bin/sh\nexit 0\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "date": '#!/bin/sh\necho "20261115T120000Z"\n',
                "ln": '#!/bin/sh\nkill -9 $PPID\nexit 1\n',
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
            res = subprocess.run(
                ["bash", str(fake_script), SHA, "--rollout-nodes"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertTrue(rel_bin.is_dir())
            self.assertEqual((rel_bin / "sandboxed-node").read_text(), "prev-sandboxed-node\n")
            self.assertEqual((rel_bin / "sandboxed-mcp").read_text(), "prev-sandboxed-mcp\n")
            self.assertEqual((rel_bin / "orb-privd").read_text(), "prev-orb-privd\n")

    def test_plain_deploy_exact_master_parity_on_stale_catalog_new(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = self._seed_existing_targets(root)
            # Pre-seed a non-empty stale $CATALOG.new directory: on master, `cp -a $TREE/catalog $CATALOG.new`
            # copies into the existing directory, causing `mv $CATALOG.new $CATALOG` or subsequent behavior
            # to match master's exact plain path (never running `rm -rf $CATALOG.new` or installing the
            # rollout EXIT trap when `ROLLOUT_NODES == 0`).
            stale_cat_new = root / f"usr/local/share/orb/releases/{SHA}/catalog.new/catalog"
            stale_cat_new.mkdir(parents=True, exist_ok=True)
            (stale_cat_new / "marker").write_text("busy\n")

            script = (Path(__file__).parent / "ops/orb-deploy").read_text()
            for prefix in ("/usr/local", "/etc/systemd", "/run/lock"):
                script = script.replace(prefix, str(root) + prefix)
            fake_script = root / "orb-deploy-test"
            fake_script.write_text(script)
            fake_script.chmod(0o755)

            tree = root / "tree"
            (tree / "lean/OrbCore/.lake/build/bin").mkdir(parents=True, exist_ok=True)
            (tree / "lean/OrbNode/.lake/build/bin").mkdir(parents=True, exist_ok=True)
            (tree / "catalog/snapshots").mkdir(parents=True, exist_ok=True)
            (tree / "scripts/ops").mkdir(parents=True, exist_ok=True)
            (tree / "catalog/providers.json").write_text("{}\n")
            for rel, content in {
                "lean/OrbCore/.lake/build/bin/orb-core": "new-orb-core\n",
                "lean/OrbCore/.lake/build/bin/orb-core-test": "#!/bin/sh\necho ok\n",
                "lean/OrbNode/.lake/build/bin/sandboxed-node": "new-sandboxed-node\n",
                "lean/OrbNode/.lake/build/bin/orb-node-test": "#!/bin/sh\necho ok\n",
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
            stubs = {
                "pgrep": "#!/bin/sh\nexit 1\n",
                "git": f'#!/bin/sh\nif [ "$1" = "rev-parse" ]; then echo "{SHA}"; fi\nexit 0\n',
                "lake": "#!/bin/sh\necho built\n",
                "systemctl": '#!/bin/sh\nif [ "$1" = "restart" ] && [ "$2" = "sandboxed-sh-dev" ]; then exit 1; fi\nexit 0\n',
                "sleep": "#!/bin/sh\nexit 0\n",
                "date": '#!/bin/sh\necho "20261115T120000Z"\n',
                "curl": f'#!/bin/sh\nprintf "%s" \'{{"status":"ok","build":"{SHA}"}}\'\n',
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
            res = subprocess.run(
                ["bash", str(fake_script), SHA],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            # Stale $CATALOG.new was NOT rm -rf'd before cp -a on the plain path:
            self.assertTrue((root / f"usr/local/share/orb/releases/{SHA}/catalog/catalog/marker").is_file())
            # No EXIT trap ran on the plain path (exact master parity):
            self.assertEqual((root / "usr/local/lib/orb/orb-node-provision.sh").read_text(), "new-provision\n")
            self.assertEqual((root / "usr/local/bin/sandboxed-mcp").read_text(), targets["usr/local/bin/sandboxed-mcp"][0])
            self.assertEqual((root / "usr/local/sbin/orb-privd").read_text(), targets["usr/local/sbin/orb-privd"][0])
            self.assertFalse((root / f"usr/local/share/orb/releases/{SHA}/bin").exists())


if __name__ == "__main__":
    unittest.main()
