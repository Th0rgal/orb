import { ErrorNotice } from "./ErrorNotice";
import { Show, createContext, createEffect, createSignal, createUniqueId, onCleanup, onMount, splitProps, useContext, type JSX } from "solid-js";
import { Portal } from "solid-js/web";
import { mountOverlay, OverlayContext, overlayFirstModal, overlayZIndex, overlayHasModalAbove, overlayTop, useOverlayParent, type OverlayLayer } from "./overlayLayer";
import { CloseIcon } from "./icons";
import "./Dialog.css";

// Embedded editors (such as persisted cron drafts) own the discard operation.
// Registering their guard keeps X, Escape, outside clicks and Cancel identical.
export const DialogCloseContext = createContext<(guard: () => void) => () => void>();

const DialogFooterContext = createContext<{ target: () => HTMLElement | undefined; register: () => () => void }>();

/** Keep reusable form actions in the modal footer, outside its scrolling body. */
export function DialogActions(p: {children: JSX.Element}) {
  const slot = useContext(DialogFooterContext);
  if (!slot) return p.children;
  onMount(() => onCleanup(slot.register()));
  return <Show when={slot.target()}>{target => <Portal mount={target()}>{p.children}</Portal>}</Show>;
}

export function Dialog(p: {
  title: string; description?: string; hint?: string;
  size?: "compact" | "standard" | "wide" | "fullscreen"; class?: string;
  busy?: boolean; dirty?: boolean; initialFocus?: () => HTMLElement | undefined;
  onClose: () => void; onKeyDown?: JSX.EventHandlerUnion<HTMLDivElement, KeyboardEvent>;
  children: JSX.Element; footer?: JSX.Element | ((requestClose: () => void) => JSX.Element);
}) {
  let root!: HTMLDivElement;
  const [discard, setDiscard] = createSignal(false);
  const [footerTarget, setFooterTarget] = createSignal<HTMLElement>();
  const [actionCount, setActionCount] = createSignal(0);
  const footerSlot = {target: footerTarget, register: () => {setActionCount(n => n + 1); return () => setActionCount(n => n - 1);}};
  const layer: OverlayLayer = {root: () => root, parent: useOverlayParent(), modal: true};
  const titleId = createUniqueId(), descriptionId = createUniqueId();
  let closeGuard: (() => void) | undefined;
  const registerClose = (guard: () => void) => {closeGuard = guard; return () => {if (closeGuard === guard) closeGuard = undefined;};};
  const requestClose = () => { if (!p.busy) closeGuard ? closeGuard() : p.dirty ? setDiscard(true) : p.onClose(); };
  createEffect(() => {if (p.busy && root && overlayTop(layer) && !root.contains(document.activeElement)) root.focus({preventScroll:true});});
  onMount(() => { onCleanup(mountOverlay(layer, {close: requestClose, busy: () => !!p.busy, outsideGesture: true,
    initialFocus: () => p.initialFocus?.() ?? root.querySelector<HTMLElement>("[autofocus], .dlg-body input:not(:disabled), .dlg-body textarea:not(:disabled)") ?? undefined})); });
  return <DialogFooterContext.Provider value={footerSlot}><DialogCloseContext.Provider value={registerClose}><OverlayContext.Provider value={layer}><Portal>
    <div class="dlg-back" classList={{"dlg-back-dim": overlayFirstModal(layer), "dlg-back-fullscreen": p.size === "fullscreen"}} style={{"z-index": overlayZIndex(layer)}}>
      <div ref={root} role="dialog" aria-modal="true" aria-labelledby={titleId} aria-describedby={p.description || p.hint ? descriptionId : undefined}
        aria-busy={p.busy || undefined} inert={overlayHasModalAbove(layer)} tabIndex={-1} onKeyDown={p.onKeyDown}
        class={`dlg dlg-${p.size ?? "standard"} ${p.class ?? ""}`}>
        <header class="dlg-head"><h3 id={titleId}>{p.title}</h3><button type="button" class="dlg-close" aria-label="Close" disabled={p.busy} onClick={requestClose}><CloseIcon size={16}/></button></header>
        <Show when={p.description || p.hint}><p class="dlg-description" id={descriptionId}>{p.description ?? p.hint}</p></Show>
        <div class="dlg-body">{p.children}</div>
        <Show when={p.footer || actionCount()}><footer ref={setFooterTarget} class="dlg-foot">{typeof p.footer === "function" ? p.footer(requestClose) : p.footer}</footer></Show>
      </div>
    </div>
  </Portal><Show when={discard()}><ConfirmDialog title="Discard unsaved changes?" description="Your changes have not been saved." action="Discard changes" destructive={false} cancelLabel="Keep editing" onConfirm={p.onClose} onClose={() => setDiscard(false)} /></Show></OverlayContext.Provider></DialogCloseContext.Provider></DialogFooterContext.Provider>;
}
export function DialogButton(p: JSX.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "destructive" }) {
  const [local, rest] = splitProps(p, ["variant", "class", "type", "onClick"]);
  return <button {...rest} type={local.type ?? "button"} class={`dlg-button dlg-button-${local.variant ?? "secondary"} ${local.class ?? ""}`} onClick={event => {
    // WebKit does not focus buttons on click. Preserve the opener for nested dialogs.
    event.currentTarget.focus({preventScroll: true});
    const handler = local.onClick;
    if (typeof handler === "function") handler(event);
    else if (handler) handler[0](handler[1], event);
  }} />;
}

/** A single-field form. Native submission keeps IME and textarea input local. */
export function NameDialog(p: {
  class?: string; title: string; description?: string; hint?: string; label?: string; placeholder?: string;
  value: string; onInput: (value: string) => void; action: string; onAction: () => void;
  onClose: () => void; busy?: boolean; disabled?: boolean; allowEmpty?: boolean; error?: string | null;
  children?: JSX.Element; footer?: JSX.Element;
}) {
  const formId = createUniqueId();
  const initial = p.value;
  let composing = false;
  return <Dialog size="compact" title={p.title} description={p.description ?? p.hint} class={p.class} busy={p.busy} dirty={p.value !== initial} onClose={p.onClose}
    footer={close => <>{p.footer}<DialogButton disabled={p.busy} onClick={close}>Cancel</DialogButton><DialogButton type="submit" form={formId} variant="primary" disabled={p.busy || p.disabled || (!p.allowEmpty && !p.value.trim())}>{p.busy ? "Working…" : p.action}</DialogButton></>}>
    <form id={formId} onSubmit={e => {e.preventDefault(); if (!composing && !p.busy && !p.disabled && (p.allowEmpty || p.value.trim())) p.onAction();}}
        onCompositionStart={() => {composing = true;}} onCompositionEnd={() => {composing = false;}}>
        <Field label={p.label ?? p.title} error={p.error}><input class="s-input" autofocus placeholder={p.placeholder} value={p.value} disabled={p.busy} onInput={e => p.onInput(e.currentTarget.value)}/></Field>
        {p.children}
      </form>
  </Dialog>;
}
export function ConfirmDialog(p: {
  title: string;
  description: string;
  action: string;
  cancelLabel?: string;
  destructive: boolean;
  busy?: boolean;
  error?: string | null;
  onConfirm: () => void;
  onClose: () => void;
}) {
  let cancel!: HTMLButtonElement;
  return <Dialog size="compact" title={p.title} description={p.description} busy={p.busy} onClose={p.onClose} initialFocus={() => cancel}
    footer={<>
      <DialogButton ref={cancel} disabled={p.busy} onClick={p.onClose}>{p.cancelLabel ?? "Cancel"}</DialogButton>
      <DialogButton variant={p.destructive ? "destructive" : "primary"} disabled={p.busy} onClick={() => { if (!p.busy) p.onConfirm(); }}>{p.busy ? "Working…" : p.action}</DialogButton>
    </>}>
    <Show when={p.error}><ErrorNotice error={p.error!} /></Show>
  </Dialog>;
}

export function Field(p: { label: string; description?: string; error?: string | null; children: JSX.Element }) {
  const id = createUniqueId(), descriptionId = `${id}-description`, errorId = `${id}-error`;
  let root!: HTMLDivElement;
  const attach = () => {
    const input = root.querySelector<HTMLElement>("input, textarea, select");
    if (!input) return;
    input.id ||= id;
    root.querySelector("label")!.htmlFor = input.id;
    const described = [p.description ? descriptionId : "", p.error ? errorId : ""].filter(Boolean).join(" ");
    if (described) input.setAttribute("aria-describedby", described); else input.removeAttribute("aria-describedby");
    if (p.error) input.setAttribute("aria-invalid", "true"); else input.removeAttribute("aria-invalid");
  };
  onMount(attach);
  createEffect(() => {p.description; p.error; if (root) attach();});
  return <div ref={root} class="field"><label for={id}>{p.label}</label>{p.children}<Show when={p.description}><span class="field-description" id={descriptionId}>{p.description}</span></Show><Show when={p.error}><span class="field-error" id={errorId} role="alert">{p.error}</span></Show></div>;
}
