import { For, Show, createEffect, createSignal, createUniqueId, on, onCleanup, onMount } from "solid-js";
import { connectionVersion, getRemoteNodes, listNodeAntigravityModels } from "./api";
import { isManagedNode } from "./machines/nodes";
import { getManagedSettings, managedError, putManagedSettings } from "./managedMachineModel";

/** "Available on Core, spark + managed machines". */
export function availabilityLine(ready: string[], managed: boolean | null, checking: boolean): string {
  const extra = managed ? " + managed machines" : "";
  if (ready.length) return `Available on ${ready.join(", ")}${extra}`;
  if (checking) return "Checking machines…";
  return managed ? "Available on managed machines" : "Not available on any machine";
}

/** Short form for the header row; the full list is its tooltip. */
export function availabilitySummary(ready: string[], managed: boolean | null, checking: boolean): string {
  if (!ready.length) return availabilityLine(ready, managed, checking);
  const extra = ready.length - 1 + (managed ? 1 : 0);
  return `Available on ${ready[0]}${extra ? ` +${extra}` : ""}`;
}

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
      // Managed machines come and go; the setting below covers them as a group.
      const nodes = (result.nodes ?? []).filter(node => !node.cordoned && node.status !== "offline" && !isManagedNode(node));
      setMachines(list => [...list, ...nodes.map(node => ({ id: node.id, label: node.display_name || node.id, phase: "loading" as const }))]);
      nodes.forEach(node => void check(request, version, node.id));
    } catch { /* Core alone still answers; Refresh retries the inventory. */ }
  };
  createEffect(on(connectionVersion, () => void refresh()));
  onMount(() => {
    const reload = () => void refresh();
    window.addEventListener("orb:providers-refresh", reload);
    onCleanup(() => window.removeEventListener("orb:providers-refresh", reload));
  });
  onCleanup(() => { disposed = true; generation++; });
  // null: the backend has no managed-machine settings (toggle hidden).
  const [managed, setManaged] = createSignal<boolean | null>(null);
  const [saving, setSaving] = createSignal(false);
  const [settingError, setSettingError] = createSignal("");
  createEffect(on(connectionVersion, () => { setManaged(null); void getManagedSettings().then(r => setManaged(r ? r.antigravity_on_managed : null)).catch(() => setManaged(null)); }));
  const toggleManaged = async () => {
    const next = !managed();
    setSaving(true); setSettingError(""); setManaged(next);
    try { const r = await putManagedSettings({ antigravity_on_managed: next }); setManaged(r?.antigravity_on_managed ?? next); }
    catch (e) { setManaged(!next); setSettingError(managedError(e)); }
    finally { setSaving(false); }
  };
  const ready = () => machines().filter(m => m.phase === "ready");
  const failed = () => machines().filter(m => m.phase === "error");
  const checking = () => machines().some(m => m.phase === "loading");
  return <section class="p-native" aria-label="Antigravity execution">
      {/* Execution availability and settings follow the account quota details. */}
      <div class="p-native-controls">
        <span class="s-row-desc p-native-where" role="status" tabIndex={0}
          title={`${availabilityLine(ready().map(m => m.label), managed(), checking())}. Native runs use this Google sign-in on every machine.`}>
          {availabilitySummary(ready().map(m => m.label), managed(), checking())}
        </span>
        <Show when={checking() && ready().length}><span class="s-row-desc">Checking…</span></Show>
        <button class="s-btn quiet" disabled={checking()} onClick={() => void refresh()}>Refresh</button>
      </div>
      <div class="p-native-row">
        <Show when={managed() !== null}>
          <label class="p-native-managed" title="Install Antigravity and hand it this sign-in on new boat.dev machines.">
            <span>Managed machines</span>
            <button class={`toggle ${managed() ? "on" : ""}`} role="switch" aria-checked={!!managed()} aria-label="Antigravity on managed machines" disabled={saving()} onClick={() => void toggleManaged()} />
          </label>
        </Show>
        <Show when={models().length}>
          <button class="p-native-models-toggle" aria-expanded={showModels()} aria-controls={modelsId} onClick={() => setShowModels(!showModels())}>
            {showModels() ? "Hide models" : `${models().length} ${models().length === 1 ? "model" : "models"} available`}<span class={`chev p-acc-chev ${showModels() ? "open" : ""}`}>›</span>
          </button>
        </Show>
      </div>
      <Show when={settingError()}><p class="s-row-desc managed-error" role="alert">{settingError()}</p></Show>
      <Show when={failed().length}>
        <ul class="p-native-failed" aria-label="Unavailable machines">
          <For each={failed()}>{m => <li><span>{m.label} unavailable</span> <button class="p-native-retry" onClick={() => void refresh(m.id)}>Retry</button></li>}</For>
        </ul>
      </Show>
      <Show when={showModels() && models().length}><ul id={modelsId} class="p-native-models" aria-label="Antigravity models"><For each={models()}>{model => <li>{model[1]}</li>}</For></ul></Show>
  </section>;
}
