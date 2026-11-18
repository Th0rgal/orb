#!/usr/bin/env python3
"""Focused U8 checks for LeanUI's compositor-facing window effects."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WAYLAND = (ROOT / "lean/OrbDesktop/LeanUI/Wayland.lean").read_text()
STYLE = (ROOT / "lean/OrbDesktop/LeanUI/Style.lean").read_text()
SCREENS = (ROOT / "lean/OrbDesktop/OrbDesktop/Screens.lean").read_text()
MAIN = (ROOT / "lean/OrbDesktop/OrbDesktop/Main.lean").read_text()
PACKAGE = (ROOT / "nix/desktop.nix").read_text()
RULES = (ROOT / "nix/orb-desktop.hyprland.conf").read_text()


def main() -> None:
    assert "def wlShmFormatArgb8888 : UInt32 := 0" in WAYLAND
    assert "def rgbaToArgb" in WAYLAND
    assert "pm (c : UInt8)" in WAYLAND
    assert ".uint wlShmFormatArgb8888" in WAYLAND
    assert "rgbaToArgb fb" in WAYLAND

    assert "def withWindowEffects" in STYLE
    assert "mainAlpha : UInt32 := if t.isDark then 240 else 244" in STYLE
    assert "sidebarAlpha : UInt32 := if t.isDark then 199 else 184" in STYLE
    assert "Theme.withWindowEffects" in MAIN and "!rt.wayland.headless" in MAIN
    assert "WidgetNode.roundedClip" in SCREENS
    assert "CornerRadii.uniform (pxToSub 12)" in SCREENS

    assert "class:^(orb-desktop)$" in RULES
    assert "windowrulev2 = opacity 0.94 override 0.94 override" in RULES
    assert "windowrulev2 = blur" in RULES
    assert "windowrulev2 = rounding 12" in RULES
    assert 'install -m 0644 "$src/nix/orb-desktop.hyprland.conf"' in PACKAGE
    assert "StartupWMClass=orb-desktop" in PACKAGE

    print("LeanUI U8 window effects: focused checks passed")


if __name__ == "__main__":
    main()
