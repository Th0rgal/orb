import { projectColor } from "./projectAppearance";
import { Show, createSignal } from "solid-js";
import * as Ic from "./icons";

import { ConfirmDialog, DialogButton, Field } from "./Dialog";
import { Popover } from "./Popover";
import { Picker } from "./Picker";
import { slugify } from "./api";

export function ProjectPicker(p: {
  projects: { id: string; name: string }[];
  selected: string;
  canCreate: boolean;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onMachine?: () => void;
  onClose: () => void;
}) {
  return <Picker label="Choose project" searchLabel="Search projects" selected={p.selected}
    items={p.projects.map(row => ({id: row.id, label: row.name, icon: <span class="row-project-color" style={{color: projectColor(row.id)}}><Ic.FolderIcon size={15}/></span>}))}
    emptyLabel="No projects yet" noResultsLabel="No matching projects" onSelect={p.onSelect} onClose={p.onClose}
    footer={<><Show when={p.canCreate}><button class="picker-row" onClick={p.onCreate}><Ic.PlusIcon size={15}/>New project…</button></Show><Show when={p.onMachine}><button class="picker-row" onClick={p.onMachine}><Ic.MachinesIcon size={15}/>Choose machine…</button></Show></>}/>;
}

export function ProjectCreation(p:{anchor?:HTMLElement;existingIds: string[];onCreate:(title:string,slug:string)=>Promise<void>;onClose:()=>void}) {
  const [name,setName]=createSignal("");
  const slug=()=>slugify(name());
  const [busy,setBusy]=createSignal(false);
  const [error,setError]=createSignal<string|null>(null);
  let composing = false;
  const [discard, setDiscard] = createSignal(false);
  const close=()=>{if(!busy()) name().trim() ? setDiscard(true) : p.onClose();};
  const submit=async()=>{
    if(busy() || composing)return;
    if(!name().trim()){setError("Enter a project name.");return;}
    if(!/^[a-z0-9][a-z0-9_-]*$/.test(slug())){setError("Choose a name containing letters or numbers.");return;}
    if(p.existingIds.includes(slug())){setError("A project with this name already exists. Choose it from Recents or use another name.");return;}
    setBusy(true);setError(null);
    try{await p.onCreate(name().trim(),slug());}
    catch(e){setError(e instanceof Error?e.message:String(e));}
    finally{setBusy(false);}
  };
  return <Popover anchor={p.anchor} label="Create project" busy={busy()} onClose={close} width={320}>
    <header class="popover-head"><h3>Create project</h3><button class="dlg-close" aria-label="Close" disabled={busy()} onClick={close}><Ic.CloseIcon size={16}/></button></header>
    <form onCompositionStart={() => {composing=true;}} onCompositionEnd={() => {composing=false;}} onSubmit={e => {e.preventDefault(); void submit();}}>
      <div class="popover-body"><Field label="Project name" error={error()} description={slug() ? `Folder: /${slug()}` : undefined}><input class="s-input" autofocus placeholder="Project name" value={name()} disabled={busy()} onInput={e => {setName(e.currentTarget.value);setError(null);}}/></Field></div>
      <footer class="popover-foot"><DialogButton disabled={busy()} onClick={close}>Cancel</DialogButton><DialogButton type="submit" variant="primary" disabled={busy() || !name().trim()}>{busy() ? "Creating…" : "Create project"}</DialogButton></footer>
    </form>
    <Show when={discard()}><ConfirmDialog title="Discard project draft?" description="This project has not been created." action="Discard draft" destructive={false} cancelLabel="Keep editing" onConfirm={p.onClose} onClose={() => setDiscard(false)}/></Show>
  </Popover>;
}
