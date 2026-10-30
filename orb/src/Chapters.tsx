import { createMemo, createSignal, For, onCleanup, Show } from "solid-js";
import type { StreamItem } from "./transcriptModel";
import { transcriptSearch } from "./VirtualTurns";

/** One chapter per delivered user message; its turn key is the message key. */
export function chaptersOf(items: StreamItem[]) {
  return items.flatMap((item) => item.kind === "user" && !item.queued && item.text.trim()
    ? [{ key: item.key, title: item.text.replace(/\s+/g, " ").trim().slice(0, 90) }] : []);
}

/** Floating table of contents for long conversations (Claude Code desktop's chapters). */
export function Chapters(p: { items: StreamItem[]; scroller: () => HTMLElement | undefined }) {
  const chapters = createMemo(
    () => chaptersOf(p.items),
    [],
    { equals: (a, b) => a.length === b.length && a.every((c, i) => c.key === b[i].key && c.title === b[i].title) },
  );
  const [open, setOpen] = createSignal(false);
  let root!: HTMLDivElement;
  const close = (e: PointerEvent) => { if (open() && !root.contains(e.target as Node)) setOpen(false); };
  const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
  document.addEventListener("pointerdown", close);
  document.addEventListener("keydown", esc);
  onCleanup(() => { document.removeEventListener("pointerdown", close); document.removeEventListener("keydown", esc); });
  const go = async (key: string) => {
    setOpen(false);
    const scope = p.scroller();
    if (scope) await transcriptSearch(scope)?.reveal({ key, occurrence: 0 });
  };
  return (
    <Show when={chapters().length >= 4}>
      <div class="chapters" ref={root}>
        <button type="button" class={`chapters-btn ${open() ? "on" : ""}`} aria-expanded={open()} aria-label="Jump to a message" title="Jump to a message" onClick={() => setOpen(!open())}>
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3 4h10M3 8h7M3 12h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none" /></svg>
          <span>{chapters().length}</span>
        </button>
        <Show when={open()}>
          <ol class="chapters-list" role="menu">
            <For each={chapters()}>{(c, i) => (
              <li><button type="button" role="menuitem" onClick={() => void go(c.key)}><span class="chapters-n">{i() + 1}</span><span class="chapters-t">{c.title}</span></button></li>
            )}</For>
          </ol>
        </Show>
      </div>
    </Show>
  );
}
