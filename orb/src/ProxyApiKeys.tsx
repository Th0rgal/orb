import { For, Show, createEffect, createMemo, createSignal, onCleanup, untrack } from "solid-js";
import { connectionVersion, getApiUrl, isConnected } from "./api";
import { ConfirmDialog } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { CopyIcon, PlusIcon } from "./icons";
import * as Keys from "./proxyKeysApi";

const message = (error: unknown) => error instanceof Error ? error.message : String(error);
const date = (value: string) => new Date(value).toLocaleString();

export function ProxyApiKeys() {
  const [keys, setKeys] = createSignal<Keys.ProxyApiKeySummary[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [listError, setListError] = createSignal("");
  const [error, setError] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [panel, setPanel] = createSignal<"create" | "cleanup" | null>(null);
  const [name, setName] = createSignal("");
  const [created, setCreated] = createSignal<Keys.ProxyApiKeyCreated>();
  const [days, setDays] = createSignal(7);
  const [candidates, setCandidates] = createSignal<Keys.ProxyApiKeySummary[]>([]);
  const [selected, setSelected] = createSignal(new Set<string>());
  const [previewLoading, setPreviewLoading] = createSignal(false);
  const [previewReady, setPreviewReady] = createSignal(false);
  const [revokeTarget, setRevokeTarget] = createSignal<Keys.ProxyApiKeySummary[]>([]);
  const [copied, setCopied] = createSignal("");
  const endpoint = createMemo(() => { connectionVersion(); return `${getApiUrl().replace(/\/+$/, "")}/v1`; });
  const validDays = () => Number.isInteger(days()) && days() >= 1 && days() <= 4294967295;
  let generation = 0;
  let listRequest = 0;
  let previewRequest = 0;
  let copyTimer: ReturnType<typeof setTimeout> | undefined;

  async function refresh() {
    const epoch = generation;
    const request = ++listRequest;
    setLoading(true);
    setListError("");
    try {
      const result = await Keys.listProxyApiKeys();
      if (epoch === generation && request === listRequest) setKeys(result);
    } catch (e) {
      if (epoch === generation && request === listRequest) setListError(message(e));
    } finally {
      if (epoch === generation && request === listRequest) setLoading(false);
    }
  }

  function closePanel() {
    previewRequest++;
    setPanel(null);
    setName("");
    setCreated(undefined);
    setCandidates([]);
    setSelected(new Set<string>());
    setPreviewReady(false);
    setPreviewLoading(false);
    setCopied("");
    setError("");
    clearTimeout(copyTimer);
  }

  createEffect(() => {
    connectionVersion();
    const connected = isConnected();
    generation++;
    listRequest++;
    closePanel();
    setRevokeTarget([]);
    setKeys([]);
    setListError("");
    setLoading(false);
    setBusy(false);
    if (connected) untrack(() => void refresh());
  });
  onCleanup(() => { generation++; clearTimeout(copyTimer); });

  async function copy(value: string, label: string) {
    const epoch = generation;
    try {
      await navigator.clipboard.writeText(value);
      if (epoch !== generation) return;
      setCopied(label);
      clearTimeout(copyTimer);
      copyTimer = setTimeout(() => setCopied(""), 1800);
    } catch {
      if (epoch === generation) setError("Could not copy to clipboard.");
    }
  }

  async function create() {
    if (busy() || created()) return;
    const value = name().trim();
    if (!value) { setError("Key name is required."); return; }
    const epoch = generation;
    setBusy(true);
    setError("");
    try {
      const result = await Keys.createProxyApiKey(value);
      if (epoch !== generation) return;
      setCreated(result);
      setName("");
      await refresh();
    } catch (e) {
      if (epoch === generation) setError(message(e));
    } finally {
      if (epoch === generation) setBusy(false);
    }
  }

  async function preview() {
    const epoch = generation;
    const request = ++previewRequest;
    setCandidates([]);
    setSelected(new Set<string>());
    setPreviewReady(false);
    setError("");
    if (!validDays()) { setPreviewLoading(false); return; }
    setPreviewLoading(true);
    try {
      const result = await Keys.previewProxyApiKeyCleanup(days());
      if (epoch !== generation || request !== previewRequest) return;
      setCandidates(result.keys);
      setSelected(new Set(result.keys.map(key => key.id)));
      setPreviewReady(true);
    } catch (e) {
      if (epoch === generation && request === previewRequest) setError(message(e));
    } finally {
      if (epoch === generation && request === previewRequest) setPreviewLoading(false);
    }
  }

  function open(next: "create" | "cleanup") {
    closePanel();
    setPanel(next);
    if (next === "cleanup") void preview();
  }

  async function revoke() {
    if (busy() || !revokeTarget().length) return;
    const epoch = generation;
    const targets = revokeTarget();
    setBusy(true);
    setError("");
    // Delete the reviewed selection, never re-run the age criterion on commit.
    const results = await Promise.allSettled(targets.map(key => Keys.deleteProxyApiKey(key.id)));
    if (epoch !== generation) return;
    const removed = new Set(targets.filter((_, i) => results[i].status === "fulfilled").map(key => key.id));
    const failures = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    setKeys(current => current.filter(key => !removed.has(key.id)));
    setCandidates(current => current.filter(key => !removed.has(key.id)));
    setSelected(current => new Set([...current].filter(id => !removed.has(id))));
    setRevokeTarget([]);
    if (failures.length) setError(`Revoked ${removed.size} of ${targets.length} keys. ${failures.length} failed: ${message(failures[0].reason)}`);
    else if (panel() === "cleanup") closePanel();
    await refresh();
    if (epoch === generation) setBusy(false);
  }

  return <section class="s-sec proxy-keys" aria-labelledby="proxy-keys-title">
    <div class="routing-heading">
      <h3 id="proxy-keys-title">Proxy API Keys</h3>
      <div class="routing-actions">
        <button class="s-btn" disabled={busy() || loading()} onClick={() => void refresh()}>{loading() ? "Refreshing…" : "Refresh"}</button>
        <button class="s-btn" disabled={busy()} onClick={() => open("cleanup")}>Clean Up</button>
        <button class="s-btn" disabled={busy()} onClick={() => open("create")}><PlusIcon size={12} /> New Key</button>
      </div>
    </div>
    <p class="routing-muted">Keys for external tools such as Cursor and Windsurf.</p>
    <div class="s-card proxy-key-endpoint">
      <div><span>Proxy endpoint</span><code>{endpoint()}</code></div>
      <button class="s-btn" aria-label="Copy proxy endpoint" onClick={() => void copy(endpoint(), "endpoint")}>
        <Show when={copied() === "endpoint"} fallback={<CopyIcon size={13} />}><span role="status">Copied</span></Show>
      </button>
    </div>
    <Show when={panel() === "create"}>
      <form class="s-card proxy-key-panel" onSubmit={e => { e.preventDefault(); void create(); }}>
        <Show when={!created()} fallback={<>
          <p class="routing-muted">Copy this key now. It won’t be shown again.</p>
          <div class="proxy-key-secret"><code>{created()?.key}</code><button type="button" class="s-btn" onClick={() => void copy(created()!.key, "key")}>
            {copied() === "key" ? <span role="status">Copied</span> : "Copy key"}
          </button></div>
        </>}>
          <label>Key name<input class="s-input" autofocus placeholder="Cursor, CI pipeline…" value={name()} disabled={busy()} onInput={e => setName(e.currentTarget.value)} /></label>
        </Show>
        <div class="routing-actions proxy-key-footer">
          <button class="s-btn" type="button" disabled={busy()} onClick={closePanel}>{created() ? "Done" : "Cancel"}</button>
          <Show when={!created()}><button class="s-btn primary" type="submit" disabled={busy() || !name().trim()}>{busy() ? "Creating…" : "Create"}</button></Show>
        </div>
      </form>
    </Show>
    <Show when={panel() === "cleanup"}>
      <div class="s-card proxy-key-panel">
        <label class="proxy-key-days">Revoke keys with no activity for
          <input aria-label="Inactive days" class="s-input" type="number" min="1" step="1" max="4294967295" value={days()} disabled={busy()} onInput={e => { setDays(e.currentTarget.valueAsNumber); void preview(); }} /> days
        </label>
        <p class="routing-muted">For keys without recorded usage, the creation date is used.</p>
        <Show when={!validDays()}><p class="routing-muted">Enter a whole number of days, at least 1.</p></Show>
        <Show when={previewLoading()}><p class="routing-muted" role="status">Checking inactive keys…</p></Show>
        <Show when={previewReady() && !candidates().length}><p class="routing-muted">No unused keys older than {days()} days.</p></Show>
        <For each={candidates()}>{key => <label class="proxy-key-candidate">
          <input type="checkbox" checked={selected().has(key.id)} disabled={busy() || previewLoading()} onChange={e => {
            const checked = e.currentTarget.checked;
            setSelected(current => { const next = new Set(current); if (checked) next.add(key.id); else next.delete(key.id); return next; });
          }} />
          <span class="proxy-key-info"><strong>{key.name}</strong><span>{key.last_used_at ? `Last used ${date(key.last_used_at)}` : `Never used · created ${date(key.created_at)}`}</span></span>
          <code>{key.key_prefix}…</code>
        </label>}</For>
        <div class="routing-actions proxy-key-footer">
          <button class="s-btn" disabled={busy()} onClick={closePanel}>Cancel</button>
          <button class="s-btn" disabled={busy() || previewLoading() || !previewReady() || !selected().size} onClick={() => setRevokeTarget(candidates().filter(key => selected().has(key.id)))}>
            Revoke {selected().size} {selected().size === 1 ? "key" : "keys"}
          </button>
        </div>
      </div>
    </Show>
    <Show when={error()}><ErrorNotice error={error()} /></Show>
    <Show when={listError()}><ErrorNotice error={`Could not load proxy API keys: ${listError()}`} /></Show>
    <Show when={!loading() && !listError() && !keys().length}><p class="routing-muted">No API keys yet. Create one to connect external tools.</p></Show>
    <div class="s-card proxy-key-list" aria-busy={loading()}>
      <For each={keys()}>{key => <div class="proxy-key-row">
        <div class="proxy-key-info"><strong>{key.name}</strong><span title={`Created ${date(key.created_at)}`}>
          {key.last_used_at ? `Last used ${date(key.last_used_at)}` : `Never used · created ${date(key.created_at)}`}
        </span></div>
        <code>{key.key_prefix}…</code>
        <button class="s-btn" disabled={busy()} aria-label={`Revoke ${key.name}`} onClick={() => { setError(""); setRevokeTarget([key]); }}>Revoke</button>
      </div>}</For>
    </div>
    <Show when={revokeTarget().length}>
      <ConfirmDialog title={revokeTarget().length === 1 ? "Revoke API key?" : "Revoke API keys?"}
        description={`Revoke ${revokeTarget().map(key => key.name).join(", ")}? External tools using these keys will stop working.`}
        action={revokeTarget().length === 1 ? "Revoke key" : `Revoke ${revokeTarget().length} keys`}
        destructive busy={busy()} onConfirm={() => void revoke()} onClose={() => setRevokeTarget([])} />
    </Show>
  </section>;
}
