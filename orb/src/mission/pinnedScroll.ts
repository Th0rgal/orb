import { createSignal, onCleanup, onMount } from "solid-js";

/** Scroll anchoring shared by every conversation view (missions, cloud agents).
 *
 * - Pinned (following the bottom) changes only on the reader's own scrolling:
 *   wheel, touch, navigation keys or a scrollbar drag. Moving up unpins at
 *   once; coming back within `NEAR` px of the bottom pins again. Layout
 *   changes (streamed lines, a narration fold collapsing, clamping) never flip
 *   it, so a slow trackpad scroll up is not pulled back down by the next delta.
 * - Pinned: every resize of the column or the dock keeps the bottom in view.
 * - Not pinned: the element at the top of the viewport is the anchor; after a
 *   resize it is put back at the same screen position, so content growing or
 *   folding anywhere leaves what the reader is looking at still. (CSS
 *   `overflow-anchor` stays off: the virtual list corrects its own rows, and
 *   the browser's choice of anchor fights both.)
 * - Not pinned, the column never shrinks: when content below the reader
 *   folds away (narration joining the Worked fold), its height is held as a
 *   reserve so the browser does not clamp the scroll up into what they read.
 *   The reserve goes as soon as they follow the bottom again. */
const NEAR = 24;
/** Input within this window of a scroll event makes it the reader's. */
const INTENT_MS = 300;
const NAV_KEYS = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "]);

/** scrollTo where available (jsdom has none). */
const toBottom = (el: HTMLElement) => { if (typeof el.scrollTo === "function") el.scrollTo({ top: el.scrollHeight }); else el.scrollTop = el.scrollHeight; };
const gapOf = (el: HTMLElement) => el.scrollHeight - el.scrollTop - el.clientHeight;
const editable = (t: EventTarget | null) => t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));

export function createPinnedScroll(o: { key: () => string; onResize?: () => void }) {
  let scroller: HTMLDivElement | undefined;
  const [pinned, setPinned] = createSignal(true);
  let landedFor = "";
  let intentAt = -Infinity, dragging = false, lastTop = 0, lastColHeight = 0;
  let anchor: { el: Element; top: number; row: Element | null; rowTop: number } | undefined;
  let content: HTMLElement | undefined, held = 0;
  const reserve = (px: number) => { held = px; scroller?.style.setProperty("--scroll-reserve", px ? `${px}px` : ""); };
  const intent = () => dragging || performance.now() - intentAt < INTENT_MS;
  const remember = () => {
    const el = scroller;
    lastTop = el?.scrollTop ?? 0; lastColHeight = content?.offsetHeight ?? 0;
    // Hit-testing forces layout: only a reader who is not following needs an anchor.
    if (!el || pinned() || typeof document.elementFromPoint !== "function") { anchor = undefined; return; }
    const box = el.getBoundingClientRect();
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + 8);
    const row = hit?.closest("[data-turn-key]") ?? null;
    anchor = hit && hit !== el && el.contains(hit) ? { el: hit, top: hit.getBoundingClientRect().top, row, rowTop: row?.getBoundingClientRect().top ?? 0 } : undefined;
  };
  /** Put the anchor back where the reader saw it. A folded-away anchor falls back to its turn. */
  const restore = () => {
    const el = scroller;
    if (!el) return;
    const height = content?.offsetHeight ?? 0;
    if (content && height < lastColHeight && lastColHeight > held) reserve(lastColHeight);
    if (!anchor) return remember();
    const [target, top] = anchor.el.isConnected ? [anchor.el, anchor.top] : anchor.row?.isConnected ? [anchor.row, anchor.rowTop] : [null, 0];
    if (target) {
      const delta = target.getBoundingClientRect().top - top;
      if (Math.abs(delta) >= 0.5) el.scrollTop += delta;
    }
    remember();
  };
  const scrollIfPinned = () => {
    if (pinned() && held) reserve(0);
    if (pinned() && scroller && !scroller.dataset.panelResizing && !scroller.querySelector(".user.editing")) { toBottom(scroller); }
  };
  const markIntent = () => { intentAt = performance.now(); };
  const onWheel = (e: WheelEvent) => {
    markIntent();
    if (e.deltaY < 0) setPinned(false);
    else if (e.deltaY > 0 && scroller && gapOf(scroller) < NEAR) setPinned(true);
  };
  const onKey = (e: KeyboardEvent) => { if (NAV_KEYS.has(e.key) && !editable(e.target)) markIntent(); };
  // A press on the scroller itself (not its content) is the scrollbar.
  const onPointerDown = (e: PointerEvent) => { if (e.target === scroller) { dragging = true; markIntent(); } };
  const onPointerUp = () => { if (dragging) { dragging = false; markIntent(); } };
  const attach = (el: HTMLDivElement) => {
    el.addEventListener("wheel", onWheel, { passive: true });
    el.addEventListener("touchstart", markIntent, { passive: true });
    el.addEventListener("touchmove", markIntent, { passive: true });
    el.addEventListener("touchend", markIntent, { passive: true });
    el.addEventListener("pointerdown", onPointerDown);
    window.addEventListener("pointerup", onPointerUp);
    window.addEventListener("keydown", onKey);
    onCleanup(() => {
      el.removeEventListener("wheel", onWheel); el.removeEventListener("touchstart", markIntent); el.removeEventListener("touchmove", markIntent);
      el.removeEventListener("touchend", markIntent); el.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("pointerup", onPointerUp); window.removeEventListener("keydown", onKey);
    });
  };
  return {
    ref: (el: HTMLDivElement) => { scroller = el; },
    el: () => scroller,
    /** Reactive: false while the reader is somewhere above the bottom. */
    pinned,
    /** A send by the reader, or "Jump to latest": follow the newest message again. */
    pin: () => { setPinned(true); queueMicrotask(scrollIfPinned); },
    scrollIfPinned,
    onScroll: () => {
      const el = scroller;
      if (!el || el.dataset.panelResizing) return;
      const top = el.scrollTop, gap = gapOf(el);
      if (intent()) {
        if (top < lastTop - 0.5) setPinned(false);
        else if (gap < NEAR) { setPinned(true); if (held) { reserve(0); toBottom(el); } }
      } else if (pinned() && gap >= NEAR && Math.abs(top - lastTop) > 1) {
        // Moved away by the app itself (a chapter, a search hit). Layout never
        // does this: growth fires no scroll event, and a shrink clamps to the bottom.
        setPinned(false);
      }
      remember();
    },
    /** First paint lands at the bottom: hide the column for the few frames the
     * virtual list needs to mount and measure the tail, instead of showing the top then jumping. */
    landAtBottom: () => {
      const key = o.key();
      if (!scroller || landedFor === key || !pinned()) { landedFor = key; return; }
      landedFor = key;
      const el = scroller;
      el.classList.add("landing");
      // Stop following the moment the reader (or a test) scrolls away during the landing frames.
      const land = () => { if (pinned()) toBottom(el); };
      land();
      // rAF can be throttled (background window, headless WebKit): never leave the thread hidden.
      let shown = false;
      const show = () => { if (shown) return; shown = true; land(); el.classList.remove("landing"); };
      const fallback = setTimeout(show, 80);
      requestAnimationFrame(() => { land(); requestAnimationFrame(() => { clearTimeout(fallback); show(); }); });
    },
    /** Resize notifications run after streaming Markdown has changed layout, before paint. */
    observe: () => onMount(() => {
      if (!scroller) return;
      attach(scroller);
      content = scroller.querySelector<HTMLElement>(":scope > .col") ?? undefined;
      remember();
      const observer = new ResizeObserver(() => {
        if (pinned()) scrollIfPinned();
        else if (!scroller?.dataset.panelResizing) restore();
        o.onResize?.();
      });
      content = scroller.querySelector<HTMLElement>(":scope > .col") ?? undefined;
      // Border box: the dock height is bottom padding, which a content-box observer misses.
      if (content) observer.observe(content, { box: "border-box" });
      const dock = scroller.nextElementSibling;
      if (dock) observer.observe(dock);
      onCleanup(() => observer.disconnect());
    }),
  };
}
