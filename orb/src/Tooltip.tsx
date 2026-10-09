import { createEffect, createSignal, onCleanup, onMount, Show, type JSX } from "solid-js";
import { Popover } from "./Popover";
import { hasInteractiveOverlay, hasOverlay } from "./overlayLayer";

/** Delayed, non-interactive details; pending and visible tips share dismissal. */
export function useTooltip<T>(id: string, render: (value: T) => JSX.Element) {
  const [tip, setTip] = createSignal<{value: T; anchor: HTMLElement}>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let owner: HTMLElement | undefined;
  const hide = () => {
    clearTimeout(timer); timer = undefined;
    owner?.removeAttribute("aria-describedby"); owner = undefined;
    setTip(undefined);
  };
  const show = (value: T, anchor: HTMLElement) => {
    hide(); owner = anchor;
    timer = setTimeout(() => {
      timer = undefined;
      if (owner !== anchor || !anchor.isConnected || hasInteractiveOverlay()) return;
      anchor.setAttribute("aria-describedby", id); setTip({value, anchor});
    }, 480);
  };
  // A delayed row hint must not appear above a newly opened menu or modal.
  createEffect(() => { if (hasInteractiveOverlay()) hide(); });
  onMount(() => {
    const dismiss = (event: Event) => {
      if (event.type === "keydown" && ((event as KeyboardEvent).isComposing || (event as KeyboardEvent).key !== "Escape")) return;
      // Visible surfaces own Escape through the layer stack, including this tip.
      if (event.type === "keydown" && hasOverlay()) return;
      if (event.type === "keydown" && (timer || tip())) {event.preventDefault(); event.stopImmediatePropagation();}
      hide();
    };
    for (const type of ["scroll", "resize", "keydown", "pointerdown"]) window.addEventListener(type, dismiss, true);
    onCleanup(() => {for (const type of ["scroll", "resize", "keydown", "pointerdown"]) window.removeEventListener(type, dismiss, true); hide();});
  });
  return {
    bind: (value: T) => ({
      onPointerEnter: (event: {currentTarget: HTMLElement}) => show(value, event.currentTarget),
      onPointerLeave: hide, onPointerDown: hide, onBlur: hide,
      onFocus: (event: {currentTarget: HTMLElement}) => {
        if (event.currentTarget.matches(":focus-visible") && !event.currentTarget.closest('[data-pointer-focus="true"]')) show(value, event.currentTarget);
      },
    }),
    surface: <Show when={tip()}>{current => <Popover id={id} label="Details" role="tooltip" class="row-tip" anchor={current().anchor} width={280} placement="right-start" trap={false} restoreFocus={false} onClose={hide}>{render(current().value)}</Popover>}</Show>,
  };
}
