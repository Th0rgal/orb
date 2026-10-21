import { createEffect, createSignal, onCleanup, onMount, type JSX } from "solid-js";
export type OverlayPlacement = "bottom-start" | "bottom-end" | "top-start" | "top-end" | "right-start";
/** Top padding of a menu, so its first row lines up with the row that opened it. */
const menuInset = (el: HTMLElement) => parseFloat(getComputedStyle(el).paddingTop) || 0;
export function useOverlayPosition(root: () => HTMLElement, options: {
  anchor?: () => HTMLElement | undefined; point?: () => {x: number; y: number} | undefined;
  placement?: OverlayPlacement; width?: () => number | "anchor" | undefined;
}) {
  const [style, setStyle] = createSignal<JSX.CSSProperties>({position: "fixed"});
  onMount(() => {
    const place = () => {
      const el = root(), anchor = options.anchor?.();
      // A detached (re-rendered) anchor measures as a zero rect at the window origin;
      // keep the last good position until the caller hands over the live row.
      if (anchor && !anchor.isConnected) return;
      const a = anchor?.getBoundingClientRect();
      const point = options.point?.();
      const margin = 16, gap = 4;
      const requestedWidth = options.width?.();
      const width = Math.min(window.innerWidth - margin * 2, requestedWidth === "anchor" ? a?.width ?? el.offsetWidth : requestedWidth ?? el.offsetWidth);
      el.style.width = `${width}px`;
      el.style.maxHeight = `${window.innerHeight - margin * 2}px`;
      const height = el.getBoundingClientRect().height;
      const placement = options.placement ?? "bottom-start";
      let x = point?.x ?? a?.left ?? margin;
      let y = point?.y ?? a?.bottom ?? margin;
      if (a) {
        if (placement.endsWith("end")) x = a.right - width;
        if (placement.startsWith("top")) { y = a.top - height - gap; if (y < margin) y = a.bottom + gap; }
        else if (placement.startsWith("right")) { x = a.right + gap; y = a.top - menuInset(el);
          if (x + width > window.innerWidth - margin && a.left - width - gap >= margin) x = a.left - width - gap;
          // Near the bottom edge, grow upward from the row instead of sliding away from it.
          if (y + height > window.innerHeight - margin) y = Math.max(margin, a.bottom + menuInset(el) - height);
        }
        else { y = a.bottom + gap; if (y + height > window.innerHeight - margin && a.top - height - gap >= margin) y = a.top - height - gap; }
      }
      setStyle({position: "fixed", left: `${Math.max(margin, Math.min(x, window.innerWidth - width - margin))}px`, top: `${Math.max(margin, Math.min(y, window.innerHeight - height - margin))}px`, width: `${width}px`, "max-height": `${window.innerHeight - margin * 2}px`});
    };
    const observer = new ResizeObserver(place); observer.observe(root());
    let observed: HTMLElement | undefined;
    createEffect(() => {
      const anchor = options.anchor?.();
      if (observed && observed !== anchor) observer.unobserve(observed);
      if (anchor && anchor !== observed) observer.observe(anchor);
      observed = anchor; options.point?.(); place();
    }); window.addEventListener("resize", place); window.addEventListener("scroll", place, true);
    onCleanup(() => { observer.disconnect(); window.removeEventListener("resize", place); window.removeEventListener("scroll", place, true); });
  });
  return style;
}
