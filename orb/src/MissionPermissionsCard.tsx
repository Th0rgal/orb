import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { ApprovalCancelled } from "./deviceApproval";
import { FingerprintIcon } from "./approvalIcons";
import { ErrorToast } from "./toast";
import { SettingsCard, SettingsRow } from "./SettingsCard";
import { pollWhileVisible } from "./poll";
import { useNow } from "./time";
import {
  approvePrivilegeAccess,
  denyPrivilegeAccess,
  emptyPrivilegeSnapshot,
  getPrivilegeAccess,
  grantMissionPrivilegeAccess,
  lifetimeLabel,
  livePrivilegeGrant,
  requestTitle,
  revokePrivilegeAccess,
  scopeUnlocks,
  type PrivilegeScope,
  type PrivilegeSnapshot,
} from "./privilegeAccessApi";

const DURATIONS = [
  { label: "1 hour", minutes: 60 },
  { label: "4 hours", minutes: 240 },
  { label: "8 hours", minutes: 480 },
  { label: "24 hours", minutes: 1440 },
] as const;

function remaining(raw: string | null | undefined, now: number): string {
  const ms = raw ? Date.parse(raw) - now : NaN;
  if (!Number.isFinite(ms) || ms <= 0) return "expired";
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  return h > 0 ? `${h} h ${m} min left` : `${m} min left`;
}

/** Per-mission hardware-signed privileged leases: grant critical access to one mission without unlocking the whole project. */
export function MissionPermissionsCard(p: { missionId: string }) {
  const [snap, setSnap] = createSignal<PrivilegeSnapshot>(emptyPrivilegeSnapshot());
  const [scope, setScope] = createSignal<PrivilegeScope>("service_deploy");
  const [targetHost, setTargetHost] = createSignal("self");
  const [ttlMinutes, setTtlMinutes] = createSignal<number>(240);
  const [busy, setBusy] = createSignal<string | null>(null);
  const [err, setErr] = createSignal<string | null>(null);
  const now = useNow(1000);

  const load = async () => {
    try { setSnap(await getPrivilegeAccess()); }
    catch { /* non-admin or offline: hide silently until actionable */ }
  };

  onMount(() => {
    void load();
    const onAns = () => void load();
    window.addEventListener("orb:privilege-access-answered", onAns);
    onCleanup(() => window.removeEventListener("orb:privilege-access-answered", onAns));
    onCleanup(pollWhileVisible(load, 8000, "missionPermissions.load"));
  });

  const mine = createMemo(() => snap().requests.filter((r) => r.requester_mission_id === p.missionId));
  const pending = createMemo(() => mine().filter((r) => r.state === "pending"));
  const active = createMemo(() => mine().filter((r) => livePrivilegeGrant(r, now())));

  const run = async (id: string, job: () => Promise<unknown>) => {
    if (busy()) return;
    setBusy(id);
    setErr(null);
    try {
      await job();
      await load();
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <SettingsCard
      title="Mission permissions"
      hint="Grant time-bounded critical access strictly to this mission with one fingerprint confirmation, without unlocking other missions in the project."
    >
      <For each={pending()}>
        {(r) => (
          <SettingsRow
            title={requestTitle(r)}
            desc={`${scopeUnlocks(r)} · ${lifetimeLabel(r)}${r.reason ? ` — ${r.reason}` : ""}`}
          >
            <div style={{ display: "flex", gap: "6px" }}>
              <button type="button" class="s-btn" disabled={busy() !== null} onClick={() => void run(r.id, () => denyPrivilegeAccess(r))}>
                Deny
              </button>
              <button type="button" class="s-btn primary" disabled={busy() !== null} onClick={() => void run(r.id, () => approvePrivilegeAccess(r))}>
                <FingerprintIcon /> {busy() === r.id ? "Signing…" : "Approve"}
              </button>
            </div>
          </SettingsRow>
        )}
      </For>

      <For each={active()}>
        {(r) => (
          <SettingsRow
            title={requestTitle(r)}
            desc={`${scopeUnlocks(r)} · ${remaining(r.expires_at, now())}`}
          >
            <button type="button" class="s-btn" disabled={busy() !== null} onClick={() => void run(r.id, () => revokePrivilegeAccess(r.id))}>
              {busy() === r.id ? "Revoking…" : "Revoke"}
            </button>
          </SettingsRow>
        )}
      </For>

      <SettingsRow
        title="Pre-authorize this mission"
        desc="Sign once to let this mission run matching critical operations unattended until expiry."
      >
        <form
          style={{ display: "flex", "flex-wrap": "wrap", gap: "6px", "align-items": "center" }}
          onSubmit={(e) => {
            e.preventDefault();
            void run("grant", () =>
              grantMissionPrivilegeAccess({
                missionId: p.missionId,
                scope: scope(),
                targetHost: targetHost(),
                ttlMinutes: ttlMinutes(),
              }),
            );
          }}
        >
          <select
            aria-label="Permission scope"
            class="s-input"
            value={scope()}
            disabled={busy() !== null}
            onChange={(e) => setScope(e.currentTarget.value as PrivilegeScope)}
          >
            <option value="ops_read">Read-only ops</option>
            <option value="service_deploy">Service deploy</option>
            <option value="root_exec">Root exec</option>
          </select>
          <input
            aria-label="Target host"
            class="s-input"
            style={{ width: "120px" }}
            placeholder="self, agent-core…"
            value={targetHost()}
            disabled={busy() !== null}
            onInput={(e) => setTargetHost(e.currentTarget.value)}
          />
          <select
            aria-label="Lease duration"
            class="s-input"
            value={String(ttlMinutes())}
            disabled={busy() !== null}
            onChange={(e) => setTtlMinutes(Number(e.currentTarget.value) || 240)}
          >
            <For each={DURATIONS}>{(d) => <option value={String(d.minutes)}>{d.label}</option>}</For>
          </select>
          <button type="submit" class="s-btn primary" disabled={busy() !== null}>
            <FingerprintIcon /> {busy() === "grant" ? "Signing…" : "Grant"}
          </button>
        </form>
      </SettingsRow>

      <Show when={err()}>
        <ErrorToast error={err()} title="Permission grant failed" onDismiss={() => setErr(null)} />
      </Show>
    </SettingsCard>
  );
}
