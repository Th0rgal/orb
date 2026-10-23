import { Show } from "solid-js";
import * as Ic from "../icons";

/** Shown while the reader is scrolled away from the bottom of a conversation;
 * sits just above the composer (absolutely, so the dock never changes height). */
export function JumpToLatest(p: { pinned: () => boolean; onJump: () => void }) {
  return <Show when={!p.pinned()}>
    <button type="button" class="jump-latest" aria-label="Jump to latest" title="Jump to latest" onClick={() => p.onJump()}><Ic.ChevronDown size={14} /></button>
  </Show>;
}
