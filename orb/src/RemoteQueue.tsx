import { For, Show, createEffect, createSignal, onCleanup, untrack } from "solid-js";
import { api, connectionVersion, listQueuedMessages, type QueuedMessage } from "./api";

/** The server inbox remains authoritative across a stop, reconnect or restart. */
export function RemoteQueue(p: {
  mission: string;
  onRows: (ids: string[]) => void;
  onCancel: (id: string) => void;
}) {
  let revision = 0, destroyed = false;
  onCleanup(() => { destroyed = true; });
  const [rows, setRows] = createSignal<QueuedMessage[]>([]);
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
        const pending = (await listQueuedMessages(mission)).filter(row => row.source === "remote-queue");
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
  return <Show when={rows().length}>
    <section class="followup-queue" aria-label="Remote queued messages" aria-live="polite">
      <header><span class="queue-count">{rows().length} Queued</span></header>
      <ol><For each={rows()}>{row => <li class="queue-row">
        <div class="queue-line">
          <span class="queue-text" title={row.content}>{row.content}</span>
          <button class="queue-send-now" disabled={cancelling() === row.id} onClick={() => void cancel(row.id)}>Cancel</button>
        </div>
        <Show when={row.queue_error}><small title={row.queue_error ?? undefined}>Delivery paused · {row.queue_error}</small></Show>
      </li>}</For></ol>
      <Show when={error()}><p role="alert">{error()}</p></Show>
    </section>
  </Show>;
}
