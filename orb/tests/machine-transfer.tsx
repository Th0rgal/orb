import { render } from "solid-js/web";
import { Show, createSignal } from "solid-js";
import { ChangeMachine } from "../src/ChangeMachine";
import "../src/styles.css";
import type { Mission } from "../src/api";
const queuedNode = new URLSearchParams(location.search).get("queued");
const initialMission: Mission = queuedNode
  ? { id: "test", title: "Conversation", status: "active", history: [], created_at: "", updated_at: "", backend: "opencode", model_override: "builtin/smart", remote_job: { id: "job-1", node_id: queuedNode, state: "queued" } as any }
  : { id: "test", title: "Conversation", status: "awaiting_user", history: [], created_at: "", updated_at: "", backend: "codex", model_override: "model" };
localStorage.setItem("orb.apiUrl", location.origin);
window.addEventListener("orb:test-mission-cancelled", () => setMissionState(m => ({ ...m, status: "interrupted", remote_job: undefined })));
const [missionState, setMissionState] = createSignal<Mission>(initialMission);
function Fixture() {
  const [open, setOpen] = createSignal(false);
  const [locationName, setLocation] = createSignal(queuedNode ?? "Core");
  const choices = queuedNode
    ? [{ backend: { id: "opencode", name: "OpenCode" }, models: [{ value: "builtin/smart", label: "Smart (Default)" }] }]
    : [{ backend: { id: "codex", name: "Codex" }, models: [{ value: "model", label: "GPT-6 Astra" }] }];
  return <div style={{ padding: "40px", "padding-top": "600px" }}><div class="fork-anchor"><button onClick={() => setOpen(!open())}>Change machine: {locationName()}</button><Show when={open()}><ChangeMachine mission={missionState()} choices={choices} onClose={() => setOpen(false)} onMoved={() => setLocation(queuedNode ? "Core" : "Spark")} /></Show></div></div>;
}
render(() => <Fixture />, document.getElementById("app")!);
