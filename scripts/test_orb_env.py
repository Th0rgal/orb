"""Env ownership and migration safety: no evaluation, overwrites or value leaks."""

import contextlib
import importlib.machinery
import io
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
        self.shared = b'PROXY_URL="http://localhost:8317"\nTOKEN=\'$(must-not-run)\'\n'
        self.prod.write_bytes(self.shared + b"PORT=3000\nWORKING_DIR=/root\nJWT_SECRET=prod-secret\n")
        self.dev.write_bytes(self.shared + b"PORT=3002\nWORKING_DIR=/var/lib/dev\nJWT_SECRET=dev-secret\n")

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
        for extra in (b"ONLY_IN_DEV=value\n", b"PROXY_URL=different\n"):
            with self.subTest(extra=extra):
                # Replace, not duplicate, the existing proxy assignment.
                self.dev.write_bytes(self.dev.read_bytes().replace(b'PROXY_URL="http://localhost:8317"\n', b"") + extra)
                with self.assertRaises(env.InvalidConfig):
                    env.migrate(self.prod, self.dev, self.output, apply=True)
                self.assertFalse(self.output.exists())

    def test_classification_reports_names_not_values(self):
        prod = env.parse_env(self.prod.read_bytes()) | {"PROD_ONLY": "private-prod"}
        dev = env.parse_env(self.dev.read_bytes()) | {"DEV_ONLY": "private-dev", "TOKEN": "private-different"}
        result = env.classify(prod, dev)
        self.assertEqual(result["prod_only"], ["PROD_ONLY"])
        self.assertEqual(result["dev_only"], ["DEV_ONLY"])
        self.assertEqual(result["different"], ["TOKEN"])
        self.assertEqual(result["shared"], ["PROXY_URL"])
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
        with self.assertRaisesRegex(env.InvalidConfig, "redefines base keys: PROXY_URL"):
            env.check(base, prod | {"PROXY_URL": base["PROXY_URL"]})
        with self.assertRaisesRegex(env.InvalidConfig, "wrong layer: UNKNOWN"):
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
