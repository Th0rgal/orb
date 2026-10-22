import {render} from "solid-js/web";
import {MdView} from "../src/Markdown";
import spec from "../../shared/orb-spec/fixtures/loose-pipe-tables.json";
import "../src/styles.css";

const prod = spec.cases.find((c) => c.name.startsWith("prod 55518e2b"))!.input;
document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") || "dark";
const text = (window as {__MD_TEXT?: string}).__MD_TEXT ?? prod;
render(() => <main style={{padding: "16px", "max-width": "900px", margin: "auto"}}>
  <MdView text={text}/>
</main>, document.getElementById("root")!);
