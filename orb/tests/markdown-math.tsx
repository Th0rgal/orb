import {render} from "solid-js/web";
import {MdView} from "../src/Markdown";
import {MATH_REPLY} from "./markdown-math.fixture";
import "../src/styles.css";

document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") || "dark";
render(() => <main style={{padding: "16px", "max-width": "900px", margin: "auto"}}>
  <MdView text={MATH_REPLY}/>
</main>, document.getElementById("root")!);
