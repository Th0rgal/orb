import { Show, createEffect, createResource, createSignal, onCleanup } from "solid-js";
import { api, connectionVersion } from "./api";
import { pollWhileVisible } from "./poll";
import { SettingsRow } from "./SettingsCard";

interface Route {
  mode: "direct" | "vpn";
  country?: string;
  countries: string[];
  can_configure: boolean;
  configuration_message?: string;
  status: "direct" | "verified" | "blocked";
  reason?: string;
  server?: string;
  exits?: string[];
  message?: string;
}

export function AccountVpnSettings(p: { account: string }) {
  const source = () => [connectionVersion(), p.account] as const;
  const uri = (id: string) => `/api/ai/providers/${encodeURIComponent(id)}/vpn`;
  async function readRoute(id: string, options?: RequestInit) {
    const result = await api<Route>(uri(id), options);
    if (!result || !["vpn", "direct"].includes(result.mode) || !Array.isArray(result.countries))
      throw new Error("Account connection settings are unavailable.");
    return result;
  }
  const [route, { mutate, refetch }] = createResource(source, ([, id]) => readRoute(id));
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  createEffect(() => {
    if (busy() || route.state !== "ready") return;
    const interval = route().reason === "vpn_awaiting_verification" ? 5000 : null;
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
      const result = await readRoute(id, { method: "PUT", body: JSON.stringify(
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
      <Show when={route()}>{r => <div class="p-native-controls">
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
        <Show when={!r().can_configure}><span>{r().configuration_message ?? "VPN routing is unavailable for this credential."}</span>
          <button class="s-btn" disabled={route.loading} onClick={() => void refetch()}>Refresh connection settings</button></Show>
        <Show when={r().can_configure && !r().countries.length}><span>Import a named server profile in AirVPN Settings to enable VPN routing.</span></Show>
        <Show when={r().status === "verified"}><span class="s-row-desc" role="status">Verified exit · {r().server} · {r().exits?.join(", ")}</span></Show>
        <Show when={r().status === "blocked"}>
          <span role="status">{r().message ?? "The VPN route is unavailable."}</span>
          <Show when={r().reason !== "vpn_awaiting_verification"}>
            <button class="s-btn" disabled={busy() || !r().can_configure} onClick={() => void save(r().country!)}>Retry verification</button>
          </Show>
        </Show>
      </div>}</Show>
    </Show>
    <Show when={error()}><span role="alert">{error()}</span></Show>
  </SettingsRow>;
}
