import { afterEach, expect, it, vi } from "vitest";
import {
  readComposerDraft,
  readSideThread,
  resetComposerDraftsMemoryForTest,
  saveComposerDraft,
  saveSideThread,
  updateSideThread,
} from "../src/composerDrafts";

const win = window as unknown as { __ORB_DESKTOP__?: unknown };

afterEach(() => {
  delete win.__ORB_DESKTOP__;
  resetComposerDraftsMemoryForTest();
  vi.unstubAllGlobals();
});

it("reopens the newest draft before its IndexedDB write has completed", async () => {
  const open = { result: undefined, onsuccess: undefined as undefined | (() => void) };
  const get = { result: { text: "Stale disk value", images: [] }, onsuccess: undefined as undefined | (() => void) };
  const transactions: Array<{ oncomplete?: () => void }> = [];
  vi.stubGlobal("indexedDB", { open: () => open });
  open.result = { transaction: () => {
    const tx = { objectStore: () => ({ get: () => get, put: vi.fn(), delete: vi.fn() }), oncomplete: undefined as undefined | (() => void) };
    transactions.push(tx);
    return tx;
  } } as any;
  const oldRead = readComposerDraft("m:race");
  open.onsuccess!();
  await Promise.resolve();
  const write = saveComposerDraft("m:race", { text: "Newest reply", images: [] });
  await expect(readComposerDraft("m:race")).resolves.toMatchObject({ text: "Newest reply" });
  get.onsuccess!();
  await expect(oldRead).resolves.toMatchObject({ text: "Newest reply" });
  transactions[1].oncomplete!();
  await write;
  const clear = saveComposerDraft("m:race", { text: "", images: [] });
  await expect(readComposerDraft("m:race")).resolves.toMatchObject({ text: "" });
  transactions[2].oncomplete!();
  await clear;
});

it("persists drafts and side threads in orb-locald SQLite and auto-migrates IndexedDB misses", async () => {
  const sqlDrafts = new Map<string, string>();
  const idbDrafts = new Map<string, unknown>([
    ["m:legacy-idb", { text: "from indexeddb", images: [] }],
    ["thread:q-1", { count: 2 }],
  ]);
  vi.stubGlobal("indexedDB", {
    open: () => {
      const req = {
        result: {
          transaction: () => {
            const tx = {
              oncomplete: undefined as undefined | (() => void),
              objectStore: () => ({
                get: (k: string) => {
                  const greq = { result: idbDrafts.get(k), onsuccess: undefined as undefined | (() => void) };
                  queueMicrotask(() => greq.onsuccess?.());
                  return greq;
                },
                put: (v: unknown, k: string) => {
                  idbDrafts.set(k, v);
                },
                delete: (k: string) => {
                  idbDrafts.delete(k);
                },
              }),
            };
            queueMicrotask(() => tx.oncomplete?.());
            return tx;
          },
        },
        onsuccess: undefined as undefined | (() => void),
      };
      queueMicrotask(() => req.onsuccess?.());
      return req;
    },
  });

  win.__ORB_DESKTOP__ = {
    core: {
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        const key = String(args?.key ?? "");
        if (cmd === "ui_draft_get") return sqlDrafts.get(key) ?? null;
        if (cmd === "ui_draft_put") {
          const raw = String(args?.raw ?? "");
          if (raw.includes("OVERSIZED_ATTACHMENT")) {
            throw new Error("Draft exceeds 16 MiB limit");
          }
          if (args?.if_absent && sqlDrafts.has(key)) {
            return null;
          }
          sqlDrafts.set(key, raw);
          return null;
        }
        if (cmd === "ui_draft_delete") {
          sqlDrafts.delete(key);
          return null;
        }
        throw new Error(`unexpected ${cmd}`);
      },
    },
  };

  // Legacy IndexedDB draft is returned on SQLite miss and migrated to SQLite in background.
  const migrated = await readComposerDraft("m:legacy-idb");
  expect(migrated).toEqual({ text: "from indexeddb", images: [] });
  await Promise.resolve();
  expect(JSON.parse(sqlDrafts.get("m:legacy-idb") ?? "null")).toEqual({
    text: "from indexeddb",
    images: [],
  });

  // New draft writes go directly to orb-locald SQLite and survive cold reload.
  await saveComposerDraft("m:native", { mode: "plan", text: "build phase a2", images: [] });
  resetComposerDraftsMemoryForTest();
  expect(await readComposerDraft("m:native")).toEqual({
    mode: "plan",
    text: "build phase a2",
    images: [],
  });

  // Oversized draft fallback deletes any stale SQLite entry so cold read returns the IndexedDB draft.
  await saveComposerDraft("m:native", {
    mode: "plan",
    text: "updated with OVERSIZED_ATTACHMENT",
    images: [],
  });
  expect(sqlDrafts.has("m:native")).toBe(false);
  resetComposerDraftsMemoryForTest();
  expect(await readComposerDraft("m:native")).toEqual({
    mode: "plan",
    text: "updated with OVERSIZED_ATTACHMENT",
    images: [],
  });

  // Atomic side-thread update serializes concurrent updates over SQLite.
  await saveSideThread("side-a", { items: ["one"] });
  const [u1, u2] = await Promise.all([
    updateSideThread<{ items: string[] }>("side-a", (cur) => ({
      items: [...(cur?.items ?? []), "two"],
    })),
    updateSideThread<{ items: string[] }>("side-a", (cur) => ({
      items: [...(cur?.items ?? []), "three"],
    })),
  ]);
  expect(u1.updated && u2.updated).toBe(true);
  expect(await readSideThread<{ items: string[] }>("side-a")).toEqual({
    items: ["one", "two", "three"],
  });
});

it("fences background IndexedDB draft migration when a newer write or delete happens in flight", async () => {
  const sqlDrafts = new Map<string, string>();
  let finishLegacyGet!: () => void;
  vi.stubGlobal("indexedDB", {
    open: () => {
      const req = {
        result: {
          transaction: () => {
            const tx = {
              oncomplete: undefined as undefined | (() => void),
              objectStore: () => ({
                get: () => {
                  const greq = {
                    result: { text: "stale legacy draft", images: [] },
                    onsuccess: undefined as undefined | (() => void),
                  };
                  finishLegacyGet = () => {
                    greq.onsuccess?.();
                    tx.oncomplete?.();
                  };
                  return greq;
                },
                put: vi.fn(),
                delete: vi.fn(),
              }),
            };
            return tx;
          },
        },
        onsuccess: undefined as undefined | (() => void),
      };
      queueMicrotask(() => req.onsuccess?.());
      return req;
    },
  });

  win.__ORB_DESKTOP__ = {
    core: {
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        const key = String(args?.key ?? "");
        if (cmd === "ui_draft_get") return sqlDrafts.get(key) ?? null;
        if (cmd === "ui_draft_put") {
          if (args?.if_absent && sqlDrafts.has(key)) return null;
          sqlDrafts.set(key, String(args?.raw ?? ""));
          return null;
        }
        if (cmd === "ui_draft_delete") {
          sqlDrafts.delete(key);
          return null;
        }
        return null;
      },
    },
  };

  const pendingRead = readComposerDraft("m:race-mig");
  await new Promise((r) => setTimeout(r, 0));
  await saveComposerDraft("m:race-mig", { text: "NEWEST", images: [] });
  finishLegacyGet();
  await expect(pendingRead).resolves.toEqual({ text: "NEWEST", images: [] });
  await new Promise((r) => setTimeout(r, 0));
  resetComposerDraftsMemoryForTest();
  await expect(readComposerDraft("m:race-mig")).resolves.toEqual({ text: "NEWEST", images: [] });
});
