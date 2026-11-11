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

    // Oversized write fails in orb-locald without permanently poisoning native cache invoke,
    // and writes a `{}` tombstone so no stale native entry can shadow IndexedDB fallback.
    await savePersistedTranscript("scope-c", "m-huge", { text: "oversized-entry" });
    expect(disk.get("transcript:scope-c::m:m-huge")).toBe("{}");

    // Subsequent normal writes still use orb-locald.
    await savePersistedTranscript("scope-c", "m-valid-2", { text: "still uses locald" });
    expect(disk.size).toBe(3);

    // Sign-out clear still invokes ui_cache_clear and wipes ~/.orb/ui-cache.
    await clearPersistentCache();
    expect(calls.filter((c) => c === "ui_cache_clear")).toHaveLength(1);
    expect(disk.size).toBe(0);
  });

  it("consults IndexedDB when native cache misses or when an oversized update falls back to IndexedDB", async () => {
    const idbStores: Record<string, Map<string, unknown>> = {
      sidebar: new Map(),
      transcripts: new Map(),
    };
    const origIndexedDB = globalThis.indexedDB;
    const fakeDb = {
      objectStoreNames: { contains: (name: string) => name in idbStores },
      createObjectStore: (name: string) => {
        idbStores[name] ??= new Map();
        return { createIndex: () => {} };
      },
      transaction: (_names: string | string[], _mode: string) => {
        const tx: Record<string, unknown> = {
          oncomplete: null as (() => void) | null,
          onerror: null,
          onabort: null,
          objectStore: (name: string) => ({
            get: (key: string) => {
              const req = { result: idbStores[name].get(key), onsuccess: null as (() => void) | null, onerror: null };
              queueMicrotask(() => req.onsuccess?.());
              return req;
            },
            put: (record: { scope?: string; id?: string }) => {
              const k = name === "sidebar" ? String(record.scope) : String(record.id);
              idbStores[name].set(k, structuredClone(record));
            },
            clear: () => {
              idbStores[name].clear();
            },
            delete: (key: string) => {
              idbStores[name].delete(String(key));
            },
            index: () => ({
              getAllKeys: () => {
                const req = { result: [...idbStores[name].keys()], onsuccess: null as (() => void) | null };
                queueMicrotask(() => req.onsuccess?.());
                return req;
              },
            }),
          }),
        };
        queueMicrotask(() => (tx.oncomplete as (() => void) | null)?.());
        return tx;
      },
    };
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: {
        open: () => {
          const req = { result: fakeDb, onupgradeneeded: null, onsuccess: null as (() => void) | null, onerror: null, onblocked: null };
          queueMicrotask(() => req.onsuccess?.());
          return req;
        },
      },
    });

    try {
      // 1. Seed pre-upgrade IndexedDB cache before native bridge is attached.
      await savePersistedSidebar("scope-idb", {
        missions: [{ id: "legacy-m" }],
        projects: [{ slug: "legacy-proj" }],
      });
      await savePersistedTranscript("scope-idb", "legacy-m", { text: "from pre-upgrade idb" });
      resetPersistentCacheMemoryForTest();

      // 2. Attach native bridge with empty `~/.orb/ui-cache` -> native miss falls through to IndexedDB!
      const disk = new Map<string, string>();
      win.__ORB_DESKTOP__ = {
        core: {
          invoke: async (cmd: string, args?: Record<string, unknown>) => {
            if (cmd === "ui_cache_put") {
              const raw = String(args?.raw ?? "");
              if (raw.includes("oversized-v2")) throw new Error("UI cache payload exceeds 8 MiB limit");
              disk.set(`${args?.kind}:${args?.key}`, raw);
              return null;
            }
            if (cmd === "ui_cache_get") return disk.get(`${args?.kind}:${args?.key}`) ?? null;
            if (cmd === "ui_cache_clear") {
              disk.clear();
              return null;
            }
            throw new Error(`unexpected ${cmd}`);
          },
        },
      };

      const sb = await loadPersistedSidebar<{ id: string }, { slug: string }>("scope-idb");
      expect(sb?.missions).toEqual([{ id: "legacy-m" }]);
      expect(await loadPersistedTranscript<{ text: string }>("scope-idb", "legacy-m")).toEqual({
        text: "from pre-upgrade idb",
      });

      // 3. Save v1 in native cache, then grow past 8 MiB in v2 -> tombstone invalidates v1 so cold reload reads v2 from IndexedDB!
      await savePersistedTranscript("scope-idb", "grew-m", { text: "small-v1" });
      await savePersistedTranscript("scope-idb", "grew-m", { text: "oversized-v2" });
      resetPersistentCacheMemoryForTest();
      expect(await loadPersistedTranscript<{ text: string }>("scope-idb", "grew-m")).toEqual({
        text: "oversized-v2",
      });
    } finally {
      Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: origIndexedDB });
    }
  });
});
