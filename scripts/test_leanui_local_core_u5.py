#!/usr/bin/env python3
"""Named U5 checks for LeanUI's real local-Core bootstrap path."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "lean/OrbDesktop/OrbDesktop/Core.lean").read_text()
MAIN = (ROOT / "lean/OrbDesktop/OrbDesktop/Main.lean").read_text()
SCRIPT = (ROOT / "scripts/orb_desktop_dev.sh").read_text()


def test_live_core_bootstrap_reads_saved_connection() -> None:
    assert "~/.orb/connection.json" in CORE
    assert "/api/projects" in CORE
    assert "/api/control/missions?limit=200" in CORE
    assert "/api/machines" in CORE
    assert "Authorization':'Bearer '+tok" in CORE
    assert "/api/control/stream" in CORE


def test_normal_launch_uses_live_state_and_goldens_keep_fixtures() -> None:
    assert "loadLiveState" in MAIN
    assert "dcfg.screenOpt.isNone && !dcfg.selfTest" in MAIN
    assert "DesktopState.forScreen" in MAIN
    assert 'exec "$STAGE_BIN_DIR/orb-desktop-native"' in SCRIPT


if __name__ == "__main__":
    test_live_core_bootstrap_reads_saved_connection()
    test_normal_launch_uses_live_state_and_goldens_keep_fixtures()
    print("LeanUI U5 local-Core bootstrap: named checks passed")
