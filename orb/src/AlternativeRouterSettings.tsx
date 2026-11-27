import { Show, Suspense, createEffect, createResource, createSignal, onCleanup } from "solid-js";
import { api, connectionVersion } from "./api";
import { AccountSettingReadError } from "./AccountSettingReadError";
import { alternativeRouterAccess } from "./accountVpn";
import { pollWhileVisible } from "./poll";
import { SettingsRow } from "./SettingsCard";
import { Toggle } from "./Toggle";

export function AlternativeRouterSettings(p: { account: string }) {
  const source = () => [connectionVersion(), p.account] as const;
  const uri = (id: string) => `/api/ai/providers/${encodeURIComponent(id)}/alternative-routers`;
  async function access(id: string, allowed?: boolean) {
    const access = alternativeRouterAccess(await api<unknown>(uri(id),
      allowed === undefined ? undefined : {
        method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ allowed }),
      }));
    if (access === null) throw new Error("Router access is unavailable.");
    return { allowed: access };
  }
  const [setting, { mutate, refetch }] = createResource(source, ([, id]) => access(id));
  const [saving, setSaving] = createSignal(false);
  const [error, setError] = createSignal("");
  const [readError, setReadError] = createSignal<unknown>(null);
  createEffect(() => {
    source();
    setReadError(null);
    setError("");
  });
  createEffect(() => {
    if (saving() || readError() || setting.state !== "ready" || !setting()) return;
    const [, id] = source();
    let active = true;
    const stop = pollWhileVisible(async () => {
      try {
        const next = await access(id);
        if (active) {
          setReadError(null);
          mutate(next);
        }
      } catch (e) {
        if (active) {
          mutate(undefined);
          setReadError(e);
        }
      }
    }, null, "alternative-routers");
    onCleanup(() => {
      active = false;
      stop();
    });
  });
  const retryRead = () => {
    setReadError(null);
    setError("");
    void refetch();
  };
  async function save(allowed: boolean) {
    const [version, id] = source();
    const current = () => version === connectionVersion() && p.account === id;
    setSaving(true);
    setError("");
    try {
      const updated = await access(id, allowed);
      if (current()) {
        setReadError(null);
        mutate(updated);
      }
    } catch {
      if (current()) {
        try {
          const recovered = await access(id);
          if (current()) {
            setReadError(null);
            mutate(recovered);
            setError("Could not confirm the change. Check the current setting before retrying.");
          }
        } catch (re) {
          if (current()) {
            mutate(undefined);
            setError("");
            setReadError(re);
          }
        }
      }
    } finally {
      setSaving(false);
    }
  }
  const activeReadError = () => readError() ?? setting.error;
  return <SettingsRow title="Alternative routers" desc="Allow OpenCode and other routed clients to use this account.">
    <Suspense fallback={<span class="p-ctrl-skel p-ctrl-skel-toggle" aria-hidden="true" />}>
      <Show when={!activeReadError()} fallback={<AccountSettingReadError error={activeReadError()} path={uri(p.account)}
        updateMessage="Update Core to configure alternative router access." retryLabel="Retry router settings" retry={retryRead} />}>
        <Show when={setting()}>{s =>
          <Toggle label="Allow alternative routers" on={s().allowed} disabled={saving() || setting.loading}
            onClick={() => void save(!s().allowed)} />
        }</Show>
      </Show>
    </Suspense>
    <Show when={error()}><span role="alert">{error()}</span></Show>
  </SettingsRow>;
}
