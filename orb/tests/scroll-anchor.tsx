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
Object.assign(window, { anchorHarness: { apply: (ev: StreamEvent) => setItems(v => applyStreamEvent(v, ev)) } });
