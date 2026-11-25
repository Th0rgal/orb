import { Show, Suspense, createEffect, createResource, createSignal, onCleanup } from "solid-js";
import { api, connectionVersion } from "./api";
import { pollWhileVisible } from "./poll";
import { AccountSettingReadError } from "./AccountSettingReadError";
import { accountVpnRoute, accountVpnView, accountVpnWrite } from "./accountVpn";
import { Select } from "./Select";
import { SettingsRow } from "./SettingsCard";

export function AccountVpnSettings(p: { account: string; nativeAccount?: boolean }) {
  const source = () => [connectionVersion(), p.account] as const;
  const uri = (id: string) => `/api/ai/providers/${encodeURIComponent(id)}/vpn`;
  async function readRoute(id: string, options?: RequestInit) {
    const result = accountVpnRoute(await api<unknown>(uri(id), options));
    if (!result) throw new Error("Account connection settings are unavailable.");
    return result;
  }
  const [route, { mutate, refetch }] = createResource(source, ([, id]) => readRoute(id));
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  createEffect(() => {
    if (busy() || route.state !== "ready") return;
    const interval = accountVpnView(route(), !!p.nativeAccount).poll ? 5000 : null;
    const [, id] = source();
    let active = true;
    const stop = pollWhileVisible(async () => {
      const next = await readRoute(id);
      if (active) mutate(next);
    }, interval, "account-vpn");
    onCleanup(() => {
      active = false;
      stop();
    });
  });
  const save = async (value: string) => {
    const [version, id] = source();
    const current = () => version === connectionVersion() && id === p.account;
    setBusy(true);
    setError("");
    try {
      const result = await readRoute(id, { method: "PUT", body: JSON.stringify(accountVpnWrite(value)) });
      if (current()) mutate({ ...result, saved: true });
    } catch (e) {
      if (current()) setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  return <SettingsRow title="Account connection" desc="Route this account through AirVPN or connect directly.">
    <Suspense fallback={<span class="p-ctrl-skel" aria-hidden="true" />}>
      <Show when={!route.error} fallback={<AccountSettingReadError error={route.error} path={uri(p.account)}
        updateMessage="Update Core to configure account VPNs." retryLabel="Retry connection settings" retry={() => void refetch()} />}>
        <Show when={route()}>{r => { const v = () => accountVpnView(r(), !!p.nativeAccount); return <div class="p-vpn-ctrl">
          <div class="p-native-controls">
            <Select aria-label="Account connection" disabled={busy() || !v().editable}
              value={v().selected} onChange={e => {
                const selected = e.currentTarget.value;
                e.currentTarget.value = v().selected;
                void save(selected);
              }}>
              <option value="">Direct</option>
              {v().countries.map(c => <option value={c}>AirVPN · {c}</option>)}
            </Select>
            <Show when={v().confirmDirect}>
              <button class="s-btn" disabled={busy()} onClick={() => void save("")}>Confirm Direct route</button>
            </Show>
            <Show when={!v().editable}>
              <button class="s-btn" disabled={route.loading} onClick={() => void refetch()}>Refresh connection settings</button></Show>
            <Show when={v().retry}>
              <button class="s-btn" disabled={busy() || !v().editable} onClick={() => void save(v().selected)}>Retry verification</button>
            </Show>
          </div>
          <Show when={v().notice}><span class="s-row-desc">{v().notice}</span></Show>
          <Show when={v().status}>
            <span classList={{ "s-row-desc": r().status === "verified" }} role="status">{v().status}</span>
          </Show>
        </div>; }}</Show>
      </Show>
    </Suspense>
    <Show when={error()}><span role="alert">{error()}</span></Show>
  </SettingsRow>;
}
