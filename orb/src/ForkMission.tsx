import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createSignal, onMount } from "solid-js";
import { forkMission, shortModelLabel, type HarnessChoice, type Mission } from "./api";
import { effortLabel, supportedEfforts } from "./effort";
import { Menu } from "./Menu";

export function ForkMission(p: { mission: Mission; choices: HarnessChoice[]; destination: string; anchor?: HTMLElement; onOpen?: () => void; onClose: () => void; onFork: (mission: Mission) => void }) {
  const [backend, setBackend] = createSignal(p.mission.backend ?? p.choices[0]?.backend.id ?? "");
  const [model, setModel] = createSignal(p.mission.model_override ?? "");
  const [modelAnchor, setModelAnchor] = createSignal<HTMLButtonElement>();
  const [effortAnchor, setEffortAnchor] = createSignal<HTMLButtonElement>();
  const [busy, setBusy] = createSignal(false), [error, setError] = createSignal("");
  const choices = () => p.choices.find(choice => choice.backend.id === backend())?.models ?? [];
  const unavailable = (id: string) => !!p.mission.remote_node_id && !["grok", "claudecode", "opencode", "antigravity", "vibe"].includes(id);
  const key = crypto.randomUUID();
  onMount(() => p.onOpen?.());
  const fork = async (effort = "") => {
    if (busy() || !backend() || unavailable(backend()) || !choices().some(choice => choice.value === model())) return;
    setBusy(true); setError("");
    try { p.onFork(await forkMission(p.mission.id, { backend: backend(), model_override: model(), model_effort: effort, idempotency_key: key })); }
    catch (e) {setError(e instanceof Error ? e.message : String(e));}
    finally {setBusy(false);}
  };
  const openModels = (id: string, anchor: HTMLButtonElement) => {
    if (busy() || unavailable(id)) return;
    setBackend(id); setEffortAnchor(undefined); setModelAnchor(anchor);
  };
  return <Menu label="Fork conversation" class="fork-harnesses" anchor={p.anchor} placement={p.anchor ? "right-start" : "top-start"} busy={busy()} onClose={p.onClose}>
    <Show when={!p.anchor}><div class="menu-group">Fork conversation</div></Show>
    <For each={p.choices}>{choice => <button type="button" class="menu-item" role="menuitem" aria-haspopup="menu" aria-expanded={!!modelAnchor() && backend() === choice.backend.id} disabled={busy() || unavailable(choice.backend.id)}
      title={unavailable(choice.backend.id) ? "Not supported on this remote workspace" : choice.backend.name}
      onMouseEnter={e => openModels(choice.backend.id, e.currentTarget)} onClick={e => openModels(choice.backend.id,e.currentTarget)}
      onKeyDown={e => {if(e.key === "ArrowRight"){e.preventDefault();e.stopPropagation();openModels(choice.backend.id,e.currentTarget);}}}>
      {choice.backend.name}<span class="menu-chevron" aria-hidden="true">›</span>
    </button>}</For>
    <Show when={modelAnchor()}>{anchor => <Menu label="Choose a model" class="fork-models" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => setModelAnchor(undefined)}>
      <For each={choices()}>{choice => {
        const choose = (anchor: HTMLButtonElement) => {if (busy()) return; setModel(choice.value); if (supportedEfforts(backend()).length) setEffortAnchor(anchor); else void fork();};
        return <button type="button" class="menu-item" role="menuitem" disabled={busy()} aria-haspopup={supportedEfforts(backend()).length ? "menu" : undefined}
          title={`Fork into ${shortModelLabel(choice.label)} · same workspace on ${p.destination}`}
          onClick={e => choose(e.currentTarget)} onMouseEnter={e => {if (!busy() && supportedEfforts(backend()).length) {setModel(choice.value);setEffortAnchor(e.currentTarget);}}}
          onKeyDown={e => {if(e.key === "ArrowRight" && supportedEfforts(backend()).length){e.preventDefault();e.stopPropagation();choose(e.currentTarget);}}}>
          {shortModelLabel(choice.label)}<Show when={supportedEfforts(backend()).length}><span class="menu-chevron" aria-hidden="true">›</span></Show>
        </button>;
      }}</For>
      <Show when={!choices().length}><div class="menu-group">No models available</div></Show>
      <Show when={effortAnchor()}>{anchor => <Menu label="Choose effort" class="fork-effort-menu" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => setEffortAnchor(undefined)}>
        <For each={["", ...supportedEfforts(backend())]}>{effort => <button type="button" role="menuitem" class="menu-item" disabled={busy()} onClick={() => void fork(effort)}>{effortLabel(effort || undefined,backend(),model())}</button>}</For>
        <Show when={error()}><ErrorNotice error={error()}/></Show>
      </Menu>}</Show>
      <Show when={error() && !effortAnchor()}><ErrorNotice error={error()}/></Show>
    </Menu>}</Show>
    <Show when={busy()}><div class="menu-group" role="status">Forking…</div></Show>
  </Menu>;
}
