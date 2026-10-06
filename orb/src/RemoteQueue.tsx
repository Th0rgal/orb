import { For, Show, createEffect, createSignal, onCleanup, untrack } from "solid-js";
import { messagePresentation } from "./messagePresentation";
import { api, connectionVersion, listQueuedMessages, type QueuedMessage } from "./api";

/** The server inbox remains authoritative across a stop, reconnect or restart. */
export function RemoteQueue(p: {
  mission: string;
  confirmed?: (QueuedMessage & {attached?:boolean})[];
  pending?: {id:string;content:string};
  onRows: (ids: string[]) => void;
  onCancel: (id: string) => void;
}) {
  let revision = 0, destroyed = false;
  onCleanup(() => { destroyed = true; });
  const [rows, setRows] = createSignal<QueuedMessage[]>([]);
  const visibleRows = () => {
    const known = new Map<string,QueuedMessage & {attached?:boolean}>(rows().map(row => [row.id, row]));
    for (const row of p.confirmed ?? []) known.set(row.id, {...known.get(row.id), ...row});
    return [...known.values()];
  };
  const [error, setError] = createSignal("");
  const [cancelling, setCancelling] = createSignal<string>();
  createEffect(() => {
    const mission = p.mission, version = connectionVersion();
    untrack(() => { setRows([]); setError(""); p.onRows([]); });
    let disposed = false, loading = false;
    const refresh = async () => {
      if (loading || !mission) return;
      loading = true;
      const started = revision;
      try {
        const pending = (await listQueuedMessages(mission)).filter(row => !row.inflight && (row.source === "remote-queue" || row.source?.startsWith("host-queue:api:")));
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
    setCancelling(id); setError("");
    const version = connectionVersion(), mission = p.mission;
    try {
      await api(`/api/control/queue/${encodeURIComponent(id)}`, { method: "DELETE" });
      if (destroyed || version !== connectionVersion() || mission !== p.mission) return;
      revision++;
      setRows(previous => previous.filter(row => row.id !== id));
      p.onRows(rows().map(row => row.id)); p.onCancel(id);
    } catch (e) { if (version === connectionVersion() && mission === p.mission) setError(e instanceof Error ? e.message : String(e)); }
    finally { setCancelling(undefined); }
  };
  return <Show when={visibleRows().length || p.pending}>
    <section class="followup-queue" aria-label="Queued messages" aria-live="polite">
      <header><span class="queue-count">{visibleRows().length ? `${visibleRows().length} Queued` : "Sending…"}</span></header>
      <ol><Show when={p.pending && !visibleRows().some(row=>row.id===p.pending?.id)}><li class="queue-row"><div class="queue-line"><span class="queue-text">{p.pending?.content}</span><span role="status">Sending…</span></div></li></Show><For each={visibleRows()}>{row => <li class="queue-row">
        <div class="queue-line">
          <div class="queue-text"><span title={messagePresentation(row.content).text}>{messagePresentation(row.content).text}</span><Show when={row.attached || messagePresentation(row.content).attached}><small class="user-context">Attached context</small></Show></div>
          <button class="queue-send-now" disabled={cancelling() === row.id} onClick={() => void cancel(row.id)}>Cancel</button>
        </div>
        <Show when={row.queue_error}><small title={row.queue_error ?? undefined}>Delivery paused · {row.queue_error}</small></Show>
      </li>}</For></ol>
      <Show when={error()}><p role="alert">{error()}</p></Show>
    </section>
  </Show>;
}
