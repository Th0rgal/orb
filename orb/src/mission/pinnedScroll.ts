import { createSignal, getOwner, onCleanup } from "solid-js";
import { NEAR, correct, scrollEvent, setScrollKeeper } from "./scrollPolicy";

/** Scroll anchoring shared by every conversation view (missions, cloud agents, /btw side questions).
 *
 * - Pinned (following the bottom) changes only on the reader's own scrolling
 *   (wheel, touch, navigation keys or scrollbar drag) or an explicit upward
 *   programmatic jump (chapter, search reveal). Moving up unpins at once; coming
 *   back within `NEAR` px of the bottom pins again. Layout changes (streamed
 *   lines, column/viewport resizes, narration folding, clamping) never flip it.
 * - Pinned: every resize of the viewport, column, blocks or dock keeps the bottom in view.
 * - Not pinned: the element at the top of the viewport is the anchor; after a
 *   resize it is put back at the same screen position, so content growing or
 *   folding anywhere leaves what the reader is looking at still. (CSS
 *   `overflow-anchor` stays off: the virtual list corrects its own rows, and
 *   the browser's choice of anchor fights both.)
 * - Not pinned, the column never shrinks: when content below the reader
 *   folds away (narration joining the Worked fold), its height is held as a
 *   reserve so the browser does not clamp the scroll up into what they read.
 *   The reserve goes as soon as they follow the bottom again.
 * - This is the only owner of the position: other code that changes the
 *   layout (virtual rows, panel resizes) calls the keeper instead of moving
 *   scrollTop, so a change is never corrected twice. The decisions are
 *   `scrollPolicy.ts`, proven in lean/Orb/Scroll.lean. */
/** Input within this window of a scroll event makes it the reader's. */
const INTENT_MS = 300;
const NAV_KEYS = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "]);
const TURN_SELECTOR = "[data-turn-key], [data-side-turn]";

/** scrollTo where available (jsdom has none). */
const toBottom = (el: HTMLElement) => { if (typeof el.scrollTo === "function") el.scrollTo({ top: el.scrollHeight }); else el.scrollTop = el.scrollHeight; };
const gapOf = (el: HTMLElement) => el.scrollHeight - el.scrollTop - el.clientHeight;
const editable = (t: EventTarget | null) => t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));

export function createPinnedScroll(o: { key: () => string; onResize?: () => void }) {
  let scroller: HTMLDivElement | undefined;
  let detach: (() => void) | undefined;
  const [pinned, setPinned] = createSignal(true);
  let landedFor = "";
  let intentAt = -Infinity, dragging = false, lastTop = 0, lastScrollHeight = 0, lastClientHeight = 0, lastColHeight = 0;
  let anchor: { el: Element; top: number; row: Element | null; rowTop: number } | undefined;
  let content: HTMLElement | undefined, held = 0;
  const reserve = (px: number) => { held = px; scroller?.style.setProperty("--scroll-reserve", px ? `${px}px` : ""); };
  const intent = () => dragging || performance.now() - intentAt < INTENT_MS;
  const recordGeometry = (el: HTMLElement | undefined) => {
    lastTop = el?.scrollTop ?? 0;
    lastScrollHeight = el?.scrollHeight ?? 0;
    lastClientHeight = el?.clientHeight ?? 0;
    lastColHeight = content?.offsetHeight ?? 0;
  };
  const syncBottom = (el: HTMLElement) => {
    toBottom(el);
    recordGeometry(el);
  };
  const remember = () => {
    const el = scroller;
    recordGeometry(el);
    // Hit-testing forces layout: only a reader who is not following needs an anchor.
    if (!el || pinned() || typeof document.elementFromPoint !== "function") { anchor = undefined; return; }
    const box = el.getBoundingClientRect();
    const hit = document.elementFromPoint(box.left + box.width / 2, box.top + 8);
    let row = hit?.closest(TURN_SELECTOR) ?? null;
    let target: Element | null | undefined = hit;
    // A container (the column, the list, a gap spacer) does not move with what
    // is inserted inside it, e.g. older turns paged in above: anchor on the
    // first turn the reader sees instead.
    if (!row) {
      row = [...el.querySelectorAll(TURN_SELECTOR)].find(r => r.getBoundingClientRect().bottom > box.top) ?? null;
      target = row;
    }
    anchor = target && target !== el && el.contains(target) ? { el: target, top: target.getBoundingClientRect().top, row, rowTop: row?.getBoundingClientRect().top ?? 0 } : undefined;
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
      // Idempotent: measured from where the anchor is now, so a second settle is a no-op.
      const next = correct(el.scrollHeight, el.clientHeight, el.scrollTop, el.scrollTop + target.getBoundingClientRect().top, top);
      if (Math.abs(next - el.scrollTop) >= 0.5) el.scrollTop = next;
      if (target === anchor.el && Math.abs(target.getBoundingClientRect().top - top) < 1) {
        recordGeometry(el);
        return;
      }
    }
    remember();
  };
  /** Bring the position back in line with the contract after any layout change. */
  const settle = () => {
    if (!scroller) return;
    if (pinned()) { if (held) reserve(0); if (!scroller.querySelector(".user.editing")) syncBottom(scroller); }
    else restore();
  };
  const scrollIfPinned = () => {
    if (pinned() && held) reserve(0);
    if (pinned() && scroller && !scroller.querySelector(".user.editing")) { syncBottom(scroller); }
  };
  const markIntent = () => { intentAt = performance.now(); };
  const onWheel = (e: WheelEvent) => {
    markIntent();
    if (e.deltaY < 0) setPinned(false);
    else if (e.deltaY > 0 && scroller && gapOf(scroller) < NEAR) setPinned(true);
  };
  const onKey = (e: KeyboardEvent) => { if (scroller?.isConnected && NAV_KEYS.has(e.key) && !editable(e.target)) markIntent(); };
  // A press on the scroller itself or the custom overlay thumb is a scrollbar drag.
  const onPointerDown = (e: PointerEvent) => {
    if (!scroller?.isConnected) return;
    if (e.target === scroller || (e.target instanceof Element && e.target.classList.contains("transcript-scroll-thumb"))) {
      dragging = true; markIntent();
    }
  };
  const onPointerUp = () => { if (dragging) { dragging = false; markIntent(); } };
  const bind = (el: HTMLDivElement | undefined) => {
    if (el === scroller) return;
    detach?.();
    detach = undefined;
    scroller = el;
    content = undefined;
    if (!el) return;
    setScrollKeeper(el, { settle, pinned, markIntent });
    el.addEventListener("wheel", onWheel, { passive: true });
    el.addEventListener("touchstart", markIntent, { passive: true });
    el.addEventListener("touchmove", markIntent, { passive: true });
    el.addEventListener("touchend", markIntent, { passive: true });
    window.addEventListener("pointerdown", onPointerDown, true);
    window.addEventListener("pointerup", onPointerUp, true);
    window.addEventListener("pointercancel", onPointerUp, true);
    window.addEventListener("keydown", onKey);
    const observer = new ResizeObserver(() => {
      if (!el.isConnected) return;
      if (pinned()) scrollIfPinned();
      else restore();
      o.onResize?.();
    });
    const blocks = new MutationObserver(records => {
      for (const r of records) r.addedNodes.forEach(n => { if (n instanceof Element) observer.observe(n, { box: "border-box" }); });
      if (pinned()) scrollIfPinned();
      else restore();
    });
    const watch = () => {
      if (scroller !== el) return;
      content = el.querySelector<HTMLElement>(":scope > .col") ?? undefined;
      // Observe the scroller itself (viewport height/width) as well as its content column and blocks.
      observer.observe(el, { box: "border-box" });
      if (content) observer.observe(content, { box: "border-box" });
      const container = content ?? el;
      for (const child of container.children) observer.observe(child, { box: "border-box" });
      blocks.observe(container, { childList: true });
      const dock = el.parentElement?.querySelector<HTMLElement>(":scope > .dock, :scope > .btw-composer-dock") ?? el.nextElementSibling;
      if (dock) observer.observe(dock);
      remember();
    };
    watch();
    queueMicrotask(watch);
    detach = () => {
      observer.disconnect();
      blocks.disconnect();
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("touchstart", markIntent);
      el.removeEventListener("touchmove", markIntent);
      el.removeEventListener("touchend", markIntent);
      window.removeEventListener("pointerdown", onPointerDown, true);
      window.removeEventListener("pointerup", onPointerUp, true);
      window.removeEventListener("pointercancel", onPointerUp, true);
      window.removeEventListener("keydown", onKey);
      setScrollKeeper(el, undefined);
    };
  };
  if (getOwner()) onCleanup(() => bind(undefined));
  return {
    ref: (el: HTMLDivElement) => bind(el),
    settle,
    el: () => scroller,
    /** Reactive: false while the reader is somewhere above the bottom. */
    pinned,
    /** A send by the reader, or "Jump to latest": follow the newest message again. */
    pin: () => { setPinned(true); queueMicrotask(scrollIfPinned); },
    scrollIfPinned,
    onScroll: () => {
      const el = scroller;
      if (!el) return;
      const top = el.scrollTop, gap = gapOf(el);
      // A collapsing narration can clamp scrollTop before ResizeObserver runs.
      // This is layout, even inside the recent wheel-intent window. Preserve
      // the old anchor until restore has reserved the lost height; remembering
      // the clamped viewport here would silently choose a different message.
      const maxTop = Math.max(0, el.scrollHeight - el.clientHeight);
      const clamped = !!content && content.offsetHeight < lastColHeight && lastTop > maxTop + 0.5 && Math.abs(top - maxTop) < 1;
      if (!pinned() && content && content.offsetHeight !== lastColHeight && (!intent() || clamped || Math.abs(top - lastTop) < 0.5)) {
        restore();
        return;
      }
      // Sub-pixel jitter is not a move up.
      const resized = Math.abs(el.scrollHeight - lastScrollHeight) >= 1
        || Math.abs(el.clientHeight - lastClientHeight) >= 1
        || (!!content && content.offsetHeight !== lastColHeight);
      const effectiveTop = top > lastTop - 0.5 ? Math.max(top, lastTop) : top;
      const next = scrollEvent({ pinned: pinned(), top: lastTop }, intent(), resized, el.scrollHeight, el.clientHeight, effectiveTop);
      if (next.pinned !== pinned()) setPinned(next.pinned);
      if (next.pinned && (held || (!intent() && gap >= 0.5 && !el.querySelector(".user.editing")))) {
        if (held) reserve(0);
        syncBottom(el);
        return;
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
      const land = () => { if (pinned()) syncBottom(el); };
      land();
      // rAF can be throttled (background window, headless WebKit): never leave the thread hidden.
      let shown = false;
      const show = () => { if (shown) return; shown = true; land(); el.classList.remove("landing"); };
      const fallback = setTimeout(show, 80);
      requestAnimationFrame(() => { land(); requestAnimationFrame(() => { clearTimeout(fallback); show(); }); });
    },
    /** Kept for call-site symmetry; `ref` now attaches and cleans up observers per element. */
    observe: () => {},
  };
}
