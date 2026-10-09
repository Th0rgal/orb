import { onCleanup, onMount, type JSX } from "solid-js";
import { Portal } from "solid-js/web";
import { mountOverlay, OverlayContext, overlayZIndex, overlayHasModalAbove, overlayTrigger, useOverlayParent, type OverlayLayer } from "./overlayLayer";
import { useOverlayPosition, type OverlayPlacement } from "./overlayPosition";
import "./Dialog.css";
export function Popover(p: {
  anchor?: HTMLElement; point?: {x: number; y: number}; placement?: OverlayPlacement; width?: number | "anchor";
  label: string; class?: string; role?: "dialog" | "menu" | "listbox" | "tooltip"; id?: string;
  busy?: boolean; trap?: boolean; restoreFocus?: boolean; initialFocus?: () => HTMLElement | undefined; returnFocus?: HTMLElement | null;
  onClose: () => void; onEscape?: () => void; onKeyDown?: JSX.EventHandlerUnion<HTMLDivElement, KeyboardEvent>;
  onMouseEnter?: () => void; onMouseLeave?: () => void; children: JSX.Element; ref?: (el: HTMLDivElement) => void;
}) {
  let root!: HTMLDivElement;
  const layer: OverlayLayer = {root: () => root, parent: useOverlayParent()};
  // If no explicit anchor is available, use the focused trigger captured before
  // the Portal mounts. Callers with pointer-only triggers must pass their anchor.
  const trigger = overlayTrigger();
  const anchor = p.anchor ?? (p.point ? undefined : trigger);
  const position = useOverlayPosition(() => root, {anchor: () => anchor, point: () => p.point, placement: p.placement, width: () => p.width});
  onMount(() => onCleanup(mountOverlay(layer, {close: p.onClose, escape: p.onEscape, busy: () => !!p.busy, trap: p.trap, restoreFocus: p.restoreFocus, initialFocus: p.initialFocus, returnFocus: p.returnFocus ?? p.anchor ?? trigger, contains: node => !!anchor?.contains(node)})));
  return <OverlayContext.Provider value={layer}><Portal><div ref={el => {root = el; p.ref?.(el);}} id={p.id} role={p.role ?? "dialog"} aria-label={p.label} aria-busy={p.busy || undefined} inert={overlayHasModalAbove(layer)} tabIndex={-1}
    class={`overlay-popover ${p.class ?? ""}`} style={{...position(), "z-index": overlayZIndex(layer)}} onPointerDown={e => e.stopPropagation()} onKeyDown={p.onKeyDown} onMouseEnter={p.onMouseEnter} onMouseLeave={p.onMouseLeave}>{p.children}</div></Portal></OverlayContext.Provider>;
}
