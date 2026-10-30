import { Show, type JSX } from "solid-js";

/** Shared Settings section card (`<section class="s-sec">…<div class="s-card">`).
 *  Compose with `SettingsRow` so every settings page shares identical spacing,
 *  typography, control column alignment, and mobile wrapping. */
export function SettingsCard(p: { title?: string; hint?: JSX.Element; class?: string; children: JSX.Element }) {
  return (
    <section class={`s-sec${p.class ? ` ${p.class}` : ""}`}>
      <Show when={p.title}>
        <h3>{p.title}</h3>
      </Show>
      <Show when={p.hint}>
        <p class="cs-hint">{p.hint}</p>
      </Show>
      <div class="s-card">{p.children}</div>
    </section>
  );
}

/** Shared row inside `SettingsCard`: flexible title/description on the left,
 *  right-aligned control slot (`.s-row-ctrl`) on the right. */
export function SettingsRow(p: {
  title: JSX.Element;
  desc?: JSX.Element;
  status?: boolean;
  stack?: boolean;
  children?: JSX.Element;
}) {
  return (
    <div class={`s-row${p.stack ? " cs-stack" : ""}`}>
      <div class="s-row-text">
        <div class="s-row-title">{p.title}</div>
        <Show when={p.desc}>
          <div class="s-row-desc" role={p.status ? "status" : undefined}>{p.desc}</div>
        </Show>
      </div>
      <Show when={p.children !== undefined}>
        <div class="s-row-ctrl">{p.children}</div>
      </Show>
    </div>
  );
}
