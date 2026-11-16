import hashlib
import hmac
import runpy
import sqlite3
import unittest
from pathlib import Path
from unittest.mock import patch


class MonitorAuthTest(unittest.TestCase):
    def test_r12_monitor_token_names_enabled_admin_and_live_epoch(self):
        ns = runpy.run_path(str(Path(__file__).parent / "ops/orb-monitor"))
        fn = ns["core_token"]
        con = sqlite3.connect(":memory:")
        con.execute("CREATE TABLE users(id TEXT, role TEXT, disabled INTEGER, session_epoch INTEGER)")
        con.executemany("INSERT INTO users VALUES(?,?,?,?)", [
            ("disabled", "admin", 1, 1), ("member", "member", 0, 1),
            ("real-admin-uuid", "admin", 0, 7)])
        with patch.dict(fn.__globals__, core_env=lambda _: "test-secret", ro=lambda _: con, NOW=100):
            token = fn()
            payload, signature = token.rsplit(".", 1)
            self.assertEqual(payload, "orb-jwt-v2:real-admin-uuid:admin:7:700")
            self.assertEqual(signature, hmac.new(b"test-secret", payload.encode(), hashlib.sha256).hexdigest())
            con.execute("UPDATE users SET disabled=1")
            self.assertEqual(fn(), "")


if __name__ == "__main__":
    unittest.main()
