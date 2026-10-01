import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("identity", Path(__file__).with_name("development_identity.py"))
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class IdentityTests(unittest.TestCase):
    def bundle(self):
        secrets = {key: "fixture" for key in identity.FIELDS}
        for key in ["GITHUB_SSH_PUBLIC_KEY", "PALOMA_SSH_PUBLIC_KEY"]:
            secrets[key] = "ssh-ed25519 Zml4dHVyZQ=="
        return dict(secrets=secrets, known_hosts="github.com fixture", ssh_hosts=[], library_revision="test", skill="skill")

    def test_full_vault_cannot_enter_bundle(self):
        b = self.bundle()
        b["secrets"]["BWS_ACCESS_TOKEN"] = "must-not-leave-core"
        with self.assertRaises(ValueError):
            identity.validate_bundle(b)

    def test_private_key_named_public_is_rejected(self):
        b = self.bundle()
        b["secrets"]["GITHUB_SSH_PUBLIC_KEY"] = "-----BEGIN OPENSSH PRIVATE KEY-----"
        with self.assertRaises(ValueError):
            identity.validate_bundle(b)

    def test_failed_canary_does_not_switch_generation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            old, new = root / "old", root / "new"
            old.mkdir(); new.mkdir()
            (root / "current").symlink_to(old)
            with patch.object(identity, "prepare_generation", return_value=new), patch.object(identity, "verify", side_effect=RuntimeError("failure")):
                with self.assertRaises(RuntimeError):
                    identity.install(root, self.bundle())
            self.assertEqual((root / "current").resolve(), old.resolve())
            self.assertFalse(new.exists())

    def test_managed_env_replaces_stale_tokens_and_preserves_policy(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); generation = root / "generation"
            generation.mkdir(); (root / "current").symlink_to(generation)
            (generation / "github-token").write_text("fresh")
            env = identity.profile_env(root, {"GH_TOKEN":"stale", "GITHUB_TOKEN":"stale", "GIT_CONFIG_COUNT":"1", "GIT_CONFIG_KEY_0":"remote.origin.pushurl", "GIT_CONFIG_VALUE_0":"blocked", "GIT_AUTHOR_EMAIL":"wrong"})
            self.assertEqual(env["GH_TOKEN"], "fresh")
            self.assertEqual(env["GIT_CONFIG_VALUE_0"], "blocked")
            self.assertEqual(env["GIT_CONFIG_KEY_1"], "include.path")
            self.assertNotIn("GIT_AUTHOR_EMAIL", env)

    def test_shell_activation_does_not_emit_or_embed_token(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); generation = root / "generation"
            generation.mkdir(); (root / "current").symlink_to(generation)
            (generation / "github-token").write_text("fixture-secret")
            hook = root / "activate.sh"; hook.write_text(identity.activation(root))
            self.assertNotIn("fixture-secret", hook.read_text())
            p = subprocess.run(["bash", "-c", '. "$1"; test "$GH_TOKEN" = fixture-secret; test "$GIT_CONFIG_COUNT" = 1', "bash", str(hook)], capture_output=True, text=True, env={"PATH":os.environ["PATH"]})
            self.assertEqual(p.returncode, 0)
            self.assertEqual(p.stdout + p.stderr, "")

    def test_unchanged_bundle_is_not_reinstalled(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); generation = root / "generation"
            generation.mkdir(); (root / "current").symlink_to(generation)
            b = self.bundle()
            (root / ".bundle-digest").write_text(identity.hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest())
            with patch.object(identity, "verify", return_value={"signed_commit":"verified"}), patch.object(identity, "prepare_generation") as prepare:
                self.assertFalse(identity.install(root,b)["changed"])
                prepare.assert_not_called()

    def test_skill_preparation_preserves_project_owned_skill(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "identity"; generation = root / "generation"
            (generation / "skill").mkdir(parents=True)
            (root / "current").symlink_to(generation)
            (generation / "receipt.json").write_text('{"library_revision":"test"}')
            project = Path(d) / "project"
            owned = project / ".claude/skills/development-identity"
            owned.mkdir(parents=True); (owned / "SKILL.md").write_text("project owned")
            identity.prepare_skills(root, project)
            self.assertEqual((owned / "SKILL.md").read_text(), "project owned")
            self.assertTrue((project / ".agents/skills/development-identity").is_symlink())
            self.assertEqual(json.loads((project / ".paloma/development-identity.json").read_text()), {"library_revision":"test"})

    def test_pending_failure_is_retried_without_deleting_bundle(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); pending = root / ".pending-bundle.json"
            pending.write_text(json.dumps(self.bundle()))
            with patch.object(identity, "install", side_effect=RuntimeError("offline")):
                with self.assertRaises(RuntimeError): identity.apply_pending(root)
            self.assertTrue(pending.exists())

    def test_pending_newer_bundle_survives_concurrent_install(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); pending = root / ".pending-bundle.json"
            pending.write_text(json.dumps(self.bundle()))
            def update(*args): pending.write_text('{"newer":true}')
            with patch.object(identity, "install", side_effect=update): identity.apply_pending(root)
            self.assertEqual(json.loads(pending.read_text()), {"newer":True})

    def test_companion_rewrap_preserves_latest_native_binary(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); companion = root / "sandboxed-mcp"
            companion.write_text("original binary")
            with patch.object(identity.os, "geteuid", return_value=1000):
                identity.install_hooks(root, companion=companion)
                identity.install_hooks(root, companion=companion)
                self.assertEqual((root / "sandboxed-mcp.identity-native").read_text(), "original binary")
                companion.write_text("new binary")
                identity.install_hooks(root, companion=companion)
                self.assertEqual((root / "sandboxed-mcp.identity-native").read_text(), "new binary")
                self.assertIn('if [ "$1" = launch ]', companion.read_text())


if __name__ == "__main__":
    unittest.main()
