import { createSignal, Show } from "solid-js";
import { render } from "solid-js/web";
import { ConfirmDialog, Dialog, DialogButton, Field, NameDialog } from "../src/Dialog";
import "../src/styles.css";
import { NestedEditor } from "./NestedEditor";

document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") ?? "dark";
function Harness() {
  const [kind, setKind] = createSignal("");
  const [draft, setDraft] = createSignal("");
  const [name, setName] = createSignal("Research notes");
  return <main style={{ background: "var(--bg)", height: "100vh", padding: "40px", color: "var(--fg)" }}>
    <h1>Projects</h1><p>Research notes · Verification · Weekly review</p>
    <div style={{ display: "flex", gap: "8px" }}>
      <DialogButton onClick={() => setKind("rename")}>Rename project</DialogButton>
      <DialogButton onClick={() => setKind("confirm")}>Delete chain</DialogButton>
      <DialogButton onClick={() => setKind("draft")}>Edit draft</DialogButton>
    </div>
    <Show when={kind() === "rename"}><NameDialog title="Rename" hint="research-notes" label="Project name" value={name()}
      onInput={setName} action="Save" onAction={() => setKind("")} onClose={() => setKind("")} /></Show>
    <Show when={kind() === "confirm"}><ConfirmDialog title="Delete chain?" description="Delete “Default routing”? This cannot be undone."
      action="Delete chain" destructive onConfirm={() => setKind("")} onClose={() => setKind("")} /></Show>
    <Show when={kind() === "draft"}><Dialog title="Edit draft" size="wide" dirty={!!draft()} onClose={() => setKind("")} footer={close => <DialogButton onClick={close}>Cancel</DialogButton>}>
      <Field label="Name"><input class="s-input" value={draft()} onInput={e => setDraft(e.currentTarget.value)} /></Field>
      <NestedEditor />
      <div style={{"min-height":"600px"}}>Draft content</div>
    </Dialog></Show>
  </main>;
}
render(() => <Harness />, document.getElementById("root")!);
