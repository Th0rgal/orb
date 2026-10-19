import { HARNESS_IDS, harnessName } from "./harnesses";
import { cloudAccounts, cloudNames, type CloudAccount } from "./cloudAgentApi";
import { ErrorToast } from "./toast";
import { ExecutionSettings } from "./ExecutionSettings";
import { Select } from "./Select";
import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createSignal, onMount, type JSX } from "solid-js";
import * as Ic from "./icons";
import { clearConnection, getApiUrl, getJwt, isConnected, login, setApiUrl } from "./api";
import { localInstalled, pathOverrides, refreshLocalAgents, setPathOverride, tauriInvoke } from "./localAgents";
import { getThemePref, setThemePref, type ThemePref } from "./theme";

const THEME_LABELS: Record<ThemePref, string> = { auto: "Auto", light: "Light", dark: "Dark" };
const THEME_PREFS: Record<string, ThemePref> = { Auto: "auto", Light: "light", Dark: "dark" };

export function Toggle(p: { on: boolean; onClick?: () => void }) {
  const [on, setOn] = createSignal(p.on);
  return (
    <button
      class={`toggle ${on() ? "on" : ""}`}
      role="switch"
      aria-checked={on()}
      onClick={() => {
        setOn(!on());
        p.onClick?.();
      }}
    />
  );
}


function Row(p: { title: string; desc?: string; children?: JSX.Element }) {
  return (
    <div class="s-row">
      <div class="s-row-text">
        <div class="s-row-title">{p.title}</div>
        <Show when={p.desc}>
          <div class="s-row-desc">{p.desc}</div>
        </Show>
      </div>
      <div class="s-row-ctrl">{p.children}</div>
    </div>
  );
}

function Card(p: { title?: string; children: JSX.Element }) {
  return (
    <section class="s-sec">
      <Show when={p.title}>
        <h3>{p.title}</h3>
      </Show>
      <div class="s-card">{p.children}</div>
    </section>
  );
}

function CloudAccountsCard(p: { onOpenPage?: (id: string) => void }) {
  const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const refresh = async () => {
    setBusy(true);
    try { setAccounts(await cloudAccounts()); setError(""); }
    catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  onMount(() => { void refresh(); });
  return <Card title="Cloud accounts">
    <Row title="Connected services" desc="Cloud agents use accounts connected to Core. Connecting an account does not start work.">
      <button class="s-btn" disabled={busy()} onClick={() => void refresh()}>{busy() ? "Checking…" : "Refresh accounts"}</button>
    </Row>
    <ErrorToast error={error()} title="Couldn’t refresh cloud accounts" onDismiss={() => setError("")} />
    <For each={accounts()}>{a => <Row title={`${cloudNames[a.provider]} · ${a.label}`} desc={a.reason}>
      <span>{a.available ? "Available" : "Unavailable"}{a.experimental ? " · Experimental" : ""}</span>
      <Show when={a.provider === "hermes" && p.onOpenPage}><button class="s-btn" onClick={() => p.onOpenPage?.("hermes-settings")}>Configure</button></Show>
    </Row>}</For>
  </Card>;
}

type ContextWorker = { project: string; connected: boolean; running: boolean };
/** Project context workers keep each project's local replica fresh, even after Orb quits. */
function BackgroundSyncCard() {
  const [workers, setWorkers] = createSignal<ContextWorker[]>([]);
  const [error, setError] = createSignal("");
  const request = (project: string) => ({ endpoint: getApiUrl(), token: getJwt() ?? "", project, paths: [] });
  const refresh = async () => {
    try {
      const invoke = tauriInvoke(); if (!invoke) return;
      const res = await invoke("project_context_workers", { request: request("list") }) as { workers: ContextWorker[] };
      setWorkers(res.workers); setError("");
    } catch (e) { setError(String(e)); }
  };
  const stop = async (project: string) => {
    try { const invoke = tauriInvoke(); if (!invoke) return; await invoke("project_context_stop", { request: request(project) }); }
    catch (e) { setError(String(e)); }
    setTimeout(() => void refresh(), 1500);
  };
  onMount(() => { if (isConnected()) void refresh(); });
  return <Show when={workers().length || error()}>
    <Card title="Background sync">
      <Row title="Project context" desc="One small process per project keeps its context folder in sync with Core, also while Orb is closed. Stopping one pauses it until you use that project again.">
        <button class="s-btn" onClick={() => void refresh()}>Refresh</button>
      </Row>
      <ErrorToast error={error()} title="Couldn’t read background sync" onDismiss={() => setError("")} />
      <For each={workers()}>{w => <Row title={w.project} desc={w.running ? "Syncing in the background" : w.connected ? "Starting…" : "Paused"}>
        <Show when={w.connected}><button class="s-btn" onClick={() => void stop(w.project)}>Stop</button></Show>
      </Row>}</For>
    </Card>
  </Show>;
}

function LocalAgentsCard() {
  const [busy, setBusy] = createSignal(false);
  const [drafts, setDrafts] = createSignal<Record<string, string>>(pathOverrides());
  const scan = async () => {
    setBusy(true);
    try {
      await refreshLocalAgents(true);
    } finally {
      setBusy(false);
    }
  };
  if (!localInstalled().length) void scan();
  const row = (id: string) => localInstalled().find((item) => item.id === id);
  const save = (id: string) => {
    setPathOverride(id, drafts()[id] ?? "");
    void scan();
  };
  return (
    <Card title="Local agents">
      <Row title="This computer" desc="CLIs Orb can launch here. A blank path uses whatever is on PATH.">
        <button class="s-btn" disabled={busy()} onClick={() => void scan()}>
          {busy() ? "Scanning…" : "Scan"}
        </button>
      </Row>
      <For each={HARNESS_IDS}>
        {(id) => {
          const found = () => row(id);
          return (
            <Row title={harnessName(id)} desc={found()?.installed ? `${found()?.version ?? "installed"} · ${found()?.path}${found()?.auth_error ? ` · ${found()?.auth_error}` : id === "antigravity" ? ` · ${found()?.models?.length ?? 0} account models` : ""}` : found()?.auth_error ? [found()?.path, found()?.auth_error].filter(Boolean).join(" · ") : "Not found"}>
              <input
                class="s-input"
                aria-label={`${harnessName(id)} path`}
                placeholder="Path override"
                value={drafts()[id] ?? ""}
                onInput={(e) => setDrafts({ ...drafts(), [id]: e.currentTarget.value })}
                onKeyDown={(e) => e.key === "Enter" && save(id)}
              />
              <button class="s-btn" onClick={() => save(id)}>
                Save
              </button>
            </Row>
          );
        }}
      </For>
    </Card>
  );
}

function BackendTab() {
  const [url, setUrl] = createSignal(getApiUrl());
  const [password, setPassword] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  const connect = async () => {
    if (busy()) return;
    setApiUrl(url());
    setBusy(true);
    setError(null);
    try {
      await login(password());
      setPassword("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Card title="Backend">
        <Row title="API URL" desc="Base URL of the sandboxed.sh core backend.">
          <input
            class="s-input"
            value={url()}
            placeholder="https://agent-backend.thomas.md"
            onInput={(e) => setUrl(e.currentTarget.value)}
          />
        </Row>
        <Show when={!isConnected()}>
          <Row title="Password" desc="Dashboard password. The returned JWT is stored in localStorage.">
            <input
              class="s-input"
              type="password"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && void connect()}
            />
          </Row>
        </Show>
        <Row
          title={isConnected() ? "Connected" : "Not connected"}
          desc={isConnected() ? `Signed in to ${getApiUrl()}.` : "Connect to enable live Machines, Providers and missions."}
        >
          <Show
            when={isConnected()}
            fallback={
              <button class="s-btn primary" disabled={busy() || !password()} onClick={() => void connect()}>
                {busy() ? "Connecting…" : "Connect"}
              </button>
            }
          >
            <button class="s-btn" onClick={() => clearConnection()}>
              Disconnect
            </button>
          </Show>
        </Row>
      </Card>
      <Show when={error()}>
        <ErrorNotice error={error()!} />
      </Show>
    </>
  );
}

export function Settings(p: { onOpenPage?: (id: string) => void } = {}) {
  const [executionMounted, setExecutionMounted] = createSignal(false);
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>General</h2>
        <BackendTab />
        <LocalAgentsCard />
        <CloudAccountsCard onOpenPage={p.onOpenPage} />
        <BackgroundSyncCard />
        <Show when={isConnected()}>
          <section class="s-sec">
            <h3>Execution</h3>
            <details class="s-card execution-disclosure" onToggle={e => { if (e.currentTarget.open) setExecutionMounted(true); }}>
              <summary class="s-row">
                <span class="s-row-text"><span class="s-row-title">Concurrency limits</span><span class="s-row-desc">Agent and task limits across all projects.</span></span>
                <Ic.ChevronDown size={14} />
              </summary>
              <Show when={executionMounted()}><ExecutionSettings inline /></Show>
            </details>
          </section>
        </Show>
        <Card title="Appearance">
          <Row title="Theme" desc="Auto follows your desktop appearance.">
            <Select
              value={THEME_LABELS[getThemePref()]}
              aria-label="Theme"
              onChange={(e) => setThemePref(THEME_PREFS[e.currentTarget.value])}
            ><option>Auto</option><option>Light</option><option>Dark</option></Select>
          </Row>
        </Card>
      </div>
    </div>
  );
}
