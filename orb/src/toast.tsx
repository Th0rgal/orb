import { render } from "solid-js/web";
import { For, Show, createEffect, createSignal, onCleanup, onMount, type JSX } from "solid-js";
import { copyText } from "./clipboard";
import { describeError } from "./ErrorNotice";
import { CheckIcon, CloseIcon, CopyIcon } from "./icons";

/**
 * Bottom notifications for transient feedback: a failed action, or an
 * undoable change. Errors that belong to something on screen (a failed
 * mission in the transcript, a panel that couldn't load, a form field) stay
 * inline with ErrorNotice.
 */
export type ToastAction = { label: string; run: () => void; kbd?: string; primary?: boolean };
export type Toast = {
  id: number;
  /** Toasts with the same key replace each other instead of stacking. */
  key: string;
  kind: "error" | "info";
  title: JSX.Element;
  /** Leading glyph for info toasts; errors always show the alert icon. */
  icon?: JSX.Element;
  /** Extra class for a specialised layout (e.g. "secret"). */
  variant?: string;
  message?: string;
  /** Extra technical text, shown under "Details". */
  details?: string;
  /** Text the copy button copies verbatim (the full original error). */
  copy?: string;
  actions?: ToastAction[];
  /** Auto-hide after this many ms. Errors default to staying until closed. */
  timeout?: number;
  onDismiss?: () => void;
};

const MAX_VISIBLE = 3;
const [toasts, setToasts] = createSignal<Toast[]>([]);
const timers = new Map<number, ReturnType<typeof setTimeout>>();
let nextId = 1;

let toasterMounted = false;
/** Pages that render Orb pieces without index.tsx (test harnesses) still get toasts. */
function ensureToaster() {
  if (toasterMounted || typeof document === "undefined") return;
  const host = document.createElement("div");
  document.body.append(host);
  render(() => <Toaster />, host);
}

export function notify(t: Omit<Toast, "id" | "key"> & { key?: string }): number {
  ensureToaster();
  const id = nextId++;
  const key = t.key ?? `toast-${id}`;
  setToasts(list => {
    const existing = list.find(x => x.key === key);
    if (existing) clearTimer(existing.id);
    const rest = list.filter(x => x.key !== key);
    return [...rest, { ...t, id, key }].slice(-MAX_VISIBLE);
  });
  if (t.timeout) startTimer(id, t.timeout);
  return id;
}

/** Remove a toast without calling its onDismiss (the owner already knows). */
export function dismissToast(idOrKey: number | string) {
  setToasts(list => list.filter(t => {
    const match = t.id === idOrKey || t.key === idOrKey;
    if (match) clearTimer(t.id);
    return !match;
  }));
}

/** Test helper: drop every toast without callbacks. */
export function clearToasts() {
  for (const id of timers.keys()) clearTimer(id);
  owners.clear();
  setToasts([]);
}

/** User closed it (button, Escape, or timeout). */
function close(t: Toast) {
  dismissToast(t.id);
  t.onDismiss?.();
}

function clearTimer(id: number) {
  const timer = timers.get(id);
  if (timer) clearTimeout(timer);
  timers.delete(id);
}

function startTimer(id: number, ms: number) {
  clearTimer(id);
  timers.set(id, setTimeout(() => {
    const t = toasts().find(x => x.id === id);
    if (t) close(t);
  }, ms));
}

// Owners of keyed toasts that ErrorToast shows. A shared toast stays up while
// any owner still has the error, so one view unmounting can't hide another's.
type Owner = { onDismiss?: () => void; action?: ToastAction };
const owners = new Map<string, Map<symbol, Owner>>();

/**
 * Shows `error` as a bottom notification while it is set. Closing the
 * notification calls onDismiss, which should clear the error. Identical
 * errors from different places merge into one notification.
 */
export function ErrorToast(p: { error?: string | null | false; title?: string; onDismiss?: () => void; action?: ToastAction }) {
  const me = Symbol();
  let key: string | undefined;
  const release = () => {
    if (key === undefined) return;
    const map = owners.get(key);
    map?.delete(me);
    if (map && !map.size) { owners.delete(key); dismissToast(key); }
    key = undefined;
  };
  createEffect(() => {
    const raw = p.error;
    if (!raw) return release();
    const info = describeError(raw, p.title);
    const next = `error:${info.title}:${info.message}`;
    if (next !== key) release();
    key = next;
    if (!owners.has(key)) owners.set(key, new Map());
    owners.get(key)!.set(me, { onDismiss: p.onDismiss, action: p.action });
    const all = [...owners.get(key)!.values()];
    const actions = all.flatMap(o => o.action ? [o.action] : []).filter((a, i, list) => list.findIndex(b => b.label === a.label) === i).slice(0, 2);
    notify({
      key,
      kind: "error",
      title: info.title,
      message: info.message,
      details: info.message !== raw ? raw : undefined,
      copy: raw,
      actions,
      // Closing a merged toast clears the error everywhere it came from.
      onDismiss: () => { const all = owners.get(next); owners.delete(next); all?.forEach(o => o.onDismiss?.()); },
    });
  });
  onCleanup(release);
  return null;
}

function ToastItem(p: { toast: Toast }) {
  const [copied, setCopied] = createSignal(false);
  const t = () => p.toast;
  const pause = () => clearTimer(t().id);
  const resume = () => { if (t().timeout) startTimer(t().id, t().timeout!); };
  const copy = async () => {
    try { await copyText(t().copy ?? ""); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* clipboard unavailable */ }
  };
  return <div class={`toast ${t().kind}${t().variant ? ` ${t().variant}` : ""}`} role={t().kind === "error" ? "alert" : "status"} onMouseEnter={pause} onMouseLeave={resume} onFocusIn={pause} onFocusOut={resume}>
    <Show when={t().kind === "error"}>
      <svg class="toast-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" aria-hidden="true"><circle cx="8" cy="8" r="6" /><path d="M8 4.5v4M8 10.5v1" /></svg>
    </Show>
    <Show when={t().kind !== "error" && t().icon}><span class="toast-glyph" aria-hidden="true">{t().icon}</span></Show>
    <div class="toast-body">
      <span class="toast-title">{t().title}</span>
      <Show when={t().message}><span class="toast-message">{t().message}</span></Show>
      <Show when={t().details}>
        <details class="toast-details"><summary>Details</summary><pre>{t().details}</pre></details>
      </Show>
    </div>
    <For each={t().actions}>{a => <button type="button" class={a.primary ? "toast-btn primary" : "toast-btn"} onClick={() => { a.run(); dismissToast(t().id); }}>{a.label}<Show when={a.kbd}><kbd>{a.kbd}</kbd></Show></button>}</For>
    <Show when={t().copy}>
      <button type="button" class="icon-btn toast-icon-btn" aria-label={copied() ? "Error copied" : "Copy error"} title={copied() ? "Copied" : "Copy error"} onClick={() => void copy()}>
        <Show when={copied()} fallback={<CopyIcon size={13} />}><CheckIcon size={13} /></Show>
      </button>
    </Show>
    <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={() => close(t())}><CloseIcon size={13} /></button>
  </div>;
}

/** Mount once at the app root. Never covers a visible composer. */
export function Toaster() {
  toasterMounted = true;
  onCleanup(() => { toasterMounted = false; });
  const [pos, setPos] = createSignal<{ bottom: number; left: string }>({ bottom: 20, left: "50%" });
  const place = () => {
    const rect = [...document.querySelectorAll(".composer")].map(el => el.getBoundingClientRect())
      .filter(r => r.height > 0 && r.width > 0 && r.top < window.innerHeight && r.bottom > 0)
      .sort((a, b) => b.bottom - a.bottom)[0];
    if (!rect) return setPos({ bottom: 20, left: "50%" });
    // Centre on the composer's column; lift above it only when it sits at the bottom.
    const docked = window.innerHeight - rect.bottom < 120;
    setPos({ bottom: docked ? window.innerHeight - rect.top + 12 : 20, left: `${rect.left + rect.width / 2}px` });
  };
  // Views swap and composers grow while a toast is up; re-measure cheaply
  // only while one is visible.
  createEffect(() => {
    if (!toasts().length) return;
    place();
    const timer = setInterval(place, 250);
    onCleanup(() => clearInterval(timer));
  });
  onMount(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || !toasts().length) return;
      const active = document.activeElement;
      if (active && !active.closest(".toaster")) return;
      close(toasts()[toasts().length - 1]);
    };
    window.addEventListener("resize", place);
    window.addEventListener("keydown", onKey);
    onCleanup(() => { window.removeEventListener("resize", place); window.removeEventListener("keydown", onKey); });
  });
  return <Show when={toasts().length}>
    <div class="toaster" style={{ bottom: `${pos().bottom}px`, left: pos().left }}>
      <For each={toasts()}>{t => <ToastItem toast={t} />}</For>
    </div>
  </Show>;
}
