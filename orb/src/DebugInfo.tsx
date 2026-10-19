import { For, Show, createResource, createSignal } from "solid-js";
import { api, getApiUrl, isConnected } from "./api";
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
  userAgent: string;
  logs: LogEntry[];
};

/** Native app version when running inside Tauri, else the bundled one. */
async function appVersion(): Promise<string> {
  const invoke = nativeInvoke();
  if (!invoke) return BUNDLE_VERSION;
  try { return (await invoke<string>("plugin:app|version")) || BUNDLE_VERSION; } catch { return BUNDLE_VERSION; }
}

/** Core version from `/api/health`, when the backend reports one. */
export async function coreVersion(): Promise<string | null> {
  if (!isConnected()) return null;
  try {
    const health = await api<{ version?: unknown }>("/api/health");
    return typeof health?.version === "string" && health.version ? health.version : null;
  } catch (error) { swallow("debugInfo.health")(error); return null; }
}

export async function debugSnapshot(): Promise<DebugSnapshot> {
  const [version, core] = await Promise.all([appVersion(), coreVersion()]);
  return {
    version, build: BUNDLE_BUILD, desktop: !!nativeInvoke(),
    backend: isConnected() ? getApiUrl() : null, coreVersion: core,
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
    `Core: ${s.coreVersion ?? "unknown"}`,
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
      <Show when={snapshot()} fallback={<div class="s-row-desc">Loading…</div>}>{s => <>
        <dl class="debug-info-facts">
          <dt>App</dt><dd>{s().version} (build {s().build}){s().desktop ? "" : " · web"}</dd>
          <dt>Backend</dt><dd>{s().backend ?? "Not connected"}</dd>
          <dt>Core</dt><dd>{s().coreVersion ?? "Unknown"}</dd>
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
