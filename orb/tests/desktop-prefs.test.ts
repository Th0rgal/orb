import { createEffect, createRoot } from "solid-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { getApiUrl, getJwt } from "../src/api";
import {
  getBackgroundSyncMode,
  isBackgroundSyncActive,
  onBackgroundSyncActiveChange,
  resetBackgroundSyncMonitorForTest,
} from "../src/backgroundSync";
import { approvalGraceSecs } from "../src/deviceApproval";
import {
  flushDesktopPrefs,
  initDesktopPrefs,
  isSharedDesktopPrefKey,
  pullDesktopPrefs,
  resetDesktopPrefsForTest,
} from "../src/desktopPrefs";
import { jsonSignal, readJson, resetStorageCache } from "../src/storage";
import { voiceLanguage } from "../src/voice";

describe("desktopPrefs shared prod/dev settings sync", () => {
  afterEach(() => {
    resetDesktopPrefsForTest();
    resetStorageCache();
    localStorage.clear();
    resetBackgroundSyncMonitorForTest();
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
      "orb.approvalGraceSecs": "600",
      "orb.voiceLang": "ja",
      "orb:background-sync-mode": "off",
    };
    let diskRev = "rev-1";

    const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === "desktop_prefs_load") {
        if (args?.since_rev === diskRev) return { unchanged: true, exists: true, rev: diskRev };
        return { unchanged: false, exists: true, rev: diskRev, prefs: { ...disk } };
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

    const activeTransitions: boolean[] = [];
    const unsubscribeBgSync = onBackgroundSyncActiveChange(() => {
      activeTransitions.push(isBackgroundSyncActive());
    });

    await initDesktopPrefs();

    // Hydrated from shared disk + module-owned signals + seeded local key back to disk:
    expect(localStorage.getItem("orb-theme")).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(localStorage.getItem("orb.approvalGraceSecs")).toBe("600");
    expect(approvalGraceSecs()).toBe(600);
    expect(voiceLanguage()).toBe("ja");
    expect(getBackgroundSyncMode()).toBe("off");
    expect(isBackgroundSyncActive()).toBe(false);
    expect(activeTransitions).toEqual([false]);
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

      // Simulate prod Orb changing theme, voice language, approval grace, background sync, btw config, and jsonSignal on shared disk:
      disk["orb-theme"] = "dark";
      disk["orb.voiceLang"] = "es";
      disk["orb.approvalGraceSecs"] = "0";
      disk["orb:background-sync-mode"] = "on";
      disk["orb.btw.cfg"] = JSON.stringify({ harness: "claudecode" });
      disk["orb.pick"] = JSON.stringify({ mode: "deep" });
      delete disk["orb.voice.lang"];
      diskRev = "rev-external-2";

      await pullDesktopPrefs(false);

      expect(localStorage.getItem("orb-theme")).toBe("dark");
      expect(document.documentElement.dataset.theme).toBe("dark");
      expect(voiceLanguage()).toBe("es");
      expect(approvalGraceSecs()).toBe(0);
      expect(getBackgroundSyncMode()).toBe("on");
      expect(isBackgroundSyncActive()).toBe(true);
      expect(activeTransitions).toEqual([false, true]);
      expect(localStorage.getItem("orb.voice.lang")).toBeNull();
      expect(observedHarness).toEqual(["opencode", "claudecode"]);
      expect(picked().mode).toBe("deep");
    } finally {
      unsubscribeBgSync();
      dispose();
    }

    // Reopening an already-migrated client must not resurrect a preference removed on disk while closed:
    resetDesktopPrefsForTest();
    delete disk["orb.files.width"];
    diskRev = "rev-removed-while-closed";
    await initDesktopPrefs();
    expect(localStorage.getItem("orb.files.width")).toBeNull();
    expect(disk["orb.files.width"]).toBeUndefined();
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

  it("retries initialization after a transient load failure while preserving local edits and syncing connection", async () => {
    vi.useFakeTimers();
    try {
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
        "orb-theme": "dark",
        "orb:background-sync-mode": "off",
      };
      let loadFails = true;
      let sharedConn: { api_url?: string; token?: string } | null = null;
      let patchCount = 0;

      const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
        if (cmd === "desktop_prefs_load") {
          if (loadFails) throw new Error("daemon starting up");
          return { unchanged: false, exists: true, rev: "r-recovered", prefs: { ...disk } };
        }
        if (cmd === "desktop_prefs_patch") {
          patchCount++;
          const setObj = (args?.set as Record<string, string> | undefined) ?? {};
          for (const [k, v] of Object.entries(setObj)) disk[k] = v;
          return { rev: `r-patched-${patchCount}`, prefs: { ...disk } };
        }
        if (cmd === "desktop_connection_load") return sharedConn;
        if (cmd === "desktop_connection_save") return null;
        if (cmd === "set_window_theme") return null;
        return undefined;
      });

      (window as unknown as { __ORB_DESKTOP__?: unknown }).__ORB_DESKTOP__ = { core: { invoke } };

      // Pre-existing local preference + local edit during transient failure:
      localStorage.setItem("orb.files.width", "480");

      await initDesktopPrefs();
      expect(localStorage.getItem("orb.files.width")).toBe("480");
      expect(patchCount).toBe(0);

      // While ui-prefs load is still failing, user edits a preference and prod client updates connection:
      localStorage.setItem("orb.voiceLang", "it");
      expect(patchCount).toBe(0);
      sharedConn = { api_url: "https://orbcore.thomas.md", token: "jwt-from-prod" };

      await pullDesktopPrefs(true);
      expect(getApiUrl()).toBe("https://orbcore.thomas.md");
      expect(getJwt()).toBe("jwt-from-prod");
      expect(localStorage.getItem("orb.voiceLang")).toBe("it");

      // Daemon recovers; scheduled retry timer hydrates remote prefs and flushes pending local edits:
      loadFails = false;
      await vi.advanceTimersByTimeAsync(1_300);

      expect(localStorage.getItem("orb-theme")).toBe("dark");
      expect(document.documentElement.dataset.theme).toBe("dark");
      expect(getBackgroundSyncMode()).toBe("off");
      expect(isBackgroundSyncActive()).toBe(false);
      expect(disk["orb.files.width"]).toBe("480");
      expect(disk["orb.voiceLang"]).toBe("it");
      expect(localStorage.getItem("orb.voiceLang")).toBe("it");
    } finally {
      vi.useRealTimers();
    }
  });
});
