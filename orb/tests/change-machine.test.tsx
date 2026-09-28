import { render, fireEvent, waitFor, cleanup } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import {cacheMachineDestinations} from "../src/machineDestinations";
import { ChangeMachine } from "../src/ChangeMachine";
import * as transfers from "../src/machineTransfer";
import type { Mission, HarnessChoice } from "../src/api";
const mission: Mission = { id: "source", title: "Original", status: "awaiting_user", history: [], created_at: "", updated_at: "", backend: "codex", model_override: "model" };
const choices: HarnessChoice[] = [{ backend: { id: "codex", name: "Codex" }, models: [{ value: "model", label: "Model" }] }];
afterEach(() => { cacheMachineDestinations([]); cleanup(); vi.restoreAllMocks(); });
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
