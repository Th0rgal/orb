#!/usr/bin/env python3
"""Unit tests for multi-user Linux confinement in `privd_confinement_model.py`."""
from __future__ import annotations

import base64
import os
from pathlib import Path
import tempfile
import time
import unittest

import privd_confinement_model as pcm


class MultiUserPrivdTests(unittest.TestCase):
    def test_valid_unix_username_grammar_and_denylist(self) -> None:
        self.assertTrue(pcm.valid_unix_username("orb-alice"))
        self.assertTrue(pcm.valid_unix_username("_worker_01"))
        self.assertFalse(pcm.valid_unix_username(""))
        self.assertFalse(pcm.valid_unix_username("root"))
        self.assertFalse(pcm.valid_unix_username("admin"))
        self.assertFalse(pcm.valid_unix_username("sandboxed-node"))
        self.assertFalse(pcm.valid_unix_username("orb-node"))
        self.assertFalse(pcm.valid_unix_username("-bad"))
        self.assertFalse(pcm.valid_unix_username("BadUpper"))
        self.assertFalse(pcm.valid_unix_username("a" * 32))

    def test_orb_privd_user_exec_step_gates(self) -> None:
        # Valid unprivileged member job
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 0, 0, 1, 2005, 2005, 1, 1, 1),
            1,
        )
        # Invalid caller_role (> 1) rejected
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 0, 2, 1, 2005, 2005, 1, 1, 1),
            3 << 8,
        )
        # Colocated admin-only node denies member
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 1, 0, 1, 2005, 2005, 1, 1, 1),
            4 << 8,
        )
        # UID < 2000 rejected
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 0, 0, 1, 1000, 2005, 1, 1, 1),
            6 << 8,
        )
        # Privileged supplementary group rejected
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 0, 0, 1, 2005, 2005, 0, 1, 1),
            7 << 8,
        )
        # Symlinked home rejected
        self.assertEqual(
            pcm.orb_privd_user_exec_step(1, 1, 0, 0, 1, 2005, 2005, 1, 0, 1),
            8 << 8,
        )

    def test_systemd_run_disables_env_expansion_for_fork_workspace_guard(self) -> None:
        from unittest import mock

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_root = tmp_path / "homes"
            state_dir = tmp_path / "state"
            logs_dir = tmp_path / "logs"
            mission_cwd = home_root / "orb-alice" / ".orb-missions" / "m-fork-01"
            mission_cwd.mkdir(parents=True, mode=0o700)
            (home_root / "orb-alice").chmod(0o700)
            state_dir.mkdir(mode=0o700)
            logs_dir.mkdir(mode=0o700)

            fork_cmd = (
                'fork_root=$(pwd -P); fork_root=${fork_root%/*}; '
                'fork_dir="$fork_root/23bad383-5b27-4b83-9a84-d86d34223509"; '
                '[ -d "$fork_dir" ] && [ ! -L "$fork_dir" ] || { echo "Fork workspace unavailable" >&2; exit 78; }'
            )
            captured_cmds: list[list[str]] = []

            def fake_run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                captured_cmds.append(list(cmd))
                if cmd[0] == "/usr/bin/systemd-run":
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="4321\n", stderr="")

            import subprocess

            old_env = {
                k: os.environ.get(k)
                for k in ("ORB_PRIVD_ALLOW_NONROOT_TEST", "ORB_PRIVD_HOME_ROOT", "ORB_PRIVD_STATE_DIR")
            }
            os.environ.pop("ORB_PRIVD_ALLOW_NONROOT_TEST", None)
            os.environ["ORB_PRIVD_HOME_ROOT"] = str(home_root)
            os.environ["ORB_PRIVD_STATE_DIR"] = str(state_dir)
            try:
                with (
                    mock.patch.object(pcm, "_peer_is_node_uid", return_value=True),
                    mock.patch.object(
                        pcm,
                        "_lookup_or_create_unix_user",
                        return_value=(2500, 2500, True),
                    ),
                    mock.patch.object(pcm.subprocess, "run", side_effect=fake_run),
                ):
                    res = pcm.handle_spawn_user_job(
                        {
                            "unix_username": "orb-alice",
                            "job_id": "ef7e8c9a-3cdb-4f80-9233-01162184601c",
                            "mission_id": "m-fork-01",
                            "log_path": str(logs_dir / "fork.log"),
                            "argv": ["/bin/bash", "-lc", fork_cmd],
                            "env": {"SANDBOXED_MISSION_ID": "m-fork-01"},
                        },
                        peer_uid=0,
                        peer_gid=0,
                    )
                self.assertTrue(res.get("ok"), res)
                self.assertGreaterEqual(len(captured_cmds), 1)
                sd_cmd = captured_cmds[0]
                self.assertEqual(sd_cmd[0], "/usr/bin/systemd-run")
                self.assertIn("--expand-environment=no", sd_cmd)
                self.assertLess(sd_cmd.index("--expand-environment=no"), sd_cmd.index("--"))
                self.assertEqual(sd_cmd[-1], fork_cmd)
            finally:
                for k, v in old_env.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v

    def test_nonroot_ensure_spawn_control_and_fs_confinement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_root = tmp_path / "homes"
            state_dir = tmp_path / "state"
            shared_elan = tmp_path / "elan"
            logs_dir = tmp_path / "logs"
            home_root.mkdir(mode=0o755)
            state_dir.mkdir(mode=0o700)
            (shared_elan / "bin").mkdir(parents=True, mode=0o755)
            (shared_elan / "toolchains" / "leanprover--lean4---v4.35.0").mkdir(parents=True, mode=0o755)
            (shared_elan / "bin" / "lean").write_text("#!/bin/sh\necho lean\n")
            (shared_elan / "settings.toml").write_text('default_toolchain = "v4.35.0"\n')

            old_env = {
                k: os.environ.get(k)
                for k in (
                    "ORB_PRIVD_ALLOW_NONROOT_TEST",
                    "ORB_PRIVD_HOME_ROOT",
                    "ORB_PRIVD_STATE_DIR",
                    "ORB_PRIVD_SHARED_ELAN",
                )
            }
            os.environ["ORB_PRIVD_ALLOW_NONROOT_TEST"] = "1"
            os.environ["ORB_PRIVD_HOME_ROOT"] = str(home_root)
            os.environ["ORB_PRIVD_STATE_DIR"] = str(state_dir)
            os.environ["ORB_PRIVD_SHARED_ELAN"] = str(shared_elan)
            my_uid = os.geteuid()
            my_gid = os.getegid()
            try:
                ens = pcm.handle_ensure_mission_user(
                    {
                        "unix_username": "orb-alice",
                        "mission_id": "m-alice-01",
                        "caller_role": "member",
                        "node_admin_only": False,
                        "workspace_files": [
                            {"path": "opencode.json", "content": '{"ok":true}\n'},
                        ],
                    },
                    peer_uid=my_uid,
                )
                self.assertTrue(ens.get("ok"), ens)
                alice_home = Path(ens["home_dir"])
                mission_cwd = Path(ens["mission_cwd"])
                self.assertEqual(alice_home.stat().st_mode & 0o777, 0o700)
                self.assertTrue((alice_home / ".elan" / "toolchains" / "leanprover--lean4---v4.35.0").is_symlink())
                self.assertTrue((mission_cwd / "opencode.json").is_file())

                # Reject node_admin_only for member
                rej = pcm.handle_ensure_mission_user(
                    {
                        "unix_username": "orb-alice",
                        "mission_id": "m-alice-02",
                        "caller_role": "member",
                        "node_admin_only": True,
                    },
                    peer_uid=my_uid,
                )
                self.assertFalse(rej.get("ok"))

                # Spawn confined job verifying env scrubbing
                log_file = logs_dir / "job-01.log"
                sp = pcm.handle_spawn_user_job(
                    {
                        "unix_username": "orb-alice",
                        "job_id": "job-01",
                        "mission_id": "m-alice-01",
                        "log_path": str(log_file),
                        "argv": [
                            "/bin/sh",
                            "-c",
                            'printf "MPT=%s|SECRET=%s" "$ANTHROPIC_API_KEY" "$SANDBOXED_NODE_TOKEN" > result.txt',
                        ],
                        "env": {
                            "ANTHROPIC_API_KEY": "orb-mpt-v1_tok123",
                            "SANDBOXED_NODE_TOKEN": "SHOULD_BE_SCRUBBED",
                            "LD_PRELOAD": "/tmp/evil.so",
                        },
                    },
                    peer_uid=my_uid,
                    peer_gid=my_gid,
                )
                self.assertTrue(sp.get("ok"), sp)

                done = False
                for _ in range(40):
                    st = pcm.handle_control_user_job(
                        {"op": "status", "job_id": "job-01", "unix_username": "orb-alice"},
                        peer_uid=my_uid,
                    )
                    if st.get("done"):
                        self.assertEqual(st.get("exit_code"), 0)
                        done = True
                        break
                    time.sleep(0.05)
                self.assertTrue(done)

                # Read result via user_fs_op
                rd = pcm.handle_user_fs_op(
                    {
                        "unix_username": "orb-alice",
                        "mission_id": "m-alice-01",
                        "subop": "file_browser",
                        "req_json": {"action": "read", "path": "result.txt"},
                    },
                    peer_uid=my_uid,
                )
                self.assertTrue(rd.get("ok"), rd)
                self.assertEqual(rd["result"]["content"], "MPT=orb-mpt-v1_tok123|SECRET=")

                # Symlink escape inside mission_cwd must be rejected by user_fs_op
                outside = tmp_path / "outside-secret.txt"
                outside.write_text("TOP_SECRET")
                (mission_cwd / "escape_link").symlink_to(outside)
                esc = pcm.handle_user_fs_op(
                    {
                        "unix_username": "orb-alice",
                        "mission_id": "m-alice-01",
                        "subop": "file_browser",
                        "req_json": {"action": "read", "path": "escape_link"},
                    },
                    peer_uid=my_uid,
                )
                self.assertFalse(esc.get("ok"))

                # Write via user_fs_op refuses overwriting symlink (`O_NOFOLLOW`)
                wr_esc = pcm.handle_user_fs_op(
                    {
                        "unix_username": "orb-alice",
                        "mission_id": "m-alice-01",
                        "subop": "write",
                        "rel_path": "escape_link",
                        "content_b64": base64.b64encode(b"pwned").decode("ascii"),
                    },
                    peer_uid=my_uid,
                )
                self.assertFalse(wr_esc.get("ok"))
                self.assertEqual(outside.read_text(), "TOP_SECRET")
            finally:
                for k, v in old_env.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
