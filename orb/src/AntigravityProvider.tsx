import { For, Show, createEffect, createSignal, createUniqueId, on, onCleanup, onMount } from "solid-js";
import { connectionVersion, getRemoteNodes, listNodeAntigravityModels } from "./api";

type Machine = { id: string; label: string; phase: "loading" | "ready" | "error" };

/** Native runs use this Google sign-in on every machine; checking one also hands it the login. */
export function AntigravityProvider() {
  const [machines, setMachines] = createSignal<Machine[]>([{ id: "core", label: "Core", phase: "loading" }]);
  const [models, setModels] = createSignal<[string, string][]>([]);
  const [showModels, setShowModels] = createSignal(false);
  const modelsId = createUniqueId();
  let generation = 0, disposed = false;
  const set = (id: string, phase: Machine["phase"]) => setMachines(list => list.map(m => m.id === id ? { ...m, phase } : m));
  const check = async (request: number, version: number, id: string) => {
    try {
      const result = await listNodeAntigravityModels(id);
      if (disposed || request !== generation || version !== connectionVersion()) return;
      set(id, result.length ? "ready" : "error");
      if (result.length && (id === "core" || !models().length)) setModels(result);
    } catch {
      if (!disposed && request === generation && version === connectionVersion()) set(id, "error");
    }
  };
  const refresh = async (only?: string) => {
    if (only) { set(only, "loading"); return check(generation, connectionVersion(), only); }
    const request = ++generation, version = connectionVersion();
    setModels([]);
    setMachines([{ id: "core", label: "Core", phase: "loading" }]);
    void check(request, version, "core");
    try {
      const result = await getRemoteNodes();
      if (disposed || request !== generation || version !== connectionVersion()) return;
      const nodes = (result.nodes ?? []).filter(node => !node.cordoned && node.status !== "offline").map(node => node.id);
      setMachines(list => [...list, ...nodes.map(id => ({ id, label: id, phase: "loading" as const }))]);
      nodes.forEach(id => void check(request, version, id));
    } catch { /* Core alone still answers; Refresh retries the inventory. */ }
  };
  createEffect(on(connectionVersion, () => void refresh()));
  onMount(() => {
    const reload = () => void refresh();
    window.addEventListener("orb:providers-refresh", reload);
    onCleanup(() => window.removeEventListener("orb:providers-refresh", reload));
  });
  onCleanup(() => { disposed = true; generation++; });
  const ready = () => machines().filter(m => m.phase === "ready");
  const failed = () => machines().filter(m => m.phase === "error");
  const checking = () => machines().some(m => m.phase === "loading");
  return <section class="p-native" aria-label="Antigravity execution">
      <p class="s-row-desc">Native runs use this Google sign-in on every machine.</p>
      <div class="p-native-controls">
        <span class="s-row-desc" role="status">{ready().length ? `Available on ${ready().map(m => m.label).join(", ")}` : checking() ? "Checking machines…" : "Not available on any machine"}</span>
        <Show when={checking() && ready().length}><span class="s-row-desc">Checking…</span></Show>
        <button class="s-btn" disabled={checking()} onClick={() => void refresh()}>Refresh</button>
      </div>
      <Show when={failed().length}>
        <ul class="p-native-failed" aria-label="Unavailable machines">
          <For each={failed()}>{m => <li><span>{m.label} unavailable</span> <button class="p-native-retry" onClick={() => void refresh(m.id)}>Retry</button></li>}</For>
        </ul>
      </Show>
      <Show when={models().length}>
        <button class="p-native-models-toggle" aria-expanded={showModels()} aria-controls={modelsId} onClick={() => setShowModels(!showModels())}>
          {showModels() ? "Hide models" : `${models().length} ${models().length === 1 ? "model" : "models"} available`}<span class={`chev p-acc-chev ${showModels() ? "open" : ""}`}>›</span>
        </button>
        <Show when={showModels()}><ul id={modelsId} class="p-native-models" aria-label="Antigravity models"><For each={models()}>{model => <li>{model[1]}</li>}</For></ul></Show>
      </Show>
  </section>;
}
