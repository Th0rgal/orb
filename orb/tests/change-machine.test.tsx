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

import * as managedModel from "../src/managedMachineModel";

it("collapses agent-spawned VMs and provisions a new Cloud VM only when Move is confirmed", async () => {
  managedModel.resetManagedCatalog();
  vi.spyOn(transfers, "inspectTransfer").mockResolvedValue({
    version: 1,
    features: ["links", "selection", "light", "bulk_copy"],
    actions: [],
    destinations: [
      { machine: { kind: "core" }, label: "Core", available: true },
      { machine: { kind: "node", id: "managed-usr1" }, label: "my-box", available: true, harnesses: ["codex"], labels: ["managed", "boat"], owner_kind: "user" },
      { machine: { kind: "node", id: "managed-ag1" }, label: "xlarge-a", available: true, harnesses: ["codex"], labels: ["managed", "boat"], owner_kind: "mission" },
      { machine: { kind: "node", id: "managed-ag2" }, label: "xlarge-b", available: true, harnesses: ["codex"], labels: ["managed", "boat"], owner_kind: "mission" },
    ],
  });
  const createVm = vi.fn().mockResolvedValue({
    id: "vm99",
    name: "large-z",
    provider: "boat",
    provider_id: "p99",
    node_id: "managed-vm99",
    image: "img",
    size: "large",
    cpu: 8,
    ram_gb: 16,
    state: "online",
    created_at: "",
    expires_at: "",
    cost_usd: 0,
    usd_per_hour: 0.288,
    ledger_closed: false,
  });
  const claimOwner = vi.fn().mockResolvedValue({});
  vi.spyOn(api, "api").mockImplementation((async (path: string, init?: RequestInit) => {
    if (path === "/api/managed-machines" && init?.method === "POST") {
      return createVm(JSON.parse(String(init.body ?? "{}")));
    }
    if (path === "/api/managed-machines/vm99/owner" && init?.method === "POST") {
      return claimOwner(JSON.parse(String(init.body ?? "{}")));
    }
    if (path === "/api/managed-machines") {
      return {
        enabled: true,
        provider: "boat",
        machines: [],
        budget: { spent_today_usd: 0, daily_cap_usd: null, active: 3, max_concurrent: null, default_ttl_minutes: 120, max_ttl_minutes: 720 },
        sizes: [],
        providers: [
          {
            provider: "boat",
            display_name: "boat.dev",
            configured: true,
            enabled: true,
            supports_snapshots: true,
            supports_free_stop: true,
            sizes: [{ size: "large", cpu: 8, ram_gb: 16, disk_gb: 80, usd_per_hour: 0.288 }],
          },
        ],
      };
    }
    if (path === "/api/managed-machines/settings") {
      return { antigravity_on_managed: true };
    }
    return {};
  }) as any);
  const lightAction: transfers.TransferAction = {
    id: "cloud-move-1",
    mission_id: "source",
    phase: "copying",
    light: true,
    source: { kind: "core" },
    destination: { kind: "node", id: "managed-vm99" },
    backend: "codex",
    model: "model",
    created_at: "",
    manifest: { bytes: 0, files: [], excluded: [] },
  };
  const prepare = vi.spyOn(transfers, "transferRequest").mockResolvedValue(lightAction as any);
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(lightAction);
  vi.spyOn(transfers, "verifyTransfer").mockResolvedValue({ ...lightAction, phase: "verified" });
  const movedMission: Mission = { ...mission, machine_transfer: { ...lightAction, phase: "activated" } };
  vi.spyOn(transfers, "activateTransfer").mockResolvedValue(movedMission);
  const moved = vi.fn();

  render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={moved} />);
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /my-box/ })).toBeTruthy());
  expect(screen.queryByRole("menuitem", { name: /xlarge-a/ })).toBeNull();
  const agentToggle = screen.getByRole("menuitem", { name: /Agent-spawned VMs/ });
  expect(agentToggle.textContent).toContain("2");

  // Open boat.dev submenu and select "large" — does NOT call createManagedMachine yet!
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /boat\.dev/ })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: /boat\.dev/ }));
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /large/ })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: /large/ }));
  expect(createVm).not.toHaveBeenCalled();

  const moveBtn = screen.getByRole("button", { name: /Move to boat\.dev · large/ });
  fireEvent.click(moveBtn);
  await waitFor(() => expect(moved).toHaveBeenCalledWith(movedMission));
  expect(createVm).toHaveBeenCalledWith(expect.objectContaining({
    provider: "boat",
    size: "large",
    wait: true,
  }));
  expect(createVm.mock.calls[0]?.[0]?.owner_mission_id).toBeUndefined();
  expect(claimOwner).toHaveBeenCalledWith({ owner_mission_id: "source" });
  expect(prepare).toHaveBeenCalledWith("source", expect.objectContaining({
    op: "prepare",
    destination: { kind: "node", id: "managed-vm99" },
    light: true,
  }));
});

it("restores cloud target on failed preparation so retrying Move provisions a fresh VM, and preserves cloud selection across destination loading", async () => {
  managedModel.resetManagedCatalog();
  let resolveInspect!: (v: transfers.TransferView) => void;
  vi.spyOn(transfers, "inspectTransfer").mockImplementation(
    () => new Promise(r => { resolveInspect = r; }),
  );
  let spawnedSeq = 0;
  const destroyedIds: string[] = [];
  vi.spyOn(api, "api").mockImplementation((async (path: string, init?: RequestInit) => {
    if (path === "/api/managed-machines" && init?.method === "POST") {
      const idx = ++spawnedSeq;
      return {
        id: `vm${idx}`,
        name: `large-${idx}`,
        provider: "boat",
        provider_id: `p${idx}`,
        node_id: `managed-vm${idx}`,
        image: "img",
        size: "large",
        cpu: 8,
        ram_gb: 16,
        state: "online",
        created_at: "",
        expires_at: "",
        cost_usd: 0,
        usd_per_hour: 0.288,
        ledger_closed: false,
      };
    }
    if (path.startsWith("/api/managed-machines/vm") && init?.method === "DELETE") {
      destroyedIds.push(path.split("/").pop()!);
      return {};
    }
    if (path === "/api/managed-machines") {
      return {
        enabled: true,
        provider: "boat",
        machines: [],
        budget: { spent_today_usd: 0, daily_cap_usd: null, active: 0, max_concurrent: null, default_ttl_minutes: 120, max_ttl_minutes: 720 },
        sizes: [],
        providers: [
          {
            provider: "boat",
            display_name: "boat.dev",
            configured: true,
            enabled: true,
            supports_snapshots: true,
            supports_free_stop: true,
            sizes: [{ size: "large", cpu: 8, ram_gb: 16, disk_gb: 80, usd_per_hour: 0.288 }],
          },
        ],
      };
    }
    if (path === "/api/managed-machines/settings") return { antigravity_on_managed: true };
    return {};
  }) as any);

  const okAction: transfers.TransferAction = {
    id: "cloud-move-2",
    mission_id: "source",
    phase: "copying",
    light: true,
    source: { kind: "core" },
    destination: { kind: "node", id: "managed-vm2" },
    backend: "codex",
    model: "model",
    created_at: "",
    manifest: { bytes: 0, files: [], excluded: [] },
  };
  let prepareCalls = 0;
  const prepare = vi.spyOn(transfers, "transferRequest").mockImplementation(async () => {
    prepareCalls++;
    if (prepareCalls === 1) throw new Error("Temporary relay hiccup");
    return okAction as any;
  });
  vi.spyOn(transfers, "copyTransfer").mockResolvedValue(okAction);
  vi.spyOn(transfers, "verifyTransfer").mockResolvedValue({ ...okAction, phase: "verified" });
  const movedMission: Mission = { ...mission, machine_transfer: { ...okAction, phase: "activated" } };
  vi.spyOn(transfers, "activateTransfer").mockResolvedValue(movedMission);
  const moved = vi.fn();

  render(() => <ChangeMachine mission={mission} choices={choices} onClose={() => {}} onMoved={moved} />);

  // Select Cloud VM BEFORE inspectTransfer resolves!
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /boat\.dev/ })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: /boat\.dev/ }));
  await waitFor(() => expect(screen.getByRole("menuitem", { name: /large/ })).toBeTruthy());
  fireEvent.click(screen.getByRole("menuitem", { name: /large/ }));
  expect(screen.getByText(/Continue on boat\.dev · large/)).toBeTruthy();

  // Now resolve inspectTransfer — synthetic Cloud VM selection MUST stay intact!
  resolveInspect({
    version: 1,
    features: ["links", "selection", "light", "bulk_copy"],
    actions: [],
    destinations: [{ machine: { kind: "core" }, label: "Core", available: true }],
  });
  await waitFor(() => expect((screen.getByRole("button", { name: /Move to boat\.dev · large/ }) as HTMLButtonElement).disabled).toBe(false));

  // Attempt 1: VM1 spawns, prepare fails -> VM1 is destroyed AND synthetic cloud target is restored!
  fireEvent.click(screen.getByRole("button", { name: /Move to boat\.dev · large/ }));
  await waitFor(() => expect(screen.getByText(/Temporary relay hiccup/)).toBeTruthy());
  expect(destroyedIds).toEqual(["vm1"]);
  expect(screen.getByRole("button", { name: /Move to boat\.dev · large/ })).toBeTruthy();

  // Attempt 2: clicking Move again provisions VM2 (not destroyed VM1!) and succeeds!
  fireEvent.click(screen.getByRole("button", { name: /Move to boat\.dev · large/ }));
  await waitFor(() => expect(moved).toHaveBeenCalledWith(movedMission));
  expect(spawnedSeq).toBe(2);
  expect(prepare).toHaveBeenLastCalledWith("source", expect.objectContaining({
    op: "prepare",
    destination: { kind: "node", id: "managed-vm2" },
  }));
});
