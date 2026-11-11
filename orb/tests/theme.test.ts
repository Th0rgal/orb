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
    expect(detectDesktopPlatform({ platform: "X11", userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15" })).toBe("linux");
    expect(detectDesktopPlatform({ platform: "", userAgent: "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/605.1.15" })).toBe("linux");
    expect(detectDesktopPlatform({ platform: "Linux armv81", userAgent: "Mozilla/5.0 (Linux; Android 15; Pixel 8)" })).toBe("other");
  });

  it("falls back to other for non-macOS, non-Linux platforms", () => {
    expect(detectDesktopPlatform({ platform: "Win32" })).toBe("other");
    expect(detectDesktopPlatform({})).toBe("other");
  });

  it("sets dataset.platform on initTheme and preserves native shell platform overrides", () => {
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
    initTheme();
    expect(document.documentElement.dataset.platform).toBe("linux");

    setThemePref("dark");
    expect(document.documentElement.dataset.platform).toBe("linux");
    expect(document.documentElement.dataset.theme).toBe("dark");
  });

  it("scopes macOS traffic-light inset strictly to macOS and defaults flush-left on Linux/other", () => {
    const css = readFileSync(resolve(__dirname, "../src/styles.css"), "utf8");
    expect(css).toMatch(
      /:root\s*\{[^}]*--sidebar-opacity:\s*76%;[^}]*--surface-opacity:\s*93\.25%;[^}]*--tb-traffic-left:\s*8px;[^}]*--tb-traffic-margin:\s*0px;/s,
    );
    expect(css).toMatch(
      /:root\[data-platform="macos"\]\s*\{[^}]*--tb-traffic-left:\s*82px;[^}]*--tb-traffic-margin:\s*70px;[^}]*\}/,
    );
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
