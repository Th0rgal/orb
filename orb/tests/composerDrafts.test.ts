import { expect, it, vi } from "vitest";
import { readComposerDraft, saveComposerDraft } from "../src/composerDrafts";

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
  try {
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
  } finally { vi.unstubAllGlobals(); }
});
