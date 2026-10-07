import { For, Show, createEffect, createSignal, onCleanup, untrack } from "solid-js";
import { messagePresentation } from "./messagePresentation";
import { api, connectionVersion, listQueuedMessages, type QueuedMessage } from "./api";
import * as Ic from "./icons";

export interface RemoteQueueHandle {
  sendNow: (id?: string) => Promise<void>;
  replaceEdited: (id: string, sendReplaced: () => Promise<boolean>, replayAfter?: (after: { content: string; attached?: boolean }[]) => Promise<void>) => Promise<boolean>;
  editFirst: () => void;
  hasQueued: () => boolean;
}

export type PendingRemoteQueueItem = { id: string; content: string; attached?: boolean };

/** The server inbox remains authoritative across a stop, reconnect or restart. */
export function RemoteQueue(p: {
  mission: string;
  confirmed?: (QueuedMessage & {attached?:boolean})[];
  pending?: PendingRemoteQueueItem | PendingRemoteQueueItem[];
  editing?: string;
  onEdit?: (row: {id: string; text: string; remote: true}) => void;
  onSendImmediate?: (ordered: {id: string; content: string; attached?: boolean}[], liveInjected?: {id: string; content: string; attached?: boolean}[]) => Promise<void>;
  onRows: (ids: string[]) => void;
  onCancel: (id: string) => void;
  ref?: (handle: RemoteQueueHandle) => void;
}) {
  let revision = 0, destroyed = false;
  const deletedIds = new Set<string>();
  onCleanup(() => { destroyed = true; });
  const [rows, setRows] = createSignal<QueuedMessage[]>([]);
  const pendingList = () => {
    if (!p.pending) return [];
    return Array.isArray(p.pending) ? p.pending : [p.pending];
  };
  const visibleRows = () => {
    const known = new Map<string,QueuedMessage & {attached?:boolean}>();
    for (const row of rows()) if (!deletedIds.has(row.id)) known.set(row.id, row);
    for (const row of p.confirmed ?? []) if (!deletedIds.has(row.id)) known.set(row.id, {...known.get(row.id), ...row});
    return [...known.values()];
  };
  const displayRows = () => {
    const confirmedMap = new Map<string, QueuedMessage & { attached?: boolean }>();
    for (const row of visibleRows()) confirmedMap.set(row.id, row);
    const out: (QueuedMessage & { attached?: boolean; sending?: boolean })[] = [];
    const seen = new Set<string>();
    for (const row of visibleRows()) {
      seen.add(row.id);
      out.push({ ...row, sending: false });
    }
    for (const item of pendingList()) {
      if (deletedIds.has(item.id) || seen.has(item.id)) continue;
      seen.add(item.id);
      const confirmed = confirmedMap.get(item.id);
      if (confirmed) out.push({ ...confirmed, sending: false });
      else out.push({ id: item.id, content: item.content, attached: item.attached, sending: true });
    }
    return out;
  };
  const [error, setError] = createSignal("");
  const [cancelling, setCancelling] = createSignal<string>();
  const [working, setWorking] = createSignal(false);
  const [collapsed, setCollapsed] = createSignal(false);
  createEffect(() => {
    const mission = p.mission, version = connectionVersion();
    deletedIds.clear();
    untrack(() => { setRows([]); setError(""); p.onRows([]); });
    let disposed = false, loading = false;
    const refresh = async () => {
      if (loading || !mission) return;
      loading = true;
      const started = revision;
      try {
        const pending = (await listQueuedMessages(mission)).filter(row => !row.inflight && !deletedIds.has(row.id) && (row.source === "remote-queue" || row.source?.startsWith("host-queue:api:")));
        if (disposed || started !== revision || version !== connectionVersion()) return;
        setRows(pending); p.onRows(pending.map(row => row.id));
      } catch { /* Keep the last confirmed inbox during a network interruption. */ }
      finally { loading = false; }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 3000);
    onCleanup(() => { disposed = true; clearInterval(timer); });
  });
  const cancel = async (id: string) => {
    setError("");
    const version = connectionVersion(), mission = p.mission;
    const snapshot = rows();
    // Optimistically remove immediately so the queue updates in < 16ms
    revision++;
    deletedIds.add(id);
    const remaining = snapshot.filter(row => row.id !== id);
    setRows(remaining);
    setCancelling(id);
    try {
      await api(`/api/control/queue/${encodeURIComponent(id)}`, { method: "DELETE" });
      if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
      p.onRows(rows().map(row => row.id));
      p.onCancel(id);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (/\b404\b/.test(msg)) {
        if (!destroyed && version === connectionVersion() && mission === p.mission) {
          p.onRows(rows().map(row => row.id));
          p.onCancel(id);
        }
        return;
      }
      // Roll back optimistic delete if the network request failed
      deletedIds.delete(id);
      if (!destroyed && version === connectionVersion() && mission === p.mission) {
        revision++;
        setRows(snapshot);
        p.onRows(snapshot.map(row => row.id));
        setError(msg);
      }
    } finally {
      setCancelling(undefined);
    }
  };
  const sendNow = async (targetId?: string) => {
    if (working() || p.editing) return;
    const list = visibleRows();
    const target = targetId ? list.find(r => r.id === targetId) : list[0];
    if (!target) return;
    setWorking(true); setError("");
    const version = connectionVersion(), mission = p.mission;
    try {
      const live = await api<{ ok?: boolean; delivered?: boolean }>(`/api/control/queue/${encodeURIComponent(target.id)}/send-now`, { method: "POST" }).catch(() => ({ delivered: false }));
      if (live?.delivered) {
        if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
        revision++;
        deletedIds.add(target.id);
        setRows(previous => previous.filter(row => row.id !== target.id));
        p.onRows(rows().map(row => row.id));
        p.onCancel(target.id);
        await p.onSendImmediate?.([], [{ id: target.id, content: messagePresentation(target.content).text, attached: target.attached || messagePresentation(target.content).attached || undefined }]);
        return;
      }
      const ordered = [target, ...list.filter(r => r.id !== target.id)];
      const payload = ordered.map(r => {
        const presented = messagePresentation(r.content);
        return { id: r.id, content: presented.text, attached: r.attached || presented.attached || undefined };
      });
      await Promise.allSettled(ordered.map(r => api(`/api/control/queue/${encodeURIComponent(r.id)}`, { method: "DELETE" })));
      if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
      revision++;
      for (const r of ordered) deletedIds.add(r.id);
      setRows([]); p.onRows([]);
      for (const r of ordered) p.onCancel(r.id);
      await p.onSendImmediate?.(payload);
    } catch (e) {
      if (version === connectionVersion() && mission === p.mission) setError(e instanceof Error ? e.message : String(e));
    } finally {
      setWorking(false);
    }
  };
  const replaceEdited: RemoteQueueHandle["replaceEdited"] = async (id, sendReplaced, replayAfter) => {
    const list = visibleRows();
    const idx = list.findIndex(r => r.id === id);
    if (idx < 0) {
      setError("This message was already sent. Your edit is still in the composer.");
      return false;
    }
    const tail = list.slice(idx);
    const after = tail.slice(1);
    setWorking(true); setError("");
    try {
      await api(`/api/control/queue/${encodeURIComponent(id)}`, { method: "DELETE" });
      for (const r of after) {
        await api(`/api/control/queue/${encodeURIComponent(r.id)}`, { method: "DELETE" }).catch(() => {});
      }
      revision++;
      for (const r of tail) deletedIds.add(r.id);
      setRows(previous => previous.filter(row => !tail.some(t => t.id === row.id)));
      p.onRows(rows().map(row => row.id));
      for (const r of tail) p.onCancel(r.id);
      const ok = await sendReplaced();
      if (!ok) return false;
      if (after.length && replayAfter) await replayAfter(after.map(r => {
        const presented = messagePresentation(r.content);
        return { content: presented.text, attached: r.attached || presented.attached || undefined };
      }));
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return false;
    } finally {
      setWorking(false);
    }
  };
  p.ref?.({
    sendNow,
    replaceEdited,
    editFirst: () => {
      const first = visibleRows()[0];
      if (first && p.onEdit && !p.editing && !working()) {
        p.onEdit({ id: first.id, text: messagePresentation(first.content).text, remote: true });
      }
    },
    hasQueued: () => visibleRows().length > 0,
  });
  return <Show when={displayRows().length || error()}>
    <section class="followup-queue" classList={{collapsed:collapsed()}} aria-label="Queued messages" aria-live="polite">
      <header>
        <span class="queue-count">{visibleRows().length ? `${displayRows().length} Queued` : `${displayRows().length} Sending…`}</span>
        <Show when={visibleRows().length > 0 && !p.editing}><span class="queue-hint"><Ic.ReturnIcon size={13}/> to Send</span></Show>
        <Show when={displayRows().length > 0}>
          <div class="queue-options">
            <button type="button" class="queue-collapse" aria-label={collapsed()?"Show queued messages":"Hide queued messages"} aria-expanded={!collapsed()} onClick={()=>setCollapsed(!collapsed())}><Ic.ChevronDown size={14}/></button>
          </div>
        </Show>
      </header>
      <Show when={!collapsed()}><ol classList={{scrollable:displayRows().length>6}}><For each={displayRows()}>{row => {
        const text = () => messagePresentation(row.content).text;
        const attached = () => row.attached || messagePresentation(row.content).attached;
        return <li class="queue-row" classList={{editing:p.editing===row.id,sending:!!row.sending,failed:!!row.queue_error}}>
          <div class="queue-line">
            <div class="queue-text" title={text()}><span>{text()}</span><Show when={attached()}><small class="user-context">Attached context</small></Show></div>
            <Show when={!row.sending} fallback={<span class="queue-editing" role="status">Sending…</span>}>
              <Show when={p.editing===row.id} fallback={<span class="queue-row-actions">
                <button type="button" class="queue-action-btn" aria-label={`Edit queued message: ${text()}`} disabled={working()||!!p.editing||cancelling()===row.id} onClick={()=>p.onEdit?.({id:row.id,text:text(),remote:true})}><Ic.PencilIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Edit</span><kbd>→</kbd></span></button>
                <button type="button" class="queue-action-btn" aria-label={`Send now: ${text()}`} disabled={working()||!!p.editing||cancelling()===row.id} onClick={()=>void sendNow(row.id)}><Ic.ArrowUpIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Send now</span><kbd>↵</kbd></span></button>
                <button type="button" class="queue-action-btn" aria-label={`Remove queued message: ${text()}`} disabled={working()||cancelling()===row.id||p.editing===row.id} onClick={()=>void cancel(row.id)}><Ic.TrashIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Delete</span></span></button>
              </span>}><span class="queue-editing">Editing</span></Show>
            </Show>
          </div>
          <Show when={row.queue_error}><small title={row.queue_error ?? undefined}>Delivery paused · {row.queue_error}</small></Show>
        </li>;
      }}</For></ol></Show>
      <Show when={error()}><p role="alert">{error()}</p></Show>
    </section>
  </Show>;
}
