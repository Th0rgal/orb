import { navigateOverlayItems } from "./overlayNavigation";
import { For, onCleanup, type JSX } from "solid-js";
import { Popover } from "./Popover";
import type { OverlayPlacement } from "./overlayPosition";
export type MenuEntry =
  | { kind: "sep" }
  | { kind: "item"; label: string; icon?: (p: {size?: number}) => JSX.Element; danger?: boolean; disabled?: boolean; openOnHover?: boolean; onClick: (anchor?: HTMLButtonElement) => void };

/** Menu navigation is shared by command menus, including custom submenu content. */
export function Menu(p: {
  label: string; anchor?: HTMLElement; point?: {x:number;y:number}; width?: number; placement?: OverlayPlacement;
  class?: string; focus?: boolean; busy?: boolean; onClose: () => void; onEscape?: () => void;
  onMouseEnter?: () => void; onMouseLeave?: () => void; children: JSX.Element; ref?: (el:HTMLDivElement) => void;
}) {
  let root!: HTMLDivElement;
  return <Popover {...p} ref={el => {root = el; p.ref?.(el);}} role="menu" class={`menu ${p.class ?? ""}`} width={p.width ?? 220}
    initialFocus={() => p.focus === false ? root : root.querySelector<HTMLElement>('button:not(:disabled)') ?? root}
    onPointerMove={e => {
      const item = (e.target as HTMLElement).closest<HTMLButtonElement>("button.menu-item");
      if (item && !item.disabled && item.getAttribute("aria-disabled") !== "true" && item.closest('[role="menu"]') === root && item !== document.activeElement) item.focus({preventScroll: true});
    }}
    onKeyDown={e => {
      if (e.defaultPrevented || e.isComposing || (e.target as HTMLElement).closest('[role="menu"]') !== root) return;
      if (e.key === "ArrowLeft") {e.preventDefault(); e.stopPropagation(); (p.onEscape ?? p.onClose)(); return;}
      if (e.key === "Tab") {p.onClose(); return;}
      navigateOverlayItems(e, root, "button");
    }}>{p.children}</Popover>;
}
export function MenuList(p: {items: MenuEntry[]; onPick?: () => void; onDismissSubmenu?: () => void}) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const clear = () => { clearTimeout(timer); timer = undefined; };
  onCleanup(clear);
  const pick = (item: Extract<MenuEntry, {kind:"item"}>, anchor:HTMLButtonElement) => {if(item.disabled)return; clear(); if(!item.openOnHover)p.onPick?.(); item.onClick(anchor);};
  return <For each={p.items}>{item => item.kind === "sep" ? <div class="menu-sep" role="separator"/> : <button type="button" role="menuitem" class={`menu-item ${item.danger ? "danger" : ""}`} disabled={item.disabled} aria-haspopup={item.openOnHover ? "menu" : undefined}
    onMouseEnter={e => {clear(); const anchor=e.currentTarget; if(!item.openOnHover)p.onDismissSubmenu?.(); else if(!item.disabled)timer=setTimeout(()=>pick(item,anchor),180);}}
    onMouseLeave={clear} onFocus={() => {if(!item.openOnHover)p.onDismissSubmenu?.();}}
    onKeyDown={e => {if(item.openOnHover && e.key === "ArrowRight"){e.preventDefault();e.stopPropagation();pick(item,e.currentTarget);}}}
    onClick={e=>pick(item,e.currentTarget)}><span class="menu-ico">{item.icon && <item.icon/>}</span>{item.label}{item.openOnHover && <span class="menu-chevron" aria-hidden="true">›</span>}</button>}</For>;
}
export function PopupMenu(p: {x:number;y:number;items:MenuEntry[];onClose:()=>void;focus?:boolean;onDismissSubmenu?:()=>void;children?:JSX.Element}) {
  return <Menu label="Actions" point={{x:p.x,y:p.y}} class="popup-menu" focus={p.focus} onClose={p.onClose}>
    <MenuList items={p.items} onDismissSubmenu={p.onDismissSubmenu} onPick={p.onClose}/>{p.children}
  </Menu>;
}
