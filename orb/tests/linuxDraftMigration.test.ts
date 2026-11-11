import { describe, expect, it, vi } from "vitest";
import {
  decodeMigratedValue,
  mergeMigratedRecord,
  migrateLinux1431Drafts,
} from "../src/linuxDraftMigration";

function stubInMemoryDraftsDb(seed: Record<string, unknown> = {}) {
  const storeData = new Map<string, unknown>(Object.entries(seed));
  const open = () => {
    const req: Record<string, unknown> = {
      result: undefined,
      error: null,
      onupgradeneeded: undefined as undefined | (() => void),
      onsuccess: undefined as undefined | (() => void),
      onerror: undefined as undefined | (() => void),
    };
    queueMicrotask(() => {
      const db = {
        objectStoreNames: { contains: (name: string) => name === "drafts" },
        createObjectStore: vi.fn(),
        close: vi.fn(),
        transaction: () => {
          const tx: Record<string, unknown> = {
            error: null,
            oncomplete: undefined as undefined | (() => void),
            onerror: undefined as undefined | (() => void),
            onabort: undefined as undefined | (() => void),
            objectStore: () => ({
              get: (key: string) => {
                const getReq: Record<string, unknown> = {
                  result: storeData.get(key),
                  onsuccess: undefined as undefined | (() => void),
                };
                queueMicrotask(() => (getReq.onsuccess as (() => void) | undefined)?.());
                return getReq;
              },
              put: (val: unknown, key: string) => {
                storeData.set(key, val);
              },
            }),
          };
          setTimeout(() => (tx.oncomplete as (() => void) | undefined)?.(), 0);
          return tx;
        },
      };
      req.result = db;
      (req.onsuccess as (() => void) | undefined)?.();
    });
    return req;
  };
  return { storeData, indexedDB: { open } };
}

describe("linuxDraftMigration", () => {
  it("decodes File, Blob, Uint8Array, ArrayBuffer, and Date payloads", async () => {
    const decoded = decodeMigratedValue({
      text: "hello",
      file: {
        __orb_t: "File",
        name: "note.txt",
        type: "text/plain",
        lastModified: 1700000000000,
        b64: btoa("abc"),
      },
      bytes: { __orb_t: "Uint8Array", b64: btoa("xyz") },
      when: { __orb_t: "Date", iso: "2026-11-11T12:00:00.000Z" },
    }) as {
      text: string;
      file: File;
      bytes: Uint8Array;
      when: Date;
    };
    expect(decoded.text).toBe("hello");
    expect(decoded.file).toBeInstanceOf(File);
    expect(decoded.file.name).toBe("note.txt");
    expect(decoded.file.size).toBe(3);
    const fileText = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.onerror = () => reject(reader.error);
      reader.readAsText(decoded.file);
    });
    expect(fileText).toBe("abc");
    expect(Array.from(decoded.bytes)).toEqual([120, 121, 122]);
    expect(decoded.when.toISOString()).toBe("2026-11-11T12:00:00.000Z");
  });

  it("merges legacy 1431 drafts and side-question history without clobbering newer tauri://localhost entries", async () => {
    const nonce = "a".repeat(64);
    const { storeData, indexedDB } = stubInMemoryDraftsDb({
      "m:newer": { text: "newer draft on tauri://localhost", images: [] },
      "thread:local-queue:u1": [{ id: "q-new", text: "new" }],
      "thread:local-queue:u1:tombstones": ["q-dropped"],
      "thread:local-queue:u1:wake-stops": { m1: { token: "t-new", blocked: false } },
    });
    vi.stubGlobal("indexedDB", indexedDB);
    let replacedUrl = "";
    const calls: Array<{ url: string; method: string }> = [];
    const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push({ url, method: init?.method ?? "GET" });
      if (url.includes("/__orb_migrate_pull")) {
        return new Response(
          JSON.stringify({
            entries: [
              ["m:legacy", { text: "saved on 1431", images: [] }],
              ["m:newer", { text: "older 1431 copy", images: [] }],
              ["thread:side-question:m1", { question: "old side thread", answer: "42" }],
              [
                "thread:local-queue:u1",
                [
                  { id: "q-new", text: "stale" },
                  { id: "q-legacy", text: "from 1431" },
                ],
              ],
              ["thread:local-queue:u1:tombstones", ["q-old-drop", "q-dropped"]],
              [
                "thread:local-queue:u1:wake-stops",
                {
                  m1: { token: "t-old", blocked: true },
                  m2: { token: "t-m2", blocked: true },
                },
              ],
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response(null, { status: 204 });
    }) as unknown as typeof fetch;

    try {
      const ok = await migrateLinux1431Drafts({
        search: `?migrate_1431=${nonce}`,
        replaceUrl: url => {
          replacedUrl = url;
        },
        fetchImpl,
      });
      expect(ok).toBe(true);
      expect(replacedUrl).toBe("/");
      expect(storeData.get("m:legacy")).toEqual({ text: "saved on 1431", images: [] });
      expect(storeData.get("m:newer")).toEqual({ text: "newer draft on tauri://localhost", images: [] });
      expect(storeData.get("thread:side-question:m1")).toEqual({
        question: "old side thread",
        answer: "42",
      });
      expect(storeData.get("thread:local-queue:u1")).toEqual([
        { id: "q-new", text: "new" },
        { id: "q-legacy", text: "from 1431" },
      ]);
      expect(storeData.get("thread:local-queue:u1:tombstones")).toEqual(["q-old-drop", "q-dropped"]);
      expect(storeData.get("thread:local-queue:u1:wake-stops")).toEqual({
        m1: { token: "t-new", blocked: false },
        m2: { token: "t-m2", blocked: true },
      });
      expect(calls).toEqual([
        { url: `http://127.0.0.1:1431/__orb_migrate_pull?nonce=${nonce}`, method: "GET" },
        { url: `http://127.0.0.1:1431/__orb_migrate_ack?nonce=${nonce}`, method: "POST" },
      ]);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("does not ack when pull fails so migration retries on a later launch", async () => {
    const nonce = "b".repeat(64);
    const calls: string[] = [];
    const ok = await migrateLinux1431Drafts({
      search: `?migrate_1431=${nonce}`,
      replaceUrl: () => {},
      fetchImpl: (async (input: RequestInfo | URL) => {
        calls.push(String(input));
        return new Response("busy", { status: 503 });
      }) as typeof fetch,
    });
    expect(ok).toBe(false);
    expect(calls).toEqual([`http://127.0.0.1:1431/__orb_migrate_pull?nonce=${nonce}`]);
    expect(mergeMigratedRecord("m:1", { text: "a" }, undefined)).toEqual({
      write: true,
      value: { text: "a" },
    });
  });
});
