import { nativeInvoke } from "./native";
import { swallow } from "./log";
import { createSignal } from "solid-js";
import { api, connectionVersion, getApiUrl } from "./api";
import { mentionText, scanMentions } from "./attach";

/** `relativePath` is set for files that came from a folder ("Folder/sub/a.txt"). */
/** `grant` names the desktop folder offer a walked file belongs to; it is readable only once granted. */
export interface UploadSource { name: string; localPath?: string; file?: File; relativePath?: string; size?: number; grant?: string }
/** A folder upload is one entry whose `path` is the uploaded folder. */
export interface UploadedFolder { name: string; count: number; bytes: number; files: string[] }
export interface UploadedFile { source: UploadSource; path: string; destination: string; connection: number; endpoint?: string; dataBase64?: string; confirmedLarge?: boolean; folder?: UploadedFolder }
export interface UploadReceipt { name: string; path: string; size: number; sha256: string }

export const SOFT_CONTEXT_BYTES = 10 * 1024 * 1024; // 10 MiB
export const SOFT_DIRECT_BYTES = 20 * 1024 * 1024; // 20 MiB
export const HARD_MAX_BYTES = 2 * 1024 * 1024 * 1024; // 2 GiB
export const RESUMABLE_CHUNK_BYTES = 4 * 1024 * 1024; // 4 MiB
const MAX = SOFT_DIRECT_BYTES;

export function hasNativePicker() { return !!nativeInvoke(); }
export async function pickNativeFiles(): Promise<UploadSource[]> {
  const invoke = nativeInvoke();
  if (!invoke) throw new Error("Use the desktop app to attach a local file path.");
  const files = await invoke<Array<{ name: string; path: string }>>("pick_upload_files");
  return files.map(file => ({ name: file.name, localPath: file.path }));
}

/** A whole folder, walked by the desktop app (junk and links skipped); paths stay relative to the folder's parent. */
export async function pickNativeFolder(): Promise<UploadSource[]> {
  const invoke = nativeInvoke();
  if (!invoke) throw new Error("Use the desktop app to attach a folder.");
  return folderOfferSources(await invoke<FolderOffer>("pick_upload_folder"));
}

export interface FolderOffer { batch?: string | null; files: Array<{ name: string; path: string; relative_path: string; size: number }> }
export const folderOfferSources = (offer: FolderOffer | undefined): UploadSource[] =>
  (offer?.files ?? []).map(file => ({ name: file.name, localPath: file.path, relativePath: file.relative_path, size: file.size, ...(offer?.batch ? { grant: offer.batch } : {}) }));

/** Makes exactly the files about to upload readable by the desktop; returns a revoke. */
export async function grantFolderSources(sources: UploadSource[]): Promise<() => void> {
  const invoke = nativeInvoke();
  const batch = sources.find(source => source.grant)?.grant;
  if (!invoke || !batch) return () => {};
  await invoke("grant_upload_folder", { batch, relativePaths: sources.map(source => source.relativePath) });
  return () => { void invoke("revoke_upload_folder", { batch }).catch(swallow("uploads.revokeFolder", {})); };
}

export function softLimitForDestination(destination: string): number {
  return destination.startsWith("context:") ? SOFT_CONTEXT_BYTES : SOFT_DIRECT_BYTES;
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export async function statUploadSource(source: UploadSource): Promise<{ size: number; modified: number }> {
  if (source.file) {
    return { size: source.file.size, modified: source.file.lastModified || 0 };
  }
  if (source.localPath) {
    const invoke = nativeInvoke();
    if (!invoke) throw new Error("Reopen this file in the desktop app.");
    try {
      return await invoke<{ size: number; modified: number }>("stat_upload_file", { path: source.localPath });
    } catch {
      const b64 = await invoke<string>("read_upload_file", { path: source.localPath });
      const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
      return { size: Math.floor((b64.length * 3) / 4) - padding, modified: 0 };
    }
  }
  throw new Error("Choose the file again.");
}

async function readSourceChunk(source: UploadSource, offset: number, length: number): Promise<Uint8Array> {
  if (source.file) {
    const slice = source.file.slice(offset, offset + length);
    if (typeof slice.arrayBuffer === "function") {
      return new Uint8Array(await slice.arrayBuffer());
    }
    const buf = await new Response(slice).arrayBuffer();
    return new Uint8Array(buf);
  }
  if (source.localPath) {
    const invoke = nativeInvoke();
    if (!invoke) throw new Error("Reopen this file in the desktop app.");
    const b64 = await invoke<string>("read_upload_file_chunk", { path: source.localPath, offset, length });
    return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
  }
  throw new Error("Choose the file again.");
}

export async function encoded(source: UploadSource, maxBytes = MAX): Promise<string> {
  if (source.localPath) {
    const invoke = nativeInvoke();
    if (!invoke) throw new Error("Reopen this file in the desktop app.");
    return invoke<string>("read_upload_file", { path: source.localPath, ...(maxBytes === MAX ? {} : { maxBytes }) });
  }
  const file = source.file;
  if (!file) throw new Error("Choose the file again.");
  if (file.size > maxBytes) throw new Error(`Files must be ${Math.round(maxBytes / 1024 / 1024)} MiB or smaller.`);
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}
export const uploadToken = (path: string) => mentionText({ kind: "file", path });

/** One path segment as Core accepts it: NFC (macOS hands out NFD), no separators or controls. */
export function cleanUploadName(name: string): string {
  const clean = name.normalize("NFC").replace(/[\\/\x00-\x1f\x7f]/g, "_").trim();
  if (!clean || clean === "." || clean === "..") throw new Error("Invalid attachment name.");
  return clean;
}

/** "Folder/sub/a.txt" with each segment cleaned; never absolute, never `..`. */
export function cleanRelativePath(relative: string): string {
  const parts = relative.split(/[\\/]+/).filter(part => part && part !== ".");
  if (!parts.length || parts.length > 32) throw new Error("Invalid folder path.");
  return parts.map(cleanUploadName).join("/");
}

export function contextAttachmentPath(source: UploadSource, batchId?: string): string {
  const id = batchId ?? crypto.randomUUID();
  return `attachments/${id}/${source.relativePath ? cleanRelativePath(source.relativePath) : cleanUploadName(source.name)}`;
}

/** The original file is gone from Orb's reach (app restarted, file moved): only the user can choose it again. */
export function isSourceUnavailable(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /choose this file again using the file picker|^choose the file again\.?$|reopen this file in the desktop app|os error 2\b|no such file/i.test(message);
}

function deterministicUploadId(destination: string, source: UploadSource, size: number, modified: number): string {
  const raw = `${getApiUrl()}|${destination}|${source.localPath ?? source.relativePath ?? source.name}|${size}|${modified}`;
  let h1 = 0xdeadbeef ^ raw.length;
  let h2 = 0x41c6ce57 ^ raw.length;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  const hex = (h1 >>> 0).toString(16).padStart(8, "0") + (h2 >>> 0).toString(16).padStart(8, "0");
  const safeName = source.name.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 32) || "file";
  return `up_${safeName}_${size}_${hex}`;
}

export interface ResumableTransferOptions {
  confirmedLarge?: boolean;
  /** Folder uploads share one batch directory and keep `source.relativePath`. */
  batchId?: string;
  /** Proves to the machine that later files belong to the batch the first one created. */
  batchToken?: string;
  chunkSize?: number;
  concurrency?: number;
  signal?: AbortSignal;
  onProgress?: (progress: { uploadedBytes: number; totalBytes: number; speedBps: number; totalChunks: number; completedChunks: number }) => void;
}

interface SessionStatusResponse {
  upload_id: string;
  size: number;
  chunk_size: number;
  total_chunks: number;
  received_chunks: number[];
  receipt?: UploadReceipt;
  hash?: string;
}

async function runChunkedSession(
  initUrl: string,
  initBody: Record<string, unknown>,
  chunkUrl: (index: number) => string,
  source: UploadSource,
  size: number,
  options: ResumableTransferOptions = {},
): Promise<SessionStatusResponse> {
  const chunkSize = options.chunkSize ?? RESUMABLE_CHUNK_BYTES;
  const concurrency = Math.max(1, options.concurrency ?? 3);
  const status = await api<SessionStatusResponse>(initUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...initBody, chunk_size: chunkSize }),
    signal: options.signal,
  });
  const effectiveChunkSize = status.chunk_size || chunkSize;
  const totalChunks = status.total_chunks || Math.max(1, Math.ceil(size / effectiveChunkSize));
  const receivedSet = new Set<number>(status.received_chunks ?? []);
  const chunkByteSize = (idx: number) => {
    if (size === 0) return 0;
    const offset = idx * effectiveChunkSize;
    return Math.min(effectiveChunkSize, Math.max(0, size - offset));
  };
  let uploadedBytes = 0;
  for (const idx of receivedSet) uploadedBytes += chunkByteSize(idx);
  const startedAt = Date.now();
  const initialBytes = uploadedBytes;
  const report = () => {
    const elapsedSec = Math.max(0.15, (Date.now() - startedAt) / 1000);
    const speedBps = Math.max(0, Math.round((uploadedBytes - initialBytes) / elapsedSec));
    options.onProgress?.({
      uploadedBytes,
      totalBytes: size,
      speedBps,
      totalChunks,
      completedChunks: receivedSet.size,
    });
  };
  report();
  if (status.receipt || status.hash || receivedSet.size >= totalChunks) {
    return status;
  }
  const missing: number[] = [];
  for (let i = 0; i < totalChunks; i++) {
    if (!receivedSet.has(i)) missing.push(i);
  }
  let cursor = 0;
  const worker = async () => {
    while (cursor < missing.length) {
      options.signal?.throwIfAborted();
      const idx = missing[cursor++];
      const offset = idx * effectiveChunkSize;
      const len = chunkByteSize(idx);
      const bytes = len === 0 ? new Uint8Array(0) : await readSourceChunk(source, offset, len);
      let attempt = 0;
      while (true) {
        options.signal?.throwIfAborted();
        try {
          await api<SessionStatusResponse>(chunkUrl(idx), {
            method: "PUT",
            headers: { "Content-Type": "application/octet-stream" },
            body: bytes as unknown as BodyInit,
            signal: options.signal,
          });
          break;
        } catch (err) {
          options.signal?.throwIfAborted();
          attempt++;
          if (attempt >= 4) throw err;
          await new Promise<void>((resolve, reject) => {
            const delay = Math.min(4000, 250 * Math.pow(2, attempt - 1));
            const timer = setTimeout(resolve, delay);
            options.signal?.addEventListener("abort", () => {
              clearTimeout(timer);
              reject(options.signal!.reason ?? new DOMException("Aborted", "AbortError"));
            }, { once: true });
          });
        }
      }
      if (!receivedSet.has(idx)) {
        receivedSet.add(idx);
        uploadedBytes += len;
        report();
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, missing.length) }, () => worker()));
  return status;
}

export async function uploadContextBlobResumable(
  project: string,
  source: UploadSource,
  size: number,
  modified: number,
  options: ResumableTransferOptions = {},
): Promise<{ hash: string; size: number; uploadId: string }> {
  const route = `/api/projects/${encodeURIComponent(project)}/context`;
  const uploadId = deterministicUploadId(`context:${project}`, source, size, modified);
  const status = await runChunkedSession(
    `${route}/upload-sessions`,
    { upload_id: uploadId, size },
    idx => `${route}/upload-sessions/${encodeURIComponent(uploadId)}/chunks/${idx}`,
    source,
    size,
    options,
  );
  if (status.hash) return { hash: status.hash, size, uploadId };
  const done = await api<{ hash: string; size: number }>(
    `${route}/upload-sessions/${encodeURIComponent(uploadId)}/complete`,
    { method: "POST", signal: options.signal },
  );
  return { hash: done.hash, size: done.size, uploadId };
}

function machineName(source: UploadSource, batchId?: string, batchToken?: string): { name: string; batch_id?: string; relative_path?: string; batch_token?: string } {
  const name = cleanUploadName(source.name);
  return batchId && batchToken && source.relativePath ? { name, batch_id: batchId, relative_path: cleanRelativePath(source.relativePath), batch_token: batchToken } : { name };
}

export async function uploadDirectMachineResumable(
  nodeId: string,
  source: UploadSource,
  size: number,
  modified: number,
  options: ResumableTransferOptions = {},
): Promise<{ receipt: UploadReceipt; uploadId: string }> {
  const uploadId = deterministicUploadId(options.batchId ? `${nodeId}|${options.batchId}` : nodeId, source, size, modified);
  const query = `?node_id=${encodeURIComponent(nodeId)}`;
  const status = await runChunkedSession(
    `/api/uploads/sessions`,
    { node_id: nodeId, upload_id: uploadId, ...machineName(source, options.batchId, options.batchToken), size },
    idx => `/api/uploads/sessions/${encodeURIComponent(uploadId)}/chunks/${idx}${query}`,
    source,
    size,
    options,
  );
  if (status.receipt) return { receipt: status.receipt, uploadId };
  const receipt = await api<UploadReceipt>(
    `/api/uploads/sessions/${encodeURIComponent(uploadId)}/complete${query}`,
    { method: "POST", signal: options.signal },
  );
  return { receipt, uploadId };
}

export async function transferFile(
  source: UploadSource,
  destination: string,
  options: ResumableTransferOptions = {},
): Promise<UploadedFile> {
  const connection = connectionVersion();
  const softLimit = softLimitForDestination(destination);
  if (destination === "side") {
    return {
      source,
      path: `side-attachment/${crypto.randomUUID()}/${source.name}`,
      destination,
      connection,
      endpoint: getApiUrl(),
      dataBase64: await encoded(source, options.confirmedLarge ? HARD_MAX_BYTES : softLimit),
      confirmedLarge: options.confirmedLarge,
    };
  }
  if (destination === "local") {
    if (!source.localPath) {
      const invoke = nativeInvoke();
      if (!invoke) throw new Error("Local file attachments require the desktop app.");
      const path = await invoke<string>("stage_upload_file", {
        name: source.name,
        dataBase64: await encoded(source, options.confirmedLarge ? HARD_MAX_BYTES : softLimit),
      });
      source = { ...source, localPath: path };
    } else if (options.confirmedLarge) {
      const invoke = nativeInvoke();
      if (invoke) {
        try {
          const path = await invoke<string>("stage_upload_file_from_path", {
            path: source.localPath,
            name: source.name,
          });
          source = { ...source, localPath: path };
        } catch {
          await statUploadSource(source);
        }
      }
    }
    return { source, path: source.localPath!, destination, connection, endpoint: getApiUrl(), confirmedLarge: options.confirmedLarge };
  }

  let stat: { size: number; modified: number } | undefined;
  if (options.confirmedLarge || options.onProgress || options.signal) {
    stat = await statUploadSource(source);
    if (stat.size > HARD_MAX_BYTES) throw new Error("Files must be 2 GiB or smaller.");
    if (!options.confirmedLarge && stat.size > softLimit) {
      throw new Error(`Files must be ${Math.round(softLimit / 1024 / 1024)} MiB or smaller.`);
    }
  }

  const useResumable = Boolean(
    options.confirmedLarge ||
    options.onProgress ||
    (stat && stat.size > softLimit),
  );

  if (destination.startsWith("context:")) {
    const project = destination.slice("context:".length);
    if (!project) throw new Error("Select a project before uploading files to shared context.");
    const route = `/api/projects/${encodeURIComponent(project)}/context`;
    let hash: string;
    if (useResumable) {
      const s = stat ?? (await statUploadSource(source));
      if (connection !== connectionVersion()) throw new Error("The backend changed. Choose the file again.");
      const uploaded = await uploadContextBlobResumable(project, source, s.size, s.modified, options);
      hash = uploaded.hash;
    } else {
      const data = await encoded(source, softLimit);
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
      if (connection !== connectionVersion()) throw new Error("The backend changed. Choose the file again.");
      const blob = await api<{ hash: string }>(`${route}/blobs`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: bytes,
      });
      hash = blob.hash;
    }
    if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
    const path = contextAttachmentPath(source, options.batchId);
    const receipt = await api<{ conflict: boolean }>(`${route}/operations`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: crypto.randomUUID(),
        path,
        base: null,
        hash,
        directory: false,
        delete: false,
        source: "Orb",
        ...(options.confirmedLarge ? { confirmed_large: true } : {}),
      }),
    });
    if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
    if (receipt.conflict) throw new Error("Shared context changed. Drop the file again.");
    return { source, path, destination, connection, endpoint: getApiUrl(), confirmedLarge: options.confirmedLarge };
  }

  if (connection !== connectionVersion()) throw new Error("The backend changed. Choose the file again.");
  if (useResumable) {
    const s = stat ?? (await statUploadSource(source));
    const { receipt } = await uploadDirectMachineResumable(destination, source, s.size, s.modified, options);
    if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
    return { source, path: receiptPath(receipt), destination, connection, endpoint: getApiUrl(), confirmedLarge: options.confirmedLarge };
  }

  const data = await encoded(source, softLimit);
  const receipt = await api<UploadReceipt>("/api/uploads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ node_id: destination, ...machineName(source, options.batchId, options.batchToken), data_base64: data }),
  });
  if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
  return { source, path: receiptPath(receipt), destination, connection, endpoint: getApiUrl() };
}

/** The machine's path for an uploaded file; a receipt without one must never become an empty mention. */
function receiptPath(receipt: UploadReceipt | undefined): string {
  const path = receipt?.path;
  if (typeof path !== "string" || !path.trim()) throw new Error("The machine did not return where it saved the file. Try again.");
  return path;
}

const samePath = (a: string, b: string) => a.normalize("NFC") === b.normalize("NFC");

/** Remove every mention of `path` (and the space after it) from a draft. */
export function removeMention(text: string, path: string): string {
  for (const mention of scanMentions(text).filter(mention => samePath(mention.value, path)).reverse()) {
    const end = mention.index + mention.raw.length;
    text = text.slice(0, mention.index) + text.slice(text[end] === " " ? end + 1 : end);
  }
  return text;
}

/**
 * Resolve only references still in the draft, and never reuse another machine's path.
 *
 * A file already uploaded to this destination on this backend is reused as-is,
 * also after a restart restored it from the draft: re-reading the original is
 * neither needed nor possible then (the desktop only reads files chosen in this
 * session). A file that must move and whose original is gone is returned in
 * `unavailable` with its mention removed, so the rest of the draft stays sendable.
 */
export async function prepareUploads(
  text: string,
  files: UploadedFile[],
  destination: string,
  transfer: (source: UploadSource, dest: string, opts?: ResumableTransferOptions) => Promise<UploadedFile> = transferFile,
  connection = connectionVersion(),
): Promise<{ text: string; files: UploadedFile[]; unavailable: UploadedFile[] }> {
  const next: UploadedFile[] = [];
  const unavailable: UploadedFile[] = [];
  for (const file of files) {
    if (!scanMentions(text).some(mention => samePath(mention.value, file.path))) continue;
    const sameBackend = file.connection === connection || (!!file.endpoint && file.endpoint === getApiUrl());
    if (file.destination === destination && sameBackend) { next.push(file); continue; }
    let resolved: UploadedFile;
    try {
      if (file.folder) throw new Error("Choose the file again.");
      resolved = await transfer(file.source, destination, { confirmedLarge: file.confirmedLarge });
    } catch (error) {
      if (!isSourceUnavailable(error)) throw error;
      unavailable.push(file);
      text = removeMention(text, file.path);
      continue;
    }
    for (const mention of scanMentions(text).filter(mention => samePath(mention.value, file.path)).reverse()) {
      text = text.slice(0, mention.index) + uploadToken(resolved.path) + text.slice(mention.index + mention.raw.length);
    }
    next.push(resolved);
  }
  return { text, files: next, unavailable };
}

export type BackgroundUploadState = "uploading" | "paused" | "completed" | "failed";

export interface BackgroundUploadTask {
  id: string;
  scope?: string;
  destination: string;
  source: UploadSource;
  name: string;
  totalBytes: number;
  uploadedBytes: number;
  speedBps: number;
  state: BackgroundUploadState;
  error?: string;
  result?: UploadedFile;
  confirmedLarge?: boolean;
  onComplete?: (file: UploadedFile) => void;
}

const [bgUploads, setBgUploads] = createSignal<BackgroundUploadTask[]>([]);
const bgControllers = new Map<string, AbortController>();
const bgRunners = new Map<string, () => Promise<UploadedFile>>();

export const backgroundUploads = bgUploads;

function updateBgTask(id: string, patch: Partial<BackgroundUploadTask>) {
  setBgUploads(list => list.map(item => (item.id === id ? { ...item, ...patch } : item)));
}

export function startBackgroundUpload(params: {
  source: UploadSource;
  destination: string;
  totalBytes: number;
  scope?: string;
  confirmedLarge?: boolean;
  customRunner?: (opts: {
    signal: AbortSignal;
    onProgress: NonNullable<ResumableTransferOptions["onProgress"]>;
  }) => Promise<UploadedFile>;
  onComplete?: (file: UploadedFile) => void;
}): string {
  const id = `bg_${crypto.randomUUID()}`;
  const task: BackgroundUploadTask = {
    id,
    scope: params.scope,
    destination: params.destination,
    source: params.source,
    name: params.source.name,
    totalBytes: params.totalBytes,
    uploadedBytes: 0,
    speedBps: 0,
    state: "uploading",
    confirmedLarge: params.confirmedLarge,
    onComplete: params.onComplete,
  };
  setBgUploads(prev => [...prev, task]);

  const launch = async (): Promise<UploadedFile> => {
    const abort = new AbortController();
    bgControllers.set(id, abort);
    updateBgTask(id, { state: "uploading", error: undefined });
    const onProgress: NonNullable<ResumableTransferOptions["onProgress"]> = p => {
      updateBgTask(id, {
        uploadedBytes: p.uploadedBytes,
        totalBytes: p.totalBytes || params.totalBytes,
        speedBps: p.speedBps,
      });
    };
    try {
      const file = params.customRunner
        ? await params.customRunner({ signal: abort.signal, onProgress })
        : await transferFile(params.source, params.destination, {
            confirmedLarge: params.confirmedLarge,
            signal: abort.signal,
            onProgress,
          });
      updateBgTask(id, {
        state: "completed",
        uploadedBytes: params.totalBytes,
        speedBps: 0,
        result: file,
      });
      params.onComplete?.(file);
      setTimeout(() => {
        setBgUploads(list => list.filter(t => t.id !== id || t.state !== "completed"));
      }, 2400);
      return file;
    } catch (err) {
      if (abort.signal.aborted) {
        const current = bgUploads().find(t => t.id === id);
        if (current?.state === "paused") throw err;
        throw err;
      }
      const message = err instanceof Error ? err.message : String(err);
      updateBgTask(id, { state: "failed", speedBps: 0, error: message });
      throw err;
    } finally {
      if (bgControllers.get(id) === abort) bgControllers.delete(id);
    }
  };

  bgRunners.set(id, launch);
  void launch().catch(swallow("uploads.background", { id }));
  return id;
}

export function pauseBackgroundUpload(id: string) {
  updateBgTask(id, { state: "paused", speedBps: 0 });
  const ctrl = bgControllers.get(id);
  if (ctrl) {
    bgControllers.delete(id);
    ctrl.abort();
  }
}

export function resumeBackgroundUpload(id: string) {
  const runner = bgRunners.get(id);
  if (!runner) return;
  void runner().catch(swallow("uploads.resume", { id }));
}

export function cancelBackgroundUpload(id: string) {
  const ctrl = bgControllers.get(id);
  if (ctrl) {
    bgControllers.delete(id);
    ctrl.abort();
  }
  bgRunners.delete(id);
  const task = bgUploads().find(t => t.id === id);
  setBgUploads(list => list.filter(t => t.id !== id));
  if (task) {
    void (async () => {
      try {
        const stat = await statUploadSource(task.source);
        const uploadId = deterministicUploadId(task.destination, task.source, stat.size, stat.modified);
        if (task.destination.startsWith("context:")) {
          const slug = task.destination.slice("context:".length);
          await api(`/api/projects/${encodeURIComponent(slug)}/context/upload-sessions/${encodeURIComponent(uploadId)}`, { method: "DELETE" });
        } else if (task.destination !== "local" && task.destination !== "side") {
          await api(`/api/uploads/sessions/${encodeURIComponent(uploadId)}?node_id=${encodeURIComponent(task.destination)}`, { method: "DELETE" });
        }
      } catch {}
    })();
  }
}

