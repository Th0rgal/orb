import { For, Show, createSignal, type JSX } from "solid-js";
import { isConnected } from "./api";
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
