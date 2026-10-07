import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import { isConnected } from "./api";
import { listChains, routingCatalog, type ModelChain, type RoutingCatalog } from "./routingApi";
import { RoutingPicker } from "./RoutingPicker";
import { Toggle } from "./Settings";
import { sideQuestionKey } from "./sideQuestionStorage";

export type InboxConfig = {
  aiSummary: boolean;
  model: string;
};

const DEFAULT_INBOX_CONFIG: InboxConfig = {
  aiSummary: true,
  model: "builtin/smart",
};

const [inboxConfigVersion, setInboxConfigVersion] = createSignal(0);
export { inboxConfigVersion };

export function inboxConfig(): InboxConfig {
  inboxConfigVersion();
  try {
    const raw = localStorage.getItem(sideQuestionKey("settings:inbox"));
    if (!raw) return { ...DEFAULT_INBOX_CONFIG };
    const parsed = JSON.parse(raw) as Partial<InboxConfig>;
    return {
      aiSummary: typeof parsed.aiSummary === "boolean" ? parsed.aiSummary : DEFAULT_INBOX_CONFIG.aiSummary,
      model: typeof parsed.model === "string" && parsed.model.trim() ? parsed.model.trim() : DEFAULT_INBOX_CONFIG.model,
    };
  } catch {
    return { ...DEFAULT_INBOX_CONFIG };
  }
}

export function saveInboxConfig(next: InboxConfig): boolean {
  try {
    const normalized: InboxConfig = {
      aiSummary: Boolean(next.aiSummary),
      model: next.model.trim() || DEFAULT_INBOX_CONFIG.model,
    };
    localStorage.setItem(sideQuestionKey("settings:inbox"), JSON.stringify(normalized));
    setInboxConfigVersion((v) => v + 1);
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

export function InboxSettings() {
  const [config, setConfig] = createSignal<InboxConfig>(inboxConfig());
  const [message, setMessage] = createSignal("");
  const [chains, setChains] = createSignal<ModelChain[]>([]);
  const [catalog, setCatalog] = createSignal<RoutingCatalog | null>(null);

  onMount(() => {
    if (!isConnected()) return;
    void listChains()
      .then((rows) => setChains(rows))
      .catch(() => {});
    void routingCatalog()
      .then((cat) => setCatalog(cat))
      .catch(() => {});
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
    return out;
  });

  const save = (next = config()) => {
    if (saveInboxConfig(next)) {
      setMessage("Saved. Inbox digests will use this configuration.");
    } else {
      setMessage("Could not save Inbox settings.");
    }
  };

  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Inbox</h2>
        <section class="s-sec">
          <h3>AI Overview &amp; Turn Digest</h3>
          <div class="s-card">
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">AI task &amp; outcome summary</div>
                <div class="s-row-desc">
                  Summarize your latest request to the agent and whether its work succeeded, failed, or is waiting on you.
                </div>
              </div>
              <div class="s-row-ctrl">
                <Toggle
                  on={config().aiSummary}
                  onClick={() => {
                    const next = { ...config(), aiSummary: !config().aiSummary };
                    setConfig(next);
                    save(next);
                  }}
                />
              </div>
            </div>

            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Summary model</div>
                <div class="s-row-desc">
                  Routing chain or provider/model used to generate the 2-line Inbox digest (defaults to <code>builtin/smart</code>).
                </div>
              </div>
              <div class="s-row-ctrl inbox-settings-model-ctrl">
                <RoutingPicker
                  label="Inbox summary model"
                  value={config().model}
                  options={modelOptions()}
                  onInput={(value) => setConfig({ ...config(), model: value })}
                />
              </div>
            </div>

            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Quick presets</div>
                <div class="s-row-desc">
                  Choose a built-in routing chain or enter any <code>provider/model</code> above.
                </div>
              </div>
              <div class="s-row-ctrl" style={{ display: "flex", gap: "6px" }}>
                <For each={PRESET_MODELS}>
                  {(preset) => (
                    <button
                      type="button"
                      class={`s-btn sm ${config().model === preset.id ? "primary" : ""}`}
                      onClick={() => {
                        const next = { ...config(), model: preset.id };
                        setConfig(next);
                        save(next);
                      }}
                    >
                      {preset.name}
                    </button>
                  )}
                </For>
              </div>
            </div>

            <div class="s-row">
              <span role="status" class="s-row-desc">
                {message()}
              </span>
              <button
                type="button"
                class="s-btn"
                disabled={!config().model.trim()}
                onClick={() => save(config())}
              >
                Save
              </button>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}
