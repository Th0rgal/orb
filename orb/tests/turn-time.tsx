import { render } from "solid-js/web";
import { createSignal } from "solid-js";
import { Transcript } from "../src/Transcript";
import { applyStreamEvent, buildTranscript } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";
import "../src/styles.css";

const params = new URLSearchParams(location.search);
if (params.get("theme") === "light") document.documentElement.dataset.theme = "light";
const now = Date.now(), iso = (ms: number) => new Date(ms).toISOString();
const done = now - 6 * 86_400_000;
const events: StreamEvent[] = [
  { type: "user_message", data: { id: "u1", content: "Refactor the session store.", at: iso(done - (12 * 60 + 6) * 60_000) } },
  { type: "assistant_message", data: { content: "Refactored the session store and added tests.", at: iso(done) } },
  { type: "user_message", data: { id: "u2", content: "Now document it.", at: iso(now - 3 * 60_000) } },
];
const [items, setItems] = createSignal(buildTranscript(events));
render(() => <main class="scroll" style={{ height: "100vh", overflow: "auto", padding: "24px 48px", background: "var(--bg)" }}><Transcript items={items()} /></main>, document.getElementById("root")!);
Object.assign(window, { turnTimeHarness: { apply: (ev: StreamEvent) => setItems(v => applyStreamEvent(v, ev)), done } });
