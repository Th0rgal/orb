import { render, screen, fireEvent, waitFor, cleanup } from "@solidjs/testing-library";
import { createSignal } from "solid-js";
import { afterEach, expect, it, vi } from "vitest";
import {cacheMachineDestinations} from "../src/machineDestinations";
import { ChangeMachine, forgetMachineDestinationLoads, preloadMachineDestinations } from "../src/ChangeMachine";
import * as api from "../src/api";
import * as transfers from "../src/machineTransfer";
import type { Mission, HarnessChoice } from "../src/api";
const mission: Mission = { id: "source", title: "Original", status: "awaiting_user", history: [], created_at: "", updated_at: "", backend: "codex", model_override: "model" };
const choices: HarnessChoice[] = [{ backend: { id: "codex", name: "Codex" }, models: [{ value: "model", label: "Model" }] }];
afterEach(() => { localStorage.clear(); sessionStorage.clear(); cacheMachineDestinations([]); forgetMachineDestinationLoads(); cleanup(); vi.restoreAllMocks(); });
it("lists the current machine and explains unavailable targets", async () => {
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({ version: 1, actions: [], destinations: [{ machine: { kind: "core" }, label: "Core", available: true }, { machine: { kind: "node", id: "offline" }, label: "Offline", available: false, reason: "Machine unreachable" }] });
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  await waitFor(() => expect((screen.getByRole("menuitem", { name: /Core/ }) as HTMLButtonElement).disabled).toBe(true));
  expect((screen.getByRole("menuitem", { name: /Offline/ }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText("Machine unreachable")).toBeTruthy();
});
it("keeps the original conversation visible when destination verification fails", async () => {
  const action: transfers.TransferAction = { id: "transfer", mission_id: "source", phase: "copying", source: { kind: "core" }, destination: { kind: "node", id: "spark" }, backend: "codex", model: "model", created_at: "", manifest: { bytes: 0, files: [], excluded: [] } };
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({ version: 1, actions: [action], destinations: [{ machine: action.destination, label: "Spark", available: true }] });
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(action);
  vi.spyOn(transfers, "verifyTransfer").mockRejectedValue(new Error("Checkpoint mismatch"));
  const activate = vi.spyOn(transfers, "activateTransfer"); const moved = vi.fn();
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={moved} />);
  await waitFor(() => expect(screen.getByRole("button", { name: "Move to Spark" })).toBeTruthy());
  fireEvent.click(screen.getByRole("button", { name: "Move to Spark" }));
  await waitFor(() => expect(screen.getByText(/Checkpoint mismatch/)).toBeTruthy());
  expect(activate).not.toHaveBeenCalled(); expect(moved).not.toHaveBeenCalled();
});

it("opens with cached machines while validating fresh transfer state", async () => {
  cacheMachineDestinations([{machine:{kind:"node",id:"spark"},label:"Spark",available:true}]);
  let finish!:(view:transfers.TransferView)=>void;
  vi.spyOn(transfers,"inspectTransfer").mockReturnValue(new Promise(resolve=>finish=resolve));
  const prepare=vi.spyOn(transfers,"transferRequest");
  const ui=render(()=><ChangeMachine mission={mission} choices={choices} onClose={()=>{}} onMoved={()=>{}}/>);
  fireEvent.click(screen.getByRole("menuitem",{name:/Spark/}));
  expect(screen.getByText("Updating machines…")).toBeTruthy();
  expect((screen.getByRole("button",{name:"Move to Spark"}) as HTMLButtonElement).disabled).toBe(true);
  expect(prepare).not.toHaveBeenCalled();
  finish({version:1,actions:[],destinations:[{machine:{kind:"node",id:"spark"},label:"Spark",available:false,reason:"Machine unreachable"}]});
  await waitFor(()=>expect(screen.queryByText("Updating machines…")).toBeNull());
  expect((screen.getByRole("button",{name:"Move to Spark"}) as HTMLButtonElement).disabled).toBe(true);
});
it("shows only the administration entry when both DGX services exist",async()=>{
  vi.spyOn(transfers,"inspectTransfer").mockResolvedValue({version:1,actions:[],destinations:[
   {machine:{kind:"node",id:"dgx-spark"},label:"dgx-spark",available:true},
   {machine:{kind:"node",id:"dgx-spark-admin"},label:"dgx-spark-admin",available:false,reason:"Machine is cordoned"},
  ]});
  const ui=render(()=><ChangeMachine mission={mission} choices={choices} onClose={()=>{}} onMoved={()=>{}}/>);
  await waitFor(()=>expect(screen.getByRole("menuitem",{name:/DGX Spark · Administration/})).toBeTruthy());
  expect(screen.queryByRole("menuitem",{name:/^dgx-spark /})).toBeNull();
});

it.each(['ashur','babylon','nippur','uruk','nimrud','dgx-spark-admin','sepolia'])('keeps Claude Code and its model selectable on %s',async id=>{
  vi.spyOn(transfers,'inspectTransfer').mockResolvedValue({version:1,actions:[],destinations:[{machine:{kind:'node',id},label:id,available:true,harnesses:['codex','claudecode']}]});
  const claude={...mission,backend:'claudecode',model_override:'claude-opus-5-5'};
  const all=[...choices,{backend:{id:'claudecode',name:'Claude Code'},models:[{value:'claude-opus-5-5',label:'Opus 5.5'}]}];
  const ui=render(()=><ChangeMachine mission={claude} choices={all} onClose={()=>{}} onMoved={()=>{}}/>);
  const label=id==='dgx-spark-admin'?'DGX Spark · Administration':id;
  await waitFor(()=>expect(screen.getByRole('menuitem',{name:new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))})).toBeTruthy());
  fireEvent.click(screen.getByRole('menuitem',{name:new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))}));
  const harness=document.body.querySelector('select[aria-label="Transfer harness"]') as HTMLSelectElement;
  expect(harness.value).toBe('claudecode');
  expect([...harness.options].some(o=>o.value==='claudecode'&&!o.disabled)).toBe(true);
  expect((document.body.querySelector('select[aria-label="Transfer model"]') as HTMLSelectElement).value).toBe('claude-opus-5-5');
  expect((document.body.querySelector('select[aria-label="Transfer files"]') as HTMLSelectElement).value).toBe('light');
  expect((screen.getByRole('button',{name:`Move to ${label}`}) as HTMLButtonElement).disabled).toBe(false);
});

it("shares an in-flight preload and reads transfer state fresh on every open", async () => {
  cacheMachineDestinations([{ machine: { kind: "node", id: "spark" }, label: "Spark", available: true }]);
  let finish!: (view: transfers.TransferView) => void;
  const view = { version: 1, actions: [], destinations: [{ machine: { kind: "node" as const, id: "spark" }, label: "Spark", available: true }] };
  const inspect = vi.spyOn(transfers, "inspectTransfer").mockReturnValueOnce(new Promise(resolve => finish = resolve)).mockResolvedValue(view);
  preloadMachineDestinations(mission.id);
  const ui = render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  expect(screen.queryByText("Checking machines…")).toBeNull();
  expect(screen.getByRole("menuitem", { name: /Spark/ })).toBeTruthy();
  expect(inspect).toHaveBeenCalledTimes(1);
  finish(view);
  await waitFor(() => expect(screen.queryByText("Updating machines…")).toBeNull());
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
 await waitFor(()=>expect(screen.getByRole('menuitem',{name:/Node/})).toBeTruthy());
 fireEvent.click(screen.getByRole('menuitem',{name:/Node/}));
 expect(selected).toHaveBeenCalledWith(destination.machine);
 expect(screen.queryByRole('option',{name:'Core only'})).toBeNull();
 expect(screen.getByRole('option',{name:'Node only'})).toBeTruthy();
 expect((screen.getByRole('button',{name:'Move to Node'}) as HTMLButtonElement).disabled).toBe(true);
 fireEvent.change(screen.getByLabelText('Transfer model'),{target:{value:'node-only'}});
 expect((screen.getByRole('button',{name:'Move to Node'}) as HTMLButtonElement).disabled).toBe(false);
});

it('selects the first destination model when changing harness', async()=>{
 const destination:transfers.Destination={machine:{kind:'node',id:'node'},label:'Node',available:true,harnesses:['codex']};
 vi.spyOn(transfers,'inspectTransfer').mockResolvedValue({version:1,actions:[],destinations:[destination]});
 const node:HarnessChoice[]=[...choices,{backend:{id:'antigravity',name:'Antigravity'},models:[{value:'node-only',label:'Node only'}]}];
 const ui=render(()=><ChangeMachine mission={mission} choices={choices} choicesFor={()=>node} onClose={()=>{}} onMoved={()=>{}}/>);
 await waitFor(()=>expect(screen.getByRole('menuitem',{name:/Node/})).toBeTruthy());
 fireEvent.click(screen.getByRole('menuitem',{name:/Node/}));
 fireEvent.change(screen.getByLabelText('Transfer harness'),{target:{value:'antigravity'}});
 expect((screen.getByLabelText('Transfer model') as HTMLSelectElement).value).toBe('node-only');
 expect((screen.getByRole('button',{name:'Move to Node'}) as HTMLButtonElement).disabled).toBe(false);
});

it("keeps old-agent → Core source label and completes an empty-workspace transfer after cancelling a queued remote job", async () => {
  const [liveMission, setLiveMission] = createSignal<Mission>({
    ...mission,
    id: "3049daa5-0879-48f2-bba0-b02d336b9b33",
    status: "active",
    backend: "opencode",
    model_override: "builtin/smart",
    remote_job: { id: "job-1", node_id: "old-agent", state: "queued" } as any,
  });
  const opencodeChoices: HarnessChoice[] = [
    { backend: { id: "opencode", name: "OpenCode" }, models: [{ value: "builtin/smart", label: "Smart (Default)" }] },
  ];
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({
    version: 1,
    actions: [],
    destinations: [
      { machine: { kind: "core" }, label: "Core", available: true, harnesses: ["opencode"] },
      { machine: { kind: "node", id: "old-agent" }, label: "old-agent", available: true, harnesses: ["opencode"] },
    ],
  });
  vi.spyOn(api, "cancelMission").mockImplementation(async () => {
    setLiveMission(prev => ({ ...prev, status: "interrupted", remote_job: undefined }));
  });
  vi.spyOn(api, "getMission").mockImplementation(async () => liveMission());
  const prepared: transfers.TransferAction = {
    id: "transfer-3049",
    mission_id: "3049daa5-0879-48f2-bba0-b02d336b9b33",
    phase: "preparing",
    source: { kind: "node", id: "old-agent" },
    destination: { kind: "core" },
    backend: "opencode",
    model: "builtin/smart",
    source_root: "mission:3049daa5-0879-48f2-bba0-b02d336b9b33",
    created_at: "",
  };
  const snapshotted: transfers.TransferAction = {
    ...prepared,
    phase: "copying",
    manifest: { bytes: 0, files: [], excluded: [] },
  };
  vi.spyOn(transfers, "transferRequest").mockResolvedValue(prepared as any);
  vi.spyOn(transfers, "inventoryTransfer").mockResolvedValue({
    rows: [],
    bytes: 0,
    files: 0,
    reserved: { bytes: 4096, files: 1 },
    truncated: false,
    protected: 0,
    limits: { bytes: 10 * 1024 * 1024 * 1024, files: 50_000 },
  });
  vi.spyOn(transfers, "selectTransfer").mockResolvedValue({ ok: true } as any);
  vi.spyOn(transfers, "snapshotTransfer").mockResolvedValue(snapshotted);
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(snapshotted);
  vi.spyOn(transfers, "verifyTransfer").mockResolvedValue({ ...snapshotted, phase: "verified" });
  const movedMission: Mission = { ...liveMission(), status: "awaiting_user", machine_transfer: { ...snapshotted, phase: "activated" } };
  vi.spyOn(transfers, "activateTransfer").mockResolvedValue(movedMission);
  const moved = vi.fn();

  render(() => <ChangeMachine mission={liveMission()} choices={opencodeChoices} onClose={() => {}} onMoved={moved} />);
  await waitFor(() => expect((screen.getByRole("menuitem", { name: /old-agent/ }) as HTMLButtonElement).disabled).toBe(true));
  expect((screen.getByRole("menuitem", { name: /Core/ }) as HTMLButtonElement).disabled).toBe(false);
  fireEvent.click(screen.getByRole("menuitem", { name: /Core/ }));
  expect(screen.getByText("old-agent → Core")).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Transfer files"), { target: { value: "workspace" } });

  fireEvent.click(screen.getByRole("button", { name: "Stop and prepare" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Continue" })).toBeTruthy());
  expect(screen.getByText("old-agent → Core")).toBeTruthy();
  expect(screen.queryByText("Core → Core")).toBeNull();

  fireEvent.click(screen.getByRole("button", { name: "Continue" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Move to Core" })).toBeTruthy());
  expect(screen.getByText("old-agent → Core")).toBeTruthy();

  fireEvent.click(screen.getByRole("button", { name: "Move to Core" }));
  await waitFor(() => expect(moved).toHaveBeenCalledWith(movedMission));
});

it("uses server-inspected source placement when an auto-placed remote mission has no active remote_job", async () => {
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({
    version: 1,
    source: { kind: "node", id: "old-agent" },
    actions: [],
    destinations: [
      { machine: { kind: "core" }, label: "Core", available: true, harnesses: ["codex"] },
      { machine: { kind: "node", id: "old-agent" }, label: "old-agent", available: true, harnesses: ["codex"] },
    ],
  });
  render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={() => {}} />);
  await waitFor(() => expect((screen.getByRole("menuitem", { name: /old-agent/ }) as HTMLButtonElement).disabled).toBe(true));
  expect((screen.getByRole("menuitem", { name: /Core/ }) as HTMLButtonElement).disabled).toBe(false);
  fireEvent.click(screen.getByRole("menuitem", { name: /Core/ }));
  expect(screen.getByText("old-agent → Core")).toBeTruthy();
});

it("defaults to light mode and moves conversation in one click without scanning workspace files", async () => {
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({
    version: 1,
    features: ["links", "selection", "light", "bulk_copy"],
    actions: [],
    destinations: [
      { machine: { kind: "core" }, label: "Core", available: true },
      { machine: { kind: "node", id: "spark" }, label: "Spark", available: true, harnesses: ["codex"] },
    ],
  });
  const lightAction: transfers.TransferAction = {
    id: "light-1",
    mission_id: "source",
    phase: "copying",
    light: true,
    source: { kind: "core" },
    destination: { kind: "node", id: "spark" },
    backend: "codex",
    model: "model",
    created_at: "",
    manifest: { bytes: 0, files: [], excluded: [] },
  };
  const prepare = vi.spyOn(transfers, "transferRequest").mockResolvedValue(lightAction as any);
  const inventory = vi.spyOn(transfers, "inventoryTransfer");
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(lightAction);
  vi.spyOn(transfers, "verifyTransfer").mockResolvedValue({ ...lightAction, phase: "verified" });
  const movedMission: Mission = { ...mission, machine_transfer: { ...lightAction, phase: "activated" } };
  vi.spyOn(transfers, "activateTransfer").mockResolvedValue(movedMission);
  const moved = vi.fn();
  const closed = vi.fn();

  render(() => <ChangeMachine mission={mission} choices={choices} onClose={closed} onMoved={moved} />);
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /Spark/ })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: /Spark/ }));
  expect(screen.getByText(/no workspace files are transferred/i)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Move to Spark" }));
  await waitFor(() => expect(moved).toHaveBeenCalledWith(movedMission));
  expect(closed).toHaveBeenCalled();
  expect(prepare).toHaveBeenCalledWith("source", expect.objectContaining({ op: "prepare", light: true }));
  expect(inventory).not.toHaveBeenCalled();
});
