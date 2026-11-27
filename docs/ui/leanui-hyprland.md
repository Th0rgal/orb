# LeanUI window effects on Hyprland

U8 keeps the GTK/WebKit (`--webkit`), hybrid (`--leanui-hybrid`), and pure LeanUI (`--leanui`) shells on the same compositor-facing path:

- all Linux shells use the `orb-desktop` Wayland/XDG `app_id` (`xdg_toplevel.set_app_id("orb-desktop")`) and `StartupWMClass=orb-desktop`;
- LeanUI presents premultiplied `ARGB8888` on `wl_shm` and `VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR` on Vulkan 1.3 WSI, so its 12px rounded window corners and frosted sidebar are composited cleanly over Hyprland Kawase blur instead of opaque `XRGB8888`;
- live LeanUI surfaces match the WebKit/hybrid Linux palette (`orb/src/styles.css` `[data-platform="linux"]`): frosted sidebar (`78%` = `199/255` dark, `72%` = `184/255` light) and solid `100%` (`255/255`) main surface; deterministic headless goldens remain opaque;
- 12px rounded corners are preserved across the base shell, context menus, error toasts, and the `Ctrl+K` search modal with its backdrop blur (via rounded-clipped `layerPop` on both CPU and Vulkan 1.3 GPU);
- live mission status badges match WebKit/hybrid: 60-step smooth active spinner (`liveSpinnerPhase`, 1 rev/s), crisp paused bars, check/clock/alert icons, case-insensitive status normalization, and the plain mission icon for ready (`awaiting_user`, `awaiting_approval`) and idle rows;
- the package installs `share/orb-desktop/hyprland.conf` with the Hyprland vibrancy blur parameters (`size = 10`, `passes = 3`, `vibrancy = 0.25`, `vibrancy_darkness = 0.25`, `ignore_opacity = true`), `opacity 1.0 override`, and `rounding 12` for `class:^(orb-desktop)$`.

For a NixOS/home-manager Hyprland configuration, import the installed fragment:

```nix
wayland.windowManager.hyprland.extraConfig =
  builtins.readFile "${pkgs.orb-desktop}/share/orb-desktop/hyprland.conf";
```

Or include the generated file from the package in an existing Hyprland config.
Restart/reload Hyprland after changing the rule.

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
