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
RULES_LUA = (ROOT / "nix/orb-desktop.hyprland.lua").read_text()


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
    # The frosted sidebar tints with the raw --bg-sidebar tokens, not a pre-composited colour.
    light_root = re.search(r':root\[data-theme="light"\]\s*\{([^}]*)\}', CSS, re.S)
    assert light_root and "--bg-sidebar: #f6f6f4;" in light_root.group(1)
    assert "--bg-sidebar: #121313;" in CSS and "sidebar         := 0x121313FF" in STYLE
    assert "if t.isDark then t.palette.sidebar else 0xF6F6F4FF" in STYLE
    assert "Theme.withWindowEffects" in MAIN and "!rt.wayland.headless" in MAIN

    # 12px rounded window corners preserved on base shell, overlays, and backdrop blur
    assert "WidgetNode.roundedClip" in SCREENS
    assert "CornerRadii.uniform (pxToSub 12)" in SCREENS
    assert "roundedClipIdx := curRClip" in VK_PIPE
    assert "#[.clipPushRounded winClipRect winRadii, .layerPush 255] ++ inner ++ #[.layerPop, .clipPop]" in MAIN
    assert "windowEffects && !(st.modal matches .searchPalette _)" in SCREENS

    # 60-step active spinner & active/paused/idle badge parity
    assert "def liveSpinnerPhase" in CHROME
    assert "liveSpinnerPhase (← IO.monoMsNow)" in MAIN
    assert "match status.toLower with" in CHROME
    assert '"canceled"' in CHROME
    assert 'chromeIcon "mission" pal.textMuted' in CHROME

    # Hyprland orb-desktop window class, solid 1.0 override and 12px rounding, scoped to
    # the orb-desktop class in both config languages. `windowrulev2` has been a hard
    # config error since Hyprland 0.54 and the hyprlang parser is gone in 0.57, so the
    # package ships a hyprlang `windowrule` (0.53 - 0.56) and a Lua rule (0.57+).
    conf_lines = [l.strip() for l in RULES.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    assert conf_lines == [
        "windowrule = match:class ^(orb-desktop)$, opacity 1.0 override 1.0 override, rounding 12"
    ], conf_lines
    lua_code = "\n".join(l for l in RULES_LUA.splitlines() if not l.lstrip().startswith("--"))
    lua_flat = re.sub(r"\s+", " ", lua_code).strip()
    assert lua_flat == (
        'hl.window_rule({ name = "orb-desktop", match = { class = "^(orb-desktop)$" }, '
        'opacity = "1.0 override 1.0 override", rounding = 12, })'
    ), lua_flat
    # A package fragment must never retune the whole compositor (global blur block) or
    # use the removed rule keyword.
    for text in (RULES, RULES_LUA):
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith(("#", "--")))
        assert "windowrulev2" not in code
        assert "decoration" not in code and "blur" not in code and "hl.config" not in code
    assert 'install -m 0644 "$src/nix/orb-desktop.hyprland.conf" "$out/share/orb-desktop/hyprland.conf"' in PACKAGE
    assert 'install -m 0644 "$src/nix/orb-desktop.hyprland.lua" "$out/share/orb-desktop/hyprland.lua"' in PACKAGE
    assert "StartupWMClass=orb-desktop" in PACKAGE
    assert 'Runtime.openWindowRuntime rcfg "orb-desktop"' in MAIN

    print("LeanUI U8 window effects: focused checks passed")


if __name__ == "__main__":
    main()
