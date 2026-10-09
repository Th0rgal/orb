import { Select } from "./Select";
import { For, Show, createEffect, createSignal, createUniqueId, on, onCleanup, onMount } from "solid-js";
import { connectionVersion, getRemoteNodes, listNodeAntigravityModels } from "./api";

/** Native Google accounts live on the execution machine, outside the API-key store. */
export function AntigravityProvider() {
  const [machine, setMachine] = createSignal("core");
  const [nodes, setNodes] = createSignal<string[]>([]);
  const [models, setModels] = createSignal<[string, string][]>([]);
  const [phase, setPhase] = createSignal<"loading" | "ready" | "error">("loading");
  const [showModels, setShowModels] = createSignal(false);
  const modelsId = createUniqueId();
  let generation = 0, inventoryGeneration = 0, disposed = false;
  const refresh = async () => {
    const request = ++generation, version = connectionVersion(), target = machine();
    setModels([]); setPhase("loading");
    try {
      const result = await listNodeAntigravityModels(target);
      if (disposed || request !== generation || version !== connectionVersion()) return;
      setModels(result); setPhase("ready");
    } catch {
      if (!disposed && request === generation && version === connectionVersion()) setPhase("error");
    }
  };
  createEffect(() => { machine(); connectionVersion(); void refresh(); });
  const refreshNodes = async () => {
    const version = connectionVersion(), request = ++inventoryGeneration;
    try {
      const result = await getRemoteNodes();
      if (disposed || version !== connectionVersion() || request !== inventoryGeneration) return;
      const available = (result.nodes ?? []).map(node => node.id);
      setNodes(available);
      if (machine() !== "core" && !available.includes(machine())) setMachine("core");
    } catch { /* Keep the current inventory; Refresh can recover a transient failure. */ }
  };
  const reload = () => { void refreshNodes(); void refresh(); };
  createEffect(on(connectionVersion, () => {
    setMachine("core");
    setNodes([]);
    void refreshNodes();
  }));
  onMount(() => {
    window.addEventListener("orb:providers-refresh", reload);
    onCleanup(() => window.removeEventListener("orb:providers-refresh", reload));
  });
  onCleanup(() => { disposed = true; generation++; });
  return <section class="p-native" aria-label="Antigravity execution">
      <h4>Execution machines</h4>
      <p class="s-row-desc">Native runs use the Google sign-in on each machine, separate from the subscription used for model routing.</p>
      <div class="p-native-controls">
        <label class="p-native-machine">Machine <Select class="s-input" aria-label="Antigravity machine" value={machine()} onChange={event => setMachine(event.currentTarget.value)}>
          <option value="core">Core</option><For each={nodes()}>{node => <option value={node}>{node}</option>}</For>
        </Select></label>
        <span class="s-row-desc" role="status">{phase() === "loading" ? "Checking machine…" : phase() === "error" ? "Machine unavailable" : models().length ? "Ready" : "No models available"}</span>
        <button class="s-btn" disabled={phase() === "loading"} onClick={reload}>Refresh machines</button>
      </div>
      <Show when={phase() === "ready" && models().length}>
        <button class="p-native-models-toggle" aria-expanded={showModels()} aria-controls={modelsId} onClick={() => setShowModels(!showModels())}>
          {showModels() ? "Hide models" : `${models().length} ${models().length === 1 ? "model" : "models"} available`}<span class={`chev p-acc-chev ${showModels() ? "open" : ""}`}>›</span>
        </button>
        <Show when={showModels()}><ul id={modelsId} class="p-native-models" aria-label="Antigravity models"><For each={models()}>{model => <li>{model[1]}</li>}</For></ul></Show>
      </Show>
      <Show when={phase() === "error"}><p class="s-row-desc">Check this machine’s connection and Antigravity sign-in, then refresh.</p></Show>
  </section>;
}
