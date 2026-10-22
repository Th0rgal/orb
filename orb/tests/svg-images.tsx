import {restoreLocalBindings} from "../src/localAgents";
import {render} from "solid-js/web";
import {FilePanelProvider} from "../src/FilePanel";
import {MdView} from "../src/Markdown";
import "../src/styles.css";
document.documentElement.dataset.theme="dark";
const text=['Logos:','','<image path="logos/svg/maxwell.svg" alt="1 · Maxwell (SVG)" />','','![Hostile](logos/svg/hostile.svg)'].join("\n");
void restoreLocalBindings().then(()=>render(()=><FilePanelProvider scope={{mission:{id:"svg",project:"test",status:"awaiting_user",title:"SVG",history:[],created_at:"",updated_at:""}}}>
 <main style={{padding:"32px",width:"760px"}}><MdView text={text}/></main>
</FilePanelProvider>,document.getElementById("root")!));
