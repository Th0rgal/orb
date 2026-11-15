import { render } from "solid-js/web";
import { createSignal } from "solid-js";
import { ProjectBoardSection } from "../src/ProjectBoard";
import { setConnection, type Mission } from "../src/api";
import "../src/styles.css";
setConnection(location.origin, "fixture");
document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") ?? "dark";
const candidate = { id: "controller", title: "Release planning", status: "running", project: "notes" } as Mission;
function Harness() {
  const [hint, setHint] = createSignal<{ id: string }>();
  return <main class="col" style={{ padding: "24px" }}><button class="s-btn" onClick={() => setHint({ id: "controller" })}>Status changed</button><ProjectBoardSection slug="notes" selectedMission={candidate} missionHint={hint()} onOpenMission={id => { document.title = id; }} /><div data-testid="after-board">Project appearance and skills</div></main>;
}
render(() => <Harness />, document.getElementById("root")!);
