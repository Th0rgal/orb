/** The conversation scroll contract, mirrored from lean/Orb/Scroll.lean (which
 * proves it) and checked against shared/orb-spec/fixtures/scroll-policy.json,
 * generated from the Lean definitions. Keep the two in step: edit the Lean
 * first, run `python3 scripts/gen_scroll_fixtures.py`, then this file. */
export type ScrollState = { pinned: boolean; top: number };
/** Within this many pixels of the bottom, a downward scroll by the reader follows again. */
export const NEAR = 24;
export const maxTop = (height: number, client: number) => Math.max(0, height - client);
export const clampTop = (height: number, client: number, t: number) => Math.max(0, Math.min(t, maxTop(height, client)));
export const gap = (height: number, client: number, top: number) => height - top - client;
/** A layout change: following stays at the bottom, otherwise the anchor moves with its content (`shift`). */
export const layout = (s: ScrollState, height: number, client: number, shift: number): ScrollState =>
  s.pinned ? { ...s, top: maxTop(height, client) } : { ...s, top: clampTop(height, client, s.top + shift) };
/** The reader scrolled: moving up stops following, reaching the bottom follows again. */
export const userScroll = (s: ScrollState, height: number, client: number, to: number): ScrollState => {
  const t = clampTop(height, client, to);
  if (t < s.top) return { pinned: false, top: t };
  if (gap(height, client, t) < NEAR) return { pinned: true, top: t };
  return { ...s, top: t };
};
/** A browser `scroll` event: reader input delegates to `userScroll`; when geometry
 * changed (`resized`), layout never flips `pinned`; at unchanged geometry, only an
 * explicit upward programmatic jump away from the bottom unpins. */
export const scrollEvent = (s: ScrollState, intent: boolean, resized: boolean, height: number, client: number, to: number): ScrollState => {
  if (intent) return userScroll(s, height, client, to);
  const t = clampTop(height, client, to);
  if (!resized && s.pinned && t < s.top && NEAR <= gap(height, client, t)) return { pinned: false, top: t };
  return { ...s, top: t };
};
export const jump = (_: ScrollState, height: number, client: number): ScrollState => ({ pinned: true, top: maxTop(height, client) });
/** Move so the anchor (now at content offset `anchorDoc`) is back at screen offset `y0`.
 * Measured from where the anchor is, so a second run changes nothing. */
export const correct = (height: number, client: number, top: number, anchorDoc: number, y0: number) => clampTop(height, client, top + (anchorDoc - top - y0));

/** One owner per conversation scroller: everything that changes its layout
 * (virtual rows measuring, a panel resizing the column) asks the keeper to
 * settle instead of adjusting scrollTop itself. */
export type ScrollOwner = { settle: () => void; pinned: () => boolean; markIntent: () => void };
const owners = new WeakMap<HTMLElement, ScrollOwner>();
export const setScrollKeeper = (el: HTMLElement, owner: (() => void) | ScrollOwner | undefined) => {
  if (!owner) owners.delete(el);
  else if (typeof owner === "function") owners.set(el, { settle: owner, pinned: () => false, markIntent: () => {} });
  else owners.set(el, owner);
};
export const scrollKeeper = (el: HTMLElement | undefined | null) => (el ? owners.get(el)?.settle : undefined);
export const isScrollPinned = (el: HTMLElement | undefined | null) => (el ? owners.get(el)?.pinned() : undefined);
export const markScrollIntent = (el: HTMLElement | undefined | null) => { if (el) owners.get(el)?.markIntent(); };
