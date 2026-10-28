import { pollWhileVisible } from "./poll";
import { swallow } from "./log";
import { AntigravityProvider } from "./AntigravityProvider";
import { ErrorToast } from "./toast";
import {CloudProviders} from './CloudProviders';
import {ProviderUsageChip, ProviderUsageMeter} from './ProviderUsageMeter';
import { Dynamic } from "solid-js/web";
import { quotaStatus, usageChips, codingPlanWindows, kimiWindows, codexWindowLabel, effectiveProviderStatus, hasProviderUsageDetails, sharedAnthropicOrganizations, usageLimitStatus, usageWindows, verificationUrl } from "./providerUsage";
import { PopupMenu } from "./Menu";
import { ProviderLogo } from "./ProviderLogo";
import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, onMount } from "solid-js";
import * as Ic from "./icons";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import {
  api,
  connectionVersion,
  getAllProviderUsage,
  getProviderUsage,
  setMistralUsageSession,
  recheckAntigravity,
  clearMistralUsageSession,
  getSubscriptionLogin,
  startProviderOAuth,
  completeProviderOAuth,
  isConnected,
  listProviders,
  setProviderEnabled,
  reorderProviders,
  openExternalUrl,
  startSubscriptionLogin,
  cancelSubscriptionLogin,
  submitCliProxyLoginCallback,
  type AIProvider,
  type ProviderUsage,
} from "./api";
import { nativeInvoke } from "./clientRuns";
import { listHealth, type AccountHealthSnapshot } from "./routingApi";
import { applyOrder, moveAccount, orderAccounts } from "./accountOrder";

type AuthKind = "oauth" | "api";

type Method = { label: string; kind: AuthKind; desc: string };

type Kind = {
  id: string;
  name: string;
  methods: Method[];
};

const KINDS: Kind[] = [
  {
    id: "muse-code",
    name: "Muse Code",
    methods: [{ label: "Muse Code subscription", kind: "oauth", desc: "Meta subscription via CLIProxyAPI. Separate from Meta API billing." }],
  },
  {
    id: "anthropic",
    name: "Anthropic",
    methods: [
      { label: "Claude Pro/Max", kind: "oauth", desc: "Subscription via CLIProxyAPI. Core does not refresh this token." },
      { label: "API key", kind: "api", desc: "Direct Anthropic API key, stored by Core." },
    ],
  },
  {
    id: "openai",
    name: "OpenAI",
    methods: [
      { label: "ChatGPT Plus/Pro", kind: "oauth", desc: "Codex / ChatGPT plan via CLIProxyAPI." },
      { label: "API key", kind: "api", desc: "api.openai.com key. Separate from the ChatGPT plan." },
    ],
  },
  {
    id: "xai",
    name: "xAI",
    methods: [
      { label: "SuperGrok OAuth", kind: "oauth", desc: "grok.com login via CLIProxyAPI. Grok Build shares this account." },
      { label: "API key", kind: "api", desc: "Direct xAI API key." },
    ],
  },
  {
    id: "google",
    name: "Google",
    methods: [
      { label: "Google OAuth", kind: "oauth", desc: "Google OAuth for OpenCode, managed by Core." },
      { label: "API key", kind: "api", desc: "Google AI Studio key." },
    ],
  },
  {
    id: "kimi",
    name: "Kimi",
    methods: [{ label: "Kimi Code", kind: "oauth", desc: "Device sign-in managed by CLIProxyAPI." }],
  },
  {
    id: "github-copilot",
    name: "GitHub Copilot",
    methods: [{ label: "GitHub Copilot", kind: "oauth", desc: "OAuth subscription." }],
  },
  { id: "open-router", name: "OpenRouter", methods: [{ label: "API key", kind: "api", desc: "OPENROUTER_API_KEY" }] },
  { id: "groq", name: "Groq", methods: [{ label: "API key", kind: "api", desc: "GROQ_API_KEY" }] },
  {
    id: "mistral",
    name: "Mistral",
    methods: [
      { label: "Mistral Vibe", kind: "oauth", desc: "Mistral Vibe subscription sign-in managed by Core." },
      { label: "API key", kind: "api", desc: "MISTRAL_API_KEY" },
    ],
  },
  { id: "minimax", name: "MiniMax", methods: [{ label: "API key", kind: "api", desc: "MINIMAX_API_KEY" }] },
  { id: "zai", name: "Z.AI", methods: [{ label: "API key", kind: "api", desc: "ZHIPU_API_KEY" }] },
  { id: "custom", name: "Custom", methods: [{ label: "OpenAI-compatible", kind: "api", desc: "Base URL + key." }] },
];

export function Providers() {
  const [remote, setRemote] = createSignal<AIProvider[] | null>(null);
  // Router circuit-breaker state per account ("Out of credit", "Auth failed").
  const [health, setHealth] = createSignal<Record<string, AccountHealthSnapshot>>({});

  const [loading, setLoading] = createSignal(false);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  let request: AbortController | undefined;
  let generation = 0;
  const reloadRemote = async () => {
    request?.abort();
    const current = ++generation;
    if (!isConnected()) return;
    const version = connectionVersion();
    const controller = new AbortController();
    request = controller;
    setLoading(true);
    setLoadError(null);
    // Aborting also releases the request; a late response must never populate
    // a different backend's page or overwrite a newer refresh.
    const timer = setTimeout(() => controller.abort(), 15_000);
    const active = () => current === generation && version === connectionVersion() && isConnected();
    try {
      const providers = await listProviders(controller.signal);
      if (active()) setRemote(providers);
      listHealth()
        .then(list => { if (active() && Array.isArray(list)) setHealth(Object.fromEntries(list.map(h => [h.account_id, h]))); })
        .catch(() => {});
    } catch (error) {
      if (active()) setLoadError(controller.signal.aborted
        ? "Loading providers timed out. Check your connection and try again."
        : String(error));
    } finally {
      clearTimeout(timer);
      if (active()) setLoading(false);
    }
  };
  createEffect(() => {
    connectionVersion();
    const connected = isConnected();
    request?.abort();
    ++generation;
    setRemote(null);
    setLoadError(null);
    if (connected) void reloadRemote();
  });
  onCleanup(() => { ++generation; request?.abort(); });

  const live = () => (isConnected() ? remote() : null);
  return (
    <Show
      when={isConnected()}
      fallback={
        <div class="page">
          <div class="page-head"><h2>Providers</h2></div>
          <p class="s-lead">Providers are configured in Core — connect in Settings → Backend to see them.</p>
        </div>
      }
    >
      <Show when={live()} fallback={<div class="page">
        <div class="page-head"><h2>Providers</h2></div>
        <Show when={loading()}><p class="s-lead shimmer" role="status">Loading providers…</p></Show>
        <Show when={loadError()}>{error => <ErrorNotice title="Could not load providers" error={error()}>
          <button class="s-btn" onClick={() => void reloadRemote()}>Try again</button>
        </ErrorNotice>}</Show>
      </div>}>
        <LiveProviders list={live() ?? []} health={health()} onRefresh={() => { void reloadRemote(); window.dispatchEvent(new Event("orb:providers-refresh")); }} loading={loading()} loadError={loadError()} />
      </Show>
    </Show>
  );
}


const SUBSCRIPTION_META: Record<string, { vendor: string; desc: string }> = {
  anthropic: { vendor: "Anthropic", desc: "Claude Code & OpenCode · OAuth via CLIProxyAPI" },
  openai: { vendor: "OpenAI", desc: "Codex & OpenCode · OAuth via CLIProxyAPI" },
  xai: { vendor: "xAI", desc: "Grok & OpenCode · OAuth via CLIProxyAPI" },
  kimi: { vendor: "Moonshot AI", desc: "OpenCode · Device sign-in via CLIProxyAPI" },
  antigravity: { vendor: "Google", desc: "Antigravity & Gemini models · OAuth via CLIProxyAPI" },
  mistral: { vendor: "Mistral AI", desc: "Le Chat Pro / Team · Browser sign-in" },
  "muse-code": { vendor: "Meta", desc: "Muse Code subscription · No paid API fallback" },
};

function LiveProviders(p: { list: AIProvider[]; health?: Record<string, AccountHealthSnapshot>; onRefresh: () => void; loading?: boolean; loadError?: string | null }) {
  const [usage, setUsage] = createSignal<Record<string, ProviderUsage>>({});
  const sharedOrgs = createMemo(() => sharedAnthropicOrganizations(usage()));
  const [keyEditor, setKeyEditor] = createSignal<AIProvider | "new" | null>(null);
  const [reauth, setReauth] = createSignal<AIProvider | null>(null);
  const [adding, setAdding] = createSignal(false);
  const [loginOptions, setLoginOptions] = createSignal<{available: boolean; providers: {id: string; name: string}[]; reason?: string}>();
  const [addType, setAddType] = createSignal("");
  const [removing, setRemoving] = createSignal<AIProvider | null>(null);
  const [removeBusy, setRemoveBusy] = createSignal(false);
  const [removeError, setRemoveError] = createSignal<string | null>(null);
  const remove = async () => {
    const account = removing(); if (!account || removeBusy()) return;
    setRemoveBusy(true);
    try { await api(`/api/ai/providers/${encodeURIComponent(account.id)}`, {method: "DELETE"}); setRemoving(null); p.onRefresh(); }
    catch (error) { setRemoveError(String(error)); }
    finally { setRemoveBusy(false); }
  };
  onMount(() => {
    void api<{available: boolean; providers: {id: string; name: string}[]; reason?: string}>("/api/ai/providers/cli-proxy-login")
      .then(res => {
        const providers = Array.isArray(res.providers) ? [...res.providers] : [];
        if (!providers.some(p => p.id === "mistral")) {
          providers.push({ id: "mistral", name: "Mistral Vibe" });
        }
        setLoginOptions({ ...res, available: true, providers });
      })
      .catch(() => setLoginOptions({available: false, providers: [], reason: "Update the backend to add subscription accounts here."}));
  });
  // uses_oauth describes what a provider supports, not the credential in use.
  // Vibe browser sign-in provisions an API key. For Mistral, uses_oauth is
  // set by the backend's subscription marker, not by the stored secret type.
  const isKey = (a: AIProvider) => !(a.provider_type === "mistral" && a.uses_oauth)
    && ((a.has_api_key === true && a.has_oauth === false) || !a.uses_oauth);
  // A reorder shows at once; the next server list replaces it.
  const [ordered, setOrdered] = createSignal<AIProvider[] | null>(null);
  createEffect(on(() => p.list, () => setOrdered(null), { defer: true }));
  const list = () => ordered() ?? p.list;
  const oauth = () => orderAccounts(list().filter(a => !isKey(a) && a.provider_type !== "google"));
  const modelConnections = () => list().filter(a => !isKey(a) && a.provider_type === "google");
  const keys = () => orderAccounts(list().filter(isKey));
  const [toggleError, setToggleError] = createSignal<string | null>(null);
  const reorder = (group: AIProvider[], a: AIProvider, to: number) => {
    const ids = moveAccount(group, a.id, to);
    if (!ids) return;
    const previous = ordered();
    setToggleError(null);
    setOrdered(applyOrder(list(), ids));
    void reorderProviders(ids).then(p.onRefresh, () => {
      setOrdered(previous);
      setToggleError(`Could not change the order of ${a.provider_type_name || a.provider_type} accounts. The previous order is kept.`);
    });
  };
  /** Position of `a` among its provider's accounts in `group`, when there are several. */
  const rankIn = (group: () => AIProvider[], a: AIProvider): AccountRank | undefined => {
    const peers = group().filter(x => x.provider_type === a.provider_type);
    if (peers.length < 2) return undefined;
    return { index: peers.findIndex(x => x.id === a.id), count: peers.length, move: to => reorder(group(), a, to) };
  };
  const toggle = (a: AIProvider, enabled: boolean) => {
    setToggleError(null);
    void setProviderEnabled(a.id, enabled).then(p.onRefresh, () => setToggleError(`Could not ${enabled ? "enable" : "disable"} ${a.name}. Nothing changed.`));
  };

  let disposed = false;
  let fetching = false;
  const refreshUsage = async () => {
    if (fetching) return;
    fetching = true;
    try {
      const snapshot = await getAllProviderUsage();
      if (!disposed) setUsage(snapshot);
      // The bulk endpoint returns its cache before starting background probes.
      // Await subscription accounts so the first visit receives their result too.
      await Promise.allSettled(p.list.filter(a => ["kimi", "minimax", "zai", "muse-code", "mistral"].includes(a.provider_type) || (a.uses_oauth && (a.provider_type === "openai" || a.provider_type === "xai"))).map(async a => {
        const value = await getProviderUsage(a.id);
        if (!disposed) setUsage(previous => ({ ...previous, [a.id]: value }));
      }));
    } finally { fetching = false; }
  };
  onMount(() => {
    void refreshUsage().catch(swallow("providers.usage"));
    const stop = pollWhileVisible(refreshUsage, 30_000, "providers.usage");
    onCleanup(() => { disposed = true; stop(); });
  });

  const confirmAddSubscription = () => {
    const kind = loginOptions()?.providers.find(x => x.id === addType());
    if (!kind) return;
    setAdding(false);
    setReauth({
      id: "",
      provider_type: kind.id,
      provider_type_name: kind.name,
      name: kind.name,
      enabled: true,
      uses_oauth: true,
      credential_owner: kind.id === "mistral" ? "sandboxed_sh" : "cli_proxy",
      status: { type: "needs_auth" },
    });
  };

  return (
    <div class="page">
      <div class="page-head">
        <h2>Providers</h2>
        <button class="s-btn" disabled={p.loading} onClick={() => { void refreshUsage().catch(swallow("providers.usage")); p.onRefresh(); }}>
          Refresh
        </button>
      </div>
      <p class="s-lead">Configured providers from the connected Core backend. <button class="link-btn" onClick={() => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: "usage-settings" }))}>Usage history</button></p>
      <Show when={p.loadError}>{error => <ErrorNotice title="Could not refresh providers" error={error()}>
        <button class="s-btn" onClick={p.onRefresh}>Try again</button>
      </ErrorNotice>}</Show>
      <ErrorToast error={toggleError()} title="Couldn’t update the provider" onDismiss={() => setToggleError(null)} />

      <section class="s-sec">
        <div class="section-row"><h3>Subscriptions</h3><button class="s-btn sm quiet" disabled={!loginOptions()?.available} onClick={() => { setAddType(loginOptions()?.providers[0]?.id ?? ""); setAdding(true); }}><Ic.PlusIcon size={12}/> Add subscription account</button></div>
        <Show when={loginOptions()?.reason}><p class="s-row-desc">{loginOptions()?.reason}</p></Show>
        <div class="s-card">
          <For each={oauth()}>
            {(a) => <LiveRow a={a} rank={rankIn(oauth, a)} usage={usage()[a.id]} sharedOrgs={sharedOrgs()} health={p.health?.[a.id]} onUsage={value => setUsage(previous => ({ ...previous, [a.id]: value }))} onReconnect={() => setReauth(a)} onRemove={() => { setRemoveError(null); setRemoving(a); }} onToggle={enabled => toggle(a, enabled)} />}
          </For>
          <Show when={oauth().length === 0}>
            <div class="s-row"><div class="s-row-desc">No OAuth providers configured.</div></div>
          </Show>
        </div>
      </section>

      <Show when={modelConnections().length}>
        <section class="s-sec" aria-label="Model connections">
          <h3>Model connections</h3>
          <p class="s-row-desc p-section-description">Model access through connected credentials, separate from subscription accounts.</p>
          <div class="s-card">
            <For each={modelConnections()}>{a => <LiveRow a={a} usage={usage()[a.id]} health={p.health?.[a.id]} onReconnect={() => setReauth(a)} onToggle={enabled => toggle(a, enabled)} />}</For>
          </div>
        </section>
      </Show>

      <CloudProviders />

      <section class="s-sec">
        <div class="section-row"><h3>API keys</h3><button class="s-btn sm quiet" onClick={() => setKeyEditor("new")}><Ic.PlusIcon size={12}/> Add API key</button></div>
        <div class="s-card">
          <For each={keys()}>
            {(a) => <LiveRow a={a} rank={rankIn(keys, a)} usage={usage()[a.id]} health={p.health?.[a.id]} onUsage={value => setUsage(previous => ({ ...previous, [a.id]: value }))} onReconnect={() => setReauth(a)} onEditKey={() => setKeyEditor(a)} onRemove={() => { setRemoveError(null); setRemoving(a); }} onToggle={enabled => toggle(a, enabled)} />}
          </For>
          <Show when={keys().length === 0}>
            <div class="s-row"><div class="s-row-desc">No API key providers configured.</div></div>
          </Show>
        </div>
      </section>

      <Show when={adding()}>
        <Dialog
          title="Add subscription account"
          description="Choose a subscription plan to connect in your browser. You can connect multiple accounts."
          onClose={() => setAdding(false)}
          footer={
            <>
              <DialogButton onClick={() => setAdding(false)}>Cancel</DialogButton>
              <DialogButton variant="primary" disabled={!addType()} onClick={confirmAddSubscription}>
                Continue in browser
              </DialogButton>
            </>
          }
        >
          <div class="p-sub-picker" role="radiogroup" aria-label="Subscription">
            <For each={loginOptions()?.providers ?? []}>
              {(kind, idx) => {
                const selected = () => addType() === kind.id;
                const meta = () => SUBSCRIPTION_META[kind.id];
                return (
                  <button
                    type="button"
                    role="radio"
                    aria-checked={selected()}
                    autofocus={idx() === 0}
                    class={`p-sub-option ${selected() ? "selected" : ""}`}
                    onClick={() => setAddType(kind.id)}
                    onDblClick={() => {
                      setAddType(kind.id);
                      confirmAddSubscription();
                    }}
                    onKeyDown={(e) => {
                      const list = loginOptions()?.providers ?? [];
                      if (!list.length) return;
                      if (e.key === "ArrowDown" || e.key === "ArrowRight") {
                        e.preventDefault();
                        const next = list[(idx() + 1) % list.length];
                        if (next) setAddType(next.id);
                        (e.currentTarget.nextElementSibling as HTMLElement | null)?.focus();
                      } else if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
                        e.preventDefault();
                        const prev = list[(idx() - 1 + list.length) % list.length];
                        if (prev) setAddType(prev.id);
                        (e.currentTarget.previousElementSibling as HTMLElement | null)?.focus();
                      } else if (e.key === "Enter") {
                        e.preventDefault();
                        confirmAddSubscription();
                      }
                    }}
                  >
                    <div class="p-sub-option-logo">
                      <ProviderLogo type={kind.id} name={kind.name} />
                    </div>
                    <div class="p-sub-option-text">
                      <div class="p-sub-option-title">
                        <span>{kind.name}</span>
                        <Show when={meta()?.vendor}>
                          <span class="p-sub-option-vendor">{meta()!.vendor}</span>
                        </Show>
                      </div>
                      <div class="p-sub-option-desc">
                        {meta()?.desc ?? "Browser OAuth sign-in"}
                      </div>
                    </div>
                    <span class="p-sub-option-radio" aria-hidden="true">
                      <Show when={selected()}>
                        <span class="p-sub-option-dot" />
                      </Show>
                    </span>
                  </button>
                );
              }}
            </For>
          </div>
        </Dialog>
      </Show>
      <Show when={removing()}>{account => <ConfirmDialog title={`Remove ${account().name}?`} description={!isKey(account()) ? "This deletes the subscription login and any independent API key saved on this provider. Running work may need another account." : "This deletes the provider and its saved API key. Running work may need another account."} action="Remove provider and credentials" destructive busy={removeBusy()} error={removeError()} onConfirm={() => void remove()} onClose={() => setRemoving(null)}/>}</Show>
      <Show when={keyEditor()} keyed>{target => <ApiKeyDialog provider={target === "new" ? undefined : target} onClose={() => setKeyEditor(null)} onDone={() => { setKeyEditor(null); p.onRefresh(); }}/>}</Show>
      <Show when={reauth()}>
        {(a) => (
          <ReAuthDialog
            provider={a()}
            onClose={() => setReauth(null)}
            onDone={() => {
              const id = a().id;
              setReauth(null);
              setUsage(previous => { const next = { ...previous }; delete next[id]; return next; });
              p.onRefresh();
              if (id) void getProviderUsage(id, true).then(value => {
                if (!disposed) setUsage(previous => ({ ...previous, [id]: value }));
              }).catch(swallow("providers.usage", { provider: id }));
            }}
          />
        )}
      </Show>
    </div>
  );
}

const API_KEY_HINTS: Record<string, { env: string; placeholder: string }> = {
  openai: { env: "OPENAI_API_KEY", placeholder: "sk-proj-…" },
  anthropic: { env: "ANTHROPIC_API_KEY", placeholder: "sk-ant-…" },
  xai: { env: "XAI_API_KEY", placeholder: "xai-…" },
  google: { env: "GEMINI_API_KEY", placeholder: "AIza…" },
  "open-router": { env: "OPENROUTER_API_KEY", placeholder: "sk-or-v1-…" },
  groq: { env: "GROQ_API_KEY", placeholder: "gsk_…" },
  mistral: { env: "MISTRAL_API_KEY", placeholder: "Mistral API key" },
  minimax: { env: "MINIMAX_API_KEY", placeholder: "eyJ…" },
  zai: { env: "ZHIPU_API_KEY", placeholder: "Z.AI API key" },
  custom: { env: "OPENAI_API_KEY", placeholder: "sk-…" },
};

function ApiKeyDialog(p: {provider?: AIProvider; onClose: () => void; onDone: () => void}) {
  const apiKinds = KINDS.filter(k => k.methods.some(m => m.kind === "api"));
  const [type, setType] = createSignal(p.provider?.provider_type ?? "openai");
  const [name, setName] = createSignal(p.provider?.name ?? "");
  const [secret, setSecret] = createSignal("");
  const [url, setUrl] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const version = connectionVersion();
  const selectedKind = createMemo(() => apiKinds.find(k => k.id === type()) ?? apiKinds[0]);
  const defaultName = createMemo(() => p.provider?.name || `${selectedKind()?.name ?? type()} key`);
  const effectiveName = createMemo(() => name().trim() || defaultName());
  const hint = createMemo(() => API_KEY_HINTS[type()]);
  onCleanup(() => setSecret(""));
  const save = async () => {
    if (busy() || !secret().trim() || !effectiveName()) return;
    if (version !== connectionVersion()) { setError("Connection changed. Close and reopen this dialog."); return; }
    setBusy(true); setError("");
    try {
      await api(`/api/ai/providers${p.provider ? `/${encodeURIComponent(p.provider.id)}` : ""}`, {
        method: p.provider ? "PUT" : "POST", headers: {"Content-Type":"application/json"},
        body: JSON.stringify(p.provider ? {name:effectiveName(),api_key:secret().trim()} : {provider_type:type(),name:effectiveName(),api_key:secret().trim(),...(type()==="custom" ? {base_url:url().trim()} : {})}),
      });
      setSecret(""); if (version === connectionVersion()) p.onDone();
    } catch { setError("Couldn’t save the API key. Check the connection and try again."); }
    finally { setBusy(false); }
  };
  return <Dialog title={p.provider ? "Edit API key" : "Add API key"} dirty={!!secret() || name() !== (p.provider?.name ?? "") || !!url()} description={p.provider ? `Update the API key stored for ${p.provider.name}.` : "Choose a provider and enter an API key to store on the connected backend."} busy={busy()} onClose={p.onClose}
    footer={requestClose => <><DialogButton disabled={busy()} onClick={requestClose}>Cancel</DialogButton><DialogButton variant="primary" disabled={busy() || !secret().trim() || !effectiveName() || (!p.provider && type()==="custom" && !/^https?:\/\//.test(url()))} onClick={() => void save()}>{busy() ? "Saving…" : "Save"}</DialogButton></>}>
    <Show when={!p.provider}>
      <div class="field">
        <span>Provider</span>
        <div class="p-key-picker" role="radiogroup" aria-label="Provider">
          <For each={apiKinds}>
            {(k) => {
              const selected = () => type() === k.id;
              return (
                <button
                  type="button"
                  role="radio"
                  aria-checked={selected()}
                  class={`p-key-option ${selected() ? "selected" : ""}`}
                  onClick={() => setType(k.id)}
                >
                  <span class="p-key-option-logo">
                    <ProviderLogo type={k.id} name={k.name} />
                  </span>
                  <span class="p-key-option-name">{k.name}</span>
                </button>
              );
            }}
          </For>
        </div>
        <select class="s-input sr-only" aria-label="Provider select" tabindex={-1} value={type()} onChange={e=>setType(e.currentTarget.value)}>
          <For each={apiKinds}>{k=><option value={k.id}>{k.name}</option>}</For>
        </select>
      </div>
    </Show>
    <div class="p-key-fields">
      <Field label="Account label">
        <input class="s-input" value={name()} onInput={e=>setName(e.currentTarget.value)} placeholder={defaultName()} />
      </Field>
      <Show when={!p.provider && type()==="custom"}>
        <Field label="Base URL">
          <input class="s-input" type="url" value={url()} onInput={e=>setUrl(e.currentTarget.value)} placeholder="https://api.example.com/v1" />
        </Field>
      </Show>
      <div class="field">
        <div class="p-key-field-head">
          <span>{p.provider ? "New API key" : "API key"}</span>
          <Show when={hint()?.env}><code class="p-key-env">{hint()!.env}</code></Show>
        </div>
        <input class="s-input p-key-secret" type="password" autocomplete="new-password" spellcheck={false} placeholder={hint()?.placeholder ?? "Enter API key…"} value={secret()} onInput={e=>setSecret(e.currentTarget.value)} onKeyDown={e => { if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); void save(); } }} />
      </div>
    </div>
    <p class="s-row-desc p-key-foot-note">{p.provider ? "Enter a replacement key. The saved key is never displayed." : "Encrypted at rest on the connected backend and never shown again."}</p>
    <Show when={error()}><p role="alert" class="inline-error">{error()}</p></Show>
  </Dialog>;
}

const LEGACY_OAUTH_TYPES = new Set(["anthropic", "openai", "google"]);
const reconnectable = (a: AIProvider) => (a.provider_type === "mistral" && a.uses_oauth) || cliProxyReconnectable(a) || (a.uses_oauth && a.credential_owner === "sandboxed_sh" && LEGACY_OAUTH_TYPES.has(a.provider_type));

const CLIPROXY_LOGIN_TYPES = new Set(["anthropic", "openai", "xai", "kimi", "antigravity", "muse-code"]);

/** Reconnect via CLIProxyAPI when the backend says so; fall back to the
 * type allowlist for backends that predate the credential_owner field. */
function cliProxyReconnectable(a: AIProvider): boolean {
  if (!a.uses_oauth) return false;
  if (a.credential_owner) return a.credential_owner === "cli_proxy";
  return CLIPROXY_LOGIN_TYPES.has(a.provider_type);
}

function UsageSummary(p: { usage: ProviderUsage }) {
  // Keep the account summary compact; detailed meters live in the expansion.
  // Grouped windows ("Gemini · 5h", "Gemini · Weekly") collapse to one chip
  // per group showing the tighter limit.
  const windows = createMemo(() => usageChips(p.usage));
  // At narrow widths only the most-used chip stays, followed by "+N".
  const top = createMemo(() => windows().reduce((best, w, i, all) => w.used > all[best].used ? i : best, 0));
  return (
    <Show when={windows().length > 0}>
      <div class="p-usage compact">
        <For each={windows()}>
          {(w, i) => (
            <span class={`p-usage-chip ${w.level}${i() === top() ? " top" : ""}`} title={w.detail ?? `${w.label} window: ${Math.round(w.used * 100)}% used`}>
              <span class="p-usage-label">{w.label === "7d" ? "Weekly" : w.label}</span>
              <span class="p-usage-pct">{Math.round(w.used * 100)}%</span>
            </span>
          )}
        </For>
        <Show when={windows().length > 1}><span class="p-usage-more" title={windows().map(w => `${w.label} ${Math.round(w.used * 100)}%`).join(" · ")}>+{windows().length - 1}</span></Show>
      </div>
    </Show>
  );
}

function ReAuthDialog(p: { provider: AIProvider; onClose: () => void; onDone: () => void }) {
  const [session, setSession] = createSignal<{ id: string; url: string; flow?: string; instructions?: string } | null>(null);
  const polledLogin = cliProxyReconnectable(p.provider) || p.provider.provider_type === "mistral";
  let disposed = false;
  let completed = false;
  const [resetting, setResetting] = createSignal(false);
  let pollGeneration = 0;
  const [phase, setPhase] = createSignal<"starting" | "awaiting" | "finishing" | "failed">("starting");
  const [error, setError] = createSignal<string | null>(null);
  const [paste, setPaste] = createSignal("");
  let pollTimer: ReturnType<typeof setInterval> | undefined;

  const stopPolling = () => {
    pollGeneration++;
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = undefined;
  };
  onCleanup(() => { disposed = true; stopPolling(); const s = session(); if (polledLogin && s && !completed) void cancelSubscriptionLogin(s.id).catch(swallow("providers.cancelLogin")); });

  const startPolling = (id: string) => {
    stopPolling();
    const generation = pollGeneration;
    pollTimer = setInterval(() => {
      getSubscriptionLogin(id)
        .then((st) => {
          if (disposed || generation !== pollGeneration) return;
          if (st.status === "completed") {
            stopPolling();
            completed = true;
            p.onDone();
          } else if (st.status === "failed") {
            stopPolling();
            setError(st.message ?? "login failed");
            setPhase("failed");
          }
        })
        .catch((e: Error) => {
          if (disposed || generation !== pollGeneration) return;
          stopPolling();
          setError(e.message);
          setPhase("failed");
        });
    }, 2000);
  };

  const beginLogin = () => {
    setPhase("starting"); setError(null); setPaste("");
    const start = polledLogin
      ? startSubscriptionLogin(p.provider.provider_type, /^[0-9a-f-]{36}$/i.test(p.provider.id) ? p.provider.id : undefined).then(s => ({ id: s.session_id, url: s.auth_url, flow: s.flow, instructions: s.instructions }))
      : startProviderOAuth(p.provider.id).then(s => ({ id: p.provider.id, url: s.url, flow: s.method, instructions: s.instructions }));
    start
      .then((s) => {
        if (disposed) { if (polledLogin) void cancelSubscriptionLogin(s.id).catch(swallow("providers.cancelLogin")); return; }
        setSession(s);
        setPhase("awaiting");
        if (polledLogin) startPolling(s.id);
        void openExternalUrl(s.url).catch(e => setError(String(e)));
      })
      .catch((e: Error) => {
        setError(e.message);
        setPhase("failed");
      });
  };
  onMount(beginLogin);
  const [closing, setClosing] = createSignal(false);
  const closeLogin = async () => {
    if (closing() || phase() === "finishing") return;
    setClosing(true);
    const s = session();
    try { if (polledLogin && s && !completed) await cancelSubscriptionLogin(s.id); completed = true; p.onClose(); }
    catch (e) { setError(`Could not cancel sign-in: ${String(e)}`); }
    finally { setClosing(false); }
  };
  const retryLogin = async () => {
    if (resetting()) return;
    setResetting(true);
    stopPolling();
    const s = session();
    try { if (polledLogin && s && !completed) await cancelSubscriptionLogin(s.id); setSession(null); beginLogin(); }
    catch (e) { setError(`Could not reset sign-in: ${String(e)}`); }
    finally { setResetting(false); }
  };

  const submitPaste = () => {
    const s = session();
    const url = paste().trim();
    if (!s || !url || phase() === "finishing") return;
    setPhase("finishing");
    setError(null);
    const submit = polledLogin ? submitCliProxyLoginCallback(s.id, url)
      : completeProviderOAuth(p.provider.id, url).then(() => ({ status: "completed" as const, message: undefined }));
    submit.then((st) => {
        if (disposed) return;
        if (st.status === "completed") { stopPolling(); completed = true; p.onDone(); return; }
        if (st.status === "failed") {
          setError(st.message ?? "callback rejected");
          setPhase("failed");
        } else {
          setPhase("awaiting");
        }
      })
      .catch((e: Error) => {
        setError(e.message);
        setPhase("failed");
      });
  };

  return (
    <Dialog
      title={`${p.provider.id ? "Reconnect" : "Connect"} ${p.provider.name}`}
      busy={phase() === "finishing" || closing()} dirty={!!paste().trim()}
      onClose={() => void closeLogin()}
      footer={requestClose =>
        <>
          <Show when={phase() === "failed"}><DialogButton disabled={resetting()} onClick={() => void retryLogin()}>Try again</DialogButton></Show>
          <DialogButton disabled={phase() === "finishing" || closing()} onClick={requestClose}>
            {phase() === "failed" ? "Close" : "Cancel"}
          </DialogButton>
          <Show when={(phase() === "awaiting" || phase() === "finishing" || phase() === "failed") && !!session() && session()?.flow !== "device"}>
            <DialogButton variant="primary" disabled={phase() === "finishing" || closing() || !paste().trim()} onClick={submitPaste}>
              {phase() === "finishing" ? "Submitting…" : "Submit callback"}
            </DialogButton>
          </Show>
        </>
      }
    >
      <Show when={phase() === "starting"}>
        <p class="s-lead">Starting the account login…</p>
      </Show>
      <Show when={phase() === "failed"}>
        <p class="s-lead">Could not complete the login.</p>
        <Show when={!session()}><ErrorNotice error={error()!} /></Show>
        <Show when={/^(404|405)\b/.test(error() ?? "")}>
          <p class="s-row-desc">This backend build does not expose the login endpoints yet. Deploy the updated Core backend first.</p>
        </Show>
      </Show>
      <Show when={phase() === "awaiting" || phase() === "finishing" || (phase() === "failed" && !!session())}>
        <p class="s-lead">
          {session()?.instructions ?? (session()?.flow === "device"
            ? "Authorize in the browser window that just opened and enter the code shown — the login completes automatically."
            : "Authorize in the browser window that just opened. The redirect to localhost will fail — copy the full URL from the address bar and paste it here.")}
        </p>
        <div class="field">
          <Show when={p.provider.account_email}><p>Sign in as {p.provider.account_email} to reconnect this account.</p></Show>
          <span>Auth URL</span>
          <div class="p-url">
            <code>{session()?.url}</code>
            <DialogButton onClick={() => session() && void openExternalUrl(session()!.url)}>
              Open
            </DialogButton>
            <DialogButton onClick={() => { const url = session()?.url; if (url) void navigator.clipboard.writeText(url).catch(e => setError(String(e))); }}>Copy link</DialogButton>
          </div>
        </div>
        <Show when={session()?.flow !== "device"}>
          <Field label={polledLogin && session()?.flow !== "code" ? "Redirect URL (http://localhost:…)" : "Authorization code or redirect URL"}>
            <input
              type="text"
              placeholder={polledLogin && session()?.flow !== "code" ? "http://localhost:54545/callback?code=…&state=…" : "Paste the code or full redirect URL"}
              value={paste()}
              onInput={(e) => setPaste(e.currentTarget.value)}
              onKeyDown={(e) => {if (!e.isComposing && e.key === "Enter") {e.preventDefault(); submitPaste();}}}
            />
          </Field>
        </Show>
        <Show when={error()}>
          <ErrorNotice error={error()!} />
        </Show>

      </Show>
    </Dialog>
  );
}

/** ISO timestamp, epoch-seconds string, or relative ("2s") → readable label. */
function fmtReset(v: string): string {
  if (/^\d+$/.test(v)) return fmtResetEpoch(v.length > 12 ? Number(v) / 1000 : Number(v));
  const t = Date.parse(v);
  if (Number.isNaN(t)) return v;
  return fmtResetEpoch(t / 1000);
}

function fmtResetEpoch(sec: number): string {
  const delta = sec * 1000 - Date.now();
  if (delta <= 0) return "now";
  const mins = Math.round(delta / 60000);
  if (mins < 60) return `in ${mins}m`;
  const hours = Math.round(mins / 60);
  if (hours < 48) return `in ${hours}h`;
  return `in ${Math.round(hours / 24)}d`;
}

const DetailBar = ProviderUsageMeter;
const Chip = ProviderUsageChip;

/** "Gemini · 5h" windows share one heading per model group; plain labels stay ungrouped. */
function windowGroups<W extends { label: string }>(windows: W[]) {
  const groups: { name?: string; windows: W[] }[] = [];
  for (const w of windows) {
    const [name, window] = w.label.includes(" · ") ? w.label.split(" · ", 2) : [undefined, w.label];
    const last = groups[groups.length - 1];
    const item = { ...w, label: window };
    if (last && last.name === name) last.windows.push(item);
    else groups.push({ name, windows: [item] });
  }
  return groups;
}

function UsageDetail(p: { usage: ProviderUsage; headerEmail?: string; planInHeader?: boolean; sharedOrg?: boolean }) {
  const u = () => p.usage;
  const type = () => u().provider_type;
  return (
    <div class="p-detail">
      <Show when={u().status === "needs_reauth"}><p class="s-row-desc inline-error">Reconnect this account to check its quota and use it for new requests.</p></Show>
      <div class="p-detail-meta">
        <Show when={u().account_email && u().account_email !== p.headerEmail}><span>{u().account_email}</span></Show>
        <Show when={u().account_name}><span>{u().account_name}</span></Show>
        <Show when={u().organization}><span>{u().organization}</span></Show>
        <Show when={p.sharedOrg}><span data-testid="shared-org-limit">Shared organization limit</span></Show>
        <Show when={usageLimitStatus(u())}>
          {(s) => <span class={s().tone === "error" ? "c-red" : "c-amber"} data-testid="usage-limit-status">{s().label}</span>}
        </Show>
      </div>

      <Show when={type() === "anthropic" && (u().unified_5h_utilization != null || u().unified_7d_utilization != null)}>
        <div class="provider-usage-row">
          <Show when={u().unified_5h_utilization != null}><Chip label="5h" usedPct={(u().unified_5h_utilization ?? 0) * 100} reset={u().unified_5h_reset ? `reset ${fmtReset(u().unified_5h_reset!)}` : undefined} /></Show>
          <Show when={u().unified_7d_utilization != null}><Chip label="Weekly" usedPct={(u().unified_7d_utilization ?? 0) * 100} reset={u().unified_7d_reset ? `reset ${fmtReset(u().unified_7d_reset!)}` : undefined} /></Show>
        </div>
      </Show>

      <Show when={type() === "openai" && u().codex_primary_used_percent != null && u().codex_primary_window_minutes !== 0}>
        <Show when={u().codex_plan_type && !p.planInHeader}>
          <div class="p-detail-meta"><span>plan: {u().codex_plan_type}</span></div>
        </Show>
        <div class="provider-usage-row">
          <Chip label={codexWindowLabel(u().codex_primary_window_minutes, "Primary window")} usedPct={u().codex_primary_used_percent ?? 0} reset={u().codex_primary_reset_at ? `reset ${fmtResetEpoch(u().codex_primary_reset_at!)}` : undefined} />
          <Show when={u().codex_secondary_used_percent != null && u().codex_secondary_window_minutes !== 0}>
            <Chip label={codexWindowLabel(u().codex_secondary_window_minutes, "Secondary window")} usedPct={u().codex_secondary_used_percent ?? 0} reset={u().codex_secondary_reset_at ? `reset ${fmtResetEpoch(u().codex_secondary_reset_at!)}` : undefined} />
          </Show>
        </div>
      </Show>
      <Show when={type() === "openai" && u().requests_limit != null}>
        <DetailBar label="Requests" usedPct={100 - ((u().requests_remaining ?? 0) / (u().requests_limit ?? 1)) * 100} reset={u().requests_reset ? `reset ${fmtReset(u().requests_reset!)}` : undefined} />
      </Show>

      <Show when={type() === "kimi"}>
        <div class="provider-usage-row"><For each={kimiWindows(u())}>{window =>
          <Chip label={window.label} usedPct={window.used_percent ?? 0} reset={window.reset_at ? `reset ${fmtResetEpoch(window.reset_at)}` : undefined} />
        }</For></div>
      </Show>

      <Show when={type() === "xai"}>
        <Show when={u().xai_credit_used_percent != null}>
          <DetailBar label={u().xai_credit_label || "Credits"} usedPct={u().xai_credit_used_percent ?? 0} reset={u().xai_credit_reset ? `reset ${fmtResetEpoch(u().xai_credit_reset!)}` : undefined} />
        </Show>
        <Show when={u().xai_prepaid_usd != null}><div class="p-detail-meta"><span>Prepaid balance: ${u().xai_prepaid_usd?.toFixed(2)}</span></div></Show>
        <Show when={u().xai_on_demand_used != null}><div class="p-detail-meta"><span>On-demand credits: {u().xai_on_demand_used}<Show when={u().xai_on_demand_cap != null}> / {u().xai_on_demand_cap}</Show></span></div></Show>
      </Show>

      <Show when={type() === "minimax" && !codingPlanWindows(u()).length && u().model_usage && (u().model_usage?.length ?? 0) > 0}>
        <For each={u().model_usage}>
          {(m) => (
            <div class="p-model">
              <div class="p-model-name">{m.model}</div>
              <DetailBar label="5h" usedPct={100 - m.interval_remaining_percent} reset={m.interval_reset > 0 ? `reset ${fmtResetEpoch(m.interval_reset)}` : undefined} />
              <DetailBar label="Weekly" usedPct={100 - m.weekly_remaining_percent} reset={m.weekly_reset > 0 ? `reset ${fmtResetEpoch(m.weekly_reset)}` : undefined} />
            </div>
          )}
        </For>
      </Show>

      <Show when={codingPlanWindows(u()).length > 0}>
        <Show when={u().zai_plan && !p.planInHeader}>
          <div class="p-detail-meta"><span>plan: {u().zai_plan}</span></div>
        </Show>
        {/* One row per pool with every window the API returns for it. */}
        <For each={windowGroups(codingPlanWindows(u()))}>{g =>
          <div class="provider-usage-row" classList={{ "provider-usage-group": !!g.name }}>
            <Show when={g.name}><span class="provider-usage-group-title">{g.name}</span></Show>
            <For each={g.windows}>{w => <Chip label={w.label} usedPct={w.used * 100} reset={w.reset ? `reset ${fmtResetEpoch(w.reset)}` : undefined} />}</For>
          </div>}</For>
        <Show when={u().zai_mcp_percentage != null}>
          <DetailBar label="MCP" usedPct={u().zai_mcp_percentage ?? 0} reset={u().zai_mcp_reset ? `reset ${fmtResetEpoch(u().zai_mcp_reset!)}` : undefined} />
        </Show>
      </Show>

      <Show when={u().usage_note}><p class="s-row-desc">{u().usage_note}</p></Show>
      <Show when={u().error}>
        <p class="s-row-desc inline-error">{u().error?.replace(/\s*—\s*/g, ". ")}</p>
      </Show>
    </div>
  );
}

/** Mistral exposes the Vibe plan's monthly counter only to a signed-in
 * console session. Orb captures that session once, in its own sign-in
 * window, and hands it to Core, which then reads the counter for every client. */
function MistralUsageConnect(p: { a: AIProvider; usage?: ProviderUsage; onUsage?: (usage: ProviderUsage) => void }) {
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const state = () => p.usage?.mistral_usage_session;
  const connect = async () => {
    const invoke = nativeInvoke();
    if (!invoke) { void openExternalUrl("https://admin.mistral.ai/subscription"); return; }
    setBusy(true); setError(null);
    try {
      const cookie = await invoke("mistral_usage_sign_in") as string | null;
      if (!cookie) return;
      p.onUsage?.(await setMistralUsageSession(p.a.id, cookie));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally { setBusy(false); }
  };
  const disconnect = async () => {
    setBusy(true); setError(null);
    try { p.onUsage?.(await clearMistralUsageSession(p.a.id)); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  return <div class="p-detail">
    <Show when={state() !== "connected"}>
      <p class="s-row-desc">{state() === "expired"
        ? "The Mistral console session expired. Sign in again to keep the monthly usage up to date."
        : "Mistral shows the monthly Vibe allowance only in its console. Sign in once with the same account to show it here, on every device."}</p>
    </Show>
    <Show when={error()}><p role="alert" class="inline-error">{error()}</p></Show>
    <div class="p-acc-actions">
      <Show when={state() !== "connected"} fallback={<button class="s-btn quiet" disabled={busy()} onClick={() => void disconnect()}>Disconnect usage</button>}>
        <button class="s-btn" disabled={busy()} onClick={() => void connect()}>{busy() ? "Waiting for sign-in…" : state() === "expired" ? "Sign in again" : "Show monthly usage"}</button>
        <button class="s-btn quiet" onClick={() => void openExternalUrl("https://admin.mistral.ai/subscription")}>Open console ↗</button>
      </Show>
    </div>
  </div>;
}

/** Email that truncates in the middle of the local part, keeping "@domain" readable. */
function EmailLabel(p: { email: string }) {
  const at = () => p.email.lastIndexOf("@");
  return (
    <span class="p-account-email" title={p.email}>
      <span class="sr-only">{p.email}</span>
      <span class="p-email-local" aria-hidden="true">{at() > 0 ? p.email.slice(0, at()) : p.email}</span>
      <Show when={at() > 0}><span class="p-email-domain" aria-hidden="true">{p.email.slice(at())}</span></Show>
    </span>
  );
}

type AccountRank = { index: number; count: number; move: (to: number) => void };

const ORDINALS = ["1st", "2nd", "3rd"];
const ordinal = (n: number) => ORDINALS[n - 1] ?? `${n}th`;

/** The account's place among its provider's accounts, with up/down buttons
 * and a drag handle (drop on another account row). Lives in the row body so
 * the header keeps its columns. */
function RankControls(p: { rank: AccountRank; name: string; title: string }) {
  const r = () => p.rank;
  return (
    <div class="p-rank-row">
      <span class="s-row-desc" title={`Tried ${ordinal(r().index + 1)} of ${r().count} ${p.title} accounts`}>Tried {ordinal(r().index + 1)} of {r().count}</span>
      <div class="p-rank-actions">
      <span class="p-rank-grip" draggable="true" title="Drag onto another account to change the order" aria-hidden="true"
        onDragStart={e => { e.dataTransfer?.setData(RANK_DRAG_TYPE, String(r().index)); if (e.dataTransfer) e.dataTransfer.effectAllowed = "move"; }}>⠿</span>
      <button type="button" class="icon-btn" aria-label={`Try ${p.name} earlier`} disabled={r().index === 0} onClick={() => r().move(r().index - 1)}>
        <Ic.ArrowUpIcon size={13} />
      </button>
      <button type="button" class="icon-btn" aria-label={`Try ${p.name} later`} disabled={r().index === r().count - 1} onClick={() => r().move(r().index + 1)}>
        <span class="routing-down"><Ic.ArrowUpIcon size={13} /></span>
      </button>
      </div>
    </div>
  );
}

const RANK_DRAG_TYPE = "application/x-orb-account-rank";

function LiveRow(p: { a: AIProvider; rank?: AccountRank; usage?: ProviderUsage; sharedOrgs?: Set<string>; health?: AccountHealthSnapshot; onUsage?: (usage: ProviderUsage) => void; onReconnect: () => void; onEditKey?: () => void; onRemove?: () => void; onToggle: (enabled: boolean) => void }) {
  const a = p.a;
  const status = () => effectiveProviderStatus(a, p.usage, p.health);
  const quota = () => p.usage ? quotaStatus(usageWindows(p.usage)) : null;
  // Quota severity uses the shared level colors (warning 80-99%, danger exhausted).
  const stClass = () => status() === "connected" ? "connected" : ["quota_exhausted", "pool_exhausted", "out_of_credit"].includes(status()) ? "exhausted" : status() === "quota_warning" ? "warning" : ["needs_reauth", "needs_verification", "error", "auth_failed"].includes(status()) ? "needs_reauth" : "not_configured";
  const stLabel = () => ({ connected: "Connected", disabled: "Disabled", needs_reauth: "Reconnect", needs_verification: "Verification required", quota_exhausted: quota()?.level === "exhausted" ? quota()!.label : "Quota exhausted", pool_exhausted: quota()?.label || "Quota exhausted", quota_warning: quota()?.label || "Connected", out_of_credit: "Out of credit", auth_failed: "Auth failed", needs_auth: "Needs auth", error: "Error" }[status()] ?? "Unknown");
  const canReconnect = () => reconnectable(a);
  const mistralSubscription = () => a.provider_type === "mistral" && a.uses_oauth;
  const expandable = () => !!p.rank || status() === "out_of_credit" || status() === "auth_failed" || a.provider_type === "antigravity" || !!p.onEditKey || canReconnect() || hasProviderUsageDetails(p.usage) || !!a.status.reason || !!a.status.message;
  const [open, setOpen] = createSignal(a.provider_type === "antigravity");
  const [menu, setMenu] = createSignal<{x:number;y:number} | null>(null);
  const [dropping, setDropping] = createSignal(false);
  const needsAuth = () => ["needs_reauth", "needs_auth"].includes(status());
  const [checking, setChecking] = createSignal(false);
  const [checkError, setCheckError] = createSignal<string | null>(null);
  const verify = () => void openExternalUrl(verificationUrl(p.usage, email())).catch(e => setCheckError(String(e)));
  const checkAgain = async () => {
    setChecking(true); setCheckError(null);
    try { p.onUsage?.(await recheckAntigravity(a.id)); }
    catch (e) { setCheckError(e instanceof Error ? e.message : String(e)); }
    finally { setChecking(false); }
  };
  const email = () => a.account_email || p.usage?.account_email || a.name.match(/\(([^()]+@[^()]+)\)/)?.[1];
  const plan = () => a.provider_type === "antigravity" ? p.usage?.antigravity_plan || "Subscription account"
    : a.provider_type === "google" ? (a.has_api_key && !a.has_oauth ? "API key" : "Model routing")
    : p.usage?.codex_plan_type || p.usage?.xai_plan || p.usage?.kimi_plan || p.usage?.zai_plan ? `${p.usage!.codex_plan_type || p.usage!.xai_plan || p.usage!.kimi_plan || p.usage!.zai_plan} plan`
    : p.usage?.muse_plan || p.usage?.mistral_plan || undefined;
  const title = () => a.provider_type === "antigravity" ? "Google Antigravity" : a.provider_type === "google" ? (a.has_api_key && !a.has_oauth ? "Gemini API" : "Gemini model access") : email() ? a.name.replace(`(${email()})`, "").trim() : a.name;
  return (
    <div class="p-acc-wrap" classList={{ "p-drop": dropping() }}
      onDragOver={e => { if (p.rank && e.dataTransfer?.types.includes(RANK_DRAG_TYPE)) { e.preventDefault(); setDropping(true); } }}
      onDragLeave={() => setDropping(false)}
      onDrop={e => { setDropping(false); const from = e.dataTransfer?.getData(RANK_DRAG_TYPE); if (p.rank && from) { e.preventDefault(); if (Number(from) !== p.rank.index) p.rank.move(p.rank.index); } }}>
      <div class="p-account-header">
      <Dynamic component={expandable() ? "button" : "div"} class={`s-row p-acc ${expandable() ? "p-acc-btn" : ""}`} aria-expanded={expandable() ? open() : undefined} onClick={expandable() ? () => setOpen(!open()) : undefined}>
        <ProviderLogo type={a.provider_type} name={a.name} />
        <div class="s-row-text">
          <div class="s-row-title">
            <span class="p-account-name">{title()}</span>
            <Show when={email()}>{e => <EmailLabel email={e()} />}</Show>
            <Show when={p.rank}>{r => <span class="p-rank" title={`Tried ${ordinal(r().index + 1)} of ${r().count} ${title()} accounts`}>{ordinal(r().index + 1)}</span>}</Show>
          </div>
          <div class="s-row-desc">
            <span class={`p-st ${stClass()}`} title={stLabel()}>{stLabel()}</span>
            <Show when={plan()}><span class="p-plan" title={plan()}><span class="p-dot">·</span>{plan()}</span></Show>

          </div>
        </div>
        <Show when={!open() && p.usage && !p.usage!.error}>
          <UsageSummary usage={p.usage!} />
        </Show>
        <Show when={expandable()}><span class={`chev p-acc-chev ${open() ? "open" : ""}`}>›</span></Show>
      </Dynamic>
      <Show when={mistralSubscription() && !open() && p.usage?.mistral_usage_session !== "connected"}>
        <button class="s-btn quiet" aria-label="View Mistral monthly usage" onClick={() => void openExternalUrl("https://admin.mistral.ai/subscription")}>Monthly usage ↗</button>
      </Show>
      <Show when={true}><button class="icon-btn p-account-menu" aria-label={`Actions for ${a.name}`} aria-haspopup="menu" aria-expanded={!!menu()} onClick={e => { const r=e.currentTarget.getBoundingClientRect(); setMenu({x:r.right-170,y:r.bottom+4}); }}><span aria-hidden="true">···</span></button></Show>
      </div>
      <Show when={menu()}>{position => <PopupMenu {...position()} onClose={()=>setMenu(null)} items={[
        ...(status() === "needs_verification" ? [{kind:"item" as const,label:"Verify account",onClick:verify},{kind:"item" as const,label:"Check again",onClick:() => void checkAgain()}] : p.onEditKey ? [{kind:"item" as const,label:"Edit API key",icon:Ic.PencilIcon,onClick:p.onEditKey}] : canReconnect() ? [{kind:"item" as const,label:needsAuth()?"Reconnect":"Re-authenticate",onClick:p.onReconnect}] : []),
        ...(p.rank && p.rank.index > 0 ? [{kind:"item" as const,label:"Try earlier",onClick:()=>p.rank!.move(p.rank!.index - 1)}] : []),
        ...(p.rank && p.rank.index < p.rank.count - 1 ? [{kind:"item" as const,label:"Try later",onClick:()=>p.rank!.move(p.rank!.index + 1)}] : []),
        {kind:"item" as const,label:a.enabled===false?"Enable":"Disable",onClick:()=>p.onToggle(a.enabled===false)},
        ...(p.onRemove ? [{kind:"item" as const,label:"Remove provider…",onClick:p.onRemove}] : []),
      ]} />}</Show>
      <Show when={open() && expandable()}>
        <div class="p-acc-body">
          <Show when={a.provider_type === "antigravity"} fallback={<Show when={p.rank}>{r => <RankControls rank={r()} name={email() ?? a.name} title={title()} />}</Show>}>
            <AntigravityProvider lead={p.rank ? <RankControls rank={p.rank} name={email() ?? a.name} title={title()} /> : undefined} />
          </Show>
          <Show when={mistralSubscription()}>
            <MistralUsageConnect a={a} usage={p.usage} onUsage={p.onUsage} />
          </Show>
          <Show when={hasProviderUsageDetails(p.usage)}>
            <UsageDetail usage={p.usage!} sharedOrg={!!p.usage?.organization_id && !!p.sharedOrgs?.has(p.usage.organization_id)} headerEmail={a.account_email ?? (p.usage?.account_email && a.name.includes(p.usage.account_email) ? p.usage.account_email : undefined)} planInHeader />
          </Show>
          <Show when={status() === "needs_verification"}>
            <p class="s-row-desc inline-error">Google requires you to verify this account.</p>
            <div class="p-acc-actions">
              <button class="s-btn" onClick={verify}>Verify account ↗</button>
              <button class="s-btn quiet" disabled={checking()} onClick={() => void checkAgain()}>{checking() ? "Checking…" : "Check again"}</button>
            </div>
            <Show when={checkError()}><p class="s-row-desc inline-error">{checkError()}</p></Show>
          </Show>
          <Show when={status() === "out_of_credit" || status() === "auth_failed"}>
            <p class="s-row-desc inline-error">{status() === "out_of_credit"
              ? "The router got 402 / out of credit from this account and skips it."
              : "The router got 401 / 403 from this account and skips it."}{p.health?.next_probe_at ? ` Next probe ${new Date(p.health.next_probe_at).toLocaleTimeString()}.` : ""}</p>
          </Show>
          <Show when={!p.usage?.error && (a.status.reason || a.status.message)}><p class="s-row-desc inline-error">{(a.status.reason || a.status.message)?.replace(/\s*—\s*/g, ". ")}</p></Show>
          <Show when={p.onEditKey}><div class="p-acc-actions"><button class="s-btn" onClick={p.onEditKey}>Edit API key</button></div></Show>
          <Show when={canReconnect() && needsAuth()}>
            <div class="p-acc-actions">
              <button class="s-btn" onClick={p.onReconnect}>
                Reconnect
              </button>
            </div>
          </Show>
        </div>
      </Show>
    </div>
  );
}

