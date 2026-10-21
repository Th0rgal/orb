import { isHarness } from "./harnesses";
import { isArchivable } from "./missionStatus";
import {CodexSpeedPicker,missionSpeed,requireSpeedSupport} from './CodexSpeedPicker';
import {localBinding} from './localAgents';
import type {CodexServiceTier} from './api';
import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createEffect, createSignal, on, onMount } from "solid-js";
import { archiveMission, cancelMission, forkMission, getMission, shortModelLabel, type HarnessChoice, type Mission } from "./api";
import { effortLabel, supportedEfforts } from "./effort";
import { Menu } from "./Menu";

export function ForkMission(p: { mission: Mission; choices: HarnessChoice[]; destination: string; anchor?: HTMLElement; onOpen?: () => void; onClose: () => void; onFork: (mission: Mission) => void }) {
  const [backend, setBackend] = createSignal(p.mission.backend ?? p.choices[0]?.backend.id ?? "");
  const [speed,setSpeed]=createSignal<CodexServiceTier>(missionSpeed(p.mission));
  const [model, setModel] = createSignal(p.mission.model_override ?? "");
  const [modelAnchor, setModelAnchor] = createSignal<HTMLButtonElement>();
  const [effortAnchor, setEffortAnchor] = createSignal<HTMLButtonElement>();
  const [busy, setBusy] = createSignal(false), [error, setError] = createSignal("");
  const choices = () => p.choices.find(choice => choice.backend.id === backend())?.models ?? [];
  const unavailable = (id: string) => !!p.mission.remote_node_id && !isHarness(id);
  const key = crypto.randomUUID();
  onMount(() => p.onOpen?.());
  // The harness catalog refreshes while the menu is open (e.g. late Antigravity models),
  // which re-renders the rows. Hand open submenus the live row so they stay beside it.
  const live = (anchor: HTMLButtonElement | undefined, selector: string) => anchor && !anchor.isConnected ? anchor.closest('[role="menu"]')?.querySelector<HTMLButtonElement>(selector) ?? document.querySelector<HTMLButtonElement>(selector) ?? undefined : anchor;
  createEffect(on(() => p.choices, () => queueMicrotask(() => {
    setModelAnchor(a => live(a, `.fork-harnesses [data-backend="${CSS.escape(backend())}"]`));
    setEffortAnchor(a => live(a, `.fork-models [data-model="${CSS.escape(model())}"]`));
  }), {defer: true}));
  const fork = async (effort = "") => {
    if (busy() || !backend() || unavailable(backend()) || !choices().some(choice => choice.value === model())) return;
    setBusy(true); setError("");
    try { if(backend()==="codex")await requireSpeedSupport(model(),speed(),undefined,!!localBinding(p.mission.id)); const next = await forkMission(p.mission.id, { backend: backend(), model_override: model(), model_effort: effort, service_tier:backend()==="codex"?speed():undefined, idempotency_key: key }); p.onFork(next); void retireTransferredSource(p.mission.id); }
    catch (e) {setError(e instanceof Error ? e.message : String(e));}
    finally {setBusy(false);}
  };
  const openModels = (id: string, anchor: HTMLButtonElement) => {
    if (busy() || unavailable(id)) return;
    if(id!==backend())setSpeed('standard');
    setBackend(id); setEffortAnchor(undefined); setModelAnchor(anchor);
  };
  return <Menu label="Transfer to another agent" class="fork-harnesses" anchor={p.anchor} placement={p.anchor ? "right-start" : "top-start"} busy={busy()} onClose={p.onClose}>
    <Show when={!p.anchor}><div class="menu-group">Transfer to another agent</div></Show>
    <For each={p.choices}>{choice => <button type="button" class="menu-item" role="menuitem" data-backend={choice.backend.id} aria-haspopup="menu" aria-expanded={!!modelAnchor() && backend() === choice.backend.id} disabled={busy() || unavailable(choice.backend.id)}
      title={unavailable(choice.backend.id) ? "Not supported on this remote workspace" : choice.backend.name}
      onMouseEnter={e => openModels(choice.backend.id, e.currentTarget)} onClick={e => openModels(choice.backend.id,e.currentTarget)}
      onKeyDown={e => {if(e.key === "ArrowRight"){e.preventDefault();e.stopPropagation();openModels(choice.backend.id,e.currentTarget);}}}>
      {choice.backend.name}<span class="menu-chevron" aria-hidden="true">›</span>
    </button>}</For>
    <Show when={modelAnchor()}>{anchor => <Menu label="Choose a model" class="fork-models" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => setModelAnchor(undefined)}>
      <For each={choices()}>{choice => {
        const choose = (anchor: HTMLButtonElement) => {if (busy()) return; setModel(choice.value); if (supportedEfforts(backend()).length) setEffortAnchor(anchor); else void fork();};
        return <button type="button" class="menu-item" role="menuitem" data-model={choice.value} disabled={busy()} aria-haspopup={supportedEfforts(backend()).length ? "menu" : undefined}
          title={`Fork into ${shortModelLabel(choice.label)} · same workspace on ${p.destination}`}
          onClick={e => choose(e.currentTarget)} onMouseEnter={e => {if (!busy() && supportedEfforts(backend()).length) {setModel(choice.value);setEffortAnchor(e.currentTarget);}}}
          onKeyDown={e => {if(e.key === "ArrowRight" && supportedEfforts(backend()).length){e.preventDefault();e.stopPropagation();choose(e.currentTarget);}}}>
          {shortModelLabel(choice.label)}<Show when={supportedEfforts(backend()).length}><span class="menu-chevron" aria-hidden="true">›</span></Show>
        </button>;
      }}</For>
      <Show when={!choices().length}><div class="menu-group">No models available</div></Show>
      <Show when={effortAnchor()}>{anchor => <Menu label="Choose effort" class="fork-effort-menu" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => setEffortAnchor(undefined)}>
        <Show when={backend()==="codex"}><CodexSpeedPicker model={model()} value={speed()} local={!!localBinding(p.mission.id)} disabled={busy()} onChange={setSpeed}/></Show>
        <For each={["", ...supportedEfforts(backend())]}>{effort => <button type="button" role="menuitem" class="menu-item" disabled={busy()} onClick={() => void fork(effort)}>{effortLabel(effort || undefined,backend(),model())}</button>}</For>
        <Show when={error()}><ErrorNotice error={error()}/></Show>
      </Menu>}</Show>
      <Show when={error() && !effortAnchor()}><ErrorNotice error={error()}/></Show>
    </Menu>}</Show>
    <Show when={busy()}><div class="menu-group" role="status">Forking…</div></Show>
  </Menu>;
}

/** A transfer replaces the original: stop it (two agents must not share its folder), then
 * archive it so one row remains. The new conversation keeps the full history as fork context. */
export async function retireTransferredSource(id: string): Promise<void> {
  window.dispatchEvent(new CustomEvent("orb:mission-archived", { detail: { id } }));
  try {
    const current = await getMission(id);
    if (!isArchivable(current.status) || current.execution?.state === "running") {
      await cancelMission(id);
      for (let i = 0; i < 20; i++) {
        const m = await getMission(id);
        if (m.execution?.state !== "running" && ["cancelled", "interrupted", "failed", "completed", "awaiting_user"].includes(m.status)) break;
        await new Promise((r) => setTimeout(r, 500));
      }
    }
    await archiveMission(id);
  } catch {
    // The original stays listed (Core refused or is unreachable); the transfer itself succeeded.
    window.dispatchEvent(new CustomEvent("orb:mission-archive-failed", { detail: { id } }));
  }
}
