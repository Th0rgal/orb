import { nativeInvoke } from "./native";
export type ThemePref = "auto" | "light" | "dark";
export type DesktopPlatform = "macos" | "linux" | "other";

const KEY = "orb-theme";

export function detectDesktopPlatform(
  nav: { platform?: string; userAgent?: string; userAgentData?: { platform?: string } } | undefined =
    typeof navigator === "undefined" ? undefined : navigator,
): DesktopPlatform {
  const ua = nav?.userAgent || "";
  const raw = nav?.userAgentData?.platform || nav?.platform || ua;
  if (/mac|iphone|ipad|ipod/i.test(raw)) return "macos";
  if (/linux/i.test(raw) && !/android/i.test(ua) && !/android/i.test(raw)) return "linux";
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
  document.documentElement.dataset.theme = resolved(pref);
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
  document.documentElement.dataset.platform = detectDesktopPlatform();
  apply(getThemePref());
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
    if (getThemePref() === "auto") apply("auto");
  });
}
