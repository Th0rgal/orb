import { localContinuation } from "./localWakeups";
import { Dynamic } from "solid-js/web";
import { Show, For, createSignal, type JSX } from "solid-js";
import { Dialog } from "./Dialog";
import { continuationLabel, actOnContinuation, type ContinuationSummary } from "./continuations";
import * as Icon from "./sidebarIcons";
import "./sidebar-status.css";
import { pendingMissionInteraction, type PendingInteraction } from "./missionAttention";

/** Preserve the backend status: idle is not success, and blocked is not failure. */
export function missionStatusPresentation(status: string, request?: PendingInteraction, continuation?: ContinuationSummary | null) {
  if (request && !["completed", "failed", "not_feasible", "interrupted", "cancelled", "canceled", "acknowledged"].includes(status)) {
    return { label: request.method === "permission" || request.method === "plan" ? "Approval requested" : "Waiting for your reply", tone: "attention", icon: Icon.MessageCircle };
  }
  if (continuation?.items.length && !["active", "running", "resuming", "starting", "waiting_background", "blocked", "failed", "not_feasible", "paused", "interrupted", "cancelled", "canceled"].includes(status)) {
    const failed = continuation.items.some(item => item.state === "error");
    return { label: continuationLabel(continuation), tone: failed ? "attention" : "scheduled", icon: failed ? Icon.CircleAlert : Icon.WakeClock };
  }
  switch (status) {
    case "active": case "running": case "resuming": case "starting":
      return { label: "Running", tone: "running", icon: Icon.LoaderCircle };
    case "pending": case "queued":
      return { label: "Queued", tone: "quiet", icon: Icon.Clock };
    case "waiting_background":
      return { label: "Background work running", tone: "running", icon: Icon.Clock };
    case "awaiting_user": case "waiting_user": case "acknowledged":
      return { label: "Ready for a follow-up", tone: "quiet", icon: null };
    case "blocked":
      return { label: "Blocked", tone: "attention", icon: Icon.CircleAlert };
    case "paused":
      return { label: "Paused", tone: "quiet", icon: Icon.Pause };
    case "completed":
      return { label: "Completed", tone: "success", icon: Icon.CircleCheck };
    case "failed": case "not_feasible":
      return { label: status === "failed" ? "Failed" : "Not feasible", tone: "attention", icon: Icon.CircleAlert };
    case "interrupted": case "cancelled":
      return { label: "Interrupted", tone: "quiet", icon: Icon.Pause };
    case "idle":
      return { label: "Idle", tone: "quiet", icon: null };
    default:
      return { label: status || "Unknown status", tone: "quiet", icon: null };
  }
}

export function MissionGlyph(p: { status: string; missionId?: string; identity?: JSX.Element; continuation?: ContinuationSummary | null }) {
  const continuation = () => {
    const local = localContinuation(p.missionId);
    const items = [...(local?.items ?? []), ...(p.continuation?.items ?? [])];
    return items.length ? { count: items.length, items } : undefined;
  };
  const [open, setOpen] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const [removed, setRemoved] = createSignal<string[]>([]);
  const [resumed, setResumed] = createSignal<string[]>([]);
  const items = () => continuation()?.items.filter(item => !removed().includes(item.id)).map(item => resumed().includes(item.id) ? { ...item, state: "queued" as const } : item) ?? [];
  const state = () => missionStatusPresentation(p.status, pendingMissionInteraction(p.missionId), { count: items().length, items: items() });
  const act = async (id: string, action: "resume" | "cancel") => {
    setBusy(true); setError("");
    try { await actOnContinuation(id, action); if (action === "cancel") setRemoved(ids => [...ids, id]); else setResumed(ids => [...ids, id]); window.dispatchEvent(new Event("orb:refresh")); }
    catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  const show = (event: MouseEvent | KeyboardEvent) => {
    event.stopPropagation(); event.preventDefault(); setOpen(true);
  };
  return <><span class={`mission-glyph ${state().tone}`} data-mission-status={p.status} title={state().label}
    role={items().length ? "button" : undefined}
    tabIndex={items().length ? 0 : undefined}
    aria-label={items().length ? `${state().label}. View wake-ups` : undefined}
    onClick={e => { if (items().length) show(e); }}
    onKeyDown={e => { if (items().length && (e.key === "Enter" || e.key === " ")) show(e); }}>
    <Show when={p.identity} fallback={<Icon.Bot />}>{p.identity}</Show>
    <Show when={state().icon}>{Glyph => <span class="mission-status-mark" aria-hidden="true"><Dynamic component={Glyph()} size={10} class={state().icon === Icon.LoaderCircle ? "mission-status-spin" : undefined} /></span>}</Show>
  </span><Show when={open()}><Dialog title="Scheduled wake-ups" busy={busy()} onClose={() => setOpen(false)}>
    <Show when={error()}><p role="alert">{error()}</p></Show>
    <For each={items()} fallback={<p>No pending wake-ups.</p>}>{item => <div class="wake-up-item">
      <p>{continuationLabel({ count: 1, items: [item] })}</p>
      <Show when={item.reason}><p>{item.reason}</p></Show>
      <Show when={item.error}><p role="alert">{item.error}</p></Show>
      <Show when={item.state === "scheduled" || item.state === "error"}>
        <div class="wake-up-actions"><Show when={item.state === "scheduled"}><button type="button" disabled={busy()} onClick={() => void act(item.id, "resume")}>Resume now</button></Show>
        <button type="button" disabled={busy()} onClick={() => void act(item.id, "cancel")}>Cancel wake-up</button></div>
      </Show>
    </div>}</For>
  </Dialog></Show></>;
}
