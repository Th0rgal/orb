/** The conversation scroll contract, backed by the verified Lean 4 WASM kernel
 * (`orb_scroll_policy_*` and `orb_wire_scroll_slice_step` from lean/Orb/Scroll.lean
 * & lean/Orb/Kernel.lean) and checked against shared/orb-spec/fixtures/scroll-policy.json.
 * Fractional sub-pixel browser scroll coordinates preserve exact JS arithmetic when
 * outside integer kernel domain. */
import {
  inScrollDomain,
  orbKernelScratchSliceStep,
  orbScrollPolicyClampTop,
  orbScrollPolicyCorrect,
  orbScrollPolicyGap,
  orbScrollPolicyMaxTop,
  orbWireScrollSliceStep,
} from "../orbKernel";

export type ScrollState = { pinned: boolean; top: number };
/** Within this many pixels of the bottom, a downward scroll by the reader follows again. */
export const NEAR = 24;

const EMPTY_SLICE: Uint8Array<ArrayBufferLike> = new Uint8Array(0);

function kernelScrollSliceStep(
  opKind: 0 | 1 | 2 | 3,
  s: ScrollState,
  intent: boolean,
  resized: boolean,
  height: number,
  client: number,
  arg: number,
): ScrollState | null {
  if (!inScrollDomain(s.top) || !inScrollDomain(height) ||
      !inScrollDomain(client) || !inScrollDomain(arg)) {
    return null;
  }
  const scratch = orbKernelScratchSliceStep();
  const res = orbWireScrollSliceStep({
    inSlice: EMPTY_SLICE,
    outBuf: scratch.outView,
    outPtr: scratch.outOffset,
    opKind,
    pinned: s.pinned,
    intent,
    resized,
    curTop: s.top,
    height,
    client,
    arg,
  });
  return res.status === 0 && res.verdict
    ? { pinned: res.verdict.pinned, top: res.verdict.top }
    : null;
}

const SUBPIXEL_SCALE = 1024;
const toScaled = (x: number): number | null => {
  if (!Number.isFinite(x)) return null;
  const v = x * SUBPIXEL_SCALE;
  return Number.isInteger(v) && inScrollDomain(v) ? v : null;
};

export const maxTop = (height: number, client: number) => {
  const k = orbScrollPolicyMaxTop(height, client);
  if (k !== null) return k;
  const h = toScaled(height), c = toScaled(client);
  if (h !== null && c !== null) {
    const sk = orbScrollPolicyMaxTop(h, c);
    if (sk !== null) return sk / SUBPIXEL_SCALE;
  }
  return Math.max(0, height - client);
};
export const clampTop = (height: number, client: number, t: number) => {
  const k = orbScrollPolicyClampTop(height, client, t);
  if (k !== null) return k;
  const h = toScaled(height), c = toScaled(client), st = toScaled(t);
  if (h !== null && c !== null && st !== null) {
    const sk = orbScrollPolicyClampTop(h, c, st);
    if (sk !== null) return sk / SUBPIXEL_SCALE;
  }
  return Math.max(0, Math.min(t, Math.max(0, height - client)));
};
export const gap = (height: number, client: number, top: number) => {
  const k = orbScrollPolicyGap(height, client, top);
  if (k !== null) return k;
  const h = toScaled(height), c = toScaled(client), st = toScaled(top);
  if (h !== null && c !== null && st !== null) {
    const sk = orbScrollPolicyGap(h, c, st);
    if (sk !== null) return sk / SUBPIXEL_SCALE;
  }
  return height - top - client;
};
/** A layout change: following stays at the bottom, otherwise the anchor moves with its content (`shift`). */
export const layout = (s: ScrollState, height: number, client: number, shift: number): ScrollState => {
  const k = kernelScrollSliceStep(0, s, false, false, height, client, shift);
  if (k) return k;
  return s.pinned ? { ...s, top: maxTop(height, client) } : { ...s, top: clampTop(height, client, s.top + shift) };
};
/** The reader scrolled: moving up stops following, reaching the bottom follows again. */
export const userScroll = (s: ScrollState, height: number, client: number, to: number): ScrollState => {
  const k = kernelScrollSliceStep(1, s, true, false, height, client, to);
  if (k) return k;
  const t = clampTop(height, client, to);
  if (t < s.top) return { pinned: false, top: t };
  if (gap(height, client, t) < NEAR) return { pinned: true, top: t };
  return { ...s, top: t };
};
/** A browser `scroll` event: reader input delegates to `userScroll`; when geometry
 * changed (`resized`), layout never flips `pinned`; at unchanged geometry, only an
 * explicit upward programmatic jump away from the bottom unpins. */
export const scrollEvent = (s: ScrollState, intent: boolean, resized: boolean, height: number, client: number, to: number): ScrollState => {
  const k = kernelScrollSliceStep(2, s, intent, resized, height, client, to);
  if (k) return k;
  if (intent) return userScroll(s, height, client, to);
  const t = clampTop(height, client, to);
  if (!resized && s.pinned && t < s.top && NEAR <= gap(height, client, t)) return { pinned: false, top: t };
  return { ...s, top: t };
};
export const jump = (s: ScrollState, height: number, client: number): ScrollState => {
  const k = kernelScrollSliceStep(3, s, false, false, height, client, 0);
  if (k) return k;
  return { pinned: true, top: maxTop(height, client) };
};
/** Move so the anchor (now at content offset `anchorDoc`) is back at screen offset `y0`.
 * Measured from where the anchor is, so a second run changes nothing. */
export const correct = (height: number, client: number, top: number, anchorDoc: number, y0: number) => {
  const k = orbScrollPolicyCorrect(height, client, top, anchorDoc, y0);
  if (k !== null) return k;
  const h = toScaled(height), c = toScaled(client), st = toScaled(top), a = toScaled(anchorDoc), sy = toScaled(y0);
  if (h !== null && c !== null && st !== null && a !== null && sy !== null) {
    const sk = orbScrollPolicyCorrect(h, c, st, a, sy);
    if (sk !== null) return sk / SUBPIXEL_SCALE;
  }
  return clampTop(height, client, top + (anchorDoc - top - y0));
};

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
