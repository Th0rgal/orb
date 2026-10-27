import { Show, createResource, createSignal } from "solid-js";
import { ErrorNotice } from "./ErrorNotice";
import { Toggle } from "./Settings";
import { getUsageTelemetryStatus, updateUsageTelemetryConfig, type UsageTelemetryConfig, type UsageTelemetryStatus } from "./usageTelemetry";

/** Settings → Account → Usage telemetry. Off by default; the hub token is
 * write-only (Core stores it encrypted and never returns it). */
export function UsageTelemetrySettings() {
  const [status, { mutate }] = createResource(getUsageTelemetryStatus);
  const [namespace, setNamespace] = createSignal("");
  const [hubUrl, setHubUrl] = createSignal("");
  const [token, setToken] = createSignal("");
  const [error, setError] = createSignal("");
  const [busy, setBusy] = createSignal(false);

  const save = async (config: UsageTelemetryConfig) => {
    setBusy(true);
    setError("");
    try {
      mutate(await updateUsageTelemetryConfig(config));
      setToken("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  const connection = (s: UsageTelemetryStatus): UsageTelemetryConfig => ({
    namespace: namespace() || s.namespace || "",
    hub_url: hubUrl() || s.hub_url,
    ...(token().trim() ? { token: token().trim() } : {}),
  });

  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Usage telemetry</h2>
        <Show when={error()}><ErrorNotice error={error()} onDismiss={() => setError("")} /></Show>
        <Show when={status()} fallback={<div class="ms-skeleton" aria-hidden="true"><div class="sk-bar" style={{ width: "100%", height: "140px" }} /><div class="sk-bar" style={{ width: "100%", height: "160px" }} /></div>}>
          {s => (
            <>
              <section class="s-sec">
                <div class="s-card">
                  <div class="s-row">
                    <div class="s-row-text">
                      <div class="s-row-title">Send usage telemetry</div>
                      <div class="s-row-desc">Pages, feature use, approvals and turn stats go to your own namespace on the telemetry hub, never the community one. No prompts, payloads or secrets.</div>
                    </div>
                    <div class="s-row-ctrl"><Toggle on={s().enabled} onClick={() => void save({ enabled: !s().enabled })} /></div>
                  </div>
                  <div class="s-row">
                    <div class="s-row-text">
                      <div class="s-row-title">Include prompts</div>
                      <div class="s-row-desc">Also send your prompt text, with API keys, tokens and passwords scrubbed first.</div>
                    </div>
                    <div class="s-row-ctrl"><Show when={s().enabled} fallback={<span class="s-row-desc">Off</span>} keyed><Toggle on={s().prompts_enabled} onClick={() => void save({ prompts_enabled: !s().prompts_enabled })} /></Show></div>
                  </div>
                  <div class="s-row">
                    <span class="s-row-desc" role="status">
                      {s().active ? `Sending · ${s().queued} queued` : s().enabled ? "On, but needs a namespace and token" : "Off"}
                      {s().last_error ? ` · Last error: ${s().last_error}` : ""}
                    </span>
                  </div>
                </div>
              </section>
              <section class="s-sec">
                <h3>Hub</h3>
                <div class="s-card">
                  <div class="s-row"><span class="s-row-title">Namespace</span><input class="s-input" aria-label="Telemetry namespace" placeholder="th0rgal" value={s().namespace ?? ""} onInput={e => setNamespace(e.currentTarget.value)} /></div>
                  <div class="s-row"><span class="s-row-title">Hub URL</span><input class="s-input" aria-label="Telemetry hub URL" value={s().hub_url} onInput={e => setHubUrl(e.currentTarget.value)} /></div>
                  <div class="s-row"><span class="s-row-title">Token</span><input class="s-input" type="password" autocomplete="off" aria-label="Telemetry token" placeholder={s().token_configured ? "Configured" : "tl_live_…"} value={token()} onInput={e => setToken(e.currentTarget.value)} /></div>
                  <div class="s-row"><span /><button class="s-btn" disabled={busy()} onClick={() => void save(connection(s()))}>Save</button></div>
                </div>
              </section>
            </>
          )}
        </Show>
      </div>
    </div>
  );
}
