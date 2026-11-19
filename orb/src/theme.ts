import { nativeInvoke } from "./native";
export type ThemePref = "auto" | "light" | "dark";
export type DesktopPlatform = "macos" | "linux" | "other";

const KEY = "orb-theme";

export function detectDesktopPlatform(
  nav: { platform?: string; userAgent?: string; userAgentData?: { platform?: string } } | undefined =
    typeof navigator === "undefined" ? undefined : navigator,
): DesktopPlatform {
  const ua = nav?.userAgent || "";
  const hint = `${nav?.userAgentData?.platform || ""} ${nav?.platform || ""} ${ua}`.trim();
  if (/mac|iphone|ipad|ipod/i.test(hint)) return "macos";
  if (/linux/i.test(hint) && !/android/i.test(hint)) return "linux";
  return "other";
}

export function getThemePref(): ThemePref {
  const v = localStorage.getItem(KEY);
  return v === "light" || v === "dark" ? v : "auto";
}

function resolved(pref: ThemePref): "light" | "dark" {
  if (pref !== "auto") return pref;
  return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

function apply(pref: ThemePref) {
  if (!document.documentElement.dataset.platform) {
    document.documentElement.dataset.platform = detectDesktopPlatform();
  }
  const theme = resolved(pref);
  document.documentElement.dataset.theme = theme;
  // The Linux GTK shell draws its sidebar natively and needs the resolved theme.
  try {
    (window as { webkit?: { messageHandlers?: { orbNative?: { postMessage(m: unknown): void } } } })
      .webkit?.messageHandlers?.orbNative?.postMessage({ command: "set_window_theme", args: { theme } });
  } catch {
    // No native chrome (browser preview, macOS uses the invoke bridge below).
  }
  // `withGlobalTauri` is enabled in tauri.conf.json. Keep this optional so
  // the same bundle remains a faithful web preview instead of requiring a
  // desktop-only import at startup.
  const invoke = nativeInvoke();
  void invoke?.("set_window_theme", { theme: pref }).catch(() => {
    // The browser preview and older desktop shells have no native bridge.
  });
}

export function setThemePref(pref: ThemePref) {
  localStorage.setItem(KEY, pref);
  apply(pref);
}

export function initTheme() {
  const pre = document.documentElement.dataset.platform;
  if (pre !== "macos" && pre !== "linux" && pre !== "other") {
    document.documentElement.dataset.platform = detectDesktopPlatform();
  }
  apply(getThemePref());
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
    if (getThemePref() === "auto") apply("auto");
  });
}
