import { createSignal, For, Show } from "solid-js";
import * as Ic from "../icons";
import { batchTotals, type FolderBatch } from "../uploadBatch";
import { formatFileSize, type UploadedFolder } from "../uploads";

const STATE_LABEL = { queued: "Waiting", uploading: "Uploading", done: "Uploaded", failed: "Failed" } as const;

/** One compact row per folder: count, size, aggregated progress; expands to the file list. */
export function FolderUploadChip(p: {
  batch?: FolderBatch;
  folder?: UploadedFolder;
  onCancel?: () => void;
  onRetry?: () => void;
  onSkipFailed?: () => void;
  onRemove?: () => void;
}) {
  const [open, setOpen] = createSignal(false);
  const name = () => p.batch?.root ?? p.folder?.name ?? "";
  const totals = () => p.batch ? batchTotals(p.batch) : { bytes: p.folder?.bytes ?? 0, uploaded: p.folder?.bytes ?? 0, done: p.folder?.count ?? 0, failed: 0, count: p.folder?.count ?? 0 };
  const pct = () => totals().bytes > 0 ? Math.min(100, Math.round((totals().uploaded / totals().bytes) * 100)) : (totals().done === totals().count ? 100 : 0);
  const meta = () => {
    const t = totals();
    const size = t.bytes ? ` · ${formatFileSize(t.bytes)}` : "";
    if (!p.batch) return `${t.count} file${t.count === 1 ? "" : "s"}${size}`;
    if (t.failed && !p.batch.running) return `${t.failed} of ${t.count} failed`;
    return `${t.done}/${t.count} files · ${pct()}%${size}`;
  };
  return (
    <div class={`composer-bg-upload-row folder-upload ${totals().failed && !p.batch?.running ? "error" : ""}`} role="group" aria-label={`Folder ${name()}`} onClick={(e) => e.stopPropagation()}>
      <button type="button" class="folder-upload-toggle" aria-expanded={open()} aria-label={`${open() ? "Hide" : "Show"} files in ${name()}`} onClick={() => setOpen(!open())}>
        <Ic.FolderIcon size={12} />
        <span class="composer-bg-upload-name" title={name()}>{name()}/</span>
      </button>
      <span class="composer-bg-upload-meta" role="status">{meta()}</span>
      <div class="composer-bg-upload-actions">
        <Show when={p.batch && totals().failed > 0 && !p.batch.running}>
          <button type="button" class="bg-upload-btn" onClick={() => p.onRetry?.()}>Retry</button>
          <Show when={totals().done > 0}><button type="button" class="bg-upload-btn" onClick={() => p.onSkipFailed?.()}>Skip failed</button></Show>
        </Show>
        <Show when={p.batch} fallback={<button type="button" class="bg-upload-btn" aria-label={`Remove ${name()}`} onClick={() => p.onRemove?.()}>×</button>}>
          <button type="button" class="bg-upload-btn" aria-label={`Cancel upload of ${name()}`} onClick={() => p.onCancel?.()}>×</button>
        </Show>
      </div>
      <Show when={p.batch}><span class="bg-upload-bar"><i style={{ width: `${pct()}%` }} /></span></Show>
      <Show when={open()}>
        <ul class="folder-upload-files">
          <Show when={p.batch} fallback={<For each={p.folder?.files ?? []}>{(file) => <li><span>{file}</span></li>}</For>}>
            <For each={p.batch!.files}>{(file) => (
              <li class={file.state}>
                <span title={file.source.relativePath}>{file.source.relativePath}</span>
                <span class="folder-upload-file-state" title={file.error}>{file.state === "failed" && file.error ? `Failed — ${file.error}` : STATE_LABEL[file.state]} · {formatFileSize(file.size)}</span>
              </li>
            )}</For>
          </Show>
          <Show when={(p.batch?.skipped ?? 0) > 0}><li class="skipped">{p.batch!.skipped} hidden or system file{p.batch!.skipped === 1 ? "" : "s"} skipped</li></Show>
        </ul>
      </Show>
    </div>
  );
}
