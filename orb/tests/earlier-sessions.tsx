import { render } from "solid-js/web";
import { FilePanelProvider, FilePanelButton } from "../src/FilePanel";
import { MdView } from "../src/Markdown";
import type { Mission } from "../src/api";
import "../src/styles.css";
localStorage.setItem("orb.apiUrl", location.origin);
localStorage.setItem("orb.jwt", "test");
document.documentElement.dataset.theme = "dark";
// A replacement mission on nippur citing its predecessor's report.
const mission = {
  id: "5b0c1f3e-2d44-4f7a-9a51-0c6a2e7d9b11",
  title: "security (fresh session) (fresh session)",
  remote_job: { node_id: "nippur", job_id: "job-current" },
} as unknown as Mission;
render(
  () => (
    <div class="app" style={{ "--sb-w": "220px" }}>
      <FilePanelProvider scope={{ mission }}>
        <aside class="sidebar" />
        <header class="titlebar">
          <span>{mission.title}</span>
          <FilePanelButton />
        </header>
        <main class="main">
          <div class="scroll">
            <div class="col">
              <MdView text={"Rapport final : `/var/lib/sandboxed-node/08ea5752-536d-4cef-9d9e-f29b117d89cc/reports/ops-2026-10-27/RAPPORT-FINAL.md`\n\nAutre : `/var/lib/sandboxed-node/9f1c2b3a-0000-4000-8000-000000000000/secret.md`"} />
            </div>
          </div>
        </main>
      </FilePanelProvider>
    </div>
  ),
  document.getElementById("root")!,
);
