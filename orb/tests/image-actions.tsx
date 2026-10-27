import {render} from "solid-js/web";
import {FileReferenceContext} from "../src/fileReferenceContext";
import {WorkspaceImage} from "../src/WorkspaceImage";
import "../src/styles.css";
// A 2×1 PNG, as an agent-written chart would arrive from the file API.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGP4z8DwHwiZGAAk/AL/VKJjlQAAAABJRU5ErkJggg==";
const bytes = Uint8Array.from(atob(PNG), c => c.charCodeAt(0));
(window as any).PNG = PNG;
const loadImage = async () => URL.createObjectURL(new Blob([bytes], {type: "image/png"}));
document.documentElement.dataset.theme = "dark";
render(() => <main style={{padding: "40px"}}><FileReferenceContext.Provider value={{resolve: async () => [], open: () => {}, search: () => {}, loadImage}}>
  <WorkspaceImage path="reports/bench chart.png" alt="Benchmark chart" />
</FileReferenceContext.Provider></main>, document.getElementById("root")!);
