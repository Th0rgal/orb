import { Show, createResource, createSignal } from "solid-js";
import { ErrorNotice } from "./ErrorNotice";
import { SettingsCard, SettingsRow } from "./SettingsCard";
import { Toggle } from "./Toggle";
import {
  getUsageTelemetryStatus,
  updateUsageTelemetryConfig,
  type UsageTelemetryConfig,
  type UsageTelemetryStatus,
} from "./usageTelemetry";

const NAMESPACE_RE = /^[a-z0-9_-]{1,40}$/;

export function telemetryNamespaceError(raw: string): string {
  if (!raw) return "";
  if (raw.toLowerCase() === "community") {
    return "Telemetry must use your personal namespace, never community.";
  }
  if (/[A-Z]/.test(raw)) {
    return "Uppercase letters aren’t allowed — use lowercase (a–z), digits, - or _.";
  }
  if (raw.length > 40) {
    return "Namespace must be 40 characters or fewer.";
  }
  if (!NAMESPACE_RE.test(raw)) {
    return "Only lowercase letters (a–z), digits, - and _ are allowed.";
  }
  return "";
}

/** Settings → Account → Usage telemetry. Off by default; the hub token is
 *  write-only (Core stores it encrypted and never returns it). */
export function UsageTelemetrySettings() {
  const [status, { mutate }] = createResource(getUsageTelemetryStatus);
  const [namespace, setNamespace] = createSignal<string | null>(null);
  const [hubUrl, setHubUrl] = createSignal<string | null>(null);
  const [token, setToken] = createSignal("");
  const [error, setError] = createSignal("");
  const [busy, setBusy] = createSignal(false);

  const currentNamespace = (s: UsageTelemetryStatus) => namespace() ?? s.namespace ?? "";
  const currentHubUrl = (s: UsageTelemetryStatus) => hubUrl() ?? s.hub_url;

  const isDirty = (s: UsageTelemetryStatus) => {
    const nsDirty = namespace() !== null && namespace() !== (s.namespace ?? "");
    const urlDirty = hubUrl() !== null && hubUrl()!.trim() !== s.hub_url;
    const tokenDirty = token().trim().length > 0;
    return nsDirty || urlDirty || tokenDirty;
  };

  const save = async (config: UsageTelemetryConfig, resetHubDraft = false) => {
    if (busy()) return;
    setBusy(true);
    setError("");
    try {
      const next = await updateUsageTelemetryConfig(config);
      mutate(next);
      if (resetHubDraft) {
        setNamespace(null);
        setHubUrl(null);
        setToken("");
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const saveConnection = (s: UsageTelemetryStatus) => {
    const ns = currentNamespace(s);
    if (!isDirty(s) || telemetryNamespaceError(ns)) return;
    return save(
      {
        namespace: ns,
        hub_url: currentHubUrl(s).trim(),
        ...(token().trim() ? { token: token().trim() } : {}),
      },
      true,
    );
  };

  const onHubKeyDown = (e: KeyboardEvent, s: UsageTelemetryStatus) => {
    if (e.key !== "Enter" || e.isComposing) return;
    e.preventDefault();
    void saveConnection(s);
  };

  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Usage telemetry</h2>
        <Show when={error()}>
          <ErrorNotice error={error()} onDismiss={() => setError("")} />
        </Show>
        <Show
          when={status()}
          fallback={
            <div class="ms-skeleton" aria-hidden="true">
              <div class="sk-bar" style={{ width: "100%", height: "148px" }} />
              <div class="sk-bar" style={{ width: "100%", height: "196px" }} />
            </div>
          }
        >
          {(s) => {
            const nsError = () => telemetryNamespaceError(currentNamespace(s()));
            return (
              <>
                <SettingsCard>
                  <SettingsRow
                    title="Send usage telemetry"
                    desc="Pages, feature use, approvals and turn stats go to your own namespace on the telemetry hub, never the community one. No prompts, payloads or secrets."
                  >
                    <Toggle
                      label="Send usage telemetry"
                      on={s().enabled}
                      disabled={busy()}
                      onClick={() => void save({ enabled: !s().enabled })}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title="Include prompts"
                    desc="Also send your prompt text, with API keys, tokens and passwords scrubbed first."
                  >
                    <Show when={s().enabled} fallback={<span class="s-row-desc">Off</span>}>
                      <Toggle
                        label="Include prompts"
                        on={s().prompts_enabled}
                        disabled={busy()}
                        onClick={() => void save({ prompts_enabled: !s().prompts_enabled })}
                      />
                    </Show>
                  </SettingsRow>
                  <SettingsRow
                    status
                    title={
                      <span class="ut-status">
                        <span
                          class={`ut-dot ${s().active ? "active" : s().enabled ? "pending" : ""}`}
                          aria-hidden="true"
                        />
                        {s().active ? "Active" : s().enabled ? "Needs setup" : "Off"}
                      </span>
                    }
                    desc={`${
                      s().active
                        ? `Sending · ${s().queued} queued${s().namespace ? ` · ${s().namespace}` : ""}`
                        : s().enabled
                          ? "On, but needs a namespace and token"
                          : "Nothing leaves this machine unless telemetry is enabled."
                    }${s().last_error ? ` · Last error: ${s().last_error}` : ""}`}
                  />
                </SettingsCard>

                <SettingsCard title="Hub">
                  <SettingsRow
                    title="Namespace"
                    desc={
                      nsError() ? (
                        <span class="ut-field-err">{nsError()}</span>
                      ) : (
                        "Personal hub namespace (lowercase letters, digits, - or _)."
                      )
                    }
                  >
                    <input
                      class="s-input"
                      aria-label="Telemetry namespace"
                      aria-invalid={nsError() ? "true" : undefined}
                      placeholder="th0rgal"
                      maxLength={40}
                      pattern="[a-z0-9_-]{1,40}"
                      autocapitalize="off"
                      autocorrect="off"
                      spellcheck={false}
                      value={currentNamespace(s())}
                      onInput={(e) => setNamespace(e.currentTarget.value)}
                      onKeyDown={(e) => onHubKeyDown(e, s())}
                    />
                  </SettingsRow>
                  <SettingsRow title="Hub URL" desc="HTTPS endpoint receiving batched events.">
                    <input
                      class="s-input"
                      type="url"
                      aria-label="Telemetry hub URL"
                      placeholder="https://telemetry.thomas.md"
                      autocapitalize="off"
                      autocorrect="off"
                      spellcheck={false}
                      value={currentHubUrl(s())}
                      onInput={(e) => setHubUrl(e.currentTarget.value)}
                      onKeyDown={(e) => onHubKeyDown(e, s())}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title="Token"
                    desc={
                      s().token_configured
                        ? "Stored encrypted on Core. Enter a new token to replace it."
                        : "Write-only hub token (tl_live_…), stored encrypted on Core."
                    }
                  >
                    <input
                      class="s-input"
                      type="password"
                      autocomplete="off"
                      autocapitalize="off"
                      autocorrect="off"
                      spellcheck={false}
                      aria-label="Telemetry token"
                      placeholder={s().token_configured ? "Configured" : "tl_live_…"}
                      value={token()}
                      onInput={(e) => setToken(e.currentTarget.value)}
                      onKeyDown={(e) => onHubKeyDown(e, s())}
                    />
                  </SettingsRow>
                  <SettingsRow
                    title={s().token_configured ? "Token configured" : "No token saved"}
                    desc={
                      s().token_configured
                        ? s().namespace
                          ? `Forwarding target: ${s().namespace}.`
                          : "Add your namespace above to finish setup."
                        : "Save your namespace, hub URL and write token to enable forwarding."
                    }
                  >
                    <Show when={s().token_configured && !token().trim()}>
                      <button
                        type="button"
                        class="s-btn"
                        disabled={busy()}
                        onClick={() => void save({ token: "" })}
                      >
                        Clear token
                      </button>
                    </Show>
                    <button
                      type="button"
                      class="s-btn primary"
                      disabled={busy() || !isDirty(s()) || Boolean(nsError())}
                      onClick={() => void saveConnection(s())}
                    >
                      {busy() ? "Saving…" : "Save"}
                    </button>
                  </SettingsRow>
                </SettingsCard>
              </>
            );
          }}
        </Show>
      </div>
    </div>
  );
}
