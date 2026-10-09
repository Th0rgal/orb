import { Popover } from "./Popover";
import { ChevronDown } from "./icons";
import { For, Show, createMemo, createSignal, createUniqueId } from "solid-js";

export function RoutingPicker(p: { label: string; value: string; options: { id: string; name: string; detail?: string }[]; onInput: (value: string) => void }) {
  const id = createUniqueId();
  let host!: HTMLDivElement;
  const show = () => setOpen(true);
  const [open, setOpen] = createSignal(false);
  const [active, setActive] = createSignal(-1);
  const matches = createMemo(() => p.options.filter(o => `${o.name} ${o.id}`.toLowerCase().includes(p.value.toLowerCase())).slice(0, 30));
  const choose = (value: string) => { p.onInput(value); setOpen(false); setActive(-1); };
  return <div class="routing-picker" ref={host}>
    <input class="s-input" role="combobox" aria-label={p.label} aria-autocomplete="list" aria-expanded={open()} aria-controls={id}
      aria-activedescendant={open() && active() >= 0 ? `${id}-${active()}` : undefined} value={p.value}
      onFocus={() => { show(); setActive(-1); }} onBlur={() => setOpen(false)}
      onInput={e => { p.onInput(e.currentTarget.value); show(); setActive(-1); }}
      onKeyDown={e => {
        if (e.isComposing) return;
        if (e.key === "Escape" && open()) { e.preventDefault(); e.stopPropagation(); setOpen(false); }
        if (["ArrowDown", "ArrowUp"].includes(e.key) && matches().length) { e.preventDefault(); show(); setActive(i => ((i < 0 && e.key === "ArrowUp" ? 0 : i) + (e.key === "ArrowDown" ? 1 : matches().length - 1) + matches().length) % matches().length); document.getElementById(`${id}-${active()}`)?.scrollIntoView?.({ block: "nearest" }); }
        if (e.key === "Enter" && open() && active() >= 0 && matches()[active()]) { e.preventDefault(); choose(matches()[active()].id); }
      }} />
    <span class="orb-select-arrows" aria-hidden="true"><ChevronDown size={10}/><ChevronDown size={10}/></span>
    <Show when={open()}>
      <Popover anchor={host} trap={false} width="anchor" onClose={() => setOpen(false)} class="routing-picker-list orb-options" role="listbox" id={id} label={`${p.label} suggestions`}>
        <For each={matches()}>{(o, i) => <div role="option" id={`${id}-${i()}`} aria-selected={p.value === o.id} data-active={active() === i()} class="routing-picker-option"
          onPointerDown={e => { e.preventDefault(); choose(o.id); }}>
          <span title={o.id}>{o.name || o.id}</span><Show when={o.detail}><small>{o.detail}</small></Show>
        </div>}</For>
      <Show when={!matches().length}><p class="picker-state" role="status">{p.options.length ? "No results" : "No options available"}</p></Show></Popover>
    </Show>
  </div>;
}
