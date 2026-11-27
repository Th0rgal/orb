#!/usr/bin/env python3
"""Focused U8 checks for LeanUI's compositor-facing window effects and badges."""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WAYLAND = (ROOT / "lean/OrbDesktop/LeanUI/Wayland.lean").read_text()
STYLE = (ROOT / "lean/OrbDesktop/LeanUI/Style.lean").read_text()
SCREENS = (ROOT / "lean/OrbDesktop/OrbDesktop/Screens.lean").read_text()
CHROME = (ROOT / "lean/OrbDesktop/OrbDesktop/Chrome.lean").read_text()
MAIN = (ROOT / "lean/OrbDesktop/OrbDesktop/Main.lean").read_text()
VK_PIPE = (ROOT / "lean/OrbDesktop/LeanUI/VulkanPipeline.lean").read_text()
CSS = (ROOT / "orb/src/styles.css").read_text()
PACKAGE = (ROOT / "nix/desktop.nix").read_text()
RULES = (ROOT / "nix/orb-desktop.hyprland.conf").read_text()


def main() -> None:
    # Premultiplied ARGB8888 wl_shm surface presentation
    assert "def wlShmFormatArgb8888 : UInt32 := 0" in WAYLAND
    assert ".uint wlShmFormatArgb8888" in WAYLAND
    assert "FFI.presentArgb (shm.ptr + offset.toUSize) fb" in WAYLAND

    # Surface opacity matches orb/src/styles.css [data-platform="linux"]
    linux_dark = re.search(r':root\[data-platform="linux"\]\s*\{([^}]*)\}', CSS, re.S)
    linux_light = re.search(r':root\[data-platform="linux"\]\[data-theme="light"\]\s*\{([^}]*)\}', CSS, re.S)
    assert linux_dark and "--sidebar-opacity: 78%;" in linux_dark.group(1)
    assert "--surface-opacity: 100%;" in linux_dark.group(1)
    assert linux_light and "--sidebar-opacity: 72%;" in linux_light.group(1)
    assert "--surface-opacity: 100%;" in linux_light.group(1)

    assert "def withWindowEffects" in STYLE
    assert "mainAlpha : UInt32 := 255" in STYLE
    assert "sidebarAlpha : UInt32 := if t.isDark then 199 else 184" in STYLE
    assert "Theme.withWindowEffects" in MAIN and "!rt.wayland.headless" in MAIN

    # 12px rounded window corners preserved on base shell, overlays, and backdrop blur
    assert "WidgetNode.roundedClip" in SCREENS
    assert "CornerRadii.uniform (pxToSub 12)" in SCREENS
    assert "roundedClipIdx := curRClip" in VK_PIPE
    assert "#[.layerPush 255] ++ inner ++ #[.clipPushRounded winClipRect winRadii, .layerPop, .clipPop]" in MAIN

    # 60-step active spinner & active/paused/idle badge parity
    assert "def liveSpinnerPhase" in CHROME
    assert "liveSpinnerPhase (← IO.monoMsNow)" in MAIN
    assert "match status.toLower with" in CHROME
    assert '"canceled"' in CHROME
    assert 'chromeIcon "mission" pal.textMuted' in CHROME

    # Hyprland orb-desktop window class, vibrancy blur, solid 1.0 override, and 12px rounding
    assert "class:^(orb-desktop)$" in RULES
    assert "vibrancy = 0.25" in RULES
    assert "vibrancy_darkness = 0.25" in RULES
    assert "ignore_opacity = true" in RULES
    assert "windowrulev2 = opacity 1.0 override 1.0 override, class:^(orb-desktop)$" in RULES
    assert "windowrulev2 = rounding 12, class:^(orb-desktop)$" in RULES
    assert 'install -m 0644 "$src/nix/orb-desktop.hyprland.conf"' in PACKAGE
    assert "StartupWMClass=orb-desktop" in PACKAGE
    assert 'Runtime.openWindowRuntime rcfg "orb-desktop"' in MAIN

    print("LeanUI U8 window effects: focused checks passed")


if __name__ == "__main__":
    main()
