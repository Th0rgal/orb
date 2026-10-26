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

    def test_proxy_jump_must_name_an_earlier_host(self):
        b = self.bundle()
        core = {"alias": "agent-core", "hostname": "203.0.113.1", "user": "root"}
        mac = {"alias": "air", "hostname": "100.64.0.2", "user": "thomas", "proxy_jump": "agent-core"}
        b["ssh_hosts"] = [core, mac]
        identity.validate_bundle(b)
        for hosts in ([mac, core], [core, {**mac, "proxy_jump": "nowhere"}], [core, {**mac, "port": "22"}]):
            b["ssh_hosts"] = hosts
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
            env = identity.profile_env(root, {"GH_TOKEN":"stale", "GITHUB_TOKEN":"stale", "GIT_CONFIG_COUNT":"1", "GIT_CONFIG_KEY_0":"remote.origin.pushurl", "GIT_CONFIG_VALUE_0":"blocked", "GIT_AUTHOR_EMAIL":"wrong", "GIT_CONFIG_PARAMETERS":"\'remote.origin.pushurl=blocked\'"})
            self.assertEqual(env["GH_TOKEN"], "fresh")
            self.assertEqual(env["GIT_CONFIG_VALUE_0"], "blocked")
            self.assertEqual(env["GIT_CONFIG_KEY_1"], "include.path")
            self.assertNotIn("GIT_AUTHOR_EMAIL", env)
            self.assertEqual(env["GIT_CONFIG_PARAMETERS"], "\'remote.origin.pushurl=blocked\'")

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
            (root / ".bundle-digest").write_text(identity.bundle_digest(b))
            with patch.object(identity, "active_profile_exists", return_value=True), patch.object(identity, "verify", return_value={"signed_commit":"verified"}), patch.object(identity, "prepare_generation") as prepare:
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

    def test_container_symlink_cannot_redirect_host_write(self):
        with tempfile.TemporaryDirectory() as d:
            image = Path(d) / "image"; outside = Path(d) / "outside"
            image.mkdir(); outside.mkdir(); (image / "root").symlink_to(outside)
            with self.assertRaises(OSError): identity.rooted_file(image, "root/token", "fixture-secret")
            self.assertFalse((outside / "token").exists())

    def test_container_leaf_symlink_is_replaced_without_following(self):
        with tempfile.TemporaryDirectory() as d:
            image = Path(d) / "image"; image.mkdir()
            outside = Path(d) / "outside"; outside.write_text("unchanged")
            (image / "token").symlink_to(outside)
            identity.rooted_file(image, "token", "fixture-secret")
            self.assertEqual(outside.read_text(), "unchanged")
            self.assertEqual(identity.rooted_file(image, "token"), "fixture-secret")
            self.assertEqual((image / "token").stat().st_mode & 0o777, 0o600)

    def test_sync_transport_uses_configured_host_key_pins(self):
        c = {"known_hosts":"/private/pins", "python":"python3", "script":"helper",
             "ssh_identity":"/private/key", "targets":[{"name":"node", "ssh":"root@node", "root":"/profile"}]}
        with patch.object(identity, "export_bundle", return_value=self.bundle()), patch.object(identity, "run", return_value='{}') as command:
            identity.sync(c, True)
        argv = command.call_args.args[0]
        self.assertIn("UserKnownHostsFile=/private/pins", argv)
        self.assertIn("GlobalKnownHostsFile=/dev/null", argv)

    def test_offline_pending_update_keeps_existing_profile_usable(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); pending = root / ".pending-bundle.json"
            pending.write_text(json.dumps(self.bundle()))
            (root / "current").mkdir(); (root / "current/receipt.json").write_text("{}")
            with patch.object(identity, "install", side_effect=RuntimeError("offline")), patch.object(identity, "active_profile_exists", return_value=True), patch.object(identity.sys, "stderr"):
                identity.apply_pending(root)
            self.assertTrue(pending.exists())
            self.assertTrue((root / "current/receipt.json").exists())

    def test_first_install_failure_does_not_publish_launcher(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            with patch.object(identity, "prepare_generation", side_effect=RuntimeError("offline")):
                with self.assertRaises(RuntimeError): identity.install(root, self.bundle())
            self.assertFalse((root / "launch").exists())
            self.assertFalse((root / "activate.sh").exists())

    def test_signing_key_listing_rejects_an_extra_primary(self):
        expected = "sec:::::::::\nfpr:::::::::" + identity.FINGERPRINT + ":\n"
        identity.assert_signing_identity(expected + "ssb:::::::::\nfpr:::::::::SUBKEY:\n")
        with self.assertRaises(ValueError):
            identity.assert_signing_identity(expected + "sec:::::::::\nfpr:::::::::OTHER:\n")
        with self.assertRaises(ValueError):
            identity.assert_signing_identity(expected + "pub:::::::::\nfpr:::::::::OTHER:\n")

    def test_project_links_and_metadata_symlinks_are_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "identity"; generation = root / "g-000000000000"
            (generation / "skill").mkdir(parents=True)
            (root / "current").symlink_to(generation)
            (generation / "receipt.json").write_text('{"library_revision":"test"}')
            project = Path(d) / "project"; project.mkdir()
            outside = Path(d) / "user-development-identity"; outside.mkdir()
            (outside / "SKILL.md").write_text("personal")
            owned = project / ".claude/skills/development-identity"
            owned.parent.mkdir(parents=True); owned.symlink_to(outside)
            (project / ".agents").symlink_to(outside)
            (project / ".paloma").symlink_to(outside)
            identity.prepare_skills(root, project)
            self.assertEqual(owned.resolve(), outside.resolve())
            self.assertEqual(sorted(p.name for p in outside.iterdir()), ["SKILL.md"])

    def test_missing_active_generation_is_repaired_even_with_matching_digest(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); stage = root / "g-000000000000"; stage.mkdir()
            (root / ".bundle-digest").write_text(identity.bundle_digest(self.bundle()))
            (root / "current").symlink_to(root / "missing")
            with patch.object(identity, "prepare_generation", return_value=stage), patch.object(identity, "verify", return_value={}):
                self.assertTrue(identity.install(root, self.bundle())["changed"])
            self.assertEqual((root / "current").resolve(), stage.resolve())

    def test_gh_probe_uses_managed_path(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root / "receipt.json").write_text('{"library_revision":"test"}')
            (root / "current").symlink_to(root)
            output = "U " + identity.FINGERPRINT + " Thomas Marchand (agent) <agent@thomas.md>"
            def execute(argv, **kwargs):
                if argv[:2] == ["git", "log"]: return output
                if argv[:2] == ["gh", "api"]: return "Th0rgal"
                return ""
            with patch.object(identity, "profile_env", return_value={"GH_TOKEN":"fixture", "PATH":"/managed/bin"}), patch.object(identity, "github_login", return_value="Th0rgal"), patch.object(identity, "run", side_effect=execute), patch.object(identity.subprocess, "run", return_value=subprocess.CompletedProcess([],1,"", "Hi Th0rgal! You've successfully authenticated")), patch.object(identity.shutil, "which", return_value="/managed/bin/gh") as which:
                identity.verify(root)
                which.assert_called_once_with("gh", path="/managed/bin")

    def test_corrupt_receipt_and_cyclic_current_are_not_valid_profiles(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); generation = root / "g-000000000000"; generation.mkdir()
            (root / "current").symlink_to(generation)
            (generation / "receipt.json").write_text("[]")
            self.assertFalse(identity.active_profile_exists(root))
            (root / "current").unlink(); (root / "current").symlink_to(root / "current")
            self.assertFalse(identity.active_profile_exists(root))

    def test_missing_profile_artifacts_require_repair(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); generation = root / "g-000000000000"; generation.mkdir()
            (root / "current").symlink_to(generation)
            (generation / "receipt.json").write_text(json.dumps({"signing_fingerprint": identity.FINGERPRINT}))
            for name in [*identity.REQUIRED_PROFILE_FILES, "gnupg/private-keys-v1.d/test.key", "gnupg/pubring.kbx"]:
                path = generation / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("fixture")
            self.assertTrue(identity.active_profile_exists(root))
            for name in [*identity.REQUIRED_PROFILE_FILES, "gnupg/private-keys-v1.d/test.key", "gnupg/pubring.kbx"]:
                with self.subTest(name=name):
                    path = generation / name; path.unlink()
                    self.assertFalse(identity.active_profile_exists(root))
                    path.write_text("fixture")

    def test_matching_digest_repairs_failed_profile_verification(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); old = root / "old"; old.mkdir()
            new = root / "new"; new.mkdir()
            (root / "current").symlink_to(old)
            bundle = self.bundle(); (root / ".bundle-digest").write_text(identity.bundle_digest(bundle))
            with patch.object(identity, "active_profile_exists", return_value=True), patch.object(identity, "prepare_generation", return_value=new), patch.object(identity, "verify", side_effect=[RuntimeError("damaged"), {"signed_commit":"verified"}]):
                self.assertTrue(identity.install(root, bundle)["changed"])
            self.assertEqual((root / "current").resolve(), new.resolve())

    def test_container_setup_uses_rooted_endpoint_and_old_core_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); script = root / "helper.py"; script.write_text("fixture")
            workspace = {"id": "test", "name": "test", "workspace_type": "container", "status": "ready", "path": str(root)}
            def request(config, method, endpoint, *args):
                if method == "GET": return [workspace]
                self.assertEqual(endpoint, "/api/workspaces/test/exec-rooted")
                raise RuntimeError("HTTP 404: older Core")
            with patch.object(identity, "core_request", side_effect=request), patch.object(identity, "rooted_file"):
                result = identity.stage_containers({"script": str(script), "native_companion": str(root / "absent")}, self.bundle())
            self.assertNotEqual(result[0]["status"], "current")

    def test_skill_is_loaded_from_pinned_commit_not_dirty_checkout(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); skill = root / "skill/development-identity/SKILL.md"
            skill.parent.mkdir(parents=True); skill.write_text("published skill")
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", *args], text=True, stderr=subprocess.DEVNULL)
            git("init", "-q"); git("add", "."); git("commit", "-q", "-m", "fixture")
            revision = git("rev-parse", "HEAD").strip()
            skill.write_text("unpublished edit")
            self.assertEqual(identity.pinned_skill({"skill":str(skill), "library_revision":revision}), "published skill")

    def test_coding_only_target_strips_fleet_ssh_keys(self):
        b = self.bundle()
        b["ssh_hosts"] = [{
            "alias": "ashur",
            "hostname": "10.88.0.11",
            "user": "root",
            "identity_key": "PALOMA_SSH_KEY_ASHUR",
            "public_key": "PALOMA_SSH_KEY_ASHUR_PUBLIC_KEY",
        }]
        b["host_keys"] = {
            "PALOMA_SSH_KEY_ASHUR": "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----",
            "PALOMA_SSH_KEY_ASHUR_PUBLIC_KEY": "ssh-ed25519 Zml4dHVyZQ==",
        }
        identity.validate_bundle(b)
        stripped = identity.coding_only_bundle(b)
        identity.validate_bundle(stripped)
        self.assertEqual(set(stripped["secrets"]), set(identity.BASE_FIELDS))
        self.assertEqual(stripped["ssh_hosts"], [])
        self.assertNotIn("host_keys", stripped)

    def test_unreferenced_or_invalid_host_keys_are_rejected(self):
        b = self.bundle()
        b["host_keys"] = {"EXTRA": "secret"}
        with self.assertRaises(ValueError):
            identity.validate_bundle(b)
        b2 = self.bundle()
        b2["ssh_hosts"] = [{
            "alias": "ashur",
            "hostname": "10.88.0.11",
            "user": "root",
            "identity_key": "PALOMA_SSH_KEY_ASHUR",
            "public_key": "PALOMA_SSH_KEY_ASHUR_PUBLIC_KEY",
        }]
        b2["host_keys"] = {
            "PALOMA_SSH_KEY_ASHUR": "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----",
            "PALOMA_SSH_KEY_ASHUR_PUBLIC_KEY": "-----BEGIN OPENSSH PRIVATE KEY-----",
        }
        with self.assertRaises(ValueError):
            identity.validate_bundle(b2)
        b3 = self.bundle()
        b3["ssh_hosts"] = b2["ssh_hosts"]
        b3["host_keys"] = {
            "PALOMA_SSH_KEY_ASHUR": "not-a-private-key",
            "PALOMA_SSH_KEY_ASHUR_PUBLIC_KEY": "ssh-ed25519 Zml4dHVyZQ==",
        }
        with self.assertRaises(ValueError):
            identity.validate_bundle(b3)

    def test_validate_targets_rejects_typo_and_missing_bws_key_raises_runtime_error(self):
        with self.assertRaises(ValueError):
            identity.validate_targets({"targets": [{"name": "node", "root": "/p", "coding-only": True}]})
        with self.assertRaises(ValueError):
            identity.validate_targets({"targets": [{"name": "node", "root": "/p", "coding_only": "yes"}]})
        identity.validate_targets({"targets": [{"name": "node", "root": "/p", "coding_only": True}]})
        with patch.object(identity.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "[]", "")):
            with self.assertRaises(RuntimeError):
                identity.export_bundle({"bitwarden_command": ["bws"], "ssh_hosts": []})

    def test_orb_ssh_identity_step_enforces_worker_secret_stripping_and_symlink_rejection(self):
        # Worker coding_only bundle without control-plane keys -> admitted (1793)
        self.assertEqual(identity.orb_ssh_identity_step(1, 0, 0, 1, 1), 1793)
        # Worker bundle with control-plane keys -> rejected (exit 78 in hi32, admitBit=0)
        leak = identity.orb_ssh_identity_step(1, 1, 0, 1, 1)
        self.assertEqual(leak & 256, 0)
        self.assertEqual(leak >> 32, 78)
        # Symlink parent directory -> rejected
        sym = identity.orb_ssh_identity_step(1, 0, 1, 1, 1)
        self.assertEqual(sym & 256, 0)
        self.assertEqual(sym >> 32, 78)

    def test_orb_privd_command_confinement_rejects_attack_vectors(self):
        import importlib.util
        privd_path = Path(__file__).with_name("orb-privd.py")
        spec = importlib.util.spec_from_file_location("orb_privd", privd_path)
        privd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(privd)

        # Valid ops_read command
        packed = privd.check_scope_restrictions(
            "ops_read", None, ["journalctl", "-u", "orb-core", "-n", "20", "--no-pager"], cwd="/var/log"
        )
        self.assertEqual(packed, 1793)

        # Valid service_deploy command for matching unit
        packed_deploy = privd.check_scope_restrictions(
            "service_deploy", "orb-core", ["systemctl", "restart", "orb-core.service"], cwd="/root"
        )
        self.assertEqual(packed_deploy, 1794)

        # Attack vectors: shell metacharacters, path traversal, unsafe env, wrong unit, escalation
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions("ops_read", None, ["ps; id"], cwd="/root")
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions("root_exec", None, ["id"], cwd="/var/lib/../../etc")
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions(
                "root_exec", None, ["id"], cwd="/root", env={"LD_PRELOAD": "/tmp/evil.so"}
            )
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions(
                "service_deploy", "orb-core", ["systemctl", "restart", "postgres.service"], cwd="/root"
            )
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions(
                "ops_read", None, ["systemctl", "restart", "orb-core"], cwd="/root"
            )
        # Path-qualified executable bypass vectors must be rejected fail-closed
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions("ops_read", None, ["/attacker-controlled/ps"], cwd="/root")
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions(
                "service_deploy", "orb-core", ["/attacker-controlled/systemctl", "restart", "orb-core"], cwd="/root"
            )
        with self.assertRaises(ValueError):
            privd.check_scope_restrictions(
                "service_deploy", "orb-core", ["./systemctl", "restart", "orb-core"], cwd="/root"
            )

    def test_exhaustive_ctypes_equivalence_against_liborb_kernel_so(self):
        import ctypes
        import importlib.util
        import itertools

        repo_root = Path(__file__).resolve().parent.parent
        so_path = repo_root / "android_dashboard/app/src/test/resources/jni/liborb_kernel.so"
        if not so_path.is_file():
            so_path = repo_root / "android_dashboard/app/src/main/jniLibs/x86_64/liborb_kernel.so"
        self.assertTrue(so_path.is_file(), f"Missing committed liborb_kernel.so at {so_path}")
        lib = ctypes.CDLL(str(so_path))
        lib.orb_privd_command_step.argtypes = [ctypes.c_uint8] * 8
        lib.orb_privd_command_step.restype = ctypes.c_uint64
        lib.orb_ssh_identity_step.argtypes = [ctypes.c_uint8] * 7
        lib.orb_ssh_identity_step.restype = ctypes.c_uint64

        privd_path = Path(__file__).with_name("orb-privd.py")
        spec = importlib.util.spec_from_file_location("orb_privd", privd_path)
        privd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(privd)

        codex_path = Path(__file__).with_name("remote_codex_app_server.py")
        codex_spec = importlib.util.spec_from_file_location("remote_codex_app_server", codex_path)
        codex_mod = importlib.util.module_from_spec(codex_spec)
        codex_spec.loader.exec_module(codex_mod)

        # Exhaustively test all 1,536 inputs of orb_privd_command_step:
        # lease in {0,1} x scope in 0..3 x class in 0..5 x {0,1}^5 = 2 * 4 * 6 * 32 = 1,536
        privd_cases = 0
        for lease, scope, cmd_class, unit_ok, metachar, traversal, unsafe_env, force_cmd in itertools.product(
            (0, 1), (0, 1, 2, 3), (0, 1, 2, 3, 4, 5), (0, 1), (0, 1), (0, 1), (0, 1), (0, 1)
        ):
            expected = int(
                lib.orb_privd_command_step(
                    lease, scope, cmd_class, unit_ok, metachar, traversal, unsafe_env, force_cmd
                )
            )
            actual = privd.orb_privd_command_step(
                lease, scope, cmd_class, unit_ok, metachar, traversal, unsafe_env, force_cmd
            )
            self.assertEqual(actual, expected)
            privd_cases += 1
        self.assertEqual(privd_cases, 1536)

        # Exhaustively test all 128 inputs of orb_ssh_identity_step: {0,1}^7 = 128
        ssh_cases = 0
        for args in itertools.product((0, 1), repeat=7):
            expected = int(lib.orb_ssh_identity_step(*args))
            self.assertEqual(identity.orb_ssh_identity_step(*args), expected)
            self.assertEqual(codex_mod.orb_ssh_identity_step(*args), expected)
            ssh_cases += 1
        self.assertEqual(ssh_cases, 128)


if __name__ == "__main__":
    unittest.main()
