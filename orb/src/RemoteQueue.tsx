import { pollWhileVisible } from "./poll";
import { swallow } from "./log";
import { For, Show, batch, createEffect, createMemo, createSignal, onCleanup, untrack } from "solid-js";
import { ErrorToast } from "./toast";
import { isBtwWrappedPrompt, messagePresentation, replaceMessageUserText } from "./messagePresentation";
import { api, ApiError, connectionVersion, editQueuedMessage, listQueuedMessages, type QueuedMessage } from "./api";
import * as Ic from "./icons";

export interface RemoteQueueHandle {
  sendNow: (id?: string) => Promise<void>;
  replaceEdited: (id: string, sendReplaced: () => Promise<boolean>, replayAfter?: (after: { content: string; attached?: boolean }[]) => Promise<void>) => Promise<boolean>;
  /** Edit a queued message in place (same id, same position). Resolves
   * "unsupported" when this Core (or this kind of row) cannot, so the caller
   * falls back to `replaceEdited`. */
  editInPlace: (id: string, content: string) => Promise<"edited" | "failed" | "unsupported">;
  editFirst: () => void;
  hasQueued: () => boolean;
}

/** How long a sent row takes to collapse out of the queue. */

export type PendingRemoteQueueItem = { id: string; content: string; attached?: boolean };

/** The server inbox remains authoritative across a stop, reconnect or restart. */
export function RemoteQueue(p: {
  mission: string;
  confirmed?: (QueuedMessage & {attached?:boolean})[];
  /** Ids already shown as sent in the transcript. Core keeps a remote follow-up in
   * its inbox until the node accepts the job, which can be long when the node is
   * full; a delivered message must not also be listed as queued. */
  delivered?: string[];
  pending?: PendingRemoteQueueItem | PendingRemoteQueueItem[];
  editing?: string;
  onEdit?: (row: {id: string; text: string; remote: true}) => void;
  onSendImmediate?: (ordered: {id: string; content: string; attached?: boolean}[], liveInjected?: {id: string; content: string; attached?: boolean}[]) => Promise<void>;
  onRows: (ids: string[]) => void;
  onCancel: (id: string) => void;
  /** Called only when a queued message is explicitly removed (`DELETE`), not when promoted via `Send now`. */
  onRemove?: (id: string) => void;
  /** Withdraw a message shown optimistically as sent, when it was not delivered live. */
  onRetract?: (id: string) => void;
  /** Core took a Send now: injected into the running turn (`live`), or
   * promoted to start the next turn once the current one stops. */
  onSendNowAccepted?: (id: string, live: boolean) => void;
  /** A queued message's content changed in place (same id). */
  onEdited?: (id: string, content: string) => void;
  /** Another client edited this queued row. The inbox poll may still hold
   * the previous text until the next read. */
  liveEdit?: { id: string; content: string; at: number } | { id: string; content: string; at: number }[];
  ref?: (handle: RemoteQueueHandle) => void;
}) {
  let revision = 0, destroyed = false, inboxClock = 0;
  const deletedIds = new Set<string>();
  const [liveEdits, setLiveEdits] = createSignal<ReadonlyMap<string, { content: string; at: number; epoch: number }>>(new Map());
  const [settledPollEpoch, setSettledPollEpoch] = createSignal(0);
  onCleanup(() => { destroyed = true; });
  const [rows, setRows] = createSignal<QueuedMessage[]>([]);
  /** Optimistic in-place edits, by id, until Core confirms or refuses them. */
  const [edits, setEdits] = createSignal<Readonly<Record<string, string>>>({});
  const pendingList = () => {
    if (!p.pending) return [];
    return Array.isArray(p.pending) ? p.pending : [p.pending];
  };
  const delivered = () => new Set(p.delivered ?? []);
  const visibleRows = () => {
    const sent = delivered();
    const known = new Map<string,QueuedMessage & {attached?:boolean}>();
    for (const row of rows()) if (!deletedIds.has(row.id) && !sent.has(row.id)) known.set(row.id, row);
    // A live edit newer than the last inbox poll wins until the next poll.
    // An older confirmed copy must not hide an edit another client already
    // wrote into the inbox.
    for (const [id, edit] of liveEdits()) {
      if (deletedIds.has(id) || sent.has(id) || edit.epoch <= settledPollEpoch()) continue;
      const current = known.get(id);
      if (current) known.set(id, { ...current, content: edit.content });
      else known.set(id, { id, mission_id: p.mission, content: edit.content, source: "remote-queue" });
    }
    for (const row of p.confirmed ?? []) {
      if (deletedIds.has(row.id) || sent.has(row.id) || known.has(row.id)) continue;
      known.set(row.id, row);
    }
    return [...known.values()];
  };
  const edited = <T extends { id: string; content: string }>(row: T): T => {
    const content = edits()[row.id];
    return content == null ? row : { ...row, content };
  };
  const displayRows = () => {
    const confirmedMap = new Map<string, QueuedMessage & { attached?: boolean }>();
    for (const row of visibleRows()) confirmedMap.set(row.id, row);
    const out: (QueuedMessage & { attached?: boolean; sending?: boolean })[] = [];
    const seen = new Set<string>();
    for (const row of visibleRows()) {
      seen.add(row.id);
      out.push({ ...edited(row), sending: false });
    }
    for (const item of pendingList()) {
      if (deletedIds.has(item.id) || seen.has(item.id) || delivered().has(item.id)) continue;
      seen.add(item.id);
      const confirmed = confirmedMap.get(item.id);
      if (confirmed) out.push({ ...edited(confirmed), sending: false });
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
    inboxClock = 0;
    untrack(() => { setSettledPollEpoch(0); setRows([]); setLiveEdits(new Map()); setError(""); p.onRows([]); });
    let disposed = false, loading = false;
    const refresh = async () => {
      if (loading || !mission) return;
      loading = true;
      const pollEpoch = ++inboxClock;
      const started = revision;
      try {
        const pending = (await listQueuedMessages(mission)).filter(row => !row.inflight && !deletedIds.has(row.id) && (row.source === "remote-queue" || row.source?.startsWith("host-queue:api:")));
        if (disposed || started !== revision || version !== connectionVersion()) return;
        const sent = untrack(delivered);
        batch(() => {
          setSettledPollEpoch(pollEpoch);
          setRows(pending);
        });
        p.onRows(pending.filter(row => !sent.has(row.id)).map(row => row.id));
      } catch { /* Keep the last confirmed inbox during a network interruption. */ }
      finally { loading = false; }
    };
    void refresh();
    const stop = pollWhileVisible(refresh, 3000, "remoteQueue.refresh");
    onCleanup(() => { disposed = true; stop(); });
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
      p.onRemove?.(id);
      p.onCancel(id);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (/\b404\b/.test(msg)) {
        if (!destroyed && version === connectionVersion() && mission === p.mission) {
          p.onRows(rows().map(row => row.id));
          p.onRemove?.(id);
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
    // Optimistic: the message leaves the queue and shows in the thread right away (same id, so
    // the later receipt dedupes); it returns to the queue only if Core refuses.
    const injected = { id: target.id, content: messagePresentation(target.content).text, attached: target.attached || messagePresentation(target.content).attached || undefined };
    const before = rows();
    // One reactive batch: the row leaves the queue and the message enters the
    // transcript together, so no frame shows it in neither place.
    batch(() => {
      deletedIds.add(target.id);
      setRows(previous => previous.filter(row => row.id !== target.id));
      void p.onSendImmediate?.([], [injected]);
    });
    try {
      // A network error or timeout does not prove the message was not delivered:
      // it must never fall through to delete-and-resend. Only an explicit
      // `delivered: false` from Core means "no live injection, stop then send".
      // `interrupt=true`: when there is no live injection, Core stops the turn and
      // delivers THIS queued message next under its same id (`promoted`).
      const live = await api<{ ok?: boolean; delivered?: boolean; promoted?: boolean }>(`/api/control/queue/${encodeURIComponent(target.id)}/send-now?interrupt=true`, { method: "POST" });
      if (live?.delivered || live?.promoted) {
        if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
        p.onSendNowAccepted?.(target.id, !!live.delivered);
        revision++;
        p.onRows(rows().map(row => row.id));
        p.onCancel(target.id);
        return;
      }
      // Older Core without promote: the fallback below shows its own copy while
      // it stops the turn and sends.
      p.onRetract?.(target.id);
      const ordered = [target, ...list.filter(r => r.id !== target.id)];
      const payload = ordered.map(r => {
        const presented = messagePresentation(r.content);
        return { id: r.id, content: isBtwWrappedPrompt(r.content) ? r.content : presented.text, attached: r.attached || presented.attached || undefined };
      });
      await Promise.allSettled(ordered.map(r => api(`/api/control/queue/${encodeURIComponent(r.id)}`, { method: "DELETE" })));
      if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
      revision++;
      for (const r of ordered) deletedIds.add(r.id);
      setRows([]); p.onRows([]);
      for (const r of ordered) p.onCancel(r.id);
      await p.onSendImmediate?.(payload);
    } catch (e) {
      if (version === connectionVersion() && mission === p.mission) {
        // Refused or unconfirmed: put the queue back as it was, same id, so nothing
        // looks sent that was not. The next queue read reconciles a late delivery.
        batch(() => {
          p.onRetract?.(target.id);
          deletedIds.delete(target.id);
          setRows(before);
          setError(e instanceof Error ? e.message : String(e));
        });
      }
    } finally {
      setWorking(false);
    }
  };
  const replaceEdited: RemoteQueueHandle["replaceEdited"] = async () => {
    setError("This edit cannot be saved atomically. The queued messages have not been changed.");
    return false;
  };
  const editInPlace: RemoteQueueHandle["editInPlace"] = async (id, content) => {
    const target = visibleRows().find(r => r.id === id);
    if (!target) {
      setError("This message was already sent. Your edit was not applied.");
      return "failed";
    }
    const nextContent = replaceMessageUserText(target.content, content);
    if (!isBtwWrappedPrompt(target.content) && target.attached && !messagePresentation(target.content).attached) {
      setError("Attached context cannot be changed on a queued message. Remove it and send a new follow-up instead.");
      return "failed";
    }
    const version = connectionVersion(), mission = p.mission;
    const previous = edits()[id];
    setError("");
    setEdits(all => ({ ...all, [id]: nextContent }));
    const revert = () => setEdits(all => {
      const next = { ...all };
      if (previous == null) delete next[id]; else next[id] = previous;
      return next;
    });
    try {
      await editQueuedMessage(id, nextContent);
      if (destroyed || version !== connectionVersion() || mission !== p.mission) return "edited";
      batch(() => {
        revision++;
        setRows(list => list.map(row => row.id === id ? { ...row, content: nextContent } : row));
        p.onEdited?.(id, nextContent);
        setEdits(all => { const next = { ...all }; delete next[id]; return next; });
      });
      return "edited";
    } catch (e) {
      revert();
      if (!destroyed && version === connectionVersion() && mission === p.mission) {
        setError(e instanceof ApiError && (e.status === 409 || e.status === 404) ? "This message was already sent, so the edit was not applied." : `Couldn’t save the edit: ${e instanceof Error ? e.message : String(e)}`);
      }
      return "failed";
    }
  };
  p.ref?.({
    sendNow,
    replaceEdited,
    editInPlace,
    editFirst: () => {
      const first = visibleRows()[0];
      if (first && p.onEdit && !p.editing && !working()) {
        p.onEdit({ id: first.id, text: messagePresentation(first.content).text, remote: true });
      }
    },
    hasQueued: () => visibleRows().length > 0,
  });
  createEffect(() => {
    const incoming = p.liveEdit ? (Array.isArray(p.liveEdit) ? p.liveEdit : [p.liveEdit]) : [];
    if (!incoming.length) return;
    setLiveEdits(previous => {
      let next = previous;
      for (const edit of incoming) {
        const seen = next.get(edit.id);
        if (seen && edit.at <= seen.at) continue;
        if (next === previous) next = new Map(previous);
        const epoch = ++inboxClock;
        (next as Map<string, { content: string; at: number; epoch: number }>).set(edit.id, { content: edit.content, at: edit.at, epoch });
      }
      return next;
    });
  });
  type Row = QueuedMessage & { attached?: boolean; sending?: boolean };
  // A row moving to the transcript leaves in the same frame its bubble lands:
  // the dock shrinks by the row exactly when the transcript grows by the
  // bubble, so a pinned transcript moves once and never bounces back.
  const rowsById = createMemo(() => new Map(displayRows().map(row => [row.id, row as Row])));
  const rowIds = createMemo(() => displayRows().map(row => row.id), [], { equals: (a, b) => a.length === b.length && a.every((id, i) => id === b[i]) });
  return <Show when={rowIds().length || error()}>
    <section class="followup-queue" classList={{collapsed:collapsed()}} aria-label="Queued messages" aria-live="polite">
      {/* The header and every row keep one geometry from send to delivery: the
          hint reserves its space and each row reserves its action area, so the
          dock height changes only when a row is added or removed. */}
      <Show when={rowIds().length}><header>
        <span class="queue-count">{`${displayRows().length} Queued`}</span>
        <span class="queue-hint" classList={{"queue-hint-hidden": !(visibleRows().length > 0 && !p.editing)}} aria-hidden={!(visibleRows().length > 0 && !p.editing)}><Ic.ReturnIcon size={13}/> to Send</span>
        <div class="queue-options">
          <button type="button" class="queue-collapse" aria-label={collapsed()?"Show queued messages":"Hide queued messages"} aria-expanded={!collapsed()} onClick={()=>setCollapsed(!collapsed())}><Ic.ChevronDown size={14}/></button>
        </div>
      </header></Show>
      <Show when={!collapsed()}><ol classList={{scrollable:rowIds().length>6}}><For each={rowIds()}>{id => {
        // Keyed by id (a string), so the same <li> lives from "sending" to
        // "confirmed": its spinner fades instead of the row being rebuilt.
        let last: Row | undefined;
        const r = () => (last = rowsById().get(id) ?? last)!;
        const text = () => messagePresentation(edits()[r().id] ?? r().content).text;
        const attached = () => r().attached || messagePresentation(r().content).attached;
        const inert = () => !!r().sending;
        return <li class="queue-row" classList={{editing:p.editing===r().id,sending:!!r().sending,failed:!!r().queue_error}}>
          <div class="queue-line">
            <div class="queue-text" title={text()}><span>{text()}</span><Show when={attached()}><small class="user-context">Attached context</small></Show></div>
            <span class="queue-trailing">
              <span class="queue-sending" classList={{visible:!!r().sending}} role={r().sending ? "status" : undefined}><Show when={r().sending}><span class="sr-only">Sending…</span></Show></span>
              <Show when={p.editing===r().id} fallback={<span class="queue-row-actions" classList={{pending:inert()}}>
                <button type="button" class="queue-action-btn" aria-label={`Edit queued message: ${text()}`} disabled={inert()||working()||!!p.editing||cancelling()===r().id} onClick={()=>p.onEdit?.({id:r().id,text:text(),remote:true})}><Ic.PencilIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Edit</span><kbd>→</kbd></span></button>
                <button type="button" class="queue-action-btn" aria-label={`Send now: ${text()}`} disabled={inert()||working()||!!p.editing||cancelling()===r().id} onClick={()=>void sendNow(r().id)}><Ic.ArrowUpIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Send now</span><kbd>↵</kbd></span></button>
                <button type="button" class="queue-action-btn" aria-label={`Remove queued message: ${text()}`} disabled={inert()||working()||cancelling()===r().id||p.editing===r().id} onClick={()=>void cancel(r().id)}><Ic.TrashIcon size={14}/><span class="queue-tooltip" aria-hidden="true"><span>Delete</span></span></button>
              </span>}><span class="queue-editing">Editing</span></Show>
            </span>
          </div>
          <Show when={r().queue_error}><small title={r().queue_error ?? undefined}>Delivery paused · {r().queue_error}</small></Show>
        </li>;
      }}</For></ol></Show>
      <ErrorToast error={error()} onDismiss={() => setError("")} />
    </section>
  </Show>;
}
