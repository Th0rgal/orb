import { createEffect, createRoot } from "solid-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  flushDesktopPrefs,
  initDesktopPrefs,
  isSharedDesktopPrefKey,
  pullDesktopPrefs,
  resetDesktopPrefsForTest,
} from "../src/desktopPrefs";
import { jsonSignal, readJson, resetStorageCache } from "../src/storage";

describe("desktopPrefs shared prod/dev settings sync", () => {
  afterEach(() => {
    resetDesktopPrefsForTest();
    resetStorageCache();
    localStorage.clear();
    delete (window as unknown as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__;
  });

  it("filters transient caches, outboxes, session state, API URL, and JWT while keeping UI settings", () => {
    expect(isSharedDesktopPrefKey("orb-theme")).toBe(true);
    expect(isSharedDesktopPrefKey("orb.approval.graceSecs")).toBe(true);
    expect(isSharedDesktopPrefKey("orb:background-sync-mode")).toBe(true);
    expect(isSharedDesktopPrefKey("orb.btw:v1:[\"https://orbcore.thomas.md\",\"prod\",\"settings:inbox\"]")).toBe(true);
    expect(isSharedDesktopPrefKey("orb.btw:v1:[\"https://orbcore.thomas.md\",\"prod\",\"settings:btw\"]")).toBe(true);
    expect(isSharedDesktopPrefKey("orb.btw:v1:[\"https://orbcore.thomas.md\",\"prod\",\"inbox-state:outbox:v1\"]")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.btw:v1:[\"https://orbcore.thomas.md\",\"prod\",\"mission-123\"]")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.inbox.client.v1")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.inbox.sequence.v1")).toBe(false);
    expect(isSharedDesktopPrefKey("orb:inbox-digest:v7")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.selectedConversation")).toBe(false);
    expect(isSharedDesktopPrefKey("followups:orb.btw:v1:[\"https://orbcore.thomas.md\",\"prod\",\"queue\"]")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.jwt")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.apiUrl")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.catalog:123:/api/projects")).toBe(false);
    expect(isSharedDesktopPrefKey("orb.software.inventory.v1:x")).toBe(false);
  });

  it("hydrates shared settings, seeds missing local keys, and reacts to live updates in real time", async () => {
    Object.defineProperty(window, "matchMedia", {
      writable: true,
      value: (query: string) => ({
        matches: false,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
      }),
    });

    const disk: Record<string, string> = {
      "orb-theme": "light",
      "orb.approval.graceSecs": "600",
    };
    let diskRev = "rev-1";

    const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "desktop_prefs_load") {
        if (args?.since_rev === diskRev) return { unchanged: true, rev: diskRev };
        return { unchanged: false, rev: diskRev, prefs: { ...disk } };
      }
      if (cmd === "desktop_prefs_patch") {
        const rem = (args?.remove as string[] | undefined) ?? [];
        for (const k of rem) delete disk[k];
        const setObj = (args?.set as Record<string, string> | undefined) ?? {};
        for (const [k, v] of Object.entries(setObj)) {
          if (isSharedDesktopPrefKey(k)) disk[k] = v;
        }
        diskRev = `rev-${Object.keys(disk).length}-${disk["orb-theme"] ?? ""}-${disk["orb.files.width"] ?? ""}-${disk["orb.concurrent.remote"] ?? ""}`;
        return { rev: diskRev, prefs: { ...disk } };
      }
      if (cmd === "set_window_theme") return null;
      if (cmd === "desktop_connection_load") return null;
      return undefined;
    });

    (window as unknown as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__ = { core: { invoke } };

    // Pre-existing local setting + excluded keys before initDesktopPrefs:
    localStorage.setItem("orb.files.width", "540");
    localStorage.setItem("orb.jwt", "secret-jwt");
    localStorage.setItem("orb.apiUrl", "https://orbcore.thomas.md");
    localStorage.setItem("orb.catalog:1:/api/projects", "[]");

    await initDesktopPrefs();

    // Hydrated from shared disk + seeded local key back to disk (without leaking jwt/apiUrl/catalog):
    expect(localStorage.getItem("orb-theme")).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(localStorage.getItem("orb.approval.graceSecs")).toBe("600");
    expect(disk["orb.files.width"]).toBe("540");
    expect(disk["orb.jwt"]).toBeUndefined();
    expect(disk["orb.apiUrl"]).toBeUndefined();
    expect(disk["orb.catalog:1:/api/projects"]).toBeUndefined();

    // Concurrent external write before local flush must not be skipped when patch advances rev:
    disk["orb.concurrent.remote"] = "seen";
    diskRev = "rev-concurrent-before-flush";
    localStorage.setItem("orb.voice.lang", "fr");
    await flushDesktopPrefs();
    expect(disk["orb.voice.lang"]).toBe("fr");
    expect(localStorage.getItem("orb.concurrent.remote")).toBe("seen");

    // Track reactive SolidJS readers (`readJson` + `jsonSignal`) while prod client mutates disk:
    const observedHarness: string[] = [];
    let picked!: () => { mode: string };
    const dispose = createRoot((d) => {
      const [sig] = jsonSignal("orb.pick", { mode: "fast" });
      picked = sig;
      createEffect(() => {
        const cfg = readJson<{ harness?: string }>("orb.btw.cfg", { harness: "opencode" });
        observedHarness.push(cfg.harness ?? "opencode");
      });
      return d;
    });

    try {
      expect(observedHarness).toEqual(["opencode"]);
      expect(picked().mode).toBe("fast");

      // Simulate prod Orb changing theme, btw config, and jsonSignal on shared disk:
      disk["orb-theme"] = "dark";
      disk["orb.btw.cfg"] = JSON.stringify({ harness: "claudecode" });
      disk["orb.pick"] = JSON.stringify({ mode: "deep" });
      delete disk["orb.voice.lang"];
      diskRev = "rev-external-2";

      await pullDesktopPrefs(false);

      expect(localStorage.getItem("orb-theme")).toBe("dark");
      expect(document.documentElement.dataset.theme).toBe("dark");
      expect(localStorage.getItem("orb.voice.lang")).toBeNull();
      expect(observedHarness).toEqual(["opencode", "claudecode"]);
      expect(picked().mode).toBe("deep");
    } finally {
      dispose();
    }
  });

  it("preserves oversized local values and serializes overlapping client flushes in order", async () => {
    Object.defineProperty(window, "matchMedia", {
      writable: true,
      value: (query: string) => ({
        matches: false,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
      }),
    });

    const disk: Record<string, string> = { "orb-theme": "dark" };
    let revCounter = 1;
    let inFlightPatches = 0;
    let maxConcurrentPatches = 0;
    let releaseFirstPatch: (() => void) | null = null;

    const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "desktop_prefs_load") {
        return { unchanged: false, rev: `r-${revCounter}`, prefs: { ...disk } };
      }
      if (cmd === "desktop_prefs_patch") {
        inFlightPatches++;
        maxConcurrentPatches = Math.max(maxConcurrentPatches, inFlightPatches);
        if (releaseFirstPatch === null) {
          await new Promise<void>((resolve) => {
            releaseFirstPatch = resolve;
          });
        }
        try {
          const setObj = (args?.set as Record<string, string> | undefined) ?? {};
          for (const [k, v] of Object.entries(setObj)) {
            if (isSharedDesktopPrefKey(k) && new TextEncoder().encode(v).byteLength <= 65_536) {
              disk[k] = v;
            }
          }
          revCounter++;
          return { rev: `r-${revCounter}`, prefs: { ...disk } };
        } finally {
          inFlightPatches--;
        }
      }
      if (cmd === "set_window_theme" || cmd === "desktop_connection_load") return null;
      return undefined;
    });

    (window as unknown as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__ = { core: { invoke } };

    const hugeValue = "x".repeat(70_000);
    localStorage.setItem("orb.hugePref", hugeValue);

    await initDesktopPrefs();
    expect(localStorage.getItem("orb.hugePref")).toBe(hugeValue);
    expect(disk["orb.hugePref"]).toBeUndefined();

    // Start first flush and mutate the same key again before the first RPC finishes:
    localStorage.setItem("orb.voiceLang", "en");
    const firstFlush = flushDesktopPrefs();
    await Promise.resolve();

    localStorage.setItem("orb.voiceLang", "fr");
    const secondFlush = flushDesktopPrefs();

    releaseFirstPatch!();
    await Promise.all([firstFlush, secondFlush]);

    expect(maxConcurrentPatches).toBe(1);
    expect(disk["orb.voiceLang"]).toBe("fr");
    expect(localStorage.getItem("orb.voiceLang")).toBe("fr");
    expect(localStorage.getItem("orb.hugePref")).toBe(hugeValue);

    // Failed patch must stay queued so a subsequent external poll retries instead of overwriting it:
    let failNextPatch = true;
    invoke.mockImplementation(async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "desktop_prefs_load") {
        return { unchanged: false, rev: `r-${revCounter}`, prefs: { ...disk } };
      }
      if (cmd === "desktop_prefs_patch") {
        if (failNextPatch) {
          failNextPatch = false;
          throw new Error("lock busy");
        }
        const setObj = (args?.set as Record<string, string> | undefined) ?? {};
        for (const [k, v] of Object.entries(setObj)) disk[k] = v;
        revCounter++;
        return { rev: `r-${revCounter}`, prefs: { ...disk } };
      }
      if (cmd === "set_window_theme" || cmd === "desktop_connection_load") return null;
      return undefined;
    });

    localStorage.setItem("orb.voiceLang", "de");
    await flushDesktopPrefs();
    // Disk still has "fr", and another client also updates "orb-theme" to "light":
    disk["orb-theme"] = "light";
    revCounter++;

    await pullDesktopPrefs(false);
    expect(disk["orb.voiceLang"]).toBe("de");
    expect(localStorage.getItem("orb.voiceLang")).toBe("de");
    expect(localStorage.getItem("orb-theme")).toBe("light");
  });
});
