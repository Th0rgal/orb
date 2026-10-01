/** Native overlay scrollbars in WKWebView can stay hidden despite thumb CSS.
 * Keep native scrolling, but draw and drag a thumb whose visibility we own. */
export function trackScrollbarHover() {
  const thumb = document.createElement('div');
  thumb.className = 'transcript-scroll-thumb';
  thumb.setAttribute('aria-hidden', 'true');
  document.body.append(thumb);
  let current: HTMLElement | null = null;
  let pointer: {x: number; y: number} | null = null;
  let scrollUntil = 0;
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  const selector = '.scroll, .btw-thread, .page, .s-body, .md';
  const nearEdge = (el: HTMLElement) => {
    const r = el.getBoundingClientRect();
    return !!pointer && pointer.x >= r.right - 48 && pointer.x <= r.right && pointer.y >= r.top && pointer.y <= r.bottom;
  };
  let drag: {pointer: number; y: number; top: number; ratio: number} | null = null;
  const clear = () => { if (drag) return; current = null; thumb.hidden = true; thumb.classList.remove('hovered'); };
  const geometry = () => {
    if (!current?.isConnected || current.clientHeight <= 0 || current.scrollHeight <= current.clientHeight) return null;
    const rect = current.getBoundingClientRect();
    const track = Math.max(0, rect.height - 8);
    const height = Math.min(track, Math.max(32, track * current.clientHeight / current.scrollHeight));
    return {rect, track, height, travel: track - height, range: current.scrollHeight - current.clientHeight};
  };
  const draw = () => {
    const g = geometry();
    if (!g) { clear(); return; }
    thumb.hidden = false;
    const left = g.rect.right - 11;
    const top = g.rect.top + 4 + g.travel * Math.max(0, Math.min(1, current!.scrollTop / g.range));
    Object.assign(thumb.style, {left: `${left}px`, top: `${top}px`, height: `${g.height}px`});
    // Explicit hit testing also works when revealing/repositioning the thumb
    // underneath a stationary pointer, where WebKit may retain stale :hover.
    const mask = `linear-gradient(to bottom, #000 ${Math.max(0, g.rect.bottom - 80 - top)}px, transparent ${Math.max(1, g.rect.bottom - 4 - top)}px)`;
    thumb.style.maskImage = mask;
    thumb.style.webkitMaskImage = mask;
    thumb.classList.toggle('hovered', !!pointer && pointer.x >= left && pointer.x <= left + 8 && pointer.y >= top && pointer.y <= top + g.height);
  };
  const move = (event: PointerEvent) => {
    pointer = {x: event.clientX, y: event.clientY};
    if (drag && current) {
      if (event.pointerId !== drag.pointer) return;
      current.scrollTop = drag.top + (event.clientY - drag.y) * drag.ratio;
      draw(); return;
    }
    if (event.pointerType === 'touch') { clear(); return; }
    // Hit-test geometry: the native gutter may target the window rather than
    // the scroller, and the composer can overlap the bottom of the transcript.
    const candidates = Array.from(document.querySelectorAll<HTMLElement>(selector));
    const next = candidates.reverse().find(el => {
      const r = el.getBoundingClientRect();
      return el.clientHeight > 0 && el.scrollHeight > el.clientHeight && event.clientX >= r.right - 48 && event.clientX <= r.right && event.clientY >= r.top && event.clientY <= r.bottom;
    }) ?? null;
    if (next) current = next;
    else if (Date.now() >= scrollUntil) { clear(); return; }
    if (current) draw();
  };
  const down = (event: PointerEvent) => {
    const g = geometry();
    if (!current || event.button !== 0 || !g || g.travel <= 0) return;
    event.preventDefault();
    // Virtualized turns can change scrollHeight while dragging. Recomputing
    // this ratio would amplify the entire pointer delta on every resize.
    drag = {pointer: event.pointerId, y: event.clientY, top: current.scrollTop, ratio: g.range / g.travel};
    thumb.setPointerCapture(event.pointerId);
    thumb.classList.add('dragging');
  };
  const up = (event: PointerEvent) => {
    if (!drag || event.pointerId !== drag.pointer) return;
    drag = null; thumb.classList.remove('dragging');
    if (thumb.hasPointerCapture(event.pointerId)) thumb.releasePointerCapture(event.pointerId);
    move(event);
  };
  const leave = (event: PointerEvent) => { if (!event.relatedTarget) clear(); };
  const blur = () => { pointer = null; drag = null; thumb.classList.remove('dragging'); clear(); };
  const redraw = () => { if (current) draw(); };
  const scrolling = (event: Event) => {
    const target = event.target;
    if (!(target instanceof HTMLElement) || !target.matches(selector)) return;
    if (!drag) current = target;
    scrollUntil = Date.now() + 900;
    clearTimeout(hideTimer);
    draw();
    hideTimer = setTimeout(() => {
      if (!drag && current && !nearEdge(current)) clear();
    }, 900);
  };
  thumb.hidden = true;
  thumb.addEventListener('pointerdown', down);
  document.addEventListener('pointermove', move, {passive: true, capture: true});
  document.addEventListener('pointerup', up, true);
  document.addEventListener('pointercancel', up, true);
  document.addEventListener('pointerout', leave, {passive: true});
  document.addEventListener('scroll', scrolling, {passive: true, capture: true});
  window.addEventListener('resize', redraw);
  window.addEventListener('blur', blur);
  return () => {
    clearTimeout(hideTimer);
    thumb.remove();
    document.removeEventListener('pointermove', move, true);
    document.removeEventListener('pointerup', up, true);
    document.removeEventListener('pointercancel', up, true);
    document.removeEventListener('pointerout', leave);
    document.removeEventListener('scroll', scrolling, true);
    window.removeEventListener('resize', redraw);
    window.removeEventListener('blur', blur);
  };
}
