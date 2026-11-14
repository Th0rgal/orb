"""Env ownership and migration safety: no evaluation, overwrites or value leaks."""

import contextlib
import importlib.machinery
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parent / "ops/orb-env"
env = importlib.machinery.SourceFileLoader("orb_env", str(SCRIPT)).load_module()


class OrbEnvTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prod = self.root / "legacy-prod.env"
        self.dev = self.root / "legacy-dev.env"
        self.output = self.root / "environments"
        self.shared = b'CLI_PROXY_API_BASE_URL="http://localhost:8317"\nCLI_PROXY_API_KEY=\'$(must-not-run)\'\n'
        self.prod.write_bytes(self.shared + b"LIBRARY_REMOTE=repo\nPORT=3000\nWORKING_DIR=/root\nJWT_SECRET=prod-secret\n")
        self.dev.write_bytes(self.shared + b"LIBRARY_REMOTE=repo\nPORT=3002\nWORKING_DIR=/var/lib/dev\nJWT_SECRET=dev-secret\n")

    def cli(self, *flags):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("sys.argv", [str(SCRIPT), "migrate", "--prod", str(self.prod),
                                "--dev", str(self.dev), "--output", str(self.output), *flags]), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = env.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_checked_in_classification_parsing_and_completeness(self):
        path = SCRIPT.with_name("env-migration.json")
        policy = env.read_ownership(path)
        self.assertEqual(set(policy["instance_keys"]) | policy["shared_from"].keys(), env.KNOWN_KEYS)
        self.assertTrue(all(source == "prod" for source in policy["shared_from"].values()))
        self.assertIn("CLI_PROXY_API_KEY", policy["instance_keys"])
        bad = self.root / "classification.json"
        bad.write_text('{"schema_version":1,"instance_keys":[],"shared_from":{}}')
        with self.assertRaisesRegex(env.InvalidConfig, "cover every known key"):
            env.migration_policy(bad, {}, {})
        bad.write_text('{"schema_version":1,"schema_version":1}')
        with self.assertRaisesRegex(env.InvalidConfig, "duplicate ownership"):
            env.migration_policy(bad, {}, {})

    def test_observed_named_groups_stay_instance_owned(self):
        dev_only = "AUTOMATION_MANAGER_MCP_BIN CODEX_APP_SERVER_MODE LIBRARY_PATH OPENAGENT_DATA_DIR RUST_MIN_STACK SANDBOXED_MANAGED_ENABLED SANDBOXED_PROXY_SECRET SANDBOXED_SH_RTK_ENABLED SCOPE_REAPER_ENABLED WORKING_DIR".split()
        different = "BROWSER_ENABLED DASHBOARD_PASSWORD DEFAULT_MODEL JWT_SECRET PORT SANDBOXED_MANAGED_REAPER_DRY_RUN SANDBOXED_PUBLIC_URL SANDBOXED_REMOTE_NODES SANDBOXED_REMOTE_NODE_SEPOLIA_TOKEN SANDBOXED_SH_OPENCODE_DEFAULT_MODEL SANDBOXED_SINGLE_TENANT_USER_ID".split()
        self.assertEqual((len(dev_only), len(different)), (10, 11))
        self.assertTrue(set(dev_only + different) <= env.INSTANCE_KEYS)

    def test_cli_default_and_explicit_dry_run(self):
        self.prod.write_bytes(self.prod.read_bytes() + b"MAX_ITERATIONS=prod-marker\n")
        for flags in ((), ("--dry-run",)):
            result, stdout, stderr = self.cli(*flags)
            self.assertEqual(result, 0, stderr)
            self.assertIn("no files written", stdout)
            self.assertNotIn("prod-marker", stdout + stderr)
            self.assertFalse(self.output.exists())
        result, _, stderr = self.cli("--apply")
        self.assertEqual(result, 0, stderr)
        base = env.parse_env((self.output / "core.env").read_bytes())
        self.assertEqual(base["MAX_ITERATIONS"], "prod-marker")
        self.assertNotIn("CLI_PROXY_API_KEY", base)

    def test_cli_unknown_refused_before_writes(self):
        self.dev.write_bytes(self.dev.read_bytes() + b"UNREVIEWED_KEY=secret-marker\n")
        for flags in ((), ("--apply",)):
            result, stdout, stderr = self.cli(*flags)
            self.assertEqual(result, 1)
            self.assertIn("unclassified environment keys: UNREVIEWED_KEY", stderr)
            self.assertNotIn("secret-marker", stdout + stderr)
            self.assertFalse(self.output.exists())

    def test_apply_validates_then_backs_up_both_before_configuration(self):
        writes = []
        real_write = env.write_private
        def record(path, raw):
            writes.append(str(path.relative_to(self.output)))
            real_write(path, raw)
        with patch.object(env, "write_private", side_effect=record):
            result, _, stderr = self.cli("--apply")
        self.assertEqual(result, 0, stderr)
        self.assertEqual(writes, ["backups/prod.env", "backups/dev.env", "ownership.json",
                                  "core.env", "prod.env", "dev.env"])
        self.assertEqual((self.output / "backups/prod.env").read_bytes(), self.prod.read_bytes())
        self.assertEqual((self.output / "backups/dev.env").read_bytes(), self.dev.read_bytes())

    def test_migration_preserves_effective_envs_and_exact_backups(self):
        originals = [path.read_bytes() for path in (self.prod, self.dev)]
        env.migrate(self.prod, self.dev, self.output, apply=True)
        base = env.parse_env((self.output / "core.env").read_bytes())
        for name, original, path in zip(("prod", "dev"), originals, (self.prod, self.dev)):
            overlay = env.parse_env((self.output / f"{name}.env").read_bytes())
            env.check(base, overlay)
            merged = base | overlay
            self.assertEqual(merged.pop("ORB_INSTANCE"), name)
            self.assertEqual(merged, env.parse_env(original))
            self.assertEqual((self.output / f"backups/{name}.env").read_bytes(), original)
            self.assertEqual(path.read_bytes(), original)
        for path in self.output.rglob("*"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)

    def test_dry_run_and_repeated_migration(self):
        env.migrate(self.prod, self.dev, self.output)
        self.assertFalse(self.output.exists())
        env.migrate(self.prod, self.dev, self.output, apply=True)
        with self.assertRaises(env.InvalidConfig):
            env.migrate(self.prod, self.dev, self.output, apply=True)

    def test_conflicting_and_one_sided_base_values_fail_before_writes(self):
        for extra in (b"ONLY_IN_DEV=value\n", b"LIBRARY_REMOTE=different\n"):
            with self.subTest(extra=extra):
                # Replace, not duplicate, the existing shared assignment.
                self.dev.write_bytes(self.dev.read_bytes().replace(b"LIBRARY_REMOTE=repo\n", b"") + extra)
                with self.assertRaises(env.InvalidConfig):
                    env.migrate(self.prod, self.dev, self.output, apply=True)
                self.assertFalse(self.output.exists())

    def test_inventory_and_instance_policy_preserve_one_sided_authority(self):
        self.prod.write_bytes(self.prod.read_bytes() + b'HERMES_TOKEN=prod-private-marker\nCONSOLE_SSH_KEY=prod-host-only\n')
        self.dev.write_bytes(self.dev.read_bytes() + b'CODEX_APP_SERVER_MODE=false\n')
        before = [p.read_bytes() for p in (self.prod, self.dev)]
        report = env.inventory(*(env.parse_env(raw) for raw in before))
        self.assertEqual(report["differences"], {"CONSOLE_SSH_KEY": "prod_only", "HERMES_TOKEN": "prod_only"})
        for value in ("prod-private-marker", "prod-host-only", "false"):
            self.assertNotIn(value, json.dumps(report))
        policy = report["ownership"]
        env.migrate(self.prod, self.dev, self.output, apply=True, policy=policy)
        self.assertEqual(env.read_ownership(self.output / "ownership.json"), policy)
        base = env.parse_env((self.output / "core.env").read_bytes())
        for name, raw in zip(("prod", "dev"), before):
            overlay = env.parse_env((self.output / (name + ".env")).read_bytes())
            env.check(base, overlay, policy)
            merged = base | overlay
            merged.pop("ORB_INSTANCE")
            self.assertEqual(merged, env.parse_env(raw))
            self.assertEqual((self.output / ("backups/" + name + ".env")).read_bytes(), raw)
        self.assertNotIn("HERMES_TOKEN", base)
        with self.assertRaisesRegex(env.InvalidConfig, "redefines base"):
            env.check(base, overlay | {"LIBRARY_REMOTE": base["LIBRARY_REMOTE"]}, policy)
        # The unchanged service check loads the manifest beside the shared base.
        with patch("sys.argv", [str(SCRIPT), "check", "--base", str(self.output / "core.env"),
                                "--overlay", str(self.output / "dev.env")]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(env.main(), 0)

    def test_protected_authority_and_unknown_names_cannot_be_shared(self):
        for key in ["HERMES_TOKEN", "CONSOLE_SSH_KEY", "SANDBOXED_REMOTE_NODE_SEPOLIA_TOKEN", "JWT_SECRET", "UNREVIEWED_AUTHORITY"]:
            policy = {"schema_version": 1, "instance_keys": [], "shared_from": {key: "prod"}}
            with self.subTest(key=key), self.assertRaises(env.InvalidConfig):
                env.migrate(self.prod, self.dev, self.output, apply=True, policy=policy)
            self.assertFalse(self.output.exists())
        self.dev.write_bytes(self.dev.read_bytes() + b'HERMES_TOKEN=synthetic-host-authority\n')
        with self.assertRaisesRegex(env.InvalidConfig, "prod-only authority configured on dev: HERMES_TOKEN"):
            env.migrate(self.prod, self.dev, self.output, apply=True)
        self.dev.write_bytes(self.dev.read_bytes().replace(b'HERMES_TOKEN=synthetic-host-authority\n', b'UNKNOWN_KEY=hidden-value\n'))
        with self.assertRaises(env.InvalidConfig):
            env.migrate(self.prod, self.dev, self.output, apply=True,
                        policy={"schema_version": 1, "instance_keys": ["UNKNOWN_KEY"], "shared_from": {}})
        self.assertFalse(self.output.exists())

    def test_operator_selects_shared_source_without_exposing_values(self):
        self.prod.write_bytes(self.prod.read_bytes() + b'MAX_ITERATIONS=private-prod-value\n')
        self.dev.write_bytes(self.dev.read_bytes().replace(b'LIBRARY_REMOTE=repo', b'LIBRARY_REMOTE=dev-repo'))
        policy = {"schema_version": 1, "instance_keys": [],
                  "shared_from": {"MAX_ITERATIONS": "prod", "LIBRARY_REMOTE": "dev"}}
        base, prod, dev = env.split_envs(env.parse_env(self.prod.read_bytes()), env.parse_env(self.dev.read_bytes()), policy)
        self.assertEqual(base["MAX_ITERATIONS"], "private-prod-value")
        self.assertEqual(env.literal(base["LIBRARY_REMOTE"]), "dev-repo")
        for overlay in (prod, dev):
            self.assertFalse(base.keys() & overlay.keys())
            env.check(base, overlay, policy)
        policy["shared_from"]["MAX_ITERATIONS"] = "dev"
        with self.assertRaisesRegex(env.InvalidConfig, "source is missing key: MAX_ITERATIONS"):
            env.migrate(self.prod, self.dev, self.output, apply=True, policy=policy)
        self.assertFalse(self.output.exists())

    def test_ownership_rejects_ambiguous_and_secret_bearing_decisions(self):
        invalid = [[], {}, {"schema_version": True, "instance_keys": [], "shared_from": {}},
                   {"schema_version": 1, "instance_keys": ["KEY", "KEY"], "shared_from": {}},
                   {"schema_version": 1, "instance_keys": ["KEY=secret-marker"], "shared_from": {}},
                   {"schema_version": 1, "instance_keys": [], "shared_from": {"JWT_SECRET": "prod"}},
                   {"schema_version": 1, "instance_keys": ["KEY"], "shared_from": {"KEY": "dev"}},
                   {"schema_version": 1, "instance_keys": [], "shared_from": {"KEY": "secret-marker"}}]
        for policy in invalid:
            with self.subTest(policy=policy), self.assertRaises(env.InvalidConfig) as caught:
                env.ownership(policy)
            self.assertNotIn("secret-marker", str(caught.exception))
        manifest = self.root / "ownership.json"
        manifest.write_text('{"schema_version":1,"instance_keys":[],"shared_from":{"KEY":"prod","KEY":"dev"}}')
        with self.assertRaisesRegex(env.InvalidConfig, "duplicate ownership"):
            env.read_ownership(manifest)
        policy = {"schema_version": 1, "instance_keys": [], "shared_from": {"MAX_ITERATIONS": "prod"}}
        with self.assertRaisesRegex(env.InvalidConfig, "absent from both inputs: MAX_ITERATIONS"):
            env.migrate(self.prod, self.dev, self.output, apply=True, policy=policy)

    def test_classification_reports_names_not_values(self):
        prod = env.parse_env(self.prod.read_bytes()) | {"PROD_ONLY": "private-prod"}
        dev = env.parse_env(self.dev.read_bytes()) | {"DEV_ONLY": "private-dev", "LIBRARY_REMOTE": "private-different"}
        result = env.classify(prod, dev)
        self.assertEqual(result["prod_only"], ["PROD_ONLY"])
        self.assertEqual(result["dev_only"], ["DEV_ONLY"])
        self.assertEqual(result["different"], ["LIBRARY_REMOTE"])
        self.assertEqual(result["shared"], [])
        self.assertNotIn("private", str(result))

    def test_classify_cli_never_writes_or_discloses_values(self):
        self.dev.write_bytes(self.dev.read_bytes() + b"DEV_FEATURE=private-value\n")
        stdout = io.StringIO()
        with patch("sys.argv", [str(SCRIPT), "classify", "--prod", str(self.prod), "--dev", str(self.dev)]), contextlib.redirect_stdout(stdout):
            self.assertEqual(env.main(), 0)
        self.assertIn("DEV_FEATURE", stdout.getvalue())
        self.assertNotIn("private-value", stdout.getvalue())
        self.assertFalse(self.output.exists())

    def test_shared_identity_cannot_be_disguised_by_quotes(self):
        self.dev.write_bytes(self.dev.read_bytes().replace(b"dev-secret", b'"prod-secret"'))
        with self.assertRaisesRegex(env.InvalidConfig, "distinct JWT_SECRET"):
            env.migrate(self.prod, self.dev, self.output, apply=True)
        self.assertFalse(self.output.exists())

    def test_startup_refuses_duplicate_even_when_equal_and_unknown_overlay(self):
        base, prod, _ = env.split_envs(env.parse_env(self.prod.read_bytes()), env.parse_env(self.dev.read_bytes()))
        with self.assertRaisesRegex(env.InvalidConfig, "redefines base keys: LIBRARY_REMOTE"):
            env.check(base, prod | {"LIBRARY_REMOTE": base["LIBRARY_REMOTE"]})
        with self.assertRaisesRegex(env.InvalidConfig, "unclassified environment keys: UNKNOWN"):
            env.check(base, prod | {"UNKNOWN": "hidden"})
        with self.assertRaisesRegex(env.InvalidConfig, "wrong layer: JWT_SECRET"):
            env.check(base | {"JWT_SECRET": "hidden"}, {key: value for key, value in prod.items() if key != "JWT_SECRET"})

    def test_parser_rejects_ambiguous_syntax_without_values(self):
        for raw in (b"KEY=hidden\nKEY=hidden\n", b"export KEY=hidden\n", b"KEY='hidden\n", b"KEY=hidden\\\n", b"KEY=hidden\0\n"):
            with self.subTest(raw=raw):
                with self.assertRaises(env.InvalidConfig) as caught:
                    env.parse_env(raw)
                self.assertNotIn("hidden", str(caught.exception))

    def test_systemd_literals_no_shell_expansion(self):
        self.assertEqual(env.literal("'a\\b $HOME $(id)'"), "a\\b $HOME $(id)")
        self.assertEqual(env.literal('"a\\q \\$HOME \\"b\\""'), 'a\\q $HOME "b"')
        self.assertEqual(env.literal("a\\ b # literal"), "a b # literal")

    def test_non_ascii_whitespace_in_values_is_preserved(self):
        value = "\u00a0non-ascii\u00a0"
        parsed = env.parse_env(f"KEY={value}\n".encode())
        self.assertEqual(parsed["KEY"], value)
        self.assertEqual(env.parse_env(env.render(parsed)), parsed)
        with self.assertRaises(env.InvalidConfig):
            env.parse_env("KEY\u00a0=value\n".encode())

    def test_cli_errors_do_not_disclose_values(self):
        self.dev.write_bytes(self.dev.read_bytes().replace(b"dev-secret", b"prod-secret"))
        stderr = io.StringIO()
        with patch("sys.argv", [str(SCRIPT), "migrate", "--prod", str(self.prod), "--dev", str(self.dev), "--output", str(self.output), "--apply"]), contextlib.redirect_stderr(stderr):
            self.assertEqual(env.main(), 1)
        self.assertIn("JWT_SECRET", stderr.getvalue())
        self.assertNotIn("prod-secret", stderr.getvalue())

    def test_partial_write_failure_leaves_inputs_and_no_output(self):
        originals = (self.prod.read_bytes(), self.dev.read_bytes())
        with patch.object(env, "render", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                env.migrate(self.prod, self.dev, self.output, apply=True)
        self.assertFalse(self.output.exists())
        self.assertEqual((self.prod.read_bytes(), self.dev.read_bytes()), originals)

    def test_both_units_share_base_and_run_check_before_start(self):
        for name in ("orb-core", "orb-core-dev"):
            unit = (SCRIPT.parents[2] / f"deploy/systemd/{name}.service").read_text()
            self.assertIn("EnvironmentFile=/etc/orb/environments/core.env\n", unit)
            self.assertIn("ExecStartPre=/usr/local/libexec/orb-env check --base /etc/orb/environments/core.env --overlay /etc/orb/environments/", unit)


if __name__ == "__main__":
    unittest.main()
