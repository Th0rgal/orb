/** Preserve a visible node while history is prepended. User input wins. */
export function prependWithAnchor(scroller: HTMLElement | undefined, update: () => void) {
  if (!scroller) { update(); return; }
  const bounds = scroller.getBoundingClientRect();
  const anchor = [...scroller.querySelectorAll<HTMLElement>('.col > .user, .col > .st-text, .col > .st-work')]
    .find(node => { const box = node.getBoundingClientRect(); return box.bottom > bounds.top && box.top < bounds.bottom; });
  const top = anchor?.getBoundingClientRect().top;
  const height = scroller.scrollHeight, scrollTop = scroller.scrollTop;
  let frame = 0, remaining = 4, cancelled = false;
  const events = ['wheel', 'touchstart', 'pointerdown', 'keydown'];
  const stop = () => { cancelled = true; cancelAnimationFrame(frame); for (const event of events) scroller.removeEventListener(event, stop); };
  for (const event of events) scroller.addEventListener(event, stop, {passive:true});
  update();
  const restore = () => {
    if (cancelled || !scroller.isConnected) { stop(); return; }
    if (anchor?.isConnected && top != null) scroller.scrollTop += anchor.getBoundingClientRect().top - top;
    else if (remaining === 4) scroller.scrollTop = scrollTop + scroller.scrollHeight - height;
    if (--remaining > 0) frame = requestAnimationFrame(restore); else stop();
  };
  frame = requestAnimationFrame(restore);
}
