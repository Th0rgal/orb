import { swallow } from "./log";
import { Show, createEffect, createSignal, onCleanup, useContext } from "solid-js";
import { FileReferenceContext } from "./fileReferenceContext";
import { Lightbox } from "./Lightbox";
import * as Ic from "./icons";
import { createImageMenu } from "./imageActions";

/** An image the agent saved in its workspace and referenced by path in a reply.
 * Bytes come through the scoped file resolver, never a webview URL. */
export function WorkspaceImage(p: { path: string; alt: string }) {
  const resolver = useContext(FileReferenceContext);
  const [url, setUrl] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(false);
  const [attempt, setAttempt] = createSignal(0);
  const [open, setOpen] = createSignal(false);
  const menu = createImageMenu(() => ({ src: url(), label: p.path, path: p.path }));
  createEffect(() => {
    const path = p.path;
    attempt();
    setUrl(null);
    if (!resolver?.loadImage) return;
    let cancelled = false, loaded: string | null = null;
    setLoading(true);
    void resolver.loadImage(path).then(value => {
      if (cancelled) { if (value?.startsWith("blob:")) URL.revokeObjectURL(value); return; }
      loaded = value; setUrl(value);
    }).catch(swallow("workspaceImage.load")).finally(() => { if (!cancelled) setLoading(false); });
    onCleanup(() => { cancelled = true; if (loaded?.startsWith("blob:")) URL.revokeObjectURL(loaded); });
  });
  return <span class="md-workspace-image">
    <Show when={url()} fallback={
      <button type="button" class="md-workspace-image-missing" disabled={loading() || !resolver?.loadImage} title={p.path}
        onClick={() => setAttempt(n => n + 1)}>
        <Ic.FileIcon size={16} /><span>{p.alt}</span>
        <small>{loading() ? "Loading image…" : resolver?.loadImage ? "Image unavailable · Retry" : p.path}</small>
      </button>}>
      {src => <button type="button" class="md-workspace-image-open" title={`${p.alt} — ${p.path}`} onClick={() => setOpen(true)} onContextMenu={menu.onContextMenu}>
        <img class="md-image" src={src()} alt={p.alt} onError={() => setUrl(null)} />
      </button>}
    </Show>
    <Show when={url()}><button type="button" class="md-image-download" aria-label="Download image" title="Save image as…" onClick={menu.save}><Ic.DownloadIcon size={14} /></button></Show>
    {menu.view()}
    <Show when={open()}><Lightbox items={[{ src: url(), label: p.path.split("/").at(-1) || p.alt, path: p.path }]} index={0} onClose={() => setOpen(false)} /></Show>
  </span>;
}
