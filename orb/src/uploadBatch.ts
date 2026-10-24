import { createStore, produce, type SetStoreFunction } from "solid-js/store";
import { cleanRelativePath, cleanUploadName, isSourceUnavailable, softLimitForDestination, type ResumableTransferOptions, type UploadedFile, type UploadSource } from "./uploads";

/** Folder and multi-file uploads: one batch directory, bounded parallelism, per-file retry. */

/** Never worth sending to an agent; skipped silently when walking a folder. */
const JUNK = new Set([".DS_Store", "Thumbs.db", "desktop.ini", ".git", ".svn", ".hg", "node_modules", "__MACOSX", ".Spotlight-V100", ".Trashes", ".fseventsd"]);
export const BATCH_WARN_FILES = 200;
export const BATCH_MAX_FILES = 2000;
export const BATCH_WARN_BYTES = 500 * 1024 * 1024;
export const BATCH_MAX_BYTES = 2 * 1024 * 1024 * 1024;
export const BATCH_CONCURRENCY = 4;
const ATTEMPTS = 3;

export function isJunkPath(relative: string): boolean {
  return relative.split(/[\\/]/).some(part => JUNK.has(part));
}

/** Mirrors Core's shared-context `valid_path` exclusions, so they are skipped up front, not failed one by one. */
export function contextExcluded(relative: string): boolean {
  return relative.split(/[\\/]/).some(name => name.startsWith(".") || ["node_modules", "target", "vendor", "id_rsa", "id_ed25519", "credentials.json", "auth.json"].includes(name) || name.endsWith("~") || name.endsWith(".pem") || name.endsWith(".key"));
}

export interface SplitSources { files: UploadSource[]; folders: Array<{ root: string; sources: UploadSource[] }>; skipped: number }

/** Loose files stay loose; files carrying a `relativePath` are grouped under their top folder. */
export function splitSources(sources: UploadSource[], destination = ""): SplitSources {
  const files: UploadSource[] = [];
  const folders = new Map<string, UploadSource[]>();
  let skipped = 0;
  for (const source of sources) {
    const relative = source.relativePath?.replace(/^[\\/]+/, "");
    if (!relative || !/[\\/]/.test(relative)) { files.push(relative ? { ...source, relativePath: undefined } : source); continue; }
    if (isJunkPath(relative) || (destination.startsWith("context:") && contextExcluded(relative))) { skipped++; continue; }
    const root = relative.split(/[\\/]/)[0];
    folders.set(root, [...(folders.get(root) ?? []), { ...source, relativePath: relative }]);
  }
  return { files, folders: [...folders].map(([root, sources]) => ({ root, sources })), skipped };
}

type Entry = { isFile: boolean; isDirectory: boolean; name: string; file?: (ok: (file: File) => void, fail: (error: unknown) => void) => void; createReader?: () => { readEntries: (ok: (entries: Entry[]) => void, fail: (error: unknown) => void) => void } };

/** Files and whole folders from a browser drop or paste. Folders are walked recursively. */
export async function sourcesFromDataTransfer(data: Pick<DataTransfer, "files"> & { items?: DataTransferItemList | ArrayLike<DataTransferItem> }): Promise<UploadSource[]> {
  const entries = Array.from(data.items ?? []).map(item => (item as DataTransferItem & { webkitGetAsEntry?: () => Entry | null }).webkitGetAsEntry?.() ?? null);
  if (!entries.some(entry => entry?.isDirectory)) return Array.from(data.files ?? []).map(file => ({ name: file.name, file }));
  const out: UploadSource[] = [];
  const walk = async (entry: Entry, prefix: string): Promise<void> => {
    if (out.length > BATCH_MAX_FILES || JUNK.has(entry.name)) return;
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isFile && entry.file) {
      const file = await new Promise<File>((ok, fail) => entry.file!(ok, fail));
      out.push({ name: file.name, file, ...(prefix ? { relativePath: relative } : {}) });
    } else if (entry.isDirectory && entry.createReader) {
      const reader = entry.createReader();
      // readEntries returns at most ~100 entries per call.
      for (;;) {
        const batch = await new Promise<Entry[]>((ok, fail) => reader.readEntries(ok, fail));
        if (!batch.length) break;
        for (const child of batch) await walk(child, relative);
      }
    }
  };
  for (const entry of entries) if (entry) await walk(entry, "");
  return out;
}

/**
 * The uploaded folder, derived from the receipts: every file must land at
 * `<folder>/<path inside the folder>`. A machine that flattens uploads
 * (older node binaries ignore `relative_path`) yields null, and the caller
 * mentions the files one by one instead.
 */
export function folderPathFromResults(results: Array<{ relativePath: string; path: string }>): string | null {
  let folder: string | null = null;
  for (const { relativePath, path } of results) {
    const relative = cleanRelativePath(relativePath);
    const root = relative.split("/")[0];
    const inside = relative.slice(root.length);
    if (!path.endsWith(relative)) return null;
    const candidate = `${path.slice(0, path.length - inside.length)}/`;
    if (folder !== null && folder !== candidate) return null;
    folder = candidate;
  }
  return folder;
}

/** For local agents the folder is already on this machine: mention it where it is. */
export function localFolderPath(sources: UploadSource[]): string | null {
  return folderPathFromResults(sources.map(source => ({ relativePath: source.relativePath ?? "", path: source.localPath ?? "" })));
}

export type BatchFileState = "queued" | "uploading" | "done" | "failed";
export interface BatchFile { source: UploadSource; size: number; uploaded: number; state: BatchFileState; error?: string; result?: UploadedFile }
export interface FolderBatch { id: string; root: string; destination: string; files: BatchFile[]; skipped: number; running: boolean; cancelled: boolean }

export interface FolderUpload {
  batch: FolderBatch;
  /** Starts (or restarts, for failed files) the bounded parallel upload. Resolves when nothing is running. */
  run(): Promise<void>;
  cancel(): void;
}

export function createFolderUpload(params: {
  root: string;
  files: Array<{ source: UploadSource; size: number }>;
  destination: string;
  skipped?: number;
  transfer: (source: UploadSource, destination: string, options: ResumableTransferOptions) => Promise<UploadedFile>;
  concurrency?: number;
}): FolderUpload {
  const id = crypto.randomUUID();
  const [batch, setBatch]: [FolderBatch, SetStoreFunction<FolderBatch>] = createStore<FolderBatch>({
    id,
    root: cleanUploadName(params.root),
    destination: params.destination,
    files: params.files.map(({ source, size }) => ({ source, size, uploaded: 0, state: "queued" as BatchFileState })),
    skipped: params.skipped ?? 0,
    running: false,
    cancelled: false,
  });
  let abort = new AbortController();
  const uploadOne = async (index: number, signal: AbortSignal) => {
    const file = batch.files[index];
    setBatch("files", index, { state: "uploading", error: undefined, uploaded: 0 });
    for (let attempt = 1; ; attempt++) {
      try {
        const result = await params.transfer(file.source, params.destination, {
          batchId: id,
          signal,
          confirmedLarge: file.size > softLimitForDestination(params.destination),
          // Byte progress for large files; small ones count when they finish.
          ...(file.size > 4 * 1024 * 1024 ? { onProgress: (progress: { uploadedBytes: number }) => setBatch("files", index, "uploaded", progress.uploadedBytes) } : {}),
        });
        setBatch("files", index, { state: "done", uploaded: file.size, result });
        return;
      } catch (error) {
        if (signal.aborted) { setBatch("files", index, { state: "queued", uploaded: 0 }); return; }
        if (attempt >= ATTEMPTS || isSourceUnavailable(error)) {
          setBatch("files", index, { state: "failed", error: error instanceof Error ? error.message : String(error) });
          return;
        }
        await new Promise(resolve => setTimeout(resolve, 300 * attempt));
      }
    }
  };
  return {
    batch,
    async run() {
      if (batch.running) return;
      abort = new AbortController();
      const signal = abort.signal;
      setBatch(produce(state => { state.running = true; state.cancelled = false; }));
      const pending = batch.files.map((file, index) => (file.state === "done" ? -1 : index)).filter(index => index >= 0);
      let cursor = 0;
      const worker = async () => {
        while (cursor < pending.length && !signal.aborted) await uploadOne(pending[cursor++], signal);
      };
      try {
        await Promise.all(Array.from({ length: Math.min(params.concurrency ?? BATCH_CONCURRENCY, pending.length) }, worker));
      } finally {
        setBatch("running", false);
      }
    },
    cancel() {
      setBatch("cancelled", true);
      abort.abort();
    },
  };
}

export function batchTotals(batch: FolderBatch) {
  let bytes = 0, uploaded = 0, done = 0, failed = 0;
  for (const file of batch.files) {
    bytes += file.size;
    uploaded += file.state === "done" ? file.size : file.uploaded;
    if (file.state === "done") done++;
    if (file.state === "failed") failed++;
  }
  return { bytes, uploaded, done, failed, count: batch.files.length };
}
