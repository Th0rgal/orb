import { afterEach, describe, expect, it } from "vitest";
import {
  clearPersistentCache,
  loadPersistedSidebar,
  loadPersistedTranscript,
  resetPersistentCacheMemoryForTest,
  savePersistedSidebar,
  savePersistedTranscript,
} from "../src/persistentCache";

describe("persistentCache native orb-locald bridge", () => {
  const win = window as unknown as { __ORB_DESKTOP__?: unknown };

  afterEach(() => {
    delete win.__ORB_DESKTOP__;
    resetPersistentCacheMemoryForTest();
  });

  it("persists and reloads sidebar + transcripts via orb-locald ui_cache_* without IndexedDB", async () => {
    const disk = new Map<string, string>();
    const calls: string[] = [];
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          calls.push(cmd);
          if (cmd === "ui_cache_put") {
            disk.set(`${args?.kind}:${args?.key}`, String(args?.raw ?? ""));
            return null;
          }
          if (cmd === "ui_cache_get") {
            return disk.get(`${args?.kind}:${args?.key}`) ?? null;
          }
          if (cmd === "ui_cache_clear") {
            disk.clear();
            return null;
          }
          throw new Error(`unexpected ${cmd}`);
        },
      },
    };

    await savePersistedSidebar("scope-a", {
      missions: [{ id: "m1" }],
      completedMissions: [{ id: "m0" }],
      projects: [{ slug: "orb" }],
    });
    await savePersistedTranscript("scope-a", "m1", { items: [{ kind: "text", key: "t1", text: "hi" }] });

    // Simulate cold start by dropping in-memory cache while preserving simulated orb-locald disk.
    resetPersistentCacheMemoryForTest();

    const sb = await loadPersistedSidebar<{ id: string }, { slug: string }>("scope-a");
    expect(sb?.missions).toEqual([{ id: "m1" }]);
    expect(sb?.projects).toEqual([{ slug: "orb" }]);

    const tx = await loadPersistedTranscript<{ items: Array<{ text: string }> }>("scope-a", "m1");
    expect(tx?.items[0]?.text).toBe("hi");

    await clearPersistentCache();
    expect(disk.size).toBe(0);
    expect(await loadPersistedTranscript("scope-a", "m1")).toBeNull();
    expect(calls).toContain("ui_cache_put");
    expect(calls).toContain("ui_cache_get");
    expect(calls).toContain("ui_cache_clear");
  });

  it("degrades gracefully when orb-locald rejects unknown commands", async () => {
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async () => {
          throw new Error("unknown desktop command");
        },
      },
    };

    await savePersistedTranscript("scope-b", "m2", { ok: true });
    expect(await loadPersistedTranscript<{ ok: boolean }>("scope-b", "m2")).toEqual({ ok: true });
    resetPersistentCacheMemoryForTest();
    expect(await loadPersistedTranscript("scope-b", "m2")).toBeNull();
  });

  it("does not disable orb-locald cache or skip sign-out wipe after an oversized payload error", async () => {
    const disk = new Map<string, string>();
    const calls: string[] = [];
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          calls.push(cmd);
          if (cmd === "ui_cache_put") {
            const raw = String(args?.raw ?? "");
            if (raw.includes("oversized-entry")) {
              throw new Error("UI cache payload exceeds 8 MiB limit");
            }
            disk.set(`${args?.kind}:${args?.key}`, raw);
            return null;
          }
          if (cmd === "ui_cache_get") {
            return disk.get(`${args?.kind}:${args?.key}`) ?? null;
          }
          if (cmd === "ui_cache_clear") {
            disk.clear();
            return null;
          }
          throw new Error(`unexpected ${cmd}`);
        },
      },
    };

    await savePersistedTranscript("scope-c", "m-valid", { text: "persisted on disk" });
    expect(disk.size).toBe(1);

    // Oversized write fails in orb-locald without permanently poisoning native cache invoke.
    await savePersistedTranscript("scope-c", "m-huge", { text: "oversized-entry" });
    expect(disk.size).toBe(1);

    // Subsequent normal writes still use orb-locald.
    await savePersistedTranscript("scope-c", "m-valid-2", { text: "still uses locald" });
    expect(disk.size).toBe(2);

    // Sign-out clear still invokes ui_cache_clear and wipes ~/.orb/ui-cache.
    await clearPersistentCache();
    expect(calls.filter((c) => c === "ui_cache_clear")).toHaveLength(1);
    expect(disk.size).toBe(0);
  });
});
