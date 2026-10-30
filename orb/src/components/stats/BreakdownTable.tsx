import { For, Show, createSignal, type JSX } from "solid-js";

export interface Column<T> {
  header: string;
  /** CSS grid track, e.g. "minmax(0,1fr)" or "72px". */
  width: string;
  cell: (row: T) => JSX.Element;
  align?: "start" | "end";
  /** Hidden below 560px (390px phones). */
  hideNarrow?: boolean;
  /** Grid track below 560px (defaults to `width`). */
  narrowWidth?: string;
}

/**
 * Data-dense ranked list with optional expandable detail and a collapsed
 * tail ("12 healthy · show"). Rows arrive already sorted. `rows` undefined
 * renders `skeletonRows` placeholder rows of the final height.
 */
export function BreakdownTable<T>(p: {
  label: string;
  columns: Column<T>[];
  rows?: T[];
  rowKey: (row: T) => string;
  detail?: (row: T) => JSX.Element;
  /** Rows matching this are folded behind a "N {collapsedLabel} · show" button. */
  collapse?: (row: T) => boolean;
  collapsedLabel?: string;
  skeletonRows?: number;
  /** Show at most this many rows behind a "Show all N" button. */
  limit?: number;
  /** Max height of the row body once expanded (scrolls inside the card). */
  maxHeight?: string;
  empty?: JSX.Element;
}) {
  const [open, setOpen] = createSignal<string | null>(null);
  const [showAll, setShowAll] = createSignal(false);
  const [unlimited, setUnlimited] = createSignal(false);
  const cols = () => p.columns.map(c => c.width).join(" ");
  const narrow = () => p.columns.filter(c => !c.hideNarrow).map(c => c.narrowWidth ?? c.width).join(" ");
  const visible = () => (p.rows ?? []).filter(r => showAll() || !p.collapse?.(r));
  const shown = () => (unlimited() || p.limit == null ? visible() : visible().slice(0, p.limit));
  const folded = () => (p.rows ?? []).filter(r => p.collapse?.(r)).length;
  const scrollBody = () => !!p.maxHeight && (unlimited() || showAll() || (p.limit == null && shown().length > 6));
  const cells = (r: T) => <For each={p.columns}>{c =>
    <span role="cell" data-align={c.align ?? "start"} data-narrow={c.hideNarrow ? "hide" : undefined}>{c.cell(r)}</span>
  }</For>;
  return <div class="st-table" role="table" aria-label={p.label} style={{ "--st-cols": cols(), "--st-cols-narrow": narrow() }}>
    <div class="st-tr st-th" role="row">
      <For each={p.columns}>{c => <span role="columnheader" data-align={c.align ?? "start"} data-narrow={c.hideNarrow ? "hide" : undefined}>{c.header}</span>}</For>
    </div>
    <Show when={p.rows} fallback={<For each={Array.from({ length: p.skeletonRows ?? 3 })}>{() =>
      <div class="st-tr" role="row" aria-hidden="true"><For each={p.columns}>{(c, i) =>
        <span data-narrow={c.hideNarrow ? "hide" : undefined}><span class="st-sk" style={{ width: i() === 0 ? "60%" : "100%" }} /></span>
      }</For></div>}</For>}>
      <Show when={p.rows!.length} fallback={<div class="st-tr" role="row"><span role="cell" class="routing-muted">{p.empty ?? "No data."}</span></div>}>
        <div classList={{ "st-tbody": true, "st-tbody-scroll": scrollBody() }} style={scrollBody() ? { "max-height": p.maxHeight } : undefined}>
          <For each={shown()}>{r => {
            const key = p.rowKey(r);
            return <Show when={p.detail} fallback={<div class="st-tr" role="row">{cells(r)}</div>}>
              <div class="st-tr st-row" role="row" tabIndex={0} aria-expanded={open() === key}
                onClick={() => setOpen(o => o === key ? null : key)}
                onKeyDown={e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setOpen(o => o === key ? null : key); } }}>{cells(r)}</div>
              <Show when={open() === key}><div class="st-detail" role="row"><div role="cell">{p.detail!(r)}</div></div></Show>
            </Show>;
          }}</For>
        </div>
        <Show when={p.limit != null && visible().length > p.limit}>
          <button type="button" class="st-more" onClick={() => setUnlimited(v => !v)} aria-expanded={unlimited()}>
            {unlimited() ? `Show top ${p.limit}` : `Show all ${visible().length}`}
          </button>
        </Show>
        <Show when={folded() > 0}>
          <button type="button" class="st-more" onClick={() => setShowAll(v => !v)} aria-expanded={showAll()}>
            {showAll() ? `Hide ${p.collapsedLabel ?? "rows"}` : `${folded()} ${p.collapsedLabel ?? "more"} · show`}
          </button>
        </Show>
      </Show>
    </Show>
  </div>;
}
