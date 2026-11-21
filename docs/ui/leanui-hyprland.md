# LeanUI window effects on Hyprland

U8 keeps the GTK/WebKit and LeanUI shells on the same compositor-facing path:

- both shells use the `orb-desktop` Wayland/XDG app id and desktop-file class;
- LeanUI presents premultiplied `ARGB8888`, so its transparent rounded corners are
  composited instead of being forced through opaque `XRGB8888`;
- live LeanUI surfaces use the WebKit Linux alphas (dark: main 94%, sidebar 78%;
  light: main 95.5%, sidebar 72%); deterministic headless goldens remain opaque;
- the package installs `share/orb-desktop/hyprland.conf` with the shared opacity,
  blur, and 12px rounding rule.

For a NixOS/home-manager Hyprland configuration, import the installed fragment:

```nix
wayland.windowManager.hyprland.extraConfig =
  builtins.readFile "${pkgs.orb-desktop}/share/orb-desktop/hyprland.conf";
```

Or include the generated file from the package in an existing Hyprland config.
Restart/reload Hyprland after changing the rule. The focused source check is:

```bash
python3 scripts/test_leanui_window_effects.py
```

## Verification limits in this checkout

This worker environment has no `WAYLAND_DISPLAY`, no `HYPRLAND_INSTANCE_SIGNATURE`,
and no `hyprctl`/Hyprland process. Therefore the required side-by-side Hyprland
screenshots could not be captured here. The PR records the exact compositor rule,
window protocol format, class, and focused source evidence; visual parity still
requires running the packaged clients in a Hyprland session.

When a saved Core session expires, the live window clears the previous account's roster. It retries in the background with bounded backoff. Saving a valid session restores the project list and reloads its model catalog in the same window.
