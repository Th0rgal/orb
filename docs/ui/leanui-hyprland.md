# LeanUI window effects on Hyprland

U8 keeps the GTK/WebKit (`--webkit`), hybrid (`--leanui-hybrid`), and pure LeanUI (`--leanui`) shells on the same compositor-facing path:

- all Linux shells use the `orb-desktop` Wayland/XDG `app_id` (`xdg_toplevel.set_app_id("orb-desktop")`) and `StartupWMClass=orb-desktop`;
- LeanUI presents premultiplied `ARGB8888` on `wl_shm` and `VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR` on Vulkan 1.3 WSI, so its 12px rounded window corners and frosted sidebar are composited cleanly over Hyprland Kawase blur instead of opaque `XRGB8888`;
- live LeanUI surfaces match the WebKit/hybrid Linux palette (`orb/src/styles.css` `[data-platform="linux"]`): frosted sidebar (`78%` = `199/255` dark, `72%` = `184/255` light) and solid `100%` (`255/255`) main surface; deterministic headless goldens remain opaque;
- 12px rounded corners are preserved across the base shell, context menus, error toasts, and the `Ctrl+K` search modal with its backdrop blur (the blurred layer is clipped once, where it is composited, on both CPU and Vulkan 1.3 GPU);
- live mission status badges match WebKit/hybrid: 60-step smooth active spinner (`liveSpinnerPhase`, 1 rev/s), crisp paused bars, check/clock/alert icons, case-insensitive status normalization, and the plain mission icon for ready (`awaiting_user`, `awaiting_approval`) and idle rows;
- the package installs class-scoped Hyprland rules (`opacity 1.0 override 1.0 override` and `rounding 12` for the `orb-desktop` class) in both config languages: `share/orb-desktop/hyprland.conf` (hyprlang) and `share/orb-desktop/hyprland.lua` (Lua). They touch only `orb-desktop` windows and leave the compositor's global blur settings alone.

## Hyprland rule fragments

Pick the fragment for the installed Hyprland version:

| Hyprland | Config language | Fragment |
| --- | --- | --- |
| 0.57 and newer | Lua only (`hyprland.lua`; the hyprlang parser was removed) | `share/orb-desktop/hyprland.lua`: `hl.window_rule({ name = "orb-desktop", match = { class = "^(orb-desktop)$" }, opacity = "1.0 override 1.0 override", rounding = 12 })` |
| 0.55 - 0.56 | Lua preferred, hyprlang still loaded | either fragment, matching the config file in use |
| 0.53 - 0.54 | hyprlang | `share/orb-desktop/hyprland.conf`: `windowrule = match:class ^(orb-desktop)$, opacity 1.0 override 1.0 override, rounding 12` |
| 0.52 and older | hyprlang, previous rule syntax | not shipped; write `windowrule = opacity 1.0 override 1.0 override, class:^(orb-desktop)$` and `windowrule = rounding 12, class:^(orb-desktop)$` by hand |

`windowrulev2` is not accepted on Hyprland 0.53 and later: 0.53 dropped the keyword and 0.54+ reports it as a config error.

With Home Manager, `extraConfig` is appended to the generated file for both `configType` values, so read the fragment that matches it:

```nix
# configType = "lua" (Hyprland 0.57+, the default from stateVersion 26.05)
wayland.windowManager.hyprland.extraConfig =
  builtins.readFile "${pkgs.orb-desktop}/share/orb-desktop/hyprland.lua";

# configType = "hyprlang" (Hyprland 0.53 - 0.56)
wayland.windowManager.hyprland.extraConfig =
  builtins.readFile "${pkgs.orb-desktop}/share/orb-desktop/hyprland.conf";
```

Without Home Manager, load the installed file from the existing config: `dofile("<prefix>/share/orb-desktop/hyprland.lua")` in `hyprland.lua`, or `source = <prefix>/share/orb-desktop/hyprland.conf` in `hyprland.conf`. Reload Hyprland after changing the rule.

The fragments were checked against the Hyprland sources at tags v0.53.0, v0.54.0, v0.55.0, v0.56.0 and v0.57.0 (rule parser, Lua `hl.window_rule` effect table, whose `rounding` range is 0-20 before 0.57), not against a running compositor.

### Optional blur tuning

Blur is enabled by default in Hyprland and the frosted sidebar works with the default settings. The values below are the ones the U8 captures simulate (Kawase blur with vibrancy). They are global `decoration:blur` options that affect every window on the desktop, which is why the package fragments do not set them. Copy them into your own config only if you want that look everywhere:

```lua
-- Hyprland 0.57+ (hyprland.lua)
hl.config({
    decoration = {
        blur = {
            enabled = true, size = 10, passes = 3, ignore_opacity = true,
            contrast = 0.85, brightness = 0.98, noise = 0.014,
            vibrancy = 0.25, vibrancy_darkness = 0.25,
        },
    },
})
```

```ini
# Hyprland 0.53 - 0.56 (hyprland.conf)
decoration {
    blur {
        enabled = true
        size = 10
        passes = 3
        ignore_opacity = true
        contrast = 0.85
        brightness = 0.98
        noise = 0.014
        vibrancy = 0.25
        vibrancy_darkness = 0.25
    }
}
```

## Verification commands

```bash
python3 scripts/test_leanui_window_effects.py
(cd lean/OrbDesktop && lake env lean --run tests/WindowEffects.lean)
target/native/orb-desktop-native --self-test
ORB_LEANUI_TEST_BINARY="$PWD/target/native/orb-desktop-native" \
  python3 -IB lean/OrbDesktop/tests/test_u8_window_effects_parity.py -v
```

`tests/WindowEffects.lean` verifies the pure Lean U8 contracts (`Theme.withWindowEffects` alphas, `liveBadgeKind` normalization, `liveSpinnerPhase` 60-step cadence, and `liveMissionLead` paths/Bot fallback). `orb-desktop-native --self-test` (`windowEffectsSelfTest`) verifies CPU and Vulkan 1.3 GPU readback parity on live window-effects scenes (sidebar transparency, solid main surface, 12px rounded corners including modal backdrop blur, active 4-quadrant spinner, stationary paused bars, `awaiting_user` Bot fallback, and 0-pixel-diff pure vs hybrid `EmbeddedSidebar` parity). `tests/test_u8_window_effects_parity.py` drives the compiled `orb-desktop-native` binary against a real AF_UNIX Wayland compositor and disposable local Core fixture to capture live premultiplied `ARGB8888` frames, assert `xdg_toplevel.set_app_id("orb-desktop")`, verify 60-step spinner rotation and paused badge pixels, and generate side-by-side vibrancy-blurred captures comparing pure `--leanui` against the hybrid/WebKit reference.

When a saved Core session expires, the live window clears the previous account's roster. It retries in the background with bounded backoff. Saving a valid session restores the project list and reloads its model catalog in the same window.
