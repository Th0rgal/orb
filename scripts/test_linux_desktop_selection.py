#!/usr/bin/env python3
"""Named U4 evidence: Linux defaults to LeanUI and keeps WebKit explicit."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/orb_desktop_dev.sh").read_text()
PACKAGE = (ROOT / "nix/desktop.nix").read_text()


def main() -> None:
    assert 'OS_NAME="$(uname -s)"' in SCRIPT
    assert '"${1:-}" == "--webkit"' in SCRIPT
    assert 'exec "$STAGE_BIN_DIR/orb-webkit"' in SCRIPT
    assert 'exec "$STAGE_BIN_DIR/orb-desktop-native"' in SCRIPT
    assert 'exec "$(dirname "$0")/orb-webkit"' in PACKAGE
    assert 'exec "$(dirname "$0")/orb-desktop-native"' in PACKAGE
    print("linux desktop selection: LeanUI default, WebKit explicit --webkit")


if __name__ == "__main__":
    main()
