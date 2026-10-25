import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { ApprovalCancelled } from "./deviceApproval";
import * as Ic from "./icons";
import {
  approvePrivilegeAccess,
  denyPrivilegeAccess,
  emptyPrivilegeSnapshot,
  getPrivilegeAccess,
  hostLabel,
  lifetimeLabel,
  livePrivilegeGrant,
  requesterLabel,
  revokePrivilegeAccess,
  scopeLabel,
  scopeUnlocks,
  type PrivilegeSnapshot,
} from "./privilegeAccessApi";
import { pollWhileVisible } from "./poll";
import { FingerprintIcon } from "./secretRequestNotices";
import { ago, useNow } from "./time";

const POLL_MS = 5000;

function until(raw: string | null | undefined, now: number): string {
  const ms = raw ? Date.parse(raw) - now : NaN;
  if (!Number.isFinite(ms) || ms <= 0) return "expired";
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60000);
  return h > 0 ? `${h} h ${m} min left` : `${m} min left`;
}
const since = (raw?: string | null) => {
  const ts = raw ? Date.parse(raw) : NaN;
  return Number.isFinite(ts) ? ago(ts, Date.now(), { round: true, days: true }) : "";
};

/** Settings section: pending privileged requests, live grants (revoke), history and command audit. */
export function PrivilegeAccessPanel(p: { onError: (message: string) => void; initial?: PrivilegeSnapshot }) {
  const [snap, setSnap] = createSignal<PrivilegeSnapshot>(p.initial ?? emptyPrivilegeSnapshot());
  const [busy, setBusy] = createSignal<string | null>(null);
  const [showLog, setShowLog] = createSignal(false);
  const now = useNow(1000);
  const load = async () => {
    if (p.initial) return;
    try { setSnap(await getPrivilegeAccess()); } catch { /* the page reports connection errors */ }
  };
  onMount(() => {
    void load();
    onCleanup(pollWhileVisible(load, POLL_MS, "privilegeAccess.load"));
  });
  const pending = createMemo(() => snap().requests.filter((r) => r.state === "pending"));
  const grants = createMemo(() => snap().requests.filter((r) => livePrivilegeGrant(r, now())));
  const history = createMemo(() => snap().requests.filter((r) => r.state !== "pending" && !livePrivilegeGrant(r, now())).slice(0, 20));

  const run = async (id: string, job: () => Promise<unknown>) => {
    if (busy()) return;
    setBusy(id);
    try {
      await job();
      await load();
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) p.onError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <section class="s-sec bw-access" data-testid="privilege-access-settings">
      <div class="bw-section-head">
        <h3>Privileged access</h3>
        <span class="s-row-desc">
          Missions can ask for root, a service deploy or read-only ops on a host. A grant lasts at most the mission session, Core checks and logs every command, and you can revoke it at any time.
        </span>
      </div>
      <Show when={snap().bunker_state > 0}>
        <div class="bw-empty-line" role="status">Bunker Mode is on: new privileged requests are locked.</div>
      </Show>
      <Show when={pending().length > 0} fallback={<div class="bw-empty-line">No mission is waiting for privileged access.</div>}>
        <div class="bw-requests" role="region" aria-label="Pending privileged access requests">
          <For each={pending()}>
            {(r) => (
              <div class="secret-row bw-request-row" data-testid="privilege-access-request">
                <div class="bw-request-body">
                  <div class="bw-request-line">
                    <strong class="secret-row-key">{scopeLabel(r.scope)} on {hostLabel(r.target_host)}</strong>
                    <span class="bw-request-meta">{requesterLabel(r)} · {since(r.created_at)}</span>
                  </div>
                  <span class="secret-row-reason" title={r.reason}>{r.reason}</span>
                  <span class="s-row-desc">Allows {scopeUnlocks(r)} · {lifetimeLabel(r)}</span>
                </div>
                <button class="s-btn" disabled={!!busy()} onClick={() => void run(r.id, () => denyPrivilegeAccess(r))}>Deny</button>
                <button class="s-btn primary bw-request-ok" disabled={!!busy()} onClick={() => void run(r.id, () => approvePrivilegeAccess(r))}>
                  <FingerprintIcon size={14} />Allow
                </button>
              </div>
            )}
          </For>
        </div>
      </Show>
      <Show when={grants().length > 0}><h4 class="bw-subhead">Active grants</h4></Show>
      <div class="s-card">
        <For each={grants()}>
          {(g) => (
            <div class="s-row" data-testid="privilege-access-grant">
              <div class="s-row-text">
                <div class="s-row-title">{requesterLabel(g)} · {scopeLabel(g.scope)} on {hostLabel(g.target_host)}</div>
                <div class="s-row-desc">{g.session_scoped ? "Ends with the session" : "Fixed lifetime"} · {until(g.expires_at, now())}</div>
              </div>
              <div class="s-row-ctrl">
                <button class="s-btn" disabled={!!busy()} onClick={() => void run(g.id, () => revokePrivilegeAccess(g.id))}>Revoke</button>
              </div>
            </div>
          )}
        </For>
        <div class="s-row">
          <div class="s-row-text">
            <button type="button" class="bw-link-btn" onClick={() => setShowLog(!showLog())}>
              <Show when={showLog()} fallback={<Ic.ChevronRight size={11} />}><Ic.ChevronDown size={11} /></Show> {showLog() ? "Hide" : "Show"} activity ({snap().command_audit.length} commands)
            </button>
          </div>
        </div>
        <Show when={showLog()}>
          <div class="bw-log">
            <For each={history()}>
              {(r) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${r.state}`}>{r.state}</span>
                  <span>{requesterLabel(r)} · {scopeLabel(r.scope)} on {hostLabel(r.target_host)}</span>
                  <span class="s-row-desc">{since(r.revoked_at || r.decided_at || r.created_at)}</span>
                </div>
              )}
            </For>
            <For each={snap().command_audit.slice(0, 60)}>
              {(c) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${c.exit_code === 0 ? "approved" : c.exit_code == null ? "read" : "denied"}`}>{c.exit_code == null ? "run" : `exit ${c.exit_code}`}</span>
                  <span title={c.command}>{c.target_host} · {c.command}</span>
                  <span class="s-row-desc">{since(c.at)}</span>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </section>
  );
}
