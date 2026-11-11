import { render } from "solid-js/web";
import { For, Show, createContext, createEffect, createSignal, onCleanup, onMount, useContext, type Accessor, type JSX } from "solid-js";
import { copyText } from "./clipboard";
import { describeError } from "./ErrorNotice";
import { CheckIcon, CloseIcon, CopyIcon } from "./icons";
import { swallow } from "./log";
import { hasInteractiveOverlay, SlotActiveContext } from "./overlayLayer";

/**
 * Unified floating bottom notifications across all active workspace panels
 * (excluding the left navigation sidebar): connection/reachability, page/panel
 * load & refresh, failed actions, undoable changes, and biometric approvals.
 * Inline ErrorNotice stays only inside active modals/popovers or persisted
 * historical timeline turns/ticks.
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
type Owner = {
  onDismiss?: () => void;
  actions: ToastAction[];
  background?: boolean;
  suppress: (key: string | null) => void;
  rebump: () => void;
};
const owners = new Map<string, Map<symbol, Owner>>();

export { SlotActiveContext };

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
  active?: boolean;
  title?: string;
  backend?: string | null;
  background?: boolean;
  onDismiss?: () => void;
  action?: ToastAction;
  actions?: ToastAction[];
}) {
  const slotActive = useContext(SlotActiveContext);
  const me = Symbol();
  const [suppressed, setSuppressed] = createSignal<string | null>(null);
  const [bump, setBump] = createSignal(0);
  let key: string | undefined;
  let releasing = false;
  const release = () => {
    if (key === undefined) return;
    const prevKey = key;
    key = undefined;
    const map = owners.get(prevKey);
    map?.delete(me);
    if (map && !map.size) {
      owners.delete(prevKey);
      dismissToast(prevKey);
    } else if (map && map.size && !releasing) {
      releasing = true;
      try {
        [...map.values()][0]?.rebump();
      } finally {
        releasing = false;
      }
    }
  };
  createEffect(() => {
    bump();
    const visible = slotActive() && p.active !== false;
    const raw = p.error;
    if (!raw) {
      setSuppressed(null);
      return release();
    }
    if (!visible) return release();
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
      onDismiss: () => {
        const current = owners.get(next);
        owners.delete(next);
        current?.forEach(o => {
          if (o.background) o.suppress(next);
          else o.onDismiss?.();
        });
      },
    });
  });
  onCleanup(release);
  return null;
}

/**
 * Shows a non-error status or warning notice in the shared bottom Toaster
 * (`role="status"`). Closing or timing out invokes `onDismiss`.
 */
export function StatusToast(p: {
  message?: string | null | false;
  active?: boolean;
  detail?: string;
  tone?: "warning";
  icon?: JSX.Element;
  timeout?: number;
  onDismiss?: () => void;
  action?: ToastAction;
  actions?: ToastAction[];
}) {
  const slotActive = useContext(SlotActiveContext);
  const instance = nextId++;
  let key: string | undefined;
  const release = () => {
    if (key !== undefined) {
      const prevKey = key;
      key = undefined;
      dismissToast(prevKey);
    }
  };
  createEffect(() => {
    const visible = slotActive() && p.active !== false;
    const msg = p.message;
    if (!msg || !visible) return release();
    const next = `status:${instance}:${p.tone ?? "info"}:${msg}`;
    if (next !== key) release();
    key = next;
    const actions = [...(p.action ? [p.action] : []), ...(p.actions ?? [])];
    notify({
      key,
      kind: "info",
      tone: p.tone,
      icon: p.icon,
      title: msg,
      message: p.detail,
      actions: actions.length ? actions : undefined,
      timeout: p.timeout,
      onDismiss: () => {
        key = undefined;
        p.onDismiss?.();
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
    if (a.dismiss !== false) list.forEach(o => o.suppress(null));
    const result = a.run();
    if (a.dismiss !== false) {
      dismissToast(t().id);
      if (list.length) {
        void Promise.resolve(result).finally(() => list.forEach(o => o.rebump()));
      }
    }
  };
  const content = t().content;
  if (content) return <div class={`toast ${t().kind} custom${t().variant ? ` ${t().variant}` : ""}`} role="status">{content()}</div>;
  const showAlertIcon = () => t().kind === "error" || (t().tone === "warning" && !t().icon);
  return <div class={`toast ${t().kind}${t().tone === "warning" ? " warning" : ""}${t().variant ? ` ${t().variant}` : ""}`} role={t().kind === "error" ? "alert" : "status"} onMouseEnter={pause} onMouseLeave={resume} onFocusIn={pause} onFocusOut={resume}>
    <Show when={showAlertIcon()}>
      <svg class="toast-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" aria-hidden="true"><circle cx="8" cy="8" r="6" /><path d="M8 4.5v4M8 10.5v1" /></svg>
    </Show>
    <Show when={!showAlertIcon() && t().icon}><span class="toast-glyph" aria-hidden="true">{t().icon}</span></Show>
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
    <div class="toast-corner">
      <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={() => close(t())}><CloseIcon size={13} /></button>
      <Show when={t().copy}>
        <button type="button" class="icon-btn toast-icon-btn" aria-label={copied() ? "Error copied" : "Copy error"} title={copied() ? "Copied" : "Copy error"} onClick={() => void copy()}>
          <Show when={copied()} fallback={<CopyIcon size={13} />}><CheckIcon size={13} /></Show>
        </button>
      </Show>
    </div>
  </div>;
}

/**
 * Mount once at the app root. Centered across the active workspace panels
 * (excluding the left navigation sidebar): aligns flush with the centered
 * content column when a single panel is open, straddles the split when two
 * panels are open, and never covers a bottom composer or save bar.
 */
export function Toaster() {
  toasterMounted = true;
  onCleanup(() => { toasterMounted = false; });
  const [pos, setPos] = createSignal<{ bottom: number; left: string; width?: number }>({ bottom: 20, left: "50%" });
  const place = () => {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    if (vw <= 0) return setPos({ bottom: 20, left: "50%" });
    const rects = (sel: string) =>
      [...document.querySelectorAll(sel)]
        .map(el => el.getBoundingClientRect())
        .filter(r => r.height > 0 && r.width > 0 && r.top < vh && r.bottom > 0 && r.left < vw && r.right > 0);
    const panes = rects(".main, .file-panel, .btw-sidebar");
    let center: number;
    let width: number | undefined;
    if (!panes.length) {
      center = vw / 2;
      const pad = vw < 520 ? 32 : 48;
      width = Math.min(580, Math.max(0, vw - pad)) || undefined;
    } else {
      const wsLeft = Math.max(0, Math.min(...panes.map(r => r.left)));
      const wsRight = Math.min(vw, Math.max(...panes.map(r => r.right)));
      const wsWidth = Math.max(0, wsRight - wsLeft);
      const sideOpen = rects(".file-panel, .btw-sidebar").some(r => r.left > wsLeft + 24);
      if (sideOpen) {
        center = wsLeft + wsWidth / 2;
        const pad = wsWidth < 520 ? 32 : 48;
        width = Math.min(580, Math.max(0, wsWidth - pad)) || undefined;
      } else {
        const composer = rects(".dock .composer")[0];
        const colEl = rects(".main .col, .main .new-inner")[0];
        const inner = rects(".main .s-inner")[0];
        const col = composer ?? colEl ?? inner;
        if (col) {
          center = col.left + col.width / 2;
          const colInset = !composer && !colEl && inner
            ? (() => {
                const el = [...document.querySelectorAll<HTMLElement>(".main .s-inner")].find(e => e.getBoundingClientRect().width > 0);
                if (!el) return 40;
                const cs = getComputedStyle(el);
                return (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
              })()
            : 0;
          width = Math.min(748, Math.max(0, col.width - colInset)) || undefined;
        } else {
          center = wsLeft + wsWidth / 2;
          const pad = wsWidth < 520 ? 32 : 48;
          width = Math.min(640, Math.max(0, wsWidth - pad)) || undefined;
        }
      }
    }
    const half = (width ?? Math.min(580, Math.max(0, vw - 32))) / 2;
    const toastLeft = center - half;
    const toastRight = center + half;
    const bars = rects(".dock .composer, .composer, .btw-composer-dock, .cs-savebar")
      .filter(r => r.right > toastLeft && r.left < toastRight && vh - r.bottom < 120 && r.top > vh * 0.35);
    const bottom = bars.length
      ? Math.max(20, ...bars.map(r => Math.round(vh - r.top + 12)))
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
      close(toasts()[toasts().length - 1]);
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
