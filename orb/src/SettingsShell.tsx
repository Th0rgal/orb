import { For, Show, createResource, createSignal, type JSX } from "solid-js";
import { connectionVersion, getAllProviderUsage, isConnected, listProviders } from "./api";
import { usageChips } from "./providerUsage";
import { settingsPageId, settingsSectionFor } from "./settingsNav";
import { ErrorToast } from "./toast";
import { ApprovalDevicesPanel } from "./ApprovalDevicesPanel";
import { PrivilegeAccessPanel } from "./PrivilegeAccessPanel";
import { MissionAccessPanel } from "./MissionAccessPanel";

/** Page chrome for a settings section: title, one-line subtitle and tabs.
 * The panel inside keeps its own markup; CSS folds its scroll box and title
 * into this page. */
export function SettingsShell(p: { page: string; onOpen: (id: string) => void; children: JSX.Element }) {
  const section = () => settingsSectionFor(p.page)!;
  const current = () => settingsPageId(p.page);
  const tabs: HTMLButtonElement[] = [];
  const onKey = (e: KeyboardEvent) => {
    const list = section().tabs;
    const i = list.findIndex(t => t.id === current());
    const next = e.key === "ArrowRight" ? i + 1 : e.key === "ArrowLeft" ? i - 1 : e.key === "Home" ? 0 : e.key === "End" ? list.length - 1 : null;
    if (next == null) return;
    e.preventDefault();
    const j = (next + list.length) % list.length;
    p.onOpen(list[j].id);
    queueMicrotask(() => tabs[j]?.focus());
  };
  return (
    <div class="s-body settings-body settings-page" aria-label={`${section().label} settings`}>
      <div class="s-inner">
        <h2>{section().label}</h2>
        <p class="s-lead settings-subtitle">{section().subtitle}</p>
        <Show when={section().id === "models"}><QuotaStrip /></Show>
        <Show when={section().tabs.length > 1}>
          <div class="settings-tabs" role="tablist" aria-label={section().label} onKeyDown={onKey}>
            <For each={section().tabs}>{(t, i) =>
              <button ref={el => (tabs[i()] = el)} role="tab" id={`settings-tab-${t.id}`} aria-selected={t.id === current()} tabIndex={t.id === current() ? 0 : -1}
                class={`settings-tab ${t.id === current() ? "active" : ""}`} onClick={() => p.onOpen(t.id)}>{t.label}</button>
            }</For>
          </div>
        </Show>
        <div class="settings-page-content" role={section().tabs.length > 1 ? "tabpanel" : undefined} aria-labelledby={section().tabs.length > 1 ? `settings-tab-${current()}` : undefined}>
          {p.children}
        </div>
      </div>
    </div>
  );
}

/** Per-provider quota bars above the Models tabs; Details has the history. */
function QuotaStrip() {
  const [rows] = createResource(() => (isConnected() ? connectionVersion() + 1 : 0), async (v) => {
    if (!v) return [];
    const [providers, usage] = await Promise.all([listProviders(), getAllProviderUsage()]);
    return providers.map(a => ({ name: a.name, chips: usage[a.id] ? usageChips(usage[a.id]) : [] })).filter(r => r.chips.length);
  });
  return (
    <section class="quota-strip" aria-label="Quotas" aria-busy={rows.loading}>
      <Show when={!rows.loading} fallback={<div class="quota-strip-row"><span class="spend-skel quota-strip-skel" /></div>}>
        <Show when={rows()?.length} fallback={<div class="quota-strip-row quota-strip-empty">{rows.error ? "Couldn’t load quotas." : "No provider reports a quota."}</div>}>
          <For each={rows()}>{r =>
            <div class="quota-strip-row">
              <span class="quota-strip-name" title={r.name}>{r.name}</span>
              <For each={r.chips}>{c =>
                <span class={`quota-strip-chip ${c.level}`} title={c.detail ?? `${c.label}: ${Math.round(c.used * 100)}% used`}>
                  <span class="quota-strip-label">{c.label === "7d" ? "Weekly" : c.label}</span>
                  <span class="p-bar"><span class="p-bar-fill" style={{ width: `${Math.min(100, Math.round(c.used * 100))}%` }} /></span>
                </span>
              }</For>
            </div>
          }</For>
        </Show>
      </Show>
    </section>
  );
}

/** Security → Access: approval devices, Fleet Bunker Mode and privileged access. */
export function SecuritySettings() {
  const [error, setError] = createSignal("");
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <ErrorToast error={error()} title="Security" onDismiss={() => setError("")} />
        <Show when={isConnected()} fallback={<p class="s-lead">Connect to Core on the Account page to manage approvals and access.</p>}>
          <ApprovalDevicesPanel onError={setError} />
          <PrivilegeAccessPanel onError={setError} />
          <MissionAccessPanel onError={setError} />
        </Show>
      </div>
    </div>
  );
}
