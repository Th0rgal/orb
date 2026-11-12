import { afterEach, describe, expect, it } from "vitest";
import {
  clearPersistentCache,
  loadPersistedSidebar,
  loadPersistedTranscript,
  loadPersistedTranscriptSlice,
  loadPersistedTranscriptTail,
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
            if (cmd === "ui_cache_put_transcript" || cmd === "ui_cache_get_tail" || cmd === "ui_cache_get_slice") {
              throw new Error("unknown desktop command");
            }
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

  it("reconciles and compacts hot native disk transcripts across simulated app restarts", async () => {
    const disk = new Map<string, { savedAt: number; tier: string; raw: string }>();
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "ui_cache_put_transcript" || cmd === "ui_cache_get_tail") {
            throw new Error("unknown desktop command");
          }
          if (cmd === "ui_cache_put") {
            const kind = String(args?.kind ?? "");
            const key = String(args?.key ?? "");
            const savedAt = Number(args?.saved_at ?? 0);
            const raw = String(args?.raw ?? "");
            const tier = args?.tier === "warm" || raw === "{}" ? "warm" : "hot";
            disk.set(`${kind}:${key}`, { savedAt, tier, raw });
            if (kind === "transcript") {
              const txEntries = [...disk.entries()]
                .filter(([k]) => k.startsWith("transcript:"))
                .map(([k, v]) => ({ key: k.slice("transcript:".length), ...v }))
                .sort((a, b) => a.savedAt - b.savedAt);
              const warmEnd = Math.max(0, txEntries.length - 32);
              const demoteKeys = txEntries
                .slice(0, warmEnd)
                .filter((e) => e.tier === "hot")
                .map((e) => e.key);
              if (demoteKeys.length > 0) return { demote_keys: demoteKeys };
            }
            return null;
          }
          if (cmd === "ui_cache_get") {
            return disk.get(`${args?.kind}:${args?.key}`)?.raw ?? null;
          }
          if (cmd === "ui_cache_clear") {
            disk.clear();
            return null;
          }
          throw new Error(`unexpected ${cmd}`);
        },
      },
    };

    const bigToolOutput = "X".repeat(2048);
    const makeHotSnap = (idx: number) => ({
      fromLog: true,
      cursor: 2,
      items: [
        { kind: "user", key: `u-${idx}`, text: `Prompt ${idx}` },
        { kind: "work", key: `w-${idx}`, entries: [{ kind: "tool", id: `tc-${idx}`, name: "bash", result: bigToolOutput }] },
        { kind: "text", key: `a-${idx}`, text: `Answer ${idx}` },
      ],
      stream: [
        { type: "user_message", sequence: 1, data: { id: `u-${idx}`, content: `Prompt ${idx}` } },
        { type: "tool_result", sequence: 2, data: { tool_call_id: `tc-${idx}`, result: bigToolOutput } },
        { type: "assistant_message", sequence: 3, data: { id: `a-${idx}`, content: `Answer ${idx}`, success: true } },
      ],
    });

    for (let i = 0; i < 20; i++) {
      await savePersistedTranscript("scope-restart", `s1-${i}`, makeHotSnap(i));
    }
    resetPersistentCacheMemoryForTest();
    for (let i = 0; i < 20; i++) {
      await savePersistedTranscript("scope-restart", `s2-${i}`, makeHotSnap(100 + i));
    }
    const hotEntries = [...disk.values()].filter((v) => v.tier === "hot");
    const warmEntries = [...disk.values()].filter((v) => v.tier === "warm");
    expect(hotEntries).toHaveLength(32);
    expect(warmEntries).toHaveLength(8);

    resetPersistentCacheMemoryForTest();
    const oldest = await loadPersistedTranscript<{
      activityCompacted?: boolean;
      stream: Array<{ type: string }>;
      items: Array<{ kind: string; entries?: Array<{ result?: string }> }>;
    }>("scope-restart", "s1-0");
    expect(oldest?.activityCompacted).toBe(true);
    expect(oldest?.stream.map((e) => e.type)).toEqual(["user_message", "assistant_message"]);
    expect(oldest?.items.find((it) => it.kind === "work")?.entries?.[0]?.result?.length).toBe(256);

    await clearPersistentCache();
    resetPersistentCacheMemoryForTest();
    for (let i = 0; i < 32; i++) {
      await savePersistedTranscript("scope-race", `r-${i}`, makeHotSnap(i));
    }
    let release33!: () => void;
    const gate33 = new Promise<void>((resolve) => {
      release33 = resolve;
    });
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === "ui_cache_put_transcript" || cmd === "ui_cache_get_tail") {
            throw new Error("unknown desktop command");
          }
          if (cmd === "ui_cache_put") {
            const kind = String(args?.kind ?? "");
            const key = String(args?.key ?? "");
            const savedAt = Number(args?.saved_at ?? 0);
            const raw = String(args?.raw ?? "");
            const tier = args?.tier === "warm" || raw === "{}" ? "warm" : "hot";
            if (key === "scope-race::m:r-32") await gate33;
            const prev = disk.get(`${kind}:${key}`);
            if (!prev || prev.savedAt <= savedAt) {
              disk.set(`${kind}:${key}`, { savedAt, tier, raw });
            }
            return null;
          }
          if (cmd === "ui_cache_get") return disk.get(`${args?.kind}:${args?.key}`)?.raw ?? null;
          if (cmd === "ui_cache_clear") {
            disk.clear();
            return null;
          }
          throw new Error(`unexpected ${cmd}`);
        },
      },
    };
    const save33 = savePersistedTranscript("scope-race", "r-32", makeHotSnap(32));
    await savePersistedTranscript("scope-race", "r-0", makeHotSnap(999));
    release33();
    await save33;

    resetPersistentCacheMemoryForTest();
    const latestR0 = await loadPersistedTranscript<{
      items: Array<{ kind: string; text?: string }>;
      stream: Array<{ type: string }>;
    }>("scope-race", "r-0");
    expect(latestR0?.items.find((it) => it.kind === "text")?.text).toBe("Answer 999");
    expect(latestR0?.stream.map((e) => e.type)).toEqual(["user_message", "tool_result", "assistant_message"]);
  });

  it("loads only the tail slice on cold open and pages older slices upward from orb-locald SQLite", async () => {
    const meta = new Map<string, { savedAt: number; totalEvents: number; headRaw: string }>();
    const eventsByKey = new Map<string, string[]>();
    win.__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          const rk = `${args?.scope}::m:${args?.mission_id}`;
          if (cmd === "ui_cache_put_transcript") {
            const startIdx = Number(args?.start_idx ?? 0);
            const evs = (args?.events_raw as string[]) ?? [];
            const prev = startIdx > 0 ? (eventsByKey.get(rk) ?? []).slice(0, startIdx) : [];
            const merged = [...prev, ...evs];
            eventsByKey.set(rk, merged);
            meta.set(rk, {
              savedAt: Number(args?.saved_at ?? 0),
              totalEvents: merged.length,
              headRaw: String(args?.head_raw ?? "{}"),
            });
            return null;
          }
          if (cmd === "ui_cache_get_tail") {
            const m = meta.get(rk);
            if (!m) return null;
            const limit = Number(args?.tail_limit ?? 3);
            const all = eventsByKey.get(rk) ?? [];
            const startIdx = Math.max(0, all.length - limit);
            return {
              saved_at: m.savedAt,
              total_events: all.length,
              start_idx: startIdx,
              head_raw: m.headRaw,
              events_raw: all.slice(startIdx),
            };
          }
          if (cmd === "ui_cache_get_slice") {
            const all = eventsByKey.get(rk);
            if (!all) return null;
            const beforeIdx = Number(args?.before_idx ?? 0);
            const limit = Number(args?.limit ?? 3);
            const startIdx = Math.max(0, beforeIdx - limit);
            return {
              start_idx: startIdx,
              events_raw: all.slice(startIdx, beforeIdx),
            };
          }
          if (cmd === "ui_cache_clear") {
            meta.clear();
            eventsByKey.clear();
            return null;
          }
          throw new Error(`unexpected ${cmd}`);
        },
      },
    };

    const fullStream = Array.from({ length: 10 }, (_, i) => ({
      type: "assistant_message",
      sequence: i + 1,
      data: { content: `msg-${i}` },
    }));
    await savePersistedTranscript("scope-tail", "m-tail", {
      fromLog: true,
      cursor: 10,
      hasOlder: false,
      items: [],
      settledItems: [{ kind: "text", key: "huge-digest", text: "x".repeat(4096) }],
      settledSeq: 10,
      openTailEvents: [],
      stream: fullStream,
    });

    expect(meta.get("scope-tail::m:m-tail")?.headRaw).not.toContain("huge-digest");
    expect(meta.get("scope-tail::m:m-tail")?.headRaw).not.toContain("settledItems");

    resetPersistentCacheMemoryForTest();

    const tail = await loadPersistedTranscriptTail<{
      fromLog: boolean;
      cursor: number;
      stream: Array<{ sequence: number }>;
    }>("scope-tail", "m-tail", 3);
    expect(tail?.startIdx).toBe(7);
    expect(tail?.totalEvents).toBe(10);
    expect(tail?.snapshot.stream.map((e) => e.sequence)).toEqual([8, 9, 10]);

    // Appending a new live event on top of a tail-hydrated snapshot preserves `0..6`!
    await savePersistedTranscript(
      "scope-tail",
      "m-tail",
      {
        fromLog: true,
        cursor: 11,
        hasOlder: false,
        items: [],
        stream: [
          ...tail!.snapshot.stream,
          { type: "assistant_message", sequence: 11, data: { content: "msg-10" } },
        ],
      },
      { startIdx: tail!.startIdx },
    );

    const older = await loadPersistedTranscriptSlice<{ sequence: number }>(
      "scope-tail",
      "m-tail",
      7,
      4,
    );
    expect(older?.startIdx).toBe(3);
    expect(older?.events.map((e) => e.sequence)).toEqual([4, 5, 6, 7]);
  });
});
