#!/usr/bin/env python3
"""Linux starts the GTK/WebKit client by default; LeanUI only with --leanui.

LeanUI renders the parity screens from fixtures but does not load real data or
handle input yet (roadmap U5-U9), so it must not be what Orb opens by default.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/orb_desktop_dev.sh").read_text()
PACKAGE = (ROOT / "nix/desktop.nix").read_text()


def main() -> None:
    assert "USE_WEBKIT=1" in SCRIPT
    assert '"${1:-}" == "--leanui"' in SCRIPT
    assert ".orb-desktop-unwrapped" not in SCRIPT, "the installed launcher must start orb-webkit"
    pkg_default = PACKAGE.strip().split('[[ "\'\'${1:-}" == "--webkit" ]] && shift')[1]
    assert 'exec "$(dirname "$0")/orb-webkit"' in pkg_default
    assert '"--leanui"' in PACKAGE
    print("linux desktop selection: WebKit default, LeanUI explicit --leanui")


if __name__ == "__main__":
    main()
