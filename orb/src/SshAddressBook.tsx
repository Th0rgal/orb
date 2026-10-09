import { For, Show, createEffect, createSignal, onCleanup } from "solid-js";
import { ApiError, connectionVersion, getApiUrl } from "./api";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { deleteSshHost, isSshHost, legacyAddresses, listSshHosts, sameAddress, saveSshHost, validAddress, type SshAddress, type SshHost } from "./sshHosts";

export function SshAddressBook(p: { onUnsupported: (value: boolean) => void }) {
  const [hosts, setHosts] = createSignal<SshHost[]>([]);
  const [ready, setReady] = createSignal(false);
  const [error, setError] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [draft, setDraft] = createSignal<SshAddress>();
  const [editing, setEditing] = createSignal<SshHost>();
  const [confirmDelete, setConfirmDelete] = createSignal(false);
  const [original, setOriginal] = createSignal("");
  const [importing, setImporting] = createSignal(false);
  const [legacy, setLegacy] = createSignal<SshAddress[]>([]);
  let disposed = false;
  let controller: AbortController | undefined;
  const cacheKey = () => `orb.sshHosts:${getApiUrl()}`;
  const importKey = () => `orb.sshHostsImported:${getApiUrl()}`;
  async function refresh() {
    const version = connectionVersion();
    controller?.abort(); controller = new AbortController();
    try {
      const rows = await listSshHosts(controller.signal);
      if (disposed || version !== connectionVersion()) return;
      // A conflict refresh updates untouched fields, but never replaces the user's edits.
      const previous = editing(), current = draft();
      const latest = !ready() && previous && rows.find(row => row.id === previous.id);
      if (latest && current) {
        const base = JSON.parse(original()) as SshAddress;
        const merged = {...latest};
        for (const key of ["name", "host", "user", "port", "note"] as const) {
          if (current[key] !== base[key]) Object.assign(merged, {[key]: current[key]});
        }
        setDraft(merged); setEditing(latest); setOriginal(JSON.stringify(latest));
      }
      setHosts(rows); setReady(true); setError(""); p.onUnsupported(false);
      try { localStorage.setItem(cacheKey(), JSON.stringify(rows)); } catch { /* optional cache */ }
    } catch (e) {
      if (disposed || version !== connectionVersion() || (e instanceof DOMException && e.name === "AbortError")) return;
      setReady(false);
      if (e instanceof ApiError && e.status === 404) { p.onUnsupported(true); setError("This backend does not support the shared address book yet. The local desktop list is shown below."); }
      else setError("Could not refresh SSH addresses. Showing the last snapshot; editing is unavailable. " + String(e));
    }
  }
  createEffect(() => {
    connectionVersion(); controller?.abort(); setReady(false); setDraft(undefined); setImporting(false); setBusy(false);
    setHosts([]); setLegacy(localStorage.getItem(importKey()) ? [] : legacyAddresses());
    try { const cached = JSON.parse(localStorage.getItem(cacheKey()) ?? "[]"); if (Array.isArray(cached) && cached.every(isSshHost)) setHosts(cached); } catch { /* empty cache */ }
    void refresh();
  });
  const foreground = () => { if (!document.hidden && !busy()) void refresh(); };
  document.addEventListener("visibilitychange", foreground);
  window.addEventListener("focus", foreground);
  onCleanup(() => { disposed = true; controller?.abort(); document.removeEventListener("visibilitychange", foreground); window.removeEventListener("focus", foreground); });
  async function mutate(action: () => Promise<unknown>) {
    if (busy() || !ready()) return;
    const version = connectionVersion(); setBusy(true); setError("");
    try {
      await action();
      if (disposed || version !== connectionVersion()) return;
      setDraft(undefined); setImporting(false); await refresh();
    } catch (e) { if (!disposed && version === connectionVersion()) { setError(String(e)); if (e instanceof ApiError && [404,409].includes(e.status)) { setReady(false); } } }
    finally { if (!disposed && version === connectionVersion()) setBusy(false); }
  }
  const start = (host?: SshHost) => {setConfirmDelete(false); setEditing(host); const value = host ? {...host} : {name:"",host:"",user:"ubuntu",port:22,note:""}; setDraft(value); setOriginal(JSON.stringify(value));};
  const dirty = () => JSON.stringify(draft()) !== original();
  const patch = (value: Partial<SshAddress>) => setDraft(d => d ? {...d,...value} : d);
  const importRows = async () => {
    const version = connectionVersion();
    for (const address of legacy()) {
      if (disposed || version !== connectionVersion()) throw new Error("Backend changed; import stopped.");
      if (!hosts().some(h => sameAddress(h,address))) await saveSshHost(address);
    }
    if (disposed || version !== connectionVersion()) return;
    // Retain the source list for older backends and recovery. Only mark this backend imported.
    localStorage.setItem(importKey(), "1"); setLegacy([]);
  };
  return <section class="ssh-address-book">
    <div class="ssh-address-head"><h3>SSH address book</h3><div class="ssh-address-actions">
      <button class="s-btn" disabled={busy()} onClick={() => void refresh()}>Refresh</button>
      <button class="s-btn" disabled={!ready() || busy()} onClick={() => start()}>Add address</button>
    </div></div>
    <p class="s-lead">Saved connections shared across your devices.</p>
    <Show when={error()}><ErrorNotice error={error()} /></Show>
    <Show when={ready() && legacy().length}><button class="s-btn" onClick={() => setImporting(true)}>Import {legacy().length} local addresses…</button></Show>
    <div class="s-card"><For each={hosts()}>{host => <div class="s-row"><div class="s-row-text"><div class="s-row-title">{host.name}</div><div class="s-row-desc">{host.user}@{host.host}:{host.port}{host.note ? ` · ${host.note}` : ""}</div></div><button class="s-btn" disabled={!ready() || busy()} onClick={() => start(host)}>Edit</button></div>}</For>
    <Show when={ready() && !hosts().length}><p class="ssh-address-empty">No SSH addresses yet.</p></Show></div>
    <Show when={draft()}>{d => <Dialog title={editing() ? "Edit SSH address" : "Add SSH address"} busy={busy()} dirty={dirty()} onClose={() => setDraft(undefined)} footer={close => <>
      <Show when={editing()}><DialogButton disabled={busy() || !ready()} onClick={() => setConfirmDelete(true)}>Remove…</DialogButton></Show>
      <Show when={!ready()}><DialogButton disabled={busy()} onClick={() => void refresh()}>Reload addresses</DialogButton></Show>
      <DialogButton disabled={busy()} onClick={close}>Cancel</DialogButton>
      <DialogButton variant="primary" disabled={busy() || !ready() || !validAddress(d())} onClick={() => void mutate(() => saveSshHost(d(), editing()))}>Save</DialogButton>
    </>}>
      <Show when={confirmDelete()}><ConfirmDialog title="Remove SSH address?" description="This removes the saved address from every device connected to this backend. The machine itself is unchanged." action="Remove address" destructive busy={busy()} error={error()} onConfirm={() => void mutate(() => deleteSshHost(editing()!))} onClose={() => setConfirmDelete(false)}/></Show>
      <For each={["name","host","user","note"] as const}>{key => <Field label={{name:"Name",host:"Host",user:"User",note:"Note"}[key]}><input class="s-input" value={d()[key]} onInput={e => patch({[key]:e.currentTarget.value})} /></Field>}</For>
      <Field label="Port"><input class="s-input" type="number" min="1" max="65535" value={d().port} onInput={e => patch({port:Number(e.currentTarget.value)})} /></Field>
      <Show when={error()}><ErrorNotice error={error()} /></Show>
    </Dialog>}</Show>
    <Show when={importing()}><Dialog title="Import local SSH addresses" busy={busy()} onClose={() => setImporting(false)} footer={<><DialogButton disabled={busy()} onClick={() => setImporting(false)}>Cancel</DialogButton><DialogButton variant="primary" disabled={busy() || !ready()} onClick={() => void mutate(importRows)}>Import to this backend</DialogButton></>}>
      <p>These addresses will be shared through {getApiUrl()}. Existing targets are kept unchanged.</p>
      <For each={legacy()}>{a => <p>{a.name} · {a.user}@{a.host}:{a.port}</p>}</For>
      <Show when={error()}><ErrorNotice error={error()} /></Show>
    </Dialog></Show>
  </section>;
}
