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


if __name__ == "__main__":
    unittest.main()
