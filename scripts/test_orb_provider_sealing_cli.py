"""Real Core CLI, temporary roots and a synthetic vault; no live credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).resolve().parents[1] / "lean/OrbCore/.lake/build/bin/orb-core"
VALUE = "synthetic-vault-provider-value"
VAULT = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
with Path(os.environ["FAKE_VAULT_CALLS"]).open("a") as log:
    log.write(" ".join(sys.argv[1:4]) + "\\n")
command = sys.argv[1:3]
if command == ["project", "list"]:
    print("[]")
elif command == ["secret", "list"]:
    rows = [{"id": "boat-id", "key": "BOAT_API_KEY"},
            {"id": "colab-id", "key": "COLAB_API_TOKEN"}]
    mode = os.environ.get("FAKE_VAULT_MODE")
    if mode == "duplicate": rows.append(rows[0])
    print(json.dumps({} if mode == "malformed" else rows))
elif command == ["secret", "get"]:
    print(json.dumps({"value": "synthetic-vault-provider-value"}))
else:
    sys.exit(1)
'''


@unittest.skipUnless(BINARY.is_file(), "build orb-core to exercise the operator CLI")
class ProviderSealingCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = self.root / "data"
        self.data.mkdir(mode=0o700)
        self.calls = self.root / "calls"
        fake = self.root / "bws"
        fake.write_text(VAULT)
        fake.chmod(0o700)
        # Deliberately construct a fresh synthetic environment. Do not inherit
        # any actual vault, provider or mission credentials from the runner.
        self.env = {"PATH": f"{self.root}:{os.defpath}", "BWS_ACCESS_TOKEN": "synthetic-vault-token",
                    "FAKE_VAULT_CALLS": str(self.calls), "BOAT_API_KEY": "synthetic-wrong-env-key"}

    def run_cli(self, *args):
        result = subprocess.run([str(BINARY), "seal-provider", *args],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertNotIn(VALUE, result.stdout + result.stderr)
        self.assertNotIn("synthetic-wrong-env-key", result.stdout + result.stderr)
        return result

    def test_batch_seals_vault_entries_without_using_environment_key(self):
        result = self.run_cli("--all", "--data-root", str(self.data))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"sealed": ["boat", "colab"]})
        calls = self.calls.read_text()
        self.assertIn("secret get boat-id", calls)
        self.assertIn("secret get colab-id", calls)
        self.assertNotIn("secret get leanci", calls)
        for provider in ("boat", "colab"):
            sealed = self.data / "managed-secrets" / f"{provider}.aead"
            self.assertNotIn(VALUE.encode(), sealed.read_bytes())
            self.assertEqual(sealed.stat().st_mode & 0o777, 0o600)

    def test_mission_cannot_read_vault_metadata_or_create_sealed_files(self):
        self.env["SANDBOXED_MISSION_ID"] = "synthetic-mission"
        result = self.run_cli("--all", "--data-root", str(self.data))
        self.assertEqual(result.returncode, 1)
        self.assertIn("operator_required", result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.data / "managed-secrets").exists())

    def test_duplicate_or_malformed_inventory_fails_before_value_lookup(self):
        for mode in ("duplicate", "malformed"):
            with self.subTest(mode=mode):
                self.env["FAKE_VAULT_MODE"] = mode
                self.calls.unlink(missing_ok=True)
                result = self.run_cli("--all", "--data-root", str(self.data))
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("secret get", self.calls.read_text())
                self.assertFalse((self.data / "managed-secrets").exists())

    def test_missing_vault_and_extra_arguments_fail_closed(self):
        del self.env["BWS_ACCESS_TOKEN"]
        self.assertEqual(self.run_cli("--all", "--data-root", str(self.data)).returncode, 1)
        self.assertEqual(self.run_cli("--all", "--unexpected").returncode, 2)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
