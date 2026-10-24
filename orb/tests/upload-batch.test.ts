import { describe, expect, it, vi } from "vitest";
import { createRoot } from "solid-js";
import { batchTotals, createFolderUpload, folderPathFromResults, localFolderPath, sourcesFromDataTransfer, splitSources } from "../src/uploadBatch";
import type { UploadSource } from "../src/uploads";

const src = (relativePath: string): UploadSource => ({ name: relativePath.split("/").at(-1)!, relativePath });

describe("folder uploads", () => {
  it("groups by top folder, keeps loose files, skips junk and shared-context exclusions", () => {
    const split = splitSources([
      { name: "loose.pdf" }, src("Aulas/a.pdf"), src("Aulas/sub/b.pdf"), src("Aulas/.DS_Store"),
      src("Aulas/node_modules/x/i.js"), src("Aulas/.env"), src("Outra/c.txt"),
    ], "context:p");
    expect(split.files.map(f => f.name)).toEqual(["loose.pdf"]);
    expect(split.folders.map(f => [f.root, f.sources.map(s => s.relativePath)])).toEqual([["Aulas", ["Aulas/a.pdf", "Aulas/sub/b.pdf"]], ["Outra", ["Outra/c.txt"]]]);
    expect(split.skipped).toBe(3);
  });
  it("derives one folder path from receipts, and refuses a flattened tree", () => {
    expect(folderPathFromResults([
      { relativePath: "Aulas (1)/a.pdf", path: "attachments/B/Aulas (1)/a.pdf" },
      { relativePath: "Aulas (1)/sub/ã.pdf", path: "attachments/B/Aulas (1)/sub/ã.pdf" },
    ])).toBe("attachments/B/Aulas (1)/");
    expect(folderPathFromResults([{ relativePath: "Aulas/a.pdf", path: "/w/uploads/u1/a.pdf" }])).toBeNull();
    expect(localFolderPath([{ name: "a", localPath: "/Users/t/Aulas/a.pdf", relativePath: "Aulas/a.pdf" }])).toBe("/Users/t/Aulas/");
  });
  it("walks dropped folders recursively through webkitGetAsEntry", async () => {
    const file = (name: string) => ({ isFile: true, isDirectory: false, name, file: (ok: (f: File) => void) => ok(new File(["x"], name)) });
    const dir = (name: string, children: unknown[]) => ({ isFile: false, isDirectory: true, name, createReader: () => { let done = false; return { readEntries: (ok: (e: unknown[]) => void) => { ok(done ? [] : children); done = true; } }; } });
    const tree = dir("Aulas", [file("a.pdf"), file(".DS_Store"), dir("sub", [file("b.pdf")]), dir("node_modules", [file("x.js")])]);
    const sources = await sourcesFromDataTransfer({ files: [] as unknown as FileList, items: [{ webkitGetAsEntry: () => tree }, { webkitGetAsEntry: () => file("loose.txt") }] as unknown as DataTransferItemList });
    expect(sources.map(s => s.relativePath ?? s.name)).toEqual(["Aulas/a.pdf", "Aulas/sub/b.pdf", "loose.txt"]);
  });
  it("uploads at most four files at once, retries a flaky file, and reports a persistent failure", async () => {
    await createRoot(async dispose => {
      let active = 0, peak = 0;
      const attempts = new Map<string, number>();
      const transfer = vi.fn(async (source: UploadSource, destination: string, options: { batchId?: string }) => {
        active++; peak = Math.max(peak, active);
        await new Promise(r => setTimeout(r, 5));
        active--;
        const n = (attempts.get(source.relativePath!) ?? 0) + 1;
        attempts.set(source.relativePath!, n);
        if (source.relativePath === "F/flaky.txt" && n === 1) throw new Error("503");
        if (source.relativePath === "F/broken.txt") throw new Error("refused");
        return { source, destination, connection: 0, path: `attachments/${options.batchId}/${source.relativePath}` };
      });
      const files = Array.from({ length: 10 }, (_, i) => ({ source: src(`F/f${i}.txt`), size: 10 })).concat([{ source: src("F/flaky.txt"), size: 5 }, { source: src("F/broken.txt"), size: 5 }]);
      const upload = createFolderUpload({ root: "F", files, destination: "context:p", transfer });
      await upload.run();
      expect(peak).toBeLessThanOrEqual(4);
      expect(attempts.get("F/flaky.txt")).toBe(2);
      expect(attempts.get("F/broken.txt")).toBe(3);
      expect(batchTotals(upload.batch)).toMatchObject({ count: 12, done: 11, failed: 1 });
      expect(upload.batch.files.find(f => f.source.relativePath === "F/broken.txt")?.error).toBe("refused");
      // Retry only re-sends what failed.
      transfer.mockClear();
      await upload.run();
      expect(transfer.mock.calls.map(c => c[0].relativePath)).toEqual(["F/broken.txt", "F/broken.txt", "F/broken.txt"]);
      dispose();
    });
  });
  it("cancel stops queued files", async () => {
    await createRoot(async dispose => {
      const transfer = vi.fn(async (source: UploadSource, _d: string, options: { signal?: AbortSignal }) => {
        await new Promise((r, reject) => { const t = setTimeout(r, 20); options.signal?.addEventListener("abort", () => { clearTimeout(t); reject(new Error("aborted")); }); });
        return { source, destination: "context:p", connection: 0, path: "x" };
      });
      const upload = createFolderUpload({ root: "F", files: Array.from({ length: 8 }, (_, i) => ({ source: src(`F/${i}`), size: 1 })), destination: "context:p", transfer });
      const running = upload.run();
      upload.cancel();
      await running;
      expect(transfer.mock.calls.length).toBeLessThanOrEqual(4);
      expect(upload.batch.cancelled).toBe(true);
      expect(batchTotals(upload.batch).done).toBe(0);
      dispose();
    });
  });
});
