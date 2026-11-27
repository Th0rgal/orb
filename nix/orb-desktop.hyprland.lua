-- Orb's Linux desktop surface parity rule for Hyprland 0.57+ (Lua config, U8).
-- Hyprland 0.53 - 0.56 with a hyprlang config uses orb-desktop.hyprland.conf
-- (installed as share/orb-desktop/hyprland.conf) instead.
--
-- Both GTK/WebKit (--webkit / --leanui-hybrid) and pure --leanui use the
-- orb-desktop Wayland app_id/class; per-pixel premultiplied alpha provides the
-- frosted sidebar (78% dark / 72% light) and solid 100% main pane without
-- multiplying window-wide opacity.
--
-- This fragment only touches windows whose class is orb-desktop. It relies on the
-- compositor's own decoration.blur settings (enabled by default); the optional
-- blur tuning is documented in docs/ui/leanui-hyprland.md and is never forced here.
hl.window_rule({
    name     = "orb-desktop",
    match    = { class = "^(orb-desktop)$" },
    opacity  = "1.0 override 1.0 override",
    rounding = 12,
})
