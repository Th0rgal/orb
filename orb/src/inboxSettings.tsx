import { isRecord, readJson } from "./storage";
import { swallow } from "./log";
import { writeInboxState } from "./inboxState";
import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import { isConnected } from "./api";
import { listChains, routingCatalog, type ModelChain, type RoutingCatalog } from "./routingApi";
import { Select } from "./Select";
import { NameDialog } from "./Dialog";
import { sideQuestionKey } from "./sideQuestionStorage";
import {
  DEFAULT_INBOX_CONFIG,
  ECO_QUIET_MS,
  formatInboxSummaryBadge,
  normalizeInboxConfig,
  normalizeSummaryMode,
  shouldRequestInboxDigest,
  type InboxConfig,
  type InboxSummaryMode,
  type InboxSummarySurface,
} from "./inboxPolicy";

export {
  DEFAULT_INBOX_CONFIG,
  ECO_QUIET_MS,
  formatInboxSummaryBadge,
  normalizeInboxConfig,
  normalizeSummaryMode,
  shouldRequestInboxDigest,
  type InboxConfig,
  type InboxSummaryMode,
  type InboxSummarySurface,
};

const [inboxConfigVersion, setInboxConfigVersion] = createSignal(0);
export { inboxConfigVersion };

export function inboxConfig(): InboxConfig {
  inboxConfigVersion();
  try {
    const parsed = readJson<Partial<InboxConfig> | null>(sideQuestionKey("settings:inbox"), null, isRecord);
    return normalizeInboxConfig(parsed);
  } catch {
    return { ...DEFAULT_INBOX_CONFIG };
  }
}

export function saveInboxConfig(
  next: Partial<InboxConfig> & Pick<InboxConfig, "aiSummary" | "model">,
  sync = true,
): boolean {
  try {
    const current = inboxConfig();
    const normalized = normalizeInboxConfig({
      ...current,
      ...next,
      model: next.model.trim() || DEFAULT_INBOX_CONFIG.model,
    });
    localStorage.setItem(sideQuestionKey("settings:inbox"), JSON.stringify(normalized));
    setInboxConfigVersion((v) => v + 1);
    if (sync) writeInboxState("preferences", normalized);
    return true;
  } catch {
    return false;
  }
}

const PRESET_MODELS: Array<{ id: string; name: string; detail: string }> = [
  {
    id: "builtin/smart",
    name: "builtin/smart",
    detail: "Default smart routing chain for concise task & outcome digests",
  },
  {
    id: "builtin/fast",
    name: "builtin/fast",
    detail: "Low-latency routing chain for rapid summaries",
  },
];

const SUMMARY_MODE_DESCRIPTIONS: Record<InboxSummaryMode, string> = {
  standard: "Pre-warm unread digests in the background and show end-of-turn recaps in chat.",
  on_open: "Save tokens: only generate summaries when Inbox is open and the run has settled.",
  eco: "Eco mode: only summarize when Inbox is open and a settled conversation has had no messages for at least 1 hour.",
};

/** Empty selection means Off and never overwrites the remembered model. */
export function inboxSummaryChoice(model: string, choice: string) {
  const selected = choice.trim();
  return { aiSummary: selected.length > 0, model: selected || model };
}

/** Agents → Inbox & summaries (`inbox-summaries`): master Inbox switch, scope, model, and Eco mode. */
export function InboxSummariesSettings() {
  const config = createMemo(inboxConfig);
  const [custom, setCustom] = createSignal<string>();
  const [customError, setCustomError] = createSignal("");
  const [message, setMessage] = createSignal("");
  const [chains, setChains] = createSignal<ModelChain[]>([]);
  const [catalog, setCatalog] = createSignal<RoutingCatalog | null>(null);

  onMount(() => {
    if (!isConnected()) return;
    void listChains()
      .then((rows) => setChains(rows))
      .catch(swallow("inboxSettings.listChains"));
    void routingCatalog()
      .then((cat) => setCatalog(cat))
      .catch(swallow("inboxSettings.routingCatalog"));
  });

  const modelOptions = createMemo(() => {
    const seen = new Set<string>();
    const out: Array<{ id: string; name: string; detail?: string }> = [];
    const push = (id: string, name: string, detail?: string) => {
      if (!id || seen.has(id)) return;
      seen.add(id);
      out.push({ id, name, detail });
    };

    for (const p of PRESET_MODELS) push(p.id, p.name, p.detail);
    for (const chain of chains()) {
      const entries = chain.entries.map((e) => `${e.provider_id}/${e.model_id}`).join(" → ");
      push(chain.id, chain.id, entries || chain.name);
    }
    const cat = catalog();
    if (cat?.providers) {
      for (const prov of cat.providers) {
        for (const m of prov.models ?? []) {
          const qualified = `${prov.id}/${m.id}`;
          push(qualified, qualified, `${prov.name} · ${m.name || m.id}`);
        }
      }
    }
    push(config().model, config().model);
    return out;
  });

  const save = (next = config()) => {
    if (saveInboxConfig(next)) {
      setMessage("Saved. Inbox will use this configuration.");
    } else {
      setMessage("Could not save Inbox settings.");
    }
  };

  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Inbox &amp; summaries</h2>
        <section class="s-sec">
          <h3>Inbox</h3>
          <div class="s-card">
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Enable Inbox</div>
                <div class="s-row-desc">
                  Show Inbox in the sidebar, keep the ⌘I shortcut active, and track unread agent updates.
                </div>
              </div>
              <div class="s-row-ctrl">
                <button
                  type="button"
                  class={`toggle ${config().inboxEnabled ? "on" : ""}`}
                  role="switch"
                  aria-label="Enable Inbox"
                  aria-checked={config().inboxEnabled}
                  onClick={() => save({ ...config(), inboxEnabled: !config().inboxEnabled })}
                />
              </div>
            </div>
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Include autonomous agents</div>
                <div class="s-row-desc">
                  Show updates from sub-agents and missions launched by Hermes in your Inbox and unread count.
                  Off by default: only agents you started directly appear.
                </div>
              </div>
              <div class="s-row-ctrl">
                <button
                  type="button"
                  class={`toggle ${config().includeAutonomous ? "on" : ""}`}
                  role="switch"
                  aria-label="Include autonomous agents"
                  aria-checked={config().includeAutonomous}
                  disabled={!config().inboxEnabled}
                  onClick={() => save({ ...config(), includeAutonomous: !config().includeAutonomous })}
                />
              </div>
            </div>
          </div>
        </section>
        <section class="s-sec">
          <h3>AI summaries</h3>
          <div class="s-card">
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">AI summaries</div>
                <div class="s-row-desc">Choose a model or routing chain for Inbox digests. Off keeps your last choice.</div>
              </div>
              <div class="s-row-ctrl inbox-settings-model-ctrl">
                <Select
                  aria-label="AI summaries"
                  disabled={!config().inboxEnabled}
                  value={config().aiSummary ? config().model : ""}
                  onChange={(e) => {
                    const choice = e.currentTarget.value;
                    if (choice === "__custom__") {
                      setCustomError("");
                      setCustom(config().model);
                      e.currentTarget.value = config().aiSummary ? config().model : "";
                    } else {
                      save({ ...config(), ...inboxSummaryChoice(config().model, choice) });
                    }
                  }}
                >
                  <option value="">Off</option>
                  <For each={modelOptions()}>{(option) => <option value={option.id}>{option.name}</option>}</For>
                  <option value="__custom__">Custom model or chain…</option>
                </Select>
              </div>
            </div>
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Summary mode</div>
                <div class="s-row-desc">{SUMMARY_MODE_DESCRIPTIONS[config().summaryMode]}</div>
              </div>
              <div class="s-row-ctrl inbox-settings-model-ctrl">
                <Select
                  aria-label="Summary mode"
                  disabled={!config().inboxEnabled || !config().aiSummary}
                  value={config().summaryMode}
                  onChange={(e) => save({ ...config(), summaryMode: normalizeSummaryMode(e.currentTarget.value) })}
                >
                  <option value="standard">Standard</option>
                  <option value="on_open">When Inbox opens</option>
                  <option value="eco">Eco (1h quiet)</option>
                </Select>
              </div>
            </div>
            <Show when={message()}>
              <div class="s-row"><span role="status" class="s-row-desc">{message()}</span></div>
            </Show>
          </div>
        </section>
        <Show when={custom() !== undefined}>
          <NameDialog
            title="Custom model or chain"
            label="Model or chain ID"
            value={custom() ?? ""}
            onInput={setCustom}
            placeholder="provider/model or chain ID"
            action="Use model"
            error={customError()}
            onClose={() => setCustom(undefined)}
            onAction={() => {
              const next = { ...config(), ...inboxSummaryChoice(config().model, custom()!) };
              if (saveInboxConfig(next)) {
                setCustom(undefined);
                setMessage("Saved. Inbox will use this configuration.");
              } else {
                setCustomError("Could not save Inbox settings. Try again.");
              }
            }}
          />
        </Show>
      </div>
    </div>
  );
}

/** Notifications (`inbox-settings`): unread scope and shortcut to Agents → Inbox & summaries. */
export function InboxSettings(p: { onOpenPage?: (id: string) => void } = {}) {
  const config = createMemo(inboxConfig);
  const [message, setMessage] = createSignal("");
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Notifications</h2>
        <section class="s-sec">
          <h3>Notifications</h3>
          <div class="s-card">
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Include autonomous agents</div>
                <div class="s-row-desc">
                  Show updates from sub-agents and missions launched by Hermes in your Inbox and unread count.
                  Off by default: only agents you started directly appear.
                </div>
              </div>
              <div class="s-row-ctrl">
                <button
                  type="button"
                  class={`toggle ${config().includeAutonomous ? "on" : ""}`}
                  role="switch"
                  aria-label="Include autonomous agents"
                  aria-checked={config().includeAutonomous}
                  disabled={!config().inboxEnabled}
                  onClick={() => {
                    const next = { ...config(), includeAutonomous: !config().includeAutonomous };
                    if (saveInboxConfig(next)) setMessage("Saved. Inbox will use this configuration.");
                    else setMessage("Could not save Inbox settings.");
                  }}
                />
              </div>
            </div>
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Inbox &amp; summaries</div>
                <div class="s-row-desc">{formatInboxSummaryBadge(config())}</div>
              </div>
              <Show when={p.onOpenPage}>
                <div class="s-row-ctrl">
                  <button type="button" class="s-btn" onClick={() => p.onOpenPage!("inbox-summaries")}>
                    Configure
                  </button>
                </div>
              </Show>
            </div>
            <Show when={message()}>
              <div class="s-row"><span role="status" class="s-row-desc">{message()}</span></div>
            </Show>
          </div>
        </section>
      </div>
    </div>
  );
}

export function applySharedInboxPreferences(prefs: unknown): void {
  if (prefs === undefined || prefs === null) {
    writeInboxState("preferences", inboxConfig());
    return;
  }
  if (typeof prefs !== "object" || Array.isArray(prefs)) return;
  const p = prefs as Partial<InboxConfig>;
  if (typeof p.aiSummary !== "boolean" || typeof p.includeAutonomous !== "boolean" || typeof p.model !== "string" || !p.model.trim()) return;
  const normalized = normalizeInboxConfig(p);
  if (JSON.stringify(inboxConfig()) !== JSON.stringify(normalized)) saveInboxConfig(normalized, false);
}
