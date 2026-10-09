import { Show, type JSX } from 'solid-js';
import { ChevronDown } from './icons';
import { Menu } from './Menu';
import { Picker } from './Picker';

export function AgentChoiceMenu(p: { label: string; meta?: boolean; dialog?: boolean; onClose: () => void; children: JSX.Element }) {
  return <Menu label={p.label} class={p.meta ? "na-menu" : "model-menu"} onClose={p.onClose}>{p.children}</Menu>;
}

/** The same trigger, menu rows and selection treatment as the agent composer. */
export function AgentChoice(p: {
  label: string; value: string; items: {value: string; label: string; description?:string}[]; description?:string;
  open: boolean; onOpen: () => void; onClose: () => void; onSelect: (value: string) => void;
  searchable?: boolean; searchLabel?: string; emptyLabel?: string; meta?: boolean; disabled?: boolean; icon?: JSX.Element; suffix?: JSX.Element;
}) {
  return <div class={p.meta ? 'na-drop' : 'model-wrap'} onPointerDown={e => e.stopPropagation()}>
    <button class={`${p.meta ? 'na-drop-btn' : 'model'} ${p.open ? 'on' : ''}`} aria-label={p.label} title={p.description ?? p.label} aria-haspopup="dialog" aria-expanded={p.open} disabled={p.disabled}
      onClick={e => {e.currentTarget.focus(); if(p.open) p.onClose(); else p.onOpen();}}>
      {p.icon}<span>{p.items.find(item => item.value === p.value)?.label ?? p.label}</span>{p.suffix}<ChevronDown size={12}/>
    </button>
    <Show when={p.open}><Picker label={p.label} searchable={!!p.searchable} searchLabel={p.searchLabel ?? "Search models"}
      items={p.items.map(item => ({id:item.value,label:item.label,description:item.description}))} selected={p.value}
      emptyLabel={p.emptyLabel} noResultsLabel={p.emptyLabel} onSelect={value => {p.onSelect(value); p.onClose();}} onClose={p.onClose}/></Show>
  </div>;
}
