#!/usr/bin/env python3
"""Unit tests for scripts/security/paloma-vault-setup and lean-mesh-heartbeat-relay."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from types import ModuleType
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load_script_module(name: str, rel_path: str) -> ModuleType:
    script_path = REPO_ROOT / rel_path
    loader = importlib.machinery.SourceFileLoader(name, str(script_path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


vault_setup = _load_script_module("paloma_vault_setup", "scripts/security/paloma-vault-setup")
heartbeat_relay = _load_script_module(
    "lean_mesh_heartbeat_relay", "scripts/security/lean-mesh-heartbeat-relay"
)


class _FakeHTTPResponse:
    def __init__(self, payload: dict) -> None:
        self._raw = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._raw

    def __enter__(self) -> _FakeHTTPResponse:
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


class PalomaVaultSetupTests(unittest.TestCase):
    def test_nsenter_pid1_cmd_wraps_target_mount_namespace(self) -> None:
        self.assertEqual(
            vault_setup.nsenter_pid1_cmd(["mount", "--bind", "/mnt/paloma-vault/etc-open_agent", "/etc/open_agent"]),
            [
                "nsenter",
                "-t",
                "1",
                "-m",
                "--",
                "mount",
                "--bind",
                "/mnt/paloma-vault/etc-open_agent",
                "/etc/open_agent",
            ],
        )

    def test_host_ismount_checks_pid1_mount_namespace(self) -> None:
        with mock.patch.object(vault_setup.subprocess, "run") as mock_run:
            mock_run.return_value.returncode = 0
            self.assertTrue(vault_setup.host_ismount("/etc/open_agent"))
            mock_run.assert_called_once_with(
                ["nsenter", "-t", "1", "-m", "--", "mountpoint", "-q", "/etc/open_agent"]
            )

    def test_format_bind_fstab_entry_orders_after_vault_mount(self) -> None:
        entry = vault_setup.format_bind_fstab_entry(
            "/mnt/paloma-vault/etc-open_agent", "/etc/open_agent"
        )
        self.assertEqual(
            entry,
            "/mnt/paloma-vault/etc-open_agent /etc/open_agent none "
            "bind,nofail,x-systemd.requires=/mnt/paloma-vault,x-systemd.after=/mnt/paloma-vault 0 0\n",
        )


class HeartbeatRelayTests(unittest.TestCase):
    def setUp(self) -> None:
        heartbeat_relay._jwt_cache.clear()

    def test_read_env_password_falls_back_when_first_path_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fallback = pathlib.Path(tmp) / "sandboxed-sh.env"
            fallback.write_text('OTHER=1\nDASHBOARD_PASSWORD="secret-value"\n', encoding="utf-8")
            missing = str(pathlib.Path(tmp) / "missing.env")
            self.assertEqual(
                heartbeat_relay.read_env_password((missing, str(fallback))),
                "secret-value",
            )

    def test_read_env_password_raises_when_all_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            p1 = str(pathlib.Path(tmp) / "a.env")
            p2 = str(pathlib.Path(tmp) / "b.env")
            with self.assertRaises(FileNotFoundError):
                heartbeat_relay.read_env_password((p1, p2))

    def test_jwt_cache_reused_and_refreshed_on_401(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_file = pathlib.Path(tmp) / "open_agent.env"
            env_file.write_text("DASHBOARD_PASSWORD=pw123\n", encoding="utf-8")
            paths = (str(env_file),)

            calls: list[tuple[str, str | None]] = []
            tokens = iter(["jwt-1", "jwt-2"])
            fail_first_hb = True

            def fake_urlopen(req, timeout=3):
                nonlocal fail_first_hb
                auth = req.headers.get("Authorization")
                calls.append((req.full_url, auth))
                if req.full_url.endswith("/api/auth/login"):
                    return _FakeHTTPResponse({"token": next(tokens)})
                if auth == "Bearer jwt-1" and fail_first_hb:
                    fail_first_hb = False
                    raise urllib.error.HTTPError(
                        req.full_url, 401, "Unauthorized", hdrs=None, fp=io.BytesIO(b"expired")
                    )
                return _FakeHTTPResponse({"admitted": True, "bunker_state": 0})

            with mock.patch.object(heartbeat_relay.urllib.request, "urlopen", side_effect=fake_urlopen):
                res1 = heartbeat_relay.forward_heartbeat(3000, paths, b'{"seq":1}')
                self.assertEqual(res1, {"admitted": True, "bunker_state": 0})
                # Second call should reuse cached jwt-2 without hitting /api/auth/login again
                res2 = heartbeat_relay.forward_heartbeat(3000, paths, b'{"seq":2}')
                self.assertEqual(res2, {"admitted": True, "bunker_state": 0})

            self.assertEqual(
                calls,
                [
                    ("http://127.0.0.1:3000/api/auth/login", None),
                    ("http://127.0.0.1:3000/api/mesh/heartbeat", "Bearer jwt-1"),
                    ("http://127.0.0.1:3000/api/auth/login", None),
                    ("http://127.0.0.1:3000/api/mesh/heartbeat", "Bearer jwt-2"),
                    ("http://127.0.0.1:3000/api/mesh/heartbeat", "Bearer jwt-2"),
                ],
            )

    def test_relay_returns_200_when_prod_admits_even_if_dev_down(self) -> None:
        targets = (
            (3000, ("/unused/prod.env",), True),
            (3002, ("/unused/dev.env",), False),
        )

        def fake_forward(port: int, paths: tuple[str, ...], body: bytes) -> dict:
            if port == 3000:
                return {"admitted": True, "bunker_state": 0}
            raise ConnectionRefusedError("dev offline")

        with mock.patch.object(heartbeat_relay, "forward_heartbeat", side_effect=fake_forward):
            status, results = heartbeat_relay.relay_heartbeat_payload(b"{}", targets=targets)
        self.assertEqual(status, 200)
        self.assertTrue(results["3000"]["admitted"])
        self.assertIn("error", results["3002"])

    def test_relay_returns_502_and_logs_when_prod_fails_or_rejects(self) -> None:
        targets = (
            (3000, ("/unused/prod.env",), True),
            (3002, ("/unused/dev.env",), False),
        )

        # Case 1: prod raises an error while dev succeeds -> still 502!
        def fake_forward_err(port: int, paths: tuple[str, ...], body: bytes) -> dict:
            if port == 3000:
                raise FileNotFoundError("none of ('/etc/open_agent/open_agent.env',) exist")
            return {"admitted": True}

        stderr_buf = io.StringIO()
        with (
            mock.patch.object(heartbeat_relay, "forward_heartbeat", side_effect=fake_forward_err),
            mock.patch("sys.stderr", stderr_buf),
        ):
            status, _ = heartbeat_relay.relay_heartbeat_payload(b"{}", targets=targets)
        self.assertEqual(status, 502)
        self.assertIn("[lean-mesh-heartbeat-relay] ERROR port=3000", stderr_buf.getvalue())

        # Case 2: prod responds HTTP 200 but admitted=False -> 502!
        with mock.patch.object(
            heartbeat_relay,
            "forward_heartbeat",
            return_value={"admitted": False, "reason": "bad_sig"},
        ):
            status2, _ = heartbeat_relay.relay_heartbeat_payload(b"{}", targets=targets)
        self.assertEqual(status2, 502)


if __name__ == "__main__":
    unittest.main()
