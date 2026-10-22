import { render } from "solid-js/web";
import { Transcript, buildTranscript } from "../src/Transcript";
import type { StreamEvent } from "../src/stream";
import fixture from "./fixtures/boat-subagent-3a510e9b.json";
import "../src/styles.css";
// Real events of parent mission 3a510e9b (opencode) that spawned a boat machine
// and started subagent 26e6bbcd on it through sandboxed_start_mission.
const theme = new URLSearchParams(location.search).get("theme");
if (theme) document.documentElement.dataset.theme = theme;
render(() => <main id="transcript" class="scroll" style={{ height: "100vh", overflow: "auto", background: "var(--bg)" }}><Transcript items={buildTranscript(fixture as StreamEvent[])} /></main>, document.getElementById("root")!);
