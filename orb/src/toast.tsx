import { render } from "solid-js/web";
import { For, Show, createEffect, createSignal, onCleanup, onMount, type JSX } from "solid-js";
import { copyText } from "./clipboard";
import { describeError } from "./ErrorNotice";
import { CheckIcon, CloseIcon, CopyIcon } from "./icons";
import { swallow } from "./log";
import { hasInteractiveOverlay } from "./overlayLayer";

/**
 * Unified floating bottom notifications across all workspace panels:
 * connection/reachability, page/panel load & refresh, failed actions,
 * undoable changes, and biometric approvals. Inline ErrorNotice stays only
 * inside active modals/popovers or persisted historical timeline turns/ticks.
 */
export type ToastAction = {
  label: string;
  run: () => unknown;
  kbd?: string;
  primary?: boolean;
  /** Rendered as a quiet text link under the message. */
  link?: boolean;
  /** Keep the toast open when clicked (e.g. opening an external link). Defaults to true. */
  dismiss?: boolean;
};
export type Toast = {
  id: number;
  /** Toasts with the same key replace each other instead of stacking. */
  key: string;
  kind: "error" | "info";
  tone?: "warning";
  title: JSX.Element;
  /** Leading glyph for info toasts; errors always show the alert icon. */
  icon?: JSX.Element;
  /** Replaces the whole layout; the content owns its own close control. */
  content?: () => JSX.Element;
  /** Extra class for a specialised layout (e.g. "secret"). */
  variant?: string;
  message?: string;
  /** Extra technical text, shown under "Technical details". */
  details?: string;
  /** Text the copy button copies verbatim (the full original error). */
  copy?: string;
  actions?: ToastAction[];
  /** Auto-hide after this many ms. Errors default to staying until closed. */
  timeout?: number;
  onDismiss?: (reason?: "dismiss" | "action" | "timeout") => void;
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

/** User closed it (button, Escape, action, or timeout). */
function close(t: Toast, reason: "dismiss" | "action" | "timeout" = "dismiss") {
  dismissToast(t.id);
  t.onDismiss?.(reason);
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
    if (t) close(t, "timeout");
  }, ms));
}

// Owners of keyed toasts that ErrorToast shows. A shared toast stays up while
// any owner still has the error, so one view unmounting can't hide another's.
type Owner = {
  onDismiss?: () => void;
  actions: ToastAction[];
  background?: boolean;
  suppress: (key: string | null) => void;
  rebump: () => void;
};
const owners = new Map<string, Map<symbol, Owner>>();

/**
 * Shows `error` as a bottom notification while it is set. Closing the
 * notification calls onDismiss, which should clear the error. Identical
 * errors from different places merge into one notification.
 *
 * Set `background` for recurring poll/refresh errors: dismissing with `×`
 * keeps repeated background ticks for that same error quiet until `error`
 * clears on a healthy refresh or an explicit Retry/Refresh runs.
 */
export function ErrorToast(p: {
  error?: string | null | false;
  title?: string;
  backend?: string | null;
  background?: boolean;
  onDismiss?: () => void;
  action?: ToastAction;
  actions?: ToastAction[];
}) {
  const me = Symbol();
  const [suppressed, setSuppressed] = createSignal<string | null>(null);
  const [bump, setBump] = createSignal(0);
  let key: string | undefined;
  const release = () => {
    if (key === undefined) return;
    const map = owners.get(key);
    map?.delete(me);
    if (map && !map.size) { owners.delete(key); dismissToast(key); }
    key = undefined;
  };
  createEffect(() => {
    bump();
    const raw = p.error;
    if (!raw) {
      setSuppressed(null);
      return release();
    }
    const info = describeError(raw, p.title, p.backend);
    const next = `error:${info.title}:${info.message}`;
    if (p.background && suppressed() === next) return release();
    if (next !== key) release();
    key = next;
    if (!owners.has(key)) owners.set(key, new Map());
    const ownActions = [...(p.action ? [p.action] : []), ...(p.actions ?? [])];
    owners.get(key)!.set(me, {
      onDismiss: p.onDismiss,
      actions: ownActions,
      background: p.background,
      suppress: setSuppressed,
      rebump: () => setBump(n => n + 1),
    });
    const all = [...owners.get(key)!.values()];
    const linkAction: ToastAction[] = info.link
      ? [{
          label: info.link.label,
          link: true,
          dismiss: false,
          run: () => import("./api").then(m => m.openExternalUrl(info.link!.url)).catch(swallow("errorToast.openLink")),
        }]
      : [];
    const grouped = new Map<string, ToastAction[]>();
    for (const a of all.flatMap(o => o.actions)) {
      const bucket = grouped.get(a.label) ?? [];
      bucket.push(a);
      grouped.set(a.label, bucket);
    }
    const mergedOwnerActions: ToastAction[] = [...grouped.values()].slice(0, 2).map(group =>
      group.length === 1
        ? group[0]
        : { ...group[0], run: () => Promise.all(group.map(a => a.run())) },
    );
    const actions = [...linkAction, ...mergedOwnerActions];
    notify({
      key,
      kind: "error",
      tone: info.tone,
      title: info.title,
      message: info.message,
      details: info.message !== raw ? raw : undefined,
      copy: raw,
      actions,
      // Closing a merged toast clears non-background errors everywhere they came from,
      // and latches background pollers quiet until recovery or explicit action.
      onDismiss: reason => {
        const current = owners.get(next);
        owners.delete(next);
        current?.forEach(o => {
          if (reason === "action") {
            o.suppress(null);
            if (!o.background) o.onDismiss?.();
          } else if (o.background) {
            o.suppress(next);
          } else {
            o.onDismiss?.();
          }
        });
      },
    });
  });
  onCleanup(release);
  return null;
}

function ToastItem(p: { toast: Toast }) {
  const [copied, setCopied] = createSignal(false);
  const t = () => p.toast;
  createEffect(() => { t().copy; setCopied(false); });
  const pause = () => clearTimer(t().id);
  const resume = () => { if (t().timeout) startTimer(t().id, t().timeout!); };
  const copy = async () => {
    try { await copyText(t().copy ?? ""); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* clipboard unavailable */ }
  };
  const runAction = (a: ToastAction) => {
    const ownersSnapshot = owners.get(t().key);
    const list = ownersSnapshot ? [...ownersSnapshot.values()] : [];
    if (a.dismiss !== false) close(t(), "action");
    const result = a.run();
    if (a.dismiss !== false && list.some(o => o.background)) {
      void Promise.resolve(result).finally(() => list.forEach(o => { if (o.background) o.rebump(); }));
    }
  };
  const content = t().content;
  if (content) return <div class={`toast ${t().kind} custom${t().variant ? ` ${t().variant}` : ""}`} role="status">{content()}</div>;
  return <div class={`toast ${t().kind}${t().tone === "warning" ? " warning" : ""}${t().variant ? ` ${t().variant}` : ""}`} role={t().kind === "error" ? "alert" : "status"} onMouseEnter={pause} onMouseLeave={resume} onFocusIn={pause} onFocusOut={resume}>
    <Show when={t().kind === "error"}>
      <svg class="toast-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" aria-hidden="true"><circle cx="8" cy="8" r="6" /><path d="M8 4.5v4M8 10.5v1" /></svg>
    </Show>
    <Show when={t().kind !== "error" && t().icon}><span class="toast-glyph" aria-hidden="true">{t().icon}</span></Show>
    <div class="toast-body">
      <span class="toast-title">{t().title}</span>
      <Show when={t().message}><span class="toast-message">{t().message}</span></Show>
      <Show when={t().actions?.some(a => a.link)}>
        <div class="toast-links">
          <For each={t().actions?.filter(a => a.link)}>{a => <button type="button" class="toast-link" onClick={() => runAction(a)}>{a.label}</button>}</For>
        </div>
      </Show>
      <Show when={t().details}>
        <details class="toast-details"><summary>Technical details</summary><pre>{t().details}</pre></details>
      </Show>
    </div>
    <div class="toast-actions">
      <For each={t().actions?.filter(a => !a.link)}>{a => <button type="button" class={a.primary ? "toast-btn primary" : "toast-btn"} onClick={() => runAction(a)}>{a.label}<Show when={a.kbd}><kbd>{a.kbd}</kbd></Show></button>}</For>
    </div>
    <Show when={t().copy}>
      <button type="button" class="icon-btn toast-icon-btn" aria-label={copied() ? "Error copied" : "Copy error"} title={copied() ? "Copied" : "Copy error"} onClick={() => void copy()}>
        <Show when={copied()} fallback={<CopyIcon size={13} />}><CheckIcon size={13} /></Show>
      </button>
    </Show>
    <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={() => close(t(), "dismiss")}><CloseIcon size={13} /></button>
  </div>;
}

/** Mount once at the app root. Centered across all active workspace panels; never covers a bottom composer or save bar. */
export function Toaster() {
  toasterMounted = true;
  onCleanup(() => { toasterMounted = false; });
  const [pos, setPos] = createSignal<{ bottom: number; left: string; width?: number }>({ bottom: 20, left: "50%" });
  const place = () => {
    const rects = (sel: string) =>
      [...document.querySelectorAll(sel)]
        .map(el => el.getBoundingClientRect())
        .filter(r => r.height > 0 && r.width > 0 && r.top < window.innerHeight && r.bottom > 0 && r.left < window.innerWidth && r.right > 0);
    const panes = rects(".main, .file-panel, .btw-sidebar");
    if (!panes.length) return setPos({ bottom: 20, left: "50%" });
    const wsLeft = Math.max(0, Math.min(...panes.map(r => r.left)));
    const wsRight = Math.min(window.innerWidth, Math.max(...panes.map(r => r.right)));
    const wsWidth = Math.max(0, wsRight - wsLeft);
    const center = wsLeft + wsWidth / 2;
    const pad = wsWidth < 520 ? 32 : 48;
    const width = Math.min(580, Math.max(0, wsWidth - pad)) || undefined;
    const half = (width ?? Math.min(580, Math.max(0, window.innerWidth - 32))) / 2;
    const toastLeft = center - half;
    const toastRight = center + half;
    const bars = rects(".dock .composer, .composer, .btw-composer-dock, .cs-savebar")
      .filter(r => r.right > toastLeft && r.left < toastRight && window.innerHeight - r.bottom < 120 && r.top > window.innerHeight * 0.35);
    const bottom = bars.length
      ? Math.max(20, ...bars.map(r => Math.round(window.innerHeight - r.top + 12)))
      : 20;
    setPos({ bottom, left: `${Math.round(center)}px`, width: width ? Math.round(width) : undefined });
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
      if (e.key !== "Escape" || !toasts().length || hasInteractiveOverlay()) return;
      const active = document.activeElement;
      if (active && active !== document.body && !active.closest(".toaster")) return;
      close(toasts()[toasts().length - 1], "dismiss");
    };
    window.addEventListener("resize", place);
    window.addEventListener("keydown", onKey);
    onCleanup(() => { window.removeEventListener("resize", place); window.removeEventListener("keydown", onKey); });
  });
  return <Show when={toasts().length}>
    <div class="toaster" classList={{ fit: !!pos().width }} style={{ bottom: `${pos().bottom}px`, left: pos().left, ...(pos().width ? { width: `${pos().width}px`, "max-width": "calc(100vw - 32px)" } : {}) }}>
      <For each={toasts()}>{t => <ToastItem toast={t} />}</For>
    </div>
  </Show>;
}
