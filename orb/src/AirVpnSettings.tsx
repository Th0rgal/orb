import { createResource, createSignal, Show } from "solid-js";
import { api, connectionVersion } from "./api";
import { SettingsCard, SettingsRow } from "./SettingsCard";

interface AirVpnStatus {
  api_key_configured: boolean;
  devices: string[];
}

const path = "/api/settings/airvpn";

export function AirVpnSettings() {
  return <Show when={String(connectionVersion())} keyed>{(_connection) => <AirVpnForm />}</Show>;
}

function AirVpnForm() {
  const [status, { refetch }] = createResource(() => api<AirVpnStatus>(path));
  const [saving, setSaving] = createSignal(false);
  const [message, setMessage] = createSignal("");
  let key!: HTMLInputElement;
  let device!: HTMLInputElement;
  let profile!: HTMLInputElement;

  async function save(kind: "key" | "device") {
    if (saving()) return;
    const version = connectionVersion();
    setSaving(true);
    setMessage("");
    try {
      let body: Record<string, string>;
      if (kind === "key") {
        if (!key.reportValidity()) return;
        body = { api_key: key.value };
      } else {
        if (!device.reportValidity() || !profile.reportValidity()) return;
        const file = profile.files?.[0];
        if (!file || file.size > 30_000) throw new Error("Choose a WireGuard profile under 30 KB.");
        body = { device_id: device.value, profile: await file.text() };
      }
      if (connectionVersion() !== version) return;
      await api(path, { method: "PUT", body: JSON.stringify(body) });
      if (connectionVersion() !== version) return;
      if (kind === "key") key.value = "";
      else profile.value = "";
      setMessage(kind === "key" ? "API key saved." : "Device profile saved.");
      await refetch();
    } catch (e) {
      if (connectionVersion() === version) setMessage(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  async function checkSessions() {
    if (saving()) return;
    setSaving(true);
    try {
      const result = await api<{ active_sessions: number }>(path, { method: "POST" });
      setMessage(`AirVPN reports ${result.active_sessions} active sessions.`);
    } catch (e) {
      setMessage(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return <SettingsCard title="AirVPN">
    <Show when={!status.error} fallback={<SettingsRow title="Couldn’t load AirVPN settings">
      <button class="s-btn" onClick={() => void refetch()}>Retry</button>
    </SettingsRow>}>
      <SettingsRow title="API key" desc={status()?.api_key_configured ? "Configured" : "Generate a key in AirVPN’s Client Area → API. Orb uses it to check active sessions."}>
        <input ref={key} class="s-input" type="password" aria-label="AirVPN API key"
          autocomplete="new-password" required maxlength={512} />
        <button class="s-btn" disabled={saving()} onClick={() => void save("key")}>Save key</button>
        <Show when={status()?.api_key_configured}>
          <button class="s-btn" disabled={saving()} onClick={() => void checkSessions()}>Test saved key</button>
        </Show>
      </SettingsRow>
      <SettingsRow title="WireGuard device profile" desc={status()?.devices.length ? status()!.devices.join(", ") : "In AirVPN’s Config Generator, select an Orb device, WireGuard, and one named server. Import the downloaded .conf file."} stack>
        <input ref={device} class="s-input" aria-label="Device name" placeholder="Device name"
          required pattern="[a-z0-9\-]{1,64}" maxlength={64} />
        <input ref={profile} type="file" aria-label="WireGuard profile" accept=".conf" required />
        <button class="s-btn" disabled={saving()} onClick={() => void save("device")}>Import profile</button>
      </SettingsRow>
    </Show>
    <Show when={message()}><SettingsRow title={message()} status /></Show>
  </SettingsCard>;
}
