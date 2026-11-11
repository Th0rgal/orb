import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { detectDesktopPlatform, initTheme, setThemePref } from "../src/theme";

describe("detectDesktopPlatform", () => {
  it("detects macOS across WebKit and Chromium platform hints", () => {
    expect(detectDesktopPlatform({ platform: "MacIntel" })).toBe("macos");
    expect(detectDesktopPlatform({ userAgentData: { platform: "macOS" } })).toBe("macos");
  });

  it("detects Linux desktop shells while excluding Android user agents", () => {
    expect(detectDesktopPlatform({ platform: "Linux aarch64", userAgent: "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/605.1.15" })).toBe("linux");
    expect(detectDesktopPlatform({ platform: "Linux x86_64", userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0.0.0" })).toBe("linux");
    expect(detectDesktopPlatform({ platform: "Linux armv81", userAgent: "Mozilla/5.0 (Linux; Android 15; Pixel 8)" })).toBe("other");
  });

  it("falls back to other for non-macOS, non-Linux platforms", () => {
    expect(detectDesktopPlatform({ platform: "Win32" })).toBe("other");
    expect(detectDesktopPlatform({})).toBe("other");
  });

  it("sets dataset.platform on initTheme and preserves explicit platform overrides on setThemePref", () => {
    Object.defineProperty(window, "matchMedia", {
      writable: true,
      value: (query: string) => ({
        matches: false,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
      }),
    });
    delete document.documentElement.dataset.platform;
    initTheme();
    expect(document.documentElement.dataset.platform).toBeTruthy();

    document.documentElement.dataset.platform = "linux";
    setThemePref("dark");
    expect(document.documentElement.dataset.platform).toBe("linux");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("tunes Linux frosted translucency, translucent active/hover pills, and removes macOS traffic-light gap", () => {
    const css = readFileSync(resolve(__dirname, "../src/styles.css"), "utf8");
    expect(css).toMatch(/--tb-traffic-left:\s*82px;/);
    expect(css).toMatch(/--tb-traffic-margin:\s*70px;/);
    expect(css).toMatch(/:root\s*\{[^}]*--sidebar-opacity:\s*76%;[^}]*--surface-opacity:\s*93\.25%;/s);
    expect(css).toMatch(/:root\[data-theme="light"\]\s*\{[^}]*--sidebar-opacity:\s*60%;[^}]*--surface-opacity:\s*94\.75%;/s);
    expect(css).toMatch(
      /:root\[data-platform="linux"\]\s*\{[^}]*--sidebar-opacity:\s*78%;[^}]*--surface-opacity:\s*94%;[^}]*--bg-active:\s*color-mix\([^;]*transparent\);[^}]*--tb-traffic-left:\s*8px;[^}]*--tb-traffic-margin:\s*0px;[^}]*\}/,
    );
    expect(css).toMatch(
      /:root\[data-platform="linux"\]\[data-theme="light"\]\s*\{[^}]*--sidebar-opacity:\s*72%;[^}]*--surface-opacity:\s*95\.5%;[^}]*--bg-active:\s*color-mix\([^;]*transparent\);[^}]*\}/,
    );
    expect(css).not.toMatch(/\.settings-view\s+\.sidebar\s*\{\s*background:\s*var\(--bg-sidebar\)/);
  });
});
