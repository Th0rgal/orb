import { Show, createSignal, onCleanup, onMount } from "solid-js";
import { Dialog } from "./Dialog";

/** `src` is null while an image is still loading or could not be loaded. */
export type LightboxItem = { src: string | null; label: string };

/** Full-window preview of a set of attached images: ←/→ move between them, Escape closes. */
export function Lightbox(p: { items: LightboxItem[]; index: number; onClose: () => void }) {
  const [index, setIndex] = createSignal(p.index);
  const go = (step: number) => setIndex(i => Math.max(0, Math.min(p.items.length - 1, i + step)));
  const item = () => p.items[Math.min(index(), p.items.length - 1)] ?? {src:null,label:"Image unavailable"};
  onMount(() => {
    const key = (e: KeyboardEvent) => {
      if (e.altKey || e.metaKey || e.ctrlKey || (e.key !== "ArrowLeft" && e.key !== "ArrowRight")) return;
      e.preventDefault(); e.stopPropagation();
      go(e.key === "ArrowLeft" ? -1 : 1);
    };
    window.addEventListener("keydown", key, true);
    onCleanup(() => window.removeEventListener("keydown", key, true));
  });
  return <Dialog class="dlg-lightbox" title={item().label} hint={p.items.length > 1 ? `${index() + 1} / ${p.items.length} · ← →` : undefined} onClose={p.onClose}>
    <div class="lightbox-stage">
      <Show when={item().src} fallback={<p class="file-muted">Loading image…</p>}>
        {src => <img class="lightbox-image" src={src()} alt={item().label} />}
      </Show>
      <Show when={p.items.length > 1}>
        <button type="button" class="lightbox-nav prev" aria-label="Previous image" disabled={index() === 0} onClick={() => go(-1)}>‹</button>
        <button type="button" class="lightbox-nav next" aria-label="Next image" disabled={index() === p.items.length - 1} onClick={() => go(1)}>›</button>
      </Show>
    </div>
  </Dialog>;
}
