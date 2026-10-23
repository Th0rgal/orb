import { render } from "solid-js/web";
import { createSignal, createEffect, on } from "solid-js";
import { Transcript, buildTranscript, applyStreamEvent } from "../src/Transcript";
import { createPinnedScroll } from "../src/mission/pinnedScroll";
import { JumpToLatest } from "../src/mission/JumpToLatest";
import type { StreamEvent } from "../src/stream";
import "../src/styles.css";
// A finished conversation (60 turns) and a live turn the spec streams into,
// wired to the same pinned scroll the mission and cloud views use.
const events: StreamEvent[] = [];
for (let i = 0; i < 60; i++) events.push(
  { type: "user_message", data: { content: `Question ${i}: ${"please look at this ".repeat(1 + i % 4)}`, id: `u${i}` } },
  { type: "assistant_message", data: { content: `## Answer ${i}\n\n${"A paragraph that wraps over a couple of lines so the turns differ in height. ".repeat(2 + i % 5)}`, id: `a${i}` } },
);
events.push({ type: "user_message", data: { content: "Now do the long task", id: "ulive" } });
const [items, setItems] = createSignal(buildTranscript(events));
function App() {
  const pin = createPinnedScroll({ key: () => "scroll-anchor" });
  pin.observe();
  createEffect(on(items, () => queueMicrotask(pin.scrollIfPinned), { defer: true }));
  queueMicrotask(pin.landAtBottom);
  return <div class="main" style={{ height: "100vh" }}>
    <div id="scroller" class="scroll" ref={pin.ref} onScroll={pin.onScroll}><div class="col"><Transcript sizeKey="scroll-anchor" items={items()} working /></div></div>
    <div class="dock"><JumpToLatest pinned={pin.pinned} onJump={pin.pin} /><div class="col" style={{ height: "60px" }} /></div>
  </div>;
}
render(() => <App />, document.getElementById("root")!);
const log: StreamEvent[] = [...events];
Object.assign(window, { anchorHarness: {
  apply: (ev: StreamEvent) => { log.push(ev); setItems(v => applyStreamEvent(v, ev)); },
  /** Cached first paint vs network: show `stale` now (spine-like: no tools, fewer
   * turns), then the fresh history (tools and narration folded into earlier turns,
   * newer turns appended) as one replacement, like MissionView's resync. */
  cacheThenNetwork: (fresh: StreamEvent[], stale: StreamEvent[]) => { log.splice(0, log.length, ...fresh); setItems(buildTranscript(stale)); return () => setItems(buildTranscript(fresh)); },
  swap: () => setItems(buildTranscript(log)),
  /** A spine-like resync: older turns come back shorter (their tools/narration are not in this page). */
  shrink: () => { for (const e of log) if (e.type === "assistant_message" && typeof e.data.content === "string" && e.data.content.length > 40) e.data = { ...e.data, content: (e.data.content as string).slice(0, 40) }; setItems(buildTranscript(log)); },
  /** A poll's resync: the whole transcript rebuilt from history, keeping `keep` latest turns (a reset page window). */
  resync: (keep?: number) => { let ev = log; if (keep) { const users = ev.flatMap((e, i) => e.type === "user_message" ? [i] : []); ev = ev.slice(users[Math.max(0, users.length - keep)]); } setItems(buildTranscript(ev)); },
} });
