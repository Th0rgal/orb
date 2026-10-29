import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { ApprovalCancelled } from "./deviceApproval";
import * as Ic from "./icons";
import {
  actorLabel,
  approveMissionAccess,
  denyMissionAccess,
  getMissionAccess,
  liveGrant,
  missionLabel,
  revokeMissionAccess,
  type MissionAccessAudit,
  type MissionAccessRequest,
  type MissionAccessSnapshot,
} from "./missionAccessApi";
import { pollWhileVisible } from "./poll";
import { EyeIcon, FingerprintIcon } from "./approvalIcons";
import { Select } from "./Select";
import { ago, useNow } from "./time";

const POLL_MS = 5000;
const LIFETIMES: [number, string][] = [[1, "1 h"], [8, "8 h"], [24, "24 h"], [72, "3 days"], [168, "7 days"]];

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

/** Settings section: pending requests, live grants (revoke), history and audit. */
export function MissionAccessPanel(p: { onError: (message: string) => void; initial?: MissionAccessSnapshot }) {
  const [snap, setSnap] = createSignal<MissionAccessSnapshot>(p.initial ?? { requests: [], audit: [] });
  const [busy, setBusy] = createSignal<string | null>(null);
  const [showLog, setShowLog] = createSignal(false);
  const now = useNow(1000);
  const load = async () => {
    if (p.initial) return;
    try { setSnap(await getMissionAccess()); } catch { /* the page reports connection errors */ }
  };
  onMount(() => {
    void load();
    onCleanup(pollWhileVisible(load, POLL_MS, "missionAccess.load"));
  });
  const pending = createMemo(() => snap().requests.filter((r) => r.state === "pending"));
  const grants = createMemo(() => snap().requests.filter((r) => liveGrant(r, now())));
  const history = createMemo(() => snap().requests.filter((r) => r.state !== "pending" && !liveGrant(r, now())).slice(0, 20));
  const who = (r: MissionAccessRequest) => actorLabel(r);
  const auditWho = (a: MissionAccessAudit) =>
    a.requester_mission_id ? a.requester_mission_id.slice(0, 8) : actorLabel(a);
  const target = (r: MissionAccessRequest) => missionLabel(r.target_title, r.target_mission_id);

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
    <section class="s-sec bw-access" data-testid="mission-access-settings">
      <div class="bw-section-head">
        <h3>Mission access grants</h3>
        <span class="s-row-desc">
          Missions can ask to read another mission (events, messages, shared files). Grants are read-only, never allow messages, cancel or resume, and expire.
        </span>
      </div>
      <Show when={pending().length > 0} fallback={<div class="bw-empty-line">No mission is waiting for access.</div>}>
        <div class="bw-requests" role="region" aria-label="Pending mission access requests">
          <For each={pending()}>
            {(r) => {
              const [ttl, setTtl] = createSignal(r.ttl_hours || 24);
              return (
                <div class="secret-row bw-request-row">
                  <span class="secret-kind" title="Read" aria-label="Read"><EyeIcon /></span>
                  <div class="bw-request-body">
                    <div class="bw-request-line">
                      <strong class="secret-row-key">Read {target(r)}</strong>
                      <span class="bw-request-meta">{who(r)} · {since(r.created_at)}</span>
                    </div>
                    <span class="secret-row-reason" title={r.reason}>{r.reason}</span>
                  </div>
                  <Select value={String(ttl())} aria-label="Grant lasts" onChange={(e) => setTtl(Number(e.currentTarget.value))}>
                    <For each={LIFETIMES}>{([h, label]) => <option value={String(h)}>{label}</option>}</For>
                  </Select>
                  <button class="s-btn" disabled={!!busy()} onClick={() => void run(r.id, () => denyMissionAccess(r))}>Deny</button>
                  <button class="s-btn primary bw-request-ok" disabled={!!busy()} onClick={() => void run(r.id, () => approveMissionAccess(r, ttl()))}>
                    <FingerprintIcon size={14} />Allow read
                  </button>
                </div>
              );
            }}
          </For>
        </div>
      </Show>
      <Show when={grants().length > 0}><h4 class="bw-subhead">Active grants</h4></Show>
      <div class="s-card">
        <For each={grants()}>
          {(g) => (
            <div class="s-row" data-testid="mission-access-grant">
              <div class="s-row-text">
                <div class="s-row-title">{who(g)} → {target(g)}</div>
                <div class="s-row-desc">Read only · {until(g.expires_at, now())}</div>
              </div>
              <div class="s-row-ctrl">
                <button class="s-btn" disabled={!!busy()} onClick={() => void run(g.id, () => revokeMissionAccess(g.id))}>Revoke</button>
              </div>
            </div>
          )}
        </For>
        <div class="s-row">
          <div class="s-row-text">
            <button type="button" class="bw-link-btn" onClick={() => setShowLog(!showLog())}>
              <Show when={showLog()} fallback={<Ic.ChevronRight size={11} />}><Ic.ChevronDown size={11} /></Show> {showLog() ? "Hide" : "Show"} activity ({snap().audit.length} events)
            </button>
          </div>
        </div>
        <Show when={showLog()}>
          <div class="bw-log">
            <For each={history()}>
              {(r) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${r.state}`}>{r.state}</span>
                  <span>{who(r)} → {target(r)}</span>
                  <span class="s-row-desc">{since(r.revoked_at || r.decided_at || r.created_at)}</span>
                </div>
              )}
            </For>
            <For each={snap().audit.slice(0, 60)}>
              {(a) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${a.action}`}>{a.action}</span>
                  <span>{auditWho(a)} → {a.target_mission_id.slice(0, 8)}{a.detail ? ` · ${a.detail}` : ""}</span>
                  <span class="s-row-desc">{since(a.at)}</span>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </section>
  );
}
