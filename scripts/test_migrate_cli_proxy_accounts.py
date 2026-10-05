import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("migration", Path(__file__).with_name("migrate-cli-proxy-accounts.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationSafetyTests(unittest.TestCase):
    def row(self, provider="anthropic", **extra):
        return dict(id="account-uuid", provider_type=provider, account_email="user@example.com",
                    oauth=dict(access_token="access", refresh_token="refresh", expires_at=2000000000000), **extra)

    def test_rejected_and_expired_tokens_require_real_reconnect(self):
        rejected = self.row(rejected_oauth_refresh_fingerprint="rejected")
        expired = self.row()
        expired["oauth"]["expires_at"] = 1
        results = list(migration.plan([rejected, expired], [], [], None, 1000))
        self.assertTrue(all(value is None and action.startswith("reconnect:") for _, action, value in results))

    def test_existing_proxy_login_wins_even_when_source_looks_newer(self):
        existing = dict(type="claude", email="USER@example.com", refresh_token="authoritative")
        _, action, value = next(migration.plan([self.row()], [existing], [], None, 1000))
        self.assertEqual(action, "preserve existing proxy login")
        self.assertIsNone(value)

    def test_replacement_requires_stale_proxy_and_healthy_source(self):
        existing = dict(type="claude", email="user@example.com", refresh_token="old", expired="2000-01-01T00:00:00Z", _filename="claude-existing.json")
        record, _, value = next(migration.plan([self.row()], [existing], [], None, 1900000000000, True))
        self.assertEqual(record["file"], "claude-existing.json")
        self.assertTrue(record["replace_unusable"])
        self.assertIsNotNone(value)
        existing["expired"] = "2099-01-01T00:00:00Z"
        _, _, value = next(migration.plan([self.row()], [existing], [], None, 1900000000000, True))
        self.assertIsNone(value)

    def test_kimi_requires_device_metadata_and_preserves_row_id(self):
        _, _, value = next(migration.plan([self.row("kimi")], [], [], None, 1000))
        self.assertIsNone(value)
        _, _, value = next(migration.plan([self.row("kimi")], [], [], "original-device", 1000))
        self.assertEqual(value["sandboxed_provider_id"], "account-uuid")
        self.assertEqual(value["device_id"], "original-device")

    def test_codex_metadata_must_match_exact_refresh_generation(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "auth.json"
            path.write_text('{"tokens":{"id_token":"id","account_id":"identity","refresh_token":"other"}}')
            _, _, value = next(migration.plan([self.row("openai")], [], [path], None, 1000))
            self.assertIsNone(value)
            path.write_text('{"tokens":{"id_token":"id","account_id":"identity","refresh_token":"refresh"}}')
            _, _, value = next(migration.plan([self.row("openai")], [], [path], None, 1000))
            self.assertEqual(value["account_id"], "identity")


if __name__ == "__main__":
    unittest.main()
