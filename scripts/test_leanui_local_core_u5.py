#!/usr/bin/env python3
"""Check the launcher/embedding contract; tests/test_live_delivery.py exercises the wire."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lean/OrbDesktop/OrbDesktop/Core.lean").read_text()
MAIN = (ROOT / "lean/OrbDesktop/OrbDesktop/Main.lean").read_text()
SCRIPT = (ROOT / "scripts/orb_desktop_dev.sh").read_text()


def test_live_core_bootstrap_reads_saved_connection() -> None:
    transport = ROOT / 'lean/OrbDesktop/OrbDesktop/live_transport.py'
    assert 'include_str "live_transport.py"' in CORE
    # Run the embedded helper in isolation with a temporary HOME. An explicit
    # missing ORB_STATE_DIR must not fall back to another user's saved token.
    with tempfile.TemporaryDirectory() as home:
        state = Path(home) / '.orb'
        state.mkdir()
        (state / 'connection.json').write_text('{"api_url":"https://example.invalid","token":"test-only"}')
        code = transport.read_text() + '\nassert credentials() == ("https://example.invalid", "test-only")'
        env = {**os.environ, 'HOME': home, 'ORB_STATE_DIR': ''}
        subprocess.run([sys.executable, '-I', '-c', code], env=env, check=True)
        code = transport.read_text() + '\ntry: credentials()\nexcept FileNotFoundError: pass\nelse: sys.exit(1)'
        subprocess.run([sys.executable, '-I', '-c', code], env={**env, 'ORB_STATE_DIR': home}, check=True)


def test_normal_launch_uses_live_state_and_goldens_keep_fixtures() -> None:
    assert "initialRosterPending := true" in MAIN and "withLiveSources" in MAIN
    assert "dcfg.screenOpt.isNone && !dcfg.selfTest" in MAIN
    assert "DesktopState.forScreen" in MAIN
    assert 'exec "$STAGE_BIN_DIR/orb-desktop-native"' in SCRIPT


if __name__ == "__main__":
    test_live_core_bootstrap_reads_saved_connection()
    test_normal_launch_uses_live_state_and_goldens_keep_fixtures()
    print("LeanUI U5 local-Core bootstrap: named checks passed")
