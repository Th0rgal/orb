import { navigateOverlayItems } from "./overlayNavigation";
import { Popover } from "./Popover";
import {cachedMachineDestinations,cacheMachineDestinations,preferSparkAdministration} from "./machineDestinations";
import {connectionVersion} from "./api";
import {nodeLabel} from "./missionLaunch";
import { Select } from "./Select";
import { For, Show, createMemo, createEffect, createSignal, onCleanup, onMount } from "solid-js";
import { ErrorNotice } from "./ErrorNotice";
import { cancelMission, getMission, type HarnessChoice, type Mission } from "./api";
import { machineIdentity, nativeInvoke } from "./clientRuns";
import { localBinding, localRunActive, pollLocal, refreshLocalAgents, stopLocal } from "./localAgents";
import { appendClientTranscript, setClientMissionStatus } from "./api";
import { MachineLoadBadge, byLeastLoaded, machineLoadTitle } from "./machineLoad";
import { TransferInventory, formatBytes } from "./TransferInventory";
import { TransferSelection, selectionRequest, selectionTotals, type Choice } from "./TransferSelection";
import { activeTransfer, activateTransfer, copyTransfer, inspectTransfer, inventoryTransfer, machineLabel, sameMachine, selectTransfer, snapshotTransfer, transferRequest, verifyTransfer, type Destination, type Machine, type TransferAction, type TransferView, type WorkspaceInventory } from "./machineTransfer";

type Loaded = { view: TransferView; rows: Destination[]; client?: string };
const loads = new Map<string, Promise<Loaded>>();
/** Shares an in-flight request, e.g. a preload, with the menu that opens meanwhile.
 * A settled result is never reused: transfer actions must be read fresh. */
export function loadMachineDestinations(missionId: string, force = false): Promise<Loaded> {
  const key = `${connectionVersion()}:${missionId}`;
  const pending = loads.get(key);
  if (pending && !force) return pending;
  const version = connectionVersion();
  const promise = (async () => {
    const local = async (): Promise<Destination> => {
      if (!nativeInvoke()) return { machine: { kind: "client", id: "unavailable" }, label: "This computer", available: false, reason: "Open Orb desktop to use this computer" };
      // A recent scan is enough to list harnesses; launching re-validates.
      const [id, installed] = await Promise.all([machineIdentity(), refreshLocalAgents(false)]);
      return { machine: { kind: "client", id }, label: "This computer", available: true, harnesses: installed.filter(c => c.installed).map(c => c.id) };
    };
    const [view, computer] = await Promise.all([inspectTransfer(missionId), local()]);
    if (view.version !== 1) throw new Error("Update the connected backend to enable machine transfer.");
    const rows = preferSparkAdministration([computer, ...view.destinations], row => row.machine.kind === "node" ? row.machine.id : undefined)
      .map(row => row.machine.kind === "node" && row.machine.id === "dgx-spark-admin" ? { ...row, label: nodeLabel(row.machine.id) } : row);
    if (version === connectionVersion()) cacheMachineDestinations(rows);
    return { view, rows, client: computer.machine.kind === "client" ? computer.machine.id : undefined };
  })();
  loads.set(key, promise);
  const settle = () => { if (loads.get(key) === promise) loads.delete(key); };
  promise.then(settle, settle);
  return promise;
}
/** Forget reusable loads (connection reset, tests). */
export function forgetMachineDestinationLoads() { loads.clear(); }
/** Warm the machine list in the background; failures surface when the menu opens. */
export function preloadMachineDestinations(missionId: string) { void loadMachineDestinations(missionId).catch(() => {}); }

export function ChangeMachine(p: { mission: Mission; choices: HarnessChoice[]; choicesFor?: (machine: Machine) => HarnessChoice[]; onDestination?: (machine: Machine) => void; onClose: () => void; onMoved: (mission: Mission) => void }) {
  const [destinations, setDestinations] = createSignal<Destination[]>(cachedMachineDestinations());
  const [selected, setSelected] = createSignal<Destination>();
  const [action, setAction] = createSignal<TransferAction>();
  const [backend, setBackend] = createSignal(p.mission.backend ?? "");
  const [model, setModel] = createSignal(p.mission.model_override ?? "");
  const [loading, setLoading] = createSignal(true);
  const [ready, setReady] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [stage, setStage] = createSignal("");
  const [progress, setProgress] = createSignal(0);
  const [error, setError] = createSignal("");
  const [inventory, setInventory] = createSignal<WorkspaceInventory>();
  const [choice, setChoice] = createSignal<Choice>({});
  let cancelled = false;
  let alive = true;
  let root!: HTMLDivElement;
  let client: string | undefined;
  const requestKey = crypto.randomUUID();
  const current = (): Machine => p.mission.machine_transfer?.destination ?? (p.mission.tags?.includes("placement:client") ? { kind: "client", id: client ?? "unknown" } : p.mission.remote_node_id || p.mission.remote_job?.node_id ? { kind: "node", id: (p.mission.remote_node_id ?? p.mission.remote_job?.node_id)! } : { kind: "core" });
  const running = () => localRunActive(p.mission.id) || ["active", "pending", "running", "starting"].includes(p.mission.status);
  createEffect(() => { const destination = selected()?.machine; if (destination) p.onDestination?.(destination); });
  const destinationChoices = () => selected() && p.choicesFor ? p.choicesFor(selected()!.machine) : p.choices;
  const models = () => destinationChoices().find(c => c.backend.id === backend())?.models ?? [];
  const availableHarnesses = () => destinationChoices().filter(c => c.backend.id === "antigravity" ? c.models.length > 0 : !selected()?.harnesses || selected()!.harnesses!.includes(c.backend.id));
  const harnessCompatible = () => backend() === "antigravity" ? models().length > 0 : !selected()?.harnesses || selected()!.harnesses!.includes(backend());
  const compatible = () => harnessCompatible() && (backend() !== "antigravity" || models().some(option => option.value === model()));
  const fail = (e: unknown) => setError(e instanceof Error ? e.message : String(e));
  const loadKey = (d: Destination) => d.machine.kind === "node" ? d.machine.id : d.machine.kind;
  // This computer and Core keep their place; usable nodes go least busy first.
  const ordered = createMemo(() => {
    const rows = destinations(), node = (d: Destination) => d.machine.kind === "node";
    return [...rows.filter(d => !node(d)), ...byLeastLoaded(rows.filter(d => node(d) && d.available), loadKey), ...rows.filter(d => node(d) && !d.available)];
  });
  const load = async (force = false) => {
    setLoading(true); setReady(false); setError("");
    const version=connectionVersion();
    try {
      const {view,rows,client:id}=await loadMachineDestinations(p.mission.id,force);
      if (!alive || version!==connectionVersion()) return;
      client=id;
      setDestinations(rows);
      setReady(true);
      const previous=selected();
      if(previous)setSelected(rows.find(row=>sameMachine(row.machine,previous.machine)));
      queueMicrotask(() => {if(!root?.contains(document.activeElement))root?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();});
      const pending = [...view.actions].reverse().find(activeTransfer);
      if (pending) {
        setAction(pending); setBackend(pending.backend); setModel(pending.model ?? "");
        setSelected(rows.find(r => sameMachine(r.machine, pending.destination)) ?? { machine: pending.destination, label: machineLabel(pending.destination), available: true });
      }
    } catch (e) { if (alive && version===connectionVersion()) fail(e); }
    finally { if (alive) setLoading(false); }
  };
  onMount(() => {
    void load();
  });
  onCleanup(() => { alive = false; cancelled = true; });
  const stopSource = async () => {
    if (current().kind === "client") {
      await stopLocal(p.mission.id, { cancelWakeups: false });
      const result = await pollLocal(p.mission.id);
      if (!result.done) throw new Error("The local agent has not stopped yet.");
      // A normal completion handler may already have saved/settled this run.
      const latest = await getMission(p.mission.id);
      if (["active", "pending"].includes(latest.status)) {
        try {
          if (result.text.trim()) await appendClientTranscript(p.mission.id, "assistant", result.text);
          await setClientMissionStatus(p.mission.id, "interrupted");
        } catch (error) {
          if (["active", "pending"].includes((await getMission(p.mission.id)).status)) throw error;
        }
      }
    } else {
      await cancelMission(p.mission.id);
      for (let i = 0; i < 40; i++) {
        const latest = await getMission(p.mission.id);
        if (!["active", "pending"].includes(latest.status) && (!latest.execution?.state || latest.execution.state === "terminal")) return;
        await new Promise(resolve => setTimeout(resolve, 250));
      }
      throw new Error("The source has not confirmed termination. Wait, then retry.");
    }
  };
  const prepare = async () => {
    const target = selected(); if (!target || busy() || !ready() || !target.available || !compatible()) return;
    cancelled = false; setBusy(true); setError(""); setStage("Preparing workspace…");
    try {
      if (current().kind === "client" && !localBinding(p.mission.id)) throw new Error("Open this conversation on its source computer before moving it.");
      if (running()) await stopSource();
      let a: TransferAction = action() ?? await transferRequest<TransferAction>(p.mission.id, { op: "prepare", destination: target.machine, client_id: client, client_root: localBinding(p.mission.id)?.cwd, idempotency_key: requestKey, backend: backend(), model: model(), effort: backend() === p.mission.backend ? p.mission.model_effort : "" });
      setAction(a);
      // A source that cannot list its folders yet snapshots everything, as before.
      const found = await inventoryTransfer(a);
      if (found) { setChoice({}); setInventory(found); }
      else { a = await snapshotTransfer(a); setAction(a); }
      setStage("");
    } catch (e) { fail(e); } finally { if (cancelled && action()) await cancel(); setBusy(false); }
  };
  const fits = () => { const found = inventory(); if (!found) return true; const t = selectionTotals(found, choice()); return t.bytes <= found.limits.bytes && t.files <= found.limits.files; };
  const snapshot = async () => {
    let a = action(); const found = inventory(); if (!a || !found || busy()) return;
    cancelled = false; setBusy(true); setError(""); setStage("Reading workspace…");
    try {
      await selectTransfer(a, selectionRequest(found.rows, choice()));
      a = await snapshotTransfer(a); setAction(a); setInventory(undefined); setStage("");
    } catch (e) { fail(e); } finally { if (cancelled && action()) await cancel(); setBusy(false); }
  };
  const move = async () => {
    let a = action(); if (!a || busy()) return;
    cancelled = false; setBusy(true); setError("");
    try {
      setStage("Copying workspace…");
      a = await copyTransfer(a, (done, total) => setProgress(total ? done / total : 1), () => cancelled);
      if (cancelled) throw new Error("Transfer cancelled before activation.");
      setStage("Verifying destination…"); a = await verifyTransfer(a); setAction(a);
      if (cancelled) throw new Error("Transfer cancelled before activation.");
      setStage("Activating destination…"); const mission = await activateTransfer(a);
      p.onMoved(mission); p.onClose();
    } catch (e) {
      fail(e);
      if (cancelled) await cancel();
    } finally { setBusy(false); }
  };
  const cancel = async () => {
    const a = action();
    try { if (a) await transferRequest(p.mission.id, { op: "cancel", transfer_id: a.id }); p.onClose(); }
    catch (e) { fail(e); }
  };
  const STEPS = ["Prepare", "Copy", "Verify", "Activate"];
  // The step in hand: preparing until an inventory exists, then the stage of the move.
  const step = () => !action()?.manifest ? 0 : stage().startsWith("Verifying") ? 2 : stage().startsWith("Activating") ? 3 : 1;
  const back = () => { setSelected(undefined); setError(""); queueMicrotask(() => root.querySelector<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')?.focus()); };
  return <Popover ref={el => {root = el;}} class={`machine-transfer-menu ${selected() ? "transfer-dialog" : ""}`} label="Change machine" width={360} placement="top-start" busy={busy()} onClose={() => {if(action()) void cancel(); else p.onClose();}} onKeyDown={e => {if (!selected()) navigateOverlayItems(e, root, "[role=menuitem]");}}>
    <Show when={!selected()}>
      <div class="menu-group">Change machine…</div>
      <Show when={loading()}><div class="menu-group" role="status">{destinations().length?"Updating machines…":"Checking machines…"}</div></Show>
      <For each={ordered()}>{d => <button class="menu-item" role="menuitem" disabled={!d.available || sameMachine(d.machine, current())} title={d.reason ?? `${d.label} · ${machineLoadTitle(loadKey(d))}`} onClick={() => { setSelected(d); setError(""); queueMicrotask(() => root.querySelector<HTMLSelectElement>("select")?.focus()); }}>
        <span>{d.label}<Show when={d.reason}><small>{d.reason}</small></Show></span><span class="machine-transfer-end"><MachineLoadBadge machine={loadKey(d)} /><span>{sameMachine(d.machine, current()) ? "✓" : "›"}</span></span>
      </button>}</For>
    </Show>
    <Show when={selected()}>
      <header class="transfer-head">
        <Show when={!action() && !busy()}><button type="button" class="icon-btn sm" aria-label="Choose another machine" title="Choose another machine" onClick={back}><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 3.5 5.5 8l4.5 4.5" /></svg></button></Show>
        <div><strong>Continue on {selected()!.label}</strong><small>{machineLabel(current())} → {selected()!.label}</small></div>
      </header>
      <ol class="transfer-steps" aria-label="Transfer progress">
        <For each={STEPS}>{(name, i) => <li classList={{ done: i() < step(), current: i() === step() }} aria-current={i() === step() ? "step" : undefined}>{name}</li>}</For>
      </ol>
      <div class="transfer-body">
        <Show when={loading()}><p role="status">{destinations().length?"Updating machines…":"Checking machines…"}</p></Show>
        <Show when={selected()?.reason}><p role="status">{selected()!.reason}</p></Show>
        <Show when={!action()?.manifest && !inventory()}><p>The conversation and its workspace files move together. The agent waits for your next message.</p></Show>
        <Show when={!action()}>
          <div class="transfer-options">
            <label>Harness<Select aria-label="Transfer harness" value={backend()} disabled={busy()} onChange={e => { setBackend(e.currentTarget.value); setModel(destinationChoices().find(c => c.backend.id === e.currentTarget.value)?.models[0]?.value ?? ""); }}>
              <Show when={!harnessCompatible()}><option value={backend()} disabled>{backend()} — unavailable</option></Show>
              <For each={availableHarnesses()}>{c => <option value={c.backend.id} selected={c.backend.id === backend()}>{c.backend.name}</option>}</For>
            </Select></label>
            <label>Model<Select aria-label="Transfer model" value={model()} disabled={busy()} onChange={e => setModel(e.currentTarget.value)}><For each={models()}>{m => <option value={m.value} selected={m.value === model()}>{m.label}</option>}</For></Select></label>
          </div>
          <Show when={!compatible()}><p>Choose a harness and model available on this machine.</p></Show>
        </Show>
        <Show when={!action()?.manifest && inventory()}>{found => <TransferSelection inventory={found()} choice={choice()} disabled={busy()} onChoice={setChoice} />}</Show>
        <Show when={action()?.manifest}>{m => <TransferInventory manifest={m()} />}</Show>
        <Show when={error()}><ErrorNotice error={error()} /></Show>
      </div>
      <footer class="transfer-foot">
        <Show when={busy() && stage()}><div class="transfer-status" role="status"><span>{stage()}</span><Show when={stage().startsWith("Copying")}><span>{Math.round(progress() * 100)}% of {formatBytes(action()?.manifest?.bytes ?? 0)}</span><progress max="1" value={progress()} /></Show></div></Show>
        <div class="transfer-actions">
          <button class="pill" disabled={stage() === "Activating destination…" && busy()} onClick={() => busy() ? cancelled = true : void cancel()}>Cancel</button>
          <Show when={action()?.manifest} fallback={<Show when={inventory()} fallback={<button class="pill on" disabled={!ready() || busy() || !selected()?.available || !compatible() || !model()} onClick={() => void prepare()}>{running() ? "Stop and prepare" : "Prepare transfer"}</button>}><button class="pill on" disabled={busy() || !fits()} onClick={() => void snapshot()}>Continue</button></Show>}>
            <Show when={!busy()}><button class="pill on" onClick={() => void move()}>Move to {selected()!.label}</button></Show>
          </Show>
        </div>
      </footer>
    </Show>
    <Show when={error() && !selected()}><ErrorNotice error={error()} /><Show when={!loading()}><button class="menu-item" onClick={() => void load(true)}>Retry</button></Show></Show>
  </Popover>;
}
