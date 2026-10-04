import { render, fireEvent, waitFor, cleanup } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import {cacheMachineDestinations} from "../src/machineDestinations";
import { ChangeMachine, forgetMachineDestinationLoads, preloadMachineDestinations } from "../src/ChangeMachine";
import * as transfers from "../src/machineTransfer";
import type { Mission, HarnessChoice } from "../src/api";
const mission: Mission = { id: "source", title: "Original", status: "awaiting_user", history: [], created_at: "", updated_at: "", backend: "codex", model_override: "model" };
const choices: HarnessChoice[] = [{ backend: { id: "codex", name: "Codex" }, models: [{ value: "model", label: "Model" }] }];
afterEach(() => { cacheMachineDestinations([]); forgetMachineDestinationLoads(); cleanup(); vi.restoreAllMocks(); });
it("lists the current machine and explains unavailable targets", async () => {
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({ version: 1, actions: [], destinations: [{ machine: { kind: "core" }, label: "Core", available: true }, { machine: { kind: "node", id: "offline" }, label: "Offline", available: false, reason: "Machine unreachable" }] });
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  await waitFor(() => expect((ui.getByRole("menuitem", { name: /Core/ }) as HTMLButtonElement).disabled).toBe(true));
  expect((ui.getByRole("menuitem", { name: /Offline/ }) as HTMLButtonElement).disabled).toBe(true);
  expect(ui.getByText("Machine unreachable")).toBeTruthy();
});
it("keeps the original conversation visible when destination verification fails", async () => {
  const action: transfers.TransferAction = { id: "transfer", mission_id: "source", phase: "copying", source: { kind: "core" }, destination: { kind: "node", id: "spark" }, backend: "codex", model: "model", created_at: "", manifest: { bytes: 0, files: [], excluded: [] } };
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({ version: 1, actions: [action], destinations: [{ machine: action.destination, label: "Spark", available: true }] });
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(action);
  vi.spyOn(transfers, "verifyTransfer").mockRejectedValue(new Error("Checkpoint mismatch"));
  const activate = vi.spyOn(transfers, "activateTransfer"); const moved = vi.fn();
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={moved} />);
  await waitFor(() => expect(ui.getByRole("button", { name: "Move to Spark" })).toBeTruthy());
  fireEvent.click(ui.getByRole("button", { name: "Move to Spark" }));
  await waitFor(() => expect(ui.getByText(/Checkpoint mismatch/)).toBeTruthy());
  expect(activate).not.toHaveBeenCalled(); expect(moved).not.toHaveBeenCalled();
});

it("opens with cached machines while validating fresh transfer state", async () => {
  cacheMachineDestinations([{machine:{kind:"node",id:"spark"},label:"Spark",available:true}]);
  let finish!:(view:transfers.TransferView)=>void;
  vi.spyOn(transfers,"inspectTransfer").mockReturnValue(new Promise(resolve=>finish=resolve));
  const prepare=vi.spyOn(transfers,"transferRequest");
  const ui=render(()=><ChangeMachine mission={mission} choices={choices} onClose={()=>{}} onMoved={()=>{}}/>);
  fireEvent.click(ui.getByRole("menuitem",{name:/Spark/}));
  expect(ui.getByText("Updating machines…")).toBeTruthy();
  expect((ui.getByRole("button",{name:"Prepare transfer"}) as HTMLButtonElement).disabled).toBe(true);
  expect(prepare).not.toHaveBeenCalled();
  finish({version:1,actions:[],destinations:[{machine:{kind:"node",id:"spark"},label:"Spark",available:false,reason:"Machine unreachable"}]});
  await waitFor(()=>expect(ui.queryByText("Updating machines…")).toBeNull());
  expect((ui.getByRole("button",{name:"Prepare transfer"}) as HTMLButtonElement).disabled).toBe(true);
});
it("shows only the administration entry when both DGX services exist",async()=>{
  vi.spyOn(transfers,"inspectTransfer").mockResolvedValue({version:1,actions:[],destinations:[
   {machine:{kind:"node",id:"dgx-spark"},label:"dgx-spark",available:true},
   {machine:{kind:"node",id:"dgx-spark-admin"},label:"dgx-spark-admin",available:false,reason:"Machine is cordoned"},
  ]});
  const ui=render(()=><ChangeMachine mission={mission} choices={choices} onClose={()=>{}} onMoved={()=>{}}/>);
  await waitFor(()=>expect(ui.getByRole("menuitem",{name:/DGX Spark · Administration/})).toBeTruthy());
  expect(ui.queryByRole("menuitem",{name:/^dgx-spark /})).toBeNull();
});

it.each(['ashur','babylon','nippur','old-agent','dgx-spark-admin','sepolia'])('keeps Claude Code and its model selectable on %s',async id=>{
  vi.spyOn(transfers,'inspectTransfer').mockResolvedValue({version:1,actions:[],destinations:[{machine:{kind:'node',id},label:id,available:true,harnesses:['codex','claudecode']}]});
  const claude={...mission,backend:'claudecode',model_override:'claude-opus-5-5'};
  const all=[...choices,{backend:{id:'claudecode',name:'Claude Code'},models:[{value:'claude-opus-5-5',label:'Opus 5.5'}]}];
  const ui=render(()=><ChangeMachine mission={claude} choices={all} onClose={()=>{}} onMoved={()=>{}}/>);
  const label=id==='dgx-spark-admin'?'DGX Spark · Administration':id;
  await waitFor(()=>expect(ui.getByRole('menuitem',{name:new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))})).toBeTruthy());
  fireEvent.click(ui.getByRole('menuitem',{name:new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))}));
  const harness=ui.container.querySelector('select[aria-label="Transfer harness"]') as HTMLSelectElement;
  expect(harness.value).toBe('claudecode');
  expect([...harness.options].some(o=>o.value==='claudecode'&&!o.disabled)).toBe(true);
  expect((ui.container.querySelector('select[aria-label="Transfer model"]') as HTMLSelectElement).value).toBe('claude-opus-5-5');
  expect((ui.getByRole('button',{name:'Prepare transfer'}) as HTMLButtonElement).disabled).toBe(false);
});

it("shares an in-flight preload and reads transfer state fresh on every open", async () => {
  cacheMachineDestinations([{ machine: { kind: "node", id: "spark" }, label: "Spark", available: true }]);
  let finish!: (view: transfers.TransferView) => void;
  const view = { version: 1, actions: [], destinations: [{ machine: { kind: "node" as const, id: "spark" }, label: "Spark", available: true }] };
  const inspect = vi.spyOn(transfers, "inspectTransfer").mockReturnValueOnce(new Promise(resolve => finish = resolve)).mockResolvedValue(view);
  preloadMachineDestinations(mission.id);
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  expect(ui.queryByText("Checking machines…")).toBeNull();
  expect(ui.getByRole("menuitem", { name: /Spark/ })).toBeTruthy();
  expect(inspect).toHaveBeenCalledTimes(1);
  finish(view);
  await waitFor(() => expect(ui.queryByText("Updating machines…")).toBeNull());
  ui.unmount();
  const reopened = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  await waitFor(() => expect(inspect).toHaveBeenCalledTimes(2));
  reopened.unmount();
});

it('uses destination account models and rejects the source-only model', async()=>{
 const destination:transfers.Destination={machine:{kind:'node',id:'node'},label:'Node',available:true,harnesses:['antigravity']};
 vi.spyOn(transfers,'inspectTransfer').mockResolvedValue({version:1,actions:[],destinations:[destination]});
 const core:HarnessChoice[]=[{backend:{id:'antigravity',name:'Antigravity'},models:[{value:'core-only',label:'Core only'}]}];
 const node:HarnessChoice[]=[{backend:{id:'antigravity',name:'Antigravity'},models:[{value:'node-only',label:'Node only'}]}];
 const selected=vi.fn();
 const ui=render(()=><ChangeMachine mission={{...mission,backend:'antigravity',model_override:'core-only'}} choices={core} choicesFor={()=>node} onDestination={selected} onClose={()=>{}} onMoved={()=>{}}/>);
 await waitFor(()=>expect(ui.getByRole('menuitem',{name:/Node/})).toBeTruthy());
 fireEvent.click(ui.getByRole('menuitem',{name:/Node/}));
 expect(selected).toHaveBeenCalledWith(destination.machine);
 expect(ui.queryByRole('option',{name:'Core only'})).toBeNull();
 expect(ui.getByRole('option',{name:'Node only'})).toBeTruthy();
 expect((ui.getByRole('button',{name:'Prepare transfer'}) as HTMLButtonElement).disabled).toBe(true);
 fireEvent.change(ui.getByLabelText('Transfer model'),{target:{value:'node-only'}});
 expect((ui.getByRole('button',{name:'Prepare transfer'}) as HTMLButtonElement).disabled).toBe(false);
});

it('selects the first destination model when changing harness', async()=>{
 const destination:transfers.Destination={machine:{kind:'node',id:'node'},label:'Node',available:true,harnesses:['codex']};
 vi.spyOn(transfers,'inspectTransfer').mockResolvedValue({version:1,actions:[],destinations:[destination]});
 const node:HarnessChoice[]=[...choices,{backend:{id:'antigravity',name:'Antigravity'},models:[{value:'node-only',label:'Node only'}]}];
 const ui=render(()=><ChangeMachine mission={mission} choices={choices} choicesFor={()=>node} onClose={()=>{}} onMoved={()=>{}}/>);
 await waitFor(()=>expect(ui.getByRole('menuitem',{name:/Node/})).toBeTruthy());
 fireEvent.click(ui.getByRole('menuitem',{name:/Node/}));
 fireEvent.change(ui.getByLabelText('Transfer harness'),{target:{value:'antigravity'}});
 expect((ui.getByLabelText('Transfer model') as HTMLSelectElement).value).toBe('node-only');
 expect((ui.getByRole('button',{name:'Prepare transfer'}) as HTMLButtonElement).disabled).toBe(false);
});
