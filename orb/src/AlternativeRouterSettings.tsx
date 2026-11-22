import { Show, createEffect, createResource, createSignal, onCleanup } from "solid-js";
import { api, connectionVersion } from "./api";
import { AccountSettingReadError } from "./AccountSettingReadError";
import { pollWhileVisible } from "./poll";
import { SettingsRow } from "./SettingsCard";
import { Toggle } from "./Toggle";

export function AlternativeRouterSettings(p: { account: string }) {
  const source = () => [connectionVersion(), p.account] as const;
  const uri = (id: string) => `/api/ai/providers/${encodeURIComponent(id)}/alternative-routers`;
  async function access(id: string, allowed?: boolean) {
    const settings = await api<{ allowed: boolean }>(uri(id),
      allowed === undefined ? undefined : {
        method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ allowed }),
      });
    if (typeof settings?.allowed !== "boolean") throw new Error("Router access is unavailable.");
    return settings;
  }
  const [setting, { mutate, refetch }] = createResource(source, ([, id]) => access(id));
  const [saving, setSaving] = createSignal(false);
  const [error, setError] = createSignal("");
  createEffect(() => {
    if (saving() || setting.state !== "ready") return;
    onCleanup(pollWhileVisible(async () => { await refetch(); }, null, "alternative-routers"));
  });
  async function save(allowed: boolean) {
    const [version, id] = source();
    const current = () => version === connectionVersion() && p.account === id;
    setSaving(true);
    setError("");
    try {
      const updated = await access(id, allowed);
      if (current()) mutate(updated);
    } catch {
      if (current()) {
        setError("Could not confirm the change. Check the current setting before retrying.");
        void refetch();
      }
    } finally {
      setSaving(false);
    }
  }
  return <SettingsRow title="Alternative routers" desc="Allow OpenCode and other routed clients to use this account.">
    <Show when={!setting.error} fallback={<AccountSettingReadError error={setting.error} path={uri(p.account)}
      updateMessage="Update Core to configure alternative router access." retryLabel="Retry router settings" retry={() => void refetch()} />}>
      <Show when={setting()}>{s =>
        <Toggle label="Allow alternative routers" on={s().allowed} disabled={saving() || setting.loading}
          onClick={() => void save(!s().allowed)} />
      }</Show>
    </Show>
    <Show when={error()}><span role="alert">{error()}</span></Show>
  </SettingsRow>;
}
