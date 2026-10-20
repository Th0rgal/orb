import { onCleanup, onMount } from "solid-js";

/** Scroll anchoring shared by every conversation view (missions, cloud agents):
 * follow the bottom while the reader is there, stop the moment they scroll up,
 * and keep following as streamed Markdown or the dock changes height. */
export function createPinnedScroll(o: { key: () => string; onResize?: () => void }) {
  let scroller: HTMLDivElement | undefined;
  let nearBottom = true;
  let landedFor = "";
  const scrollIfPinned = () => {
    if (nearBottom && !scroller?.dataset.panelResizing && !scroller?.querySelector(".user.editing")) scroller?.scrollTo({ top: scroller.scrollHeight });
  };
  return {
    ref: (el: HTMLDivElement) => { scroller = el; },
    el: () => scroller,
    pinned: () => nearBottom,
    /** A send by the reader: follow the new message again. */
    pin: () => { nearBottom = true; queueMicrotask(scrollIfPinned); },
    scrollIfPinned,
    onScroll: () => {
      if (scroller?.dataset.panelResizing) return;
      nearBottom = !scroller || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
    },
    /** First paint lands at the bottom: hide the column for the few frames the
     * virtual list needs to mount and measure the tail, instead of showing the top then jumping. */
    landAtBottom: () => {
      const key = o.key();
      if (!scroller || landedFor === key || !nearBottom) { landedFor = key; return; }
      landedFor = key;
      const el = scroller;
      el.classList.add("landing");
      // Stop following the moment the reader (or a test) scrolls away during the landing frames.
      const land = () => { if (nearBottom) el.scrollTo({ top: el.scrollHeight }); };
      land();
      // rAF can be throttled (background window, headless WebKit): never leave the thread hidden.
      let shown = false;
      const show = () => { if (shown) return; shown = true; land(); el.classList.remove("landing"); };
      const fallback = setTimeout(show, 80);
      requestAnimationFrame(() => { land(); requestAnimationFrame(() => { clearTimeout(fallback); show(); }); });
    },
    /** Resize notifications run after streaming Markdown has changed layout. */
    observe: () => onMount(() => {
      if (!scroller) return;
      const observer = new ResizeObserver(() => { if (nearBottom) scrollIfPinned(); o.onResize?.(); });
      const content = scroller.querySelector(".col");
      // Border box: the dock height is bottom padding, which a content-box observer misses.
      if (content) observer.observe(content, { box: "border-box" });
      const dock = scroller.nextElementSibling;
      if (dock) observer.observe(dock);
      onCleanup(() => observer.disconnect());
    }),
  };
}
