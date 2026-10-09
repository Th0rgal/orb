import {FindBar} from "../src/FindBar";
import { createSignal, Show } from "solid-js";
import { render } from "solid-js/web";
import { Dialog, DialogButton, ConfirmDialog, Field, NameDialog } from "../src/Dialog";
import { ErrorDialog } from "../src/ErrorNotice";
import { Menu, MenuList } from "../src/Menu";
import { Picker } from "../src/Picker";
import { Select } from "../src/Select";
import { SchedulePicker } from "../src/SchedulePicker";
import { ProjectCreation } from "../src/ProjectPicker";
import { Lightbox } from "../src/Lightbox";
import { UserTurn } from "../src/Transcript";
import "../src/styles.css";
import "../src/Dialog.css";
import "./overlays.css";

document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") ?? "dark";
const longTitle = "Connect a provider for a project with a long descriptive name";
function Gallery() {
  const [open,setOpen] = createSignal("");
  const [pickerState,setPickerState] = createSignal(new URLSearchParams(location.search).get("picker-state") ?? "ready");
  const [name,setName] = createSignal("Research notes");
  const [busy,setBusy] = createSignal(false), [error,setError] = createSignal<string|null>(null), [attempts,setAttempts] = createSignal(0);
  const [selected,setSelected] = createSignal("one"), [searchOpen,setSearchOpen] = createSignal(false);
  const [anchor,setAnchor] = createSignal<HTMLElement>(), [sub,setSub] = createSignal<HTMLElement>();
  const [schedule,setSchedule] = createSignal("every 1h");
  const close = () => setOpen("");
  const show = (kind:string,button:HTMLButtonElement) => {setAnchor(button); setError(null); setOpen(kind);};
  const save = async () => {
    if (busy() || !name().trim()) return;
    setBusy(true);setAttempts(a=>a+1); await new Promise(resolve => setTimeout(resolve,200));
    if(attempts()===1)setError("Could not save the name. Check the connection and try again. Your changes are kept.");else close();
    setBusy(false);
  };
  return <main class="overlay-gallery" data-find-conversation>
    <FindBar/><h1>Orb overlays</h1><p>Compact surfaces, clear actions, predictable keyboard focus.</p>
    <section class="gallery-actions" aria-label="Examples">
      <DialogButton onClick={e=>show("name",e.currentTarget)}>Rename</DialogButton>
      <DialogButton onClick={e=>show("confirm",e.currentTarget)}>Confirm deletion</DialogButton>
      <DialogButton onClick={e=>show("form",e.currentTarget)}>Provider form</DialogButton>
      <DialogButton onClick={e=>show("picker",e.currentTarget)}>Choose model</DialogButton>
      <DialogButton onClick={e=>show("menu",e.currentTarget)}>Actions</DialogButton>
      <DialogButton onClick={e=>show("project",e.currentTarget)}>New project</DialogButton>
      <DialogButton onClick={e=>show("error",e.currentTarget)}>Error details</DialogButton>
      <DialogButton onClick={e=>show("image",e.currentTarget)}>Image preview</DialogButton>
    </section>
    <p role="status">Save attempts: {attempts()} · Selected: {selected()}</p>
    <section class="gallery-message" aria-label="Message editor example"><UserTurn text="Document the exact prompt an agent needs to continue this work, including the full scope, acceptance criteria and the evidence already collected." onSend={async()=>true}/></section>
    <Show when={open()==="name"}><NameDialog title="Rename agent" label="Agent name" value={name()} onInput={setName} action="Rename" disabled={!name().trim()} busy={busy()} error={error()} onAction={()=>void save()} onClose={close}/></Show>
    <Show when={open()==="confirm"}><ConfirmDialog title="Delete folder" description="Delete Research notes and its contents? This cannot be undone." action="Delete folder" destructive onConfirm={close} onClose={close}/></Show>
    <Show when={open()==="form"}><Dialog title={longTitle} description="Choose a provider and enter the credentials for this project." busy={busy()} dirty={name() !== "Research notes"} onClose={close}
      footer={requestClose=><><DialogButton onClick={requestClose}>Cancel</DialogButton><DialogButton variant="primary" onClick={close}>Save</DialogButton></>}>
      <Field label="Provider"><Select aria-label="Provider" value={selected()} onChange={e=>setSelected(e.currentTarget.value)}><option value="one">OpenAI</option><option disabled value="disabled">Unavailable provider</option><option value="two">Anthropic</option></Select></Field>
      <Field label="Account name" description="This name is shown on all devices."><input class="s-input" value={name()} onInput={e=>setName(e.currentTarget.value)}/></Field>
      <Field label="API key"><input class="s-input" type="password" autocomplete="off" placeholder="Enter API key"/></Field>
      <Field label="Notes"><textarea class="s-input" aria-label="Notes" rows="3"/></Field>
      <SchedulePicker value={schedule()} onChange={setSchedule}/>
      <DialogButton onClick={()=>setSearchOpen(true)}>Pick a model</DialogButton>
      <Show when={searchOpen()}><Picker label="Models" items={Array.from({length:80},(_,i)=>({id:`model-${i}`,label:`Model ${i}`,group:i<4?"Recent":"All models",disabled:i===1}))} selected={selected()} onSelect={id=>{setSelected(id);setSearchOpen(false);}} onClose={()=>setSearchOpen(false)}/></Show>
    </Dialog></Show>
    <Show when={open()==="picker"}><Picker label="Models" searchLabel="Search models" anchor={anchor()} selected={selected()} loading={pickerState()==="loading"} error={pickerState()==="error" ? "Models could not load. Try again." : undefined} onRetry={()=>setPickerState("ready")} items={pickerState()==="empty" ? [] : [{id:"one",label:"Standard",group:"Available"},{id:"disabled",label:"Unavailable model",disabled:true,group:"Available"},{id:"two",label:"Advanced",description:"Additional reasoning",group:"Available"},...Array.from({length:40},(_,i)=>({id:`option-${i}`,label:`Model ${i}`,group:"Other models"}))]} onSelect={id=>{setSelected(id);close();}} onClose={close}/></Show>
    <Show when={open()==="menu"}><Menu label="Project actions" anchor={anchor()} onClose={close}>
      <MenuList items={[{kind:"item",label:"Rename…",onClick:()=>setOpen("name")},{kind:"item",label:"Unavailable action",disabled:true,onClick:()=>{}},{kind:"item",label:"More actions",openOnHover:true,onClick:el=>setSub(el)}]}/>
      <Show when={sub()}>{button=><Menu label="More actions" anchor={button()} placement="right-start" onClose={()=>setSub(undefined)}><MenuList items={[{kind:"item",label:"Copy path",onClick:()=>setSub(undefined)},{kind:"item",label:"Delete folder…",danger:true,onClick:()=>{setSub(undefined);setOpen("confirm");}}]}/></Menu>}</Show>
    </Menu></Show>
    <Show when={open()==="project"}><ProjectCreation anchor={anchor()} existingIds={[]} onCreate={async()=>close()} onClose={close}/></Show>
    <Show when={open()==="error"}><ErrorDialog error="HTTP 503: The service is temporarily unavailable. Check your connection and try again." onClose={close}/></Show>
    <Show when={open()==="image"}><Lightbox items={[{label:"Preview",src:"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='500' height='300'%3E%3Crect width='500' height='300' fill='%23262626'/%3E%3Ctext x='250' y='160' text-anchor='middle' fill='%23ddd' font-size='24'%3EAttachment preview%3C/text%3E%3C/svg%3E"}]} index={0} onClose={close}/></Show>
  </main>;
}
render(()=><Gallery/>,document.getElementById("root")!);
