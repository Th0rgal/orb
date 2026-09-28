import { For, Show, onCleanup, onMount, createSignal, createMemo, type JSX } from 'solid-js';
import { ChevronDown } from './icons';
import { trapFocus } from './focusScope';

export function AgentChoiceMenu(p: { label: string; meta?: boolean; dialog?: boolean; onClose: () => void; children: JSX.Element }) {
  let root!: HTMLDivElement;
  onMount(() => {
    const release = trapFocus(root, p.onClose, {initialFocus: () => root.querySelector<HTMLElement>('input') ?? root.querySelector<HTMLElement>('[aria-checked="true"]') ?? undefined});
    const outside = (event: PointerEvent) => { if (!root.contains(event.target as Node)) p.onClose(); };
    document.addEventListener('pointerdown', outside);
    onCleanup(() => { document.removeEventListener('pointerdown', outside); release(); });
  });
  return <div ref={root} class={`menu ${p.meta ? 'na-menu' : 'model-menu'}`} role={p.dialog ? 'dialog' : 'menu'} aria-label={p.label} onPointerDown={e => e.stopPropagation()} onKeyDown={e => {
    if (eventIsTextNavigation(e) || p.dialog || !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    const items = Array.from(root.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]:not(:disabled)'));
    if (!items.length) return;
    e.preventDefault();
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    const next = current < 0 ? (e.key === 'ArrowUp' || e.key === 'End' ? items.length - 1 : 0) : e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (current + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next].focus(); items[next].scrollIntoView?.({block: 'nearest'});
  }}>{p.children}</div>;
}

function eventIsTextNavigation(event: KeyboardEvent) {
  return event.target instanceof HTMLInputElement && ['Home', 'End'].includes(event.key);
}

/** The same trigger, menu rows and selection treatment as the agent composer. */
export function AgentChoice(p: {
  label: string; value: string; items: {value: string; label: string; description?:string}[]; description?:string;
  open: boolean; onOpen: () => void; onClose: () => void; onSelect: (value: string) => void;
  searchable?: boolean; searchLabel?: string; emptyLabel?: string; meta?: boolean; disabled?: boolean; icon?: JSX.Element; suffix?: JSX.Element;
}) {
  const [query,setQuery]=createSignal('');
  const filtered = createMemo(() => p.items.filter(item => !p.searchable || `${item.label} ${item.description ?? ''}`.toLowerCase().includes(query().trim().toLowerCase())));
  return <div class={p.meta ? 'na-drop' : 'model-wrap'} onPointerDown={e => e.stopPropagation()}>
    <button class={`${p.meta ? 'na-drop-btn' : 'model'} ${p.open ? 'on' : ''}`} aria-label={p.label} title={p.description ?? p.label} aria-haspopup="menu" aria-expanded={p.open} disabled={p.disabled}
      onClick={e => {e.currentTarget.focus(); if(p.open) p.onClose(); else {setQuery(''); p.onOpen();}}}>
      {p.icon}<span>{p.items.find(item => item.value === p.value)?.label ?? p.label}</span>{p.suffix}<ChevronDown size={12}/>
    </button>
    <Show when={p.open}><AgentChoiceMenu label={p.label} meta={p.meta} onClose={p.onClose}>
      <Show when={p.searchable}><input class="project-search" aria-label={p.searchLabel ?? 'Search models'} placeholder={`${p.searchLabel ?? 'Search models'}…`} value={query()} onInput={e=>setQuery(e.currentTarget.value)}/></Show><div class={p.meta ? 'na-menu-list' : 'cloud-choice-list'}><For each={filtered()}>{item => <button class={`menu-item ${item.value === p.value ? 'on' : ''}`} role="menuitemradio" title={item.description} aria-checked={item.value === p.value}
        onClick={() => {p.onSelect(item.value); p.onClose();}}>
        <span class="pick-name">{item.label}</span><span class="pick-check">{item.value === p.value ? '✓' : ''}</span>
      </button>}</For><Show when={p.searchable && !filtered().length}><p class="project-empty" role="status">{p.emptyLabel ?? 'No matching models'}</p></Show></div>
    </AgentChoiceMenu></Show>
  </div>;
}
