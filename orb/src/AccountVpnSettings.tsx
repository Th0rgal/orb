import { Show, createResource, createSignal } from "solid-js";
import { api, connectionVersion } from "./api";
import { SettingsRow } from "./SettingsCard";

interface Route {
  mode: "direct" | "vpn";
  country?: string;
  countries: string[];
  can_configure: boolean;
  status: "direct" | "verified" | "blocked";
  server?: string;
  exits?: string[];
  message?: string;
}

export function AccountVpnSettings(p: { account: string }) {
  const source = () => [connectionVersion(), p.account] as const;
  const uri = (id: string) => `/api/ai/providers/${encodeURIComponent(id)}/vpn`;
  const [route, { mutate, refetch }] = createResource(source, ([, id]) => api<Route>(uri(id)));
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const save = async (value: string) => {
    const [version, id] = source();
    const current = () => version === connectionVersion() && id === p.account;
    setBusy(true);
    setError("");
    try {
      const result = await api<Route>(uri(id), { method: "PUT", body: JSON.stringify(
        value ? { mode: "vpn", country: value } : { mode: "direct" }
      ) });
      if (current()) mutate(result);
    } catch (e) {
      if (current()) setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  return <SettingsRow title="Account connection" stack>
    <Show when={!route.error} fallback={<button class="s-btn" onClick={() => void refetch()}>Retry connection settings</button>}>
      <Show when={route()}>{r => <>
        <select class="s-input" aria-label="Account connection" disabled={busy() || !r().can_configure}
          value={r().country ?? ""} onChange={e => {
            const selected = e.currentTarget.value;
            e.currentTarget.value = r().country ?? "";
            void save(selected);
          }}>
          <option value="">Direct</option>
          {Array.from(new Set([...(r().country ? [r().country!] : []), ...r().countries])).map(c =>
            <option value={c}>AirVPN · {c}</option>)}
        </select>
        <Show when={!r().can_configure}><span>This credential’s connection is managed by the sidecar.</span></Show>
        <Show when={r().can_configure && !r().countries.length}><span>Import a named server profile in AirVPN Settings to enable VPN routing.</span></Show>
        <Show when={r().status === "verified"}><span>Verified exit · {r().server} · {r().exits?.join(", ")}</span></Show>
        <Show when={r().status === "blocked"}>
          <span role="status">{r().message ?? "The VPN route is unavailable."}</span>
          <button class="s-btn" disabled={busy() || !r().can_configure} onClick={() => void save(r().country!)}>Retry verification</button>
        </Show>
      </>}</Show>
    </Show>
    <Show when={error()}><span role="alert">{error()}</span></Show>
  </SettingsRow>;
}
