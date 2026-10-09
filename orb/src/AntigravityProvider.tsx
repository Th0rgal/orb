import { Select } from "./Select";
import { For, Show, createEffect, createSignal, on, onCleanup, onMount } from "solid-js";
import { connectionVersion, getRemoteNodes, listNodeAntigravityModels } from "./api";
import { ProviderLogo } from "./ProviderLogo";

/** Native Google accounts live on the execution machine, outside the API-key store. */
export function AntigravityProvider(p: { embedded?: boolean } = {}) {
  const [machine, setMachine] = createSignal("core");
  const [nodes, setNodes] = createSignal<string[]>([]);
  const [models, setModels] = createSignal<[string, string][]>([]);
  const [phase, setPhase] = createSignal<"loading" | "ready" | "error">("loading");
  const [open, setOpen] = createSignal(false);
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
  return <section class="s-sec" aria-label="Antigravity CLI">
    <Show when={!p.embedded}><h3>Native execution</h3></Show>
    <div class="s-card p-acc-wrap">
      <button class="s-row p-acc p-acc-btn" aria-expanded={open()} onClick={() => setOpen(!open())}>
        <ProviderLogo type="antigravity" />
        <div class="s-row-text">
          <div class="s-row-title">Execution machines</div>
          <div class="s-row-desc"><span class={`p-st ${phase() === "ready" && models().length ? "connected" : "not_configured"}`}>
            {phase() === "loading" ? "Checking machine…" : phase() === "error" ? "Machine unavailable" : models().length ? `Connected · ${models().length} ${models().length === 1 ? "model" : "models"}` : "No models available"}
          </span><span class="p-dot">·</span>{machine() === "core" ? "Core" : machine()}</div>
        </div><span class={`chev p-acc-chev ${open() ? "open" : ""}`}>›</span>
      </button>
      <Show when={open()}><div class="p-acc-body">
        <label class="s-row-desc">Machine <Select class="s-input" aria-label="Antigravity machine" value={machine()} onChange={event => setMachine(event.currentTarget.value)}>
          <option value="core">Core</option><For each={nodes()}>{node => <option value={node}>{node}</option>}</For>
        </Select></label>
        <p class="s-row-desc">The subscription above connects the model router. Native Antigravity execution uses the Google sign-in on each machine; its credentials are separate.</p>
        <Show when={phase() === "ready" && models().length}><ul aria-label="Antigravity models"><For each={models()}>{model => <li>{model[1]}</li>}</For></ul></Show>
        <Show when={phase() === "error"}><p class="s-row-desc" role="status">Check this machine’s connection and Antigravity sign-in, then refresh.</p></Show>
        <div class="p-acc-actions"><button class="s-btn" disabled={phase() === "loading"} onClick={reload}>Refresh machines</button></div>
      </div></Show>
    </div>
  </section>;
}
