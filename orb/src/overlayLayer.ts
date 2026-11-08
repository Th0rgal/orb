import { createContext, createSignal, useContext } from "solid-js";
import { trapFocus } from "./focusScope";

// WebKit does not focus buttons on pointer clicks. Remember the real trigger so
// anchored surfaces and focus restoration do not depend on that browser quirk.
let lastTrigger: HTMLElement | undefined;
window.addEventListener("pointerdown", event => {
  const target = event.target instanceof Element ? event.target.closest<HTMLElement>("button, [role='button'], input, select, textarea") : null;
  if (target) lastTrigger = target;
}, true);
window.addEventListener("focusin", event => {
  if (!(event.target instanceof HTMLElement)) return;
  // WebKit may focus a tabindex ancestor on right-click instead of the button.
  // That fallback must not replace the actual pointer target used for return focus.
  if (lastTrigger && event.target !== lastTrigger && event.target.contains(lastTrigger)) return;
  lastTrigger = event.target;
});
export const overlayTrigger = () => lastTrigger?.isConnected ? lastTrigger : document.activeElement instanceof HTMLElement && document.activeElement !== document.body ? document.activeElement : undefined;

export type OverlayLayer = { root: () => HTMLElement; parent?: OverlayLayer; modal?: boolean };
export const OverlayContext = createContext<OverlayLayer>();
export const useOverlayParent = () => useContext(OverlayContext);
const [layers, setLayers] = createSignal<OverlayLayer[]>([]);
export const hasOverlay = () => layers().length > 0;
export const hasInteractiveOverlay = () => layers().some(layer => layer.root().getAttribute("role") !== "tooltip");
export const overlayFirstModal = (layer: OverlayLayer) => layers().find(item => item.modal) === layer;
export const overlayIndex = (layer: OverlayLayer) => layers().indexOf(layer);
export const overlayTop = (layer: OverlayLayer) => layers().at(-1) === layer;
export const overlayZIndex = (layer: OverlayLayer) => 1300 + Math.max(0, overlayIndex(layer)) * 2;
export const overlayHasModalAbove = (layer: OverlayLayer) => layers().slice(overlayIndex(layer) + 1).some(item => item.modal);
type InertHold = { holders: Set<OverlayLayer>; original: boolean };
const inerted = new Map<HTMLElement, InertHold>();
let overflow = "";
let scrollLocked = false;
let observer: MutationObserver | undefined;
function readInert(el: HTMLElement): boolean {
  return el.inert === true || el.hasAttribute("inert");
}
function writeInert(el: HTMLElement, value: boolean) {
  el.inert = value;
  if (value) el.setAttribute("inert", "");
  else el.removeAttribute("inert");
}
function releaseInert(el: HTMLElement) {
  const hold = inerted.get(el);
  if (!hold) return;
  writeInert(el, hold.original);
  inerted.delete(el);
}
function syncInert(el: HTMLElement, modalLayers: OverlayLayer[]) {
  const hold = inerted.get(el);
  if (!modalLayers.length) {
    releaseInert(el);
    return;
  }
  if (hold) {
    hold.holders = new Set(modalLayers);
    writeInert(el, true);
    return;
  }
  inerted.set(el, { holders: new Set(modalLayers), original: readInert(el) });
  writeInert(el, true);
}
export function inertHoldDepth(el: HTMLElement): number {
  return inerted.get(el)?.holders.size ?? 0;
}
function updateBackground() {
  const modalLayers = layers().filter(layer => layer.modal);
  const wanted = new Map<HTMLElement, OverlayLayer[]>();
  if (modalLayers.length > 0) {
    for (const child of Array.from(document.body.children)) {
      if (!(child instanceof HTMLElement) || layers().some(layer => child.contains(layer.root()))) continue;
      wanted.set(child, modalLayers);
    }
    for (let i = 0; i < modalLayers.length; i++) {
      const modal = modalLayers[i];
      const above = modalLayers.slice(i + 1);
      if (!above.length) continue;
      const modalContainer = Array.from(document.body.children).find(
        (child): child is HTMLElement => child instanceof HTMLElement && child.contains(modal.root()),
      );
      if (!modalContainer || modalContainer === modal.root()) {
        wanted.set(modal.root(), above);
        continue;
      }
      if (!layers().some(other => other !== modal && modalContainer.contains(other.root()))) {
        wanted.set(modalContainer, above);
      } else {
        wanted.set(modal.root(), above);
      }
    }
  }
  for (const el of [...inerted.keys()]) if (!wanted.has(el)) releaseInert(el);
  for (const [el, owners] of wanted) syncInert(el, owners);
}
export function mountOverlay(layer: OverlayLayer, options: {
  close: () => void; busy?: () => boolean; trap?: boolean; initialFocus?: () => HTMLElement | undefined;
  returnFocus?: HTMLElement | null; restoreFocus?: boolean; contains?: (target: Node) => boolean; outsideGesture?: boolean;
  /** Only Escape or explicit controls close it; outside presses are ignored. */
  persistent?: boolean;
  escape?: () => void;
}) {
  const previous = options.returnFocus !== undefined ? options.returnFocus : overlayTrigger() ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
  const wasModal = layers().some(item => item.modal);
  // Solid mounts portalled children first. Preserve logical parent/child order.
  setLayers(current => {
    const child = current.findIndex(item => item.parent === layer);
    return child < 0 ? [...current, layer] : [...current.slice(0, child), layer, ...current.slice(child)];
  });
  if (layer.modal && !wasModal) { overflow = document.body.style.overflow; scrollLocked = true; document.body.style.overflow = "hidden"; }
  if (!observer) { observer = new MutationObserver(updateBackground); observer.observe(document.body, {childList: true}); }
  updateBackground();
  const owns = (node: Node) => layer.root().contains(node) || !!options.contains?.(node) || layers().some(child => {
    let parent = child.parent;
    while (parent) { if (parent === layer) return child.root().contains(node); parent = parent.parent; }
    return false;
  });
  const dismiss = () => { if (overlayTop(layer) && !options.busy?.()) options.close(); };
  let pressedOutside = false;
  const down = (event: PointerEvent) => {
    if (!overlayTop(layer)) return;
    pressedOutside = !options.persistent && !owns(event.target as Node);
    if (pressedOutside && !options.outsideGesture) dismiss();
  };
  const up = (event: PointerEvent) => {
    if (options.outsideGesture && pressedOutside && !owns(event.target as Node)) dismiss();
    pressedOutside = false;
  };
  const key = (event: KeyboardEvent) => {
    if (!overlayTop(layer) || event.defaultPrevented || event.isComposing || event.key !== "Escape") return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (!options.busy?.()) (options.escape ?? options.close)();
  };
  window.addEventListener("pointerdown", down, true);
  window.addEventListener("pointerup", up, true);
  window.addEventListener("keydown", key, true);
  const release = options.trap === false ? undefined : trapFocus(layer.root(), dismiss, {parent: layer.parent?.root, returnFocus: previous, initialFocus: options.initialFocus});
  return () => {
    const top = overlayTop(layer);
    window.removeEventListener("pointerdown", down, true);
    window.removeEventListener("pointerup", up, true);
    window.removeEventListener("keydown", key, true);
    setLayers(current => current.filter(item => item !== layer));
    updateBackground();
    release?.();
    if (!release && options.restoreFocus !== false && top && previous?.isConnected) previous.focus({preventScroll: true});
    if (scrollLocked && !layers().some(item => item.modal)) {document.body.style.overflow = overflow; scrollLocked = false;}
    if (!layers().length) { observer?.disconnect(); observer = undefined; }
  };
}
