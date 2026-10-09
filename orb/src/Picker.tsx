import { Index, Show, createRenderEffect, createMemo, createSignal, createUniqueId, untrack, type JSX } from "solid-js";
import type { OverlayPlacement } from "./overlayPosition";
import { Popover } from "./Popover";
export type PickerItem = {id: string; label: string; description?: string; group?: string; disabled?: boolean; icon?: JSX.Element};
/** Search navigation changes only the active option. Selection needs activation. */
export function Picker(p: {
  label: string; items: PickerItem[]; selected?: string; anchor?: HTMLElement; width?: number; placement?: OverlayPlacement;
  onSelect: (id: string) => void; onClose: () => void; searchable?: boolean; searchLabel?: string;
  loading?: boolean; error?: string; onRetry?: () => void; emptyLabel?: string; noResultsLabel?: string;
  footer?: JSX.Element; class?: string;
}) {
  const id = createUniqueId();
  const [query, setQuery] = createSignal("");
  const [activeId, setActiveId] = createSignal<string | null>(null);
  let root!: HTMLDivElement, search: HTMLInputElement | undefined;
  const items = createMemo(() => p.items.filter(item => `${item.label} ${item.description ?? ""} ${item.id}`.toLowerCase().includes(query().trim().toLowerCase())));
  const active = () => items().findIndex(item => item.id === activeId());
  // Polling often rebuilds option objects. Preserve navigation by ID, and start
  // on the committed value instead of highlighting a second, unrelated option.
  createRenderEffect(() => {
    const rows = items(), current = untrack(activeId);
    const next = rows.find(item => item.id === current && !item.disabled)
      ?? rows.find(item => item.id === p.selected && !item.disabled)
      ?? rows.find(item => !item.disabled);
    setActiveId(next?.id ?? null);
  });
  const scroll = () => document.getElementById(`${id}-${active()}`)?.scrollIntoView?.({block: "nearest"});
  const move = (delta: number, edge?: "first" | "last") => {
    const rows = items(); let index = edge === "first" ? -1 : edge === "last" ? 0 : active();
    for (let n = 0; n < rows.length; n++) { index = (index + delta + rows.length) % rows.length; if (!rows[index].disabled) {setActiveId(rows[index].id); scroll();
      if (!search) document.getElementById(`${id}-${index}`)?.focus({preventScroll: true});
      break;} }
  };
  const choose = (index: number) => { const item = items()[index]; if (item && !item.disabled && !p.loading && !p.error) p.onSelect(item.id); };
  return <Popover label={p.label} placement={p.placement} anchor={p.anchor} width={p.width ?? 280} class={`picker ${p.class ?? ""}`} onClose={p.onClose} ref={el => {root = el;}}
    initialFocus={() => search ?? root.querySelector<HTMLElement>("[aria-selected='true']:not(:disabled)") ?? root.querySelector<HTMLElement>("[role='option']:not(:disabled)") ?? root}
    onKeyDown={e => {
      if (e.isComposing || e.defaultPrevented) return;
      if (["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) {
        if ((e.key === "Home" || e.key === "End") && e.target === search) return;
        e.preventDefault(); e.stopPropagation(); move(e.key === "ArrowUp" || e.key === "End" ? -1 : 1, e.key === "Home" ? "first" : e.key === "End" ? "last" : undefined);
      } else if ((e.key === "Enter" || (e.key === " " && e.target !== search)) && (e.target === search || (e.target as HTMLElement).closest('[role="option"]'))) {e.preventDefault(); e.stopPropagation(); choose(active());}
    }}>
    <Show when={p.searchable !== false}><input ref={search} class="picker-search" role="combobox" aria-label={p.searchLabel ?? `Search ${p.label.toLowerCase()}`} aria-expanded="true" aria-controls={id} aria-autocomplete="list" aria-activedescendant={active() >= 0 ? `${id}-${active()}` : undefined} placeholder={`${p.searchLabel ?? "Search"}…`} value={query()} onInput={e => setQuery(e.currentTarget.value)}/></Show>
    <Show when={!p.loading} fallback={<div class="picker-state" role="status">Loading…</div>}>
      <Show when={!p.error} fallback={<div class="picker-state" role="alert">{p.error}<Show when={p.onRetry}><button class="dlg-button" onClick={p.onRetry}>Try again</button></Show></div>}>
        <div class="picker-list" role="listbox" id={id} aria-label={p.label}>
          <Index each={items()}>{(item, index) => <>
            <Show when={item().group && item().group !== items()[index - 1]?.group}><div class="picker-group">{item().group}</div></Show>
            <button type="button" id={`${id}-${index}`} role="option" class="picker-row" aria-selected={item().id === p.selected} aria-disabled={item().disabled} disabled={item().disabled} data-active={active() === index}
              onPointerMove={e => {if (!item().disabled) {setActiveId(item().id); if (!search) e.currentTarget.focus({preventScroll: true});}}} onFocus={() => !item().disabled && setActiveId(item().id)} onClick={() => choose(index)}>
              {item().icon}<span class="picker-row-copy"><span>{item().label}</span><Show when={item().description}><small>{item().description}</small></Show></span><Show when={item().id === p.selected}><span aria-hidden="true">✓</span></Show>
            </button></>}</Index>
        </div>
        <Show when={!items().length}><div class="picker-state" role="status">{p.items.length ? p.noResultsLabel ?? "No results" : p.emptyLabel ?? "No options available"}</div></Show>
      </Show>
    </Show>
    <Show when={p.footer}><div class="picker-footer">{p.footer}</div></Show>
  </Popover>;
}
