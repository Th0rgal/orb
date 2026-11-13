import { For, Show, createResource, createSignal } from "solid-js";
import { api, connectionVersion, getApiUrl, isConnected } from "./api";
import { SettingsCard, SettingsRow } from "./SettingsCard";
import { copyText } from "./clipboard";
import { recentLogs, swallow, type LogEntry } from "./log";
import { nativeInvoke } from "./native";

/** Version baked in by vite.config.ts; `getVersion` from Tauri wins in the desktop app. */
export const BUNDLE_VERSION: string = import.meta.env.VITE_ORB_VERSION ?? "dev";
export const BUNDLE_BUILD: string = import.meta.env.VITE_ORB_BUILD ?? "dev";

export type DebugSnapshot = {
  version: string;
  build: string;
  desktop: boolean;
  backend: string | null;
  coreVersion: string | null;
  coreBuild: string | null;
  userAgent: string;
  logs: LogEntry[];
};

/** Native app version when running inside Tauri, else the bundled one. */
async function appVersion(): Promise<string> {
  const invoke = nativeInvoke();
  if (!invoke) return BUNDLE_VERSION;
  try { return (await invoke<string>("plugin:app|version")) || BUNDLE_VERSION; } catch { return BUNDLE_VERSION; }
}

const healthString = (value: unknown): string | null => typeof value === "string" && value.trim() ? value.trim() : null;

/** Build identity comes from the connected Core, never the client bundle. */
export async function coreBuildInfo(): Promise<{ version: string | null; build: string | null }> {
  const unknown = { version: null, build: null };
  if (!isConnected()) return unknown;
  try {
    const health = await api<{ version?: unknown; build?: unknown }>("/api/health");
    return { version: healthString(health?.version), build: healthString(health?.build) };
  } catch (error) { swallow("debugInfo.health")(error); return unknown; }
}

export async function coreVersion(): Promise<string | null> {
  return (await coreBuildInfo()).version;
}

/** Always visible in Settings; a connection change discards the previous server identity. */
export function AboutCard() {
  const [core, { refetch }] = createResource(() => connectionVersion(), coreBuildInfo);
  return <SettingsCard title="About">
    <SettingsRow title="Client build commit" desc={`Orb ${BUNDLE_VERSION}`}><code>{BUNDLE_BUILD}</code></SettingsRow>
    <SettingsRow title="Server build commit" desc={isConnected() ? "Reported by the connected Core via /api/health." : "Not connected"}>
      <Show when={!core.loading} fallback={<span class="sk-bar" role="status" aria-label="Loading server build" style={{ display: "inline-block", width: "104px", height: "13px" }} />}>
        <code>{isConnected() ? core()?.build ?? "Unknown" : "Not connected"}</code>
      </Show>
    </SettingsRow>
    <SettingsRow title="Build information" desc="Refresh after updating the server.">
      <button class="s-btn" disabled={!isConnected() || core.loading} onClick={() => void refetch()}>Refresh build info</button>
    </SettingsRow>
  </SettingsCard>;
}

export async function debugSnapshot(): Promise<DebugSnapshot> {
  const [version, core] = await Promise.all([appVersion(), coreBuildInfo()]);
  return {
    version, build: BUNDLE_BUILD, desktop: !!nativeInvoke(),
    backend: isConnected() ? getApiUrl() : null, coreVersion: core.version, coreBuild: core.build,
    userAgent: typeof navigator === "undefined" ? "" : navigator.userAgent,
    logs: recentLogs(50),
  };
}

const logLine = (e: LogEntry) => `${e.at} ${e.level.toUpperCase()} [${e.scope}] ${e.message}${e.data ? ` ${JSON.stringify(e.data)}` : ""}${e.dropped ? ` (+${e.dropped} dropped)` : ""}`;

/** Plain-text report for bug reports: versions, backend, then recent log lines. */
export function diagnosticsText(s: DebugSnapshot): string {
  return [
    `Orb ${s.version} (build ${s.build})${s.desktop ? " desktop" : " web"}`,
    `Backend: ${s.backend ?? "not connected"}`,
    `Core: ${s.coreVersion ?? "unknown"} (build ${s.coreBuild ?? "unknown"})`,
    `User agent: ${s.userAgent}`,
    "",
    `Recent log (${s.logs.length}):`,
    ...(s.logs.length ? s.logs.map(logLine) : ["(empty)"]),
  ].join("\n");
}

/** Settings → Debug info. Reads a fresh snapshot each time it is opened. */
export function DebugInfoPanel() {
  const [snapshot, { refetch }] = createResource(debugSnapshot);
  const [copied, setCopied] = createSignal<string | null>(null);
  const copy = async () => {
    const s = await debugSnapshot();
    try { await copyText(diagnosticsText(s)); setCopied("Copied"); } catch (e) { setCopied(`Couldn’t copy: ${String(e)}`); }
  };
  return (
    <div class="debug-info" data-testid="debug-info">
      <Show when={snapshot()} fallback={<div role="status" aria-label="Loading diagnostics"><span class="sr-only">Loading…</span><dl class="debug-info-facts"><dt>App</dt><dd><span class="sk-bar" style={{ display: "inline-block", width: "136px", height: "13px", "vertical-align": "middle" }} /></dd><dt>Backend</dt><dd><span class="sk-bar" style={{ display: "inline-block", width: "184px", height: "13px", "vertical-align": "middle" }} /></dd><dt>Core</dt><dd><span class="sk-bar" style={{ display: "inline-block", width: "104px", height: "13px", "vertical-align": "middle" }} /></dd></dl><div class="debug-info-actions"><span class="sk-bar" style={{ width: "112px", height: "28px" }} /><span class="sk-bar" style={{ width: "68px", height: "28px" }} /></div><div class="sk-bar" style={{ width: "100%", height: "72px" }} /></div>}>{s => <>
        <dl class="debug-info-facts">
          <dt>App</dt><dd>{s().version} (build {s().build}){s().desktop ? "" : " · web"}</dd>
          <dt>Backend</dt><dd>{s().backend ?? "Not connected"}</dd>
          <dt>Core</dt><dd>{s().coreVersion ?? "Unknown"} (build {s().coreBuild ?? "Unknown"})</dd>
        </dl>
        <div class="debug-info-actions">
          <button class="s-btn" onClick={() => void copy()}>Copy diagnostics</button>
          <button class="s-btn" onClick={() => { setCopied(null); void refetch(); }}>Refresh</button>
          <Show when={copied()}><span class="s-row-desc" role="status">{copied()}</span></Show>
        </div>
        <pre class="debug-info-log" aria-label="Recent log entries"><Show when={s().logs.length} fallback="No log entries yet."><For each={s().logs}>{e => <>{logLine(e)}{"\n"}</>}</For></Show></pre>
      </>}</Show>
    </div>
  );
}
