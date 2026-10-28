import { pollWhileVisible } from "./poll";
import { ago, useNow } from "./time";
import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import {
  approveSecretRequest,
  getSecretBroker,
  rejectSecretRequest,
  revokeSecretGrant,
  secretChangeVerb,
  type BitwardenProject,
  type SecretAccessRequest,
  type SecretBrokerSnapshot,
  type SecretGrant,
} from "./bitwardenApi";
import * as Ic from "./icons";
import { readString, writeString } from "./storage";
import { Select } from "./Select";
import { ApprovalCancelled, approvalGraceSecs, graceUntil, setApprovalGraceSecs } from "./deviceApproval";
import { FingerprintIcon, SecretKindIcon } from "./approvalIcons";

const POLL_MS = 5000;
const GRANTS_KEY = "orb.secretGrants.expanded";

function since(raw?: string | null): string {
  const ts = raw ? Date.parse(raw) : NaN;
  return Number.isFinite(ts) ? ago(ts, Date.now(), { round: true, days: true }) : "";
}

function until(raw: string): string {
  const ms = Date.parse(raw) - Date.now();
  if (!Number.isFinite(ms) || ms <= 0) return "expired";
  const h = Math.floor(ms / 3_600_000);
  const m = Math.round((ms % 3_600_000) / 60000);
  return h > 0 ? `${h} h ${m} min left` : `${m} min left`;
}

export function SecretAccessPanel(p: {
  projects: BitwardenProject[];
  requireBiometric: (reason: string) => Promise<boolean>;
  onError: (message: string) => void;
  onSecretsChanged: () => void;
}) {
  const [snap, setSnap] = createSignal<SecretBrokerSnapshot>({ requests: [], grants: [], audit: [] });
  const [busy, setBusy] = createSignal<string | null>(null);
  const [showLog, setShowLog] = createSignal(false);
  // Collapsed by default; the choice is remembered on this device.
  const [showGrants, setShowGrants] = createSignal(readString(GRANTS_KEY) === "1");

  const projectName = (id?: string | null) =>
    (id && p.projects.find((x) => x.id === id)?.name) || (id ? id.slice(0, 8) : "");

  const load = async () => {
    try {
      setSnap(await getSecretBroker());
    } catch {
      // The rest of the page reports connection errors.
    }
  };
  onMount(() => {
    void load();
    onCleanup(pollWhileVisible(load, POLL_MS, "secretAccess.load"));
  });

  const now = useNow(1000);
  const graceText = () => {
    const left = Math.max(0, graceUntil() * 1000 - now());
    if (!left) return "Touch ID required";
    const sec = Math.ceil(left / 1000);
    return `Touch ID · ${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")} left`;
  };

  const pending = createMemo(() => snap().requests.filter((r) => r.status === "pending"));
  const recent = createMemo(() => snap().requests.filter((r) => r.status !== "pending").slice(0, 8));

  const describe = (r: SecretAccessRequest) => {
    if (r.kind === "write") return `store ${r.key} in ${projectName(r.project_id)}`;
    if (r.kind === "delete") return `delete ${r.key} from ${projectName(r.project_id)}`;
    if (r.kind === "move") return `move ${r.key} from ${projectName(r.project_id)} to ${projectName(r.target_project_id)}`;
    if (r.key) return `read ${r.key}${r.project_id ? ` (${projectName(r.project_id)})` : ""}`;
    if (r.all_projects) return "read every project";
    return `read project ${projectName(r.project_id)}`;
  };
  const scopeLabel = (g: SecretGrant) =>
    g.scope.kind === "all"
      ? "All projects"
      : g.scope.kind === "project"
        ? `Project ${projectName(g.scope.project_id)}`
        : `Secret ${g.scope.key}`;
  const who = (x: { mission_title?: string | null; mission_id: string; paloma_project?: string | null }) =>
    `${x.mission_title || `Mission ${x.mission_id.slice(0, 8)}`}${x.paloma_project ? ` · ${x.paloma_project}` : ""}`;

  // Grants of one mission are listed together so its title appears once.
  const grantGroups = createMemo(() => {
    const groups = new Map<string, SecretGrant[]>();
    for (const g of snap().grants) groups.set(g.mission_id, [...(groups.get(g.mission_id) ?? []), g]);
    return [...groups.values()];
  });
  const nextExpiry = createMemo(() =>
    snap().grants.map((g) => g.expires_at).sort((a, b) => Date.parse(a) - Date.parse(b))[0],
  );
  // Not optimistic: Core may refuse, so the row stays until the reload confirms it.
  const revoke = async (id: string, grants: SecretGrant[]) => {
    if (busy()) return;
    setBusy(id);
    try {
      for (const g of grants) await revokeSecretGrant(g.id);
    } catch (e) {
      p.onError(e instanceof Error ? e.message : String(e));
    } finally {
      await load();
      setBusy(null);
    }
  };

  const act = async (id: string, reason: string, run: () => Promise<unknown>, secretsChanged = false) => {
    if (busy()) return;
    if (!(await p.requireBiometric(reason))) return;
    setBusy(id);
    try {
      await run();
      await load();
      if (secretsChanged) p.onSecretsChanged();
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) p.onError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <section class="s-sec bw-access">
      <div class="bw-section-head">
        <h3>Mission access</h3>
        <span class="s-row-desc">
          Missions ask Core for secrets. Projects allowed by default are set in each project's settings.
        </span>
      </div>

      <Show
        when={pending().length > 0}
        fallback={<div class="bw-empty-line">No mission is waiting for a secret.</div>}
      >
        <div class="bw-requests" role="region" aria-label="Pending secret requests">
          <For each={pending()}>
            {(r) => {
              const [scope, setScope] = createSignal<"secret" | "project" | "all">(r.key ? "secret" : r.project_id ? "project" : "all");
              const tier = () => projectName(r.project_id);
              const verb = secretChangeVerb(r);
              const write = verb !== null;
              return (
                <div class="secret-row bw-request-row">
                  <SecretKindIcon request={r} />
                  <div class="bw-request-body">
                    <div class="bw-request-line">
                      <strong class="secret-row-key">{r.key || (r.all_projects ? "Every secret project" : `Project ${tier()}`)}</strong>
                      <Show when={r.project_id && r.key}>
                        <span class={`bw-tier bw-tier-${tier()}`}>{tier()}</span>
                      </Show>
                      <Show when={r.kind === "move"}>
                        <span class="bw-request-meta">→ {projectName(r.target_project_id)}</span>
                      </Show>
                      <span class="bw-request-meta" title={who(r)}>{who(r)} · {since(r.created_at)}</span>
                    </div>
                    <Show when={r.reason}>
                      <span class="secret-row-reason" title={r.reason!}>{r.reason}</span>
                    </Show>
                  </div>
                  <Show when={!write}>
                    <Select
                      value={scope()}
                      aria-label="What to allow"
                      onChange={(e) => setScope(e.currentTarget.value as "secret" | "project" | "all")}
                    >
                      <Show when={r.key}><option value="secret">This secret</option></Show>
                      <Show when={r.project_id}><option value="project">All of {tier()}</option></Show>
                      <option value="all">Every project</option>
                    </Select>
                  </Show>
                  <button
                    class="s-btn"
                    disabled={!!busy()}
                    onClick={() => void act(r.id, "decline a mission secret request", () => rejectSecretRequest(r.id))}
                  >
                    Deny
                  </button>
                  <button
                    class="s-btn primary bw-request-ok"
                    disabled={!!busy()}
                    title={verb ?? "Allow for 24 h"}
                    onClick={() =>
                      void (write
                        ? act(r.id, describe(r), () => approveSecretRequest(r.id), true)
                        : act(r.id, "allow a mission secret access", () => approveSecretRequest(r.id, scope())))
                    }
                  >
                    <FingerprintIcon size={14} />
                    {verb ?? "Allow"}
                  </button>
                </div>
              );
            }}
          </For>
          <div class="secret-bar">
            <span class="secret-grace">{graceText()}</span>
            <label class="bw-grace-setting">
              One Touch ID covers
              <Select
                value={String(approvalGraceSecs())}
                aria-label="Touch ID grace"
                onChange={(e) => setApprovalGraceSecs(Number(e.currentTarget.value))}
              >
                <option value="0">nothing</option>
                <option value="60">1 min</option>
                <option value="300">5 min</option>
                <option value="900">15 min</option>
              </Select>
            </label>
          </div>
        </div>
      </Show>

      <div class="s-card">
        <Show when={snap().grants.length > 0}>
          <div class="s-row">
            <div class="s-row-text">
              <button
                type="button"
                class="bw-link-btn"
                aria-expanded={showGrants()}
                onClick={() => {
                  const next = !showGrants();
                  setShowGrants(next);
                  writeString(GRANTS_KEY, next ? "1" : "0");
                }}
              >
                <Show when={showGrants()} fallback={<Ic.ChevronRight size={11} />}><Ic.ChevronDown size={11} /></Show>{" "}
                {snap().grants.length} active {snap().grants.length === 1 ? "grant" : "grants"}
                {nextExpiry() ? ` · next expires in ${until(nextExpiry()!).replace(" left", "")}` : ""}
              </button>
            </div>
          </div>
          <Show when={showGrants()}>
            <div class="bw-log bw-grants">
              <For each={grantGroups()}>
                {(group) => (
                  <div class="bw-grant-group">
                    <div class="bw-log-row bw-grant-head">
                      <span class="bw-grant-mission" title={who(group[0])}>{who(group[0])}</span>
                      <Show when={group.length > 1}>
                        <button
                          type="button"
                          class="bw-link-btn"
                          disabled={!!busy()}
                          onClick={() => void revoke(group[0].mission_id, group)}
                        >
                          Revoke all
                        </button>
                      </Show>
                    </div>
                    <For each={group}>
                      {(g) => (
                        <div class="bw-log-row bw-grant-row">
                          <code class="bw-mono bw-grant-scope" title={scopeLabel(g)}>
                            {g.scope.kind === "secret" ? g.scope.key : scopeLabel(g)}
                          </code>
                          <span class="s-row-desc">{until(g.expires_at)}</span>
                          <button type="button" class="bw-link-btn" disabled={!!busy()} onClick={() => void revoke(g.id, [g])}>
                            Revoke
                          </button>
                        </div>
                      )}
                    </For>
                  </div>
                )}
              </For>
            </div>
          </Show>
        </Show>
        <div class="s-row">
          <div class="s-row-text">
            <button type="button" class="bw-link-btn" onClick={() => setShowLog(!showLog())}>
              <Show when={showLog()} fallback={<Ic.ChevronRight size={11} />}><Ic.ChevronDown size={11} /></Show> {showLog() ? "Hide" : "Show"} activity ({snap().audit.length} reads,{" "}
              {recent().length} answered requests)
            </button>
          </div>
        </div>
        <Show when={showLog()}>
          <div class="bw-log">
            <For each={recent()}>
              {(r) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${r.status}`}>{r.status}</span>
                  <span>{describe(r)}</span>
                  <span class="s-row-desc">
                    {who(r)} · {since(r.resolved_at || r.created_at)}
                    {r.error ? ` · ${r.error}` : ""}
                  </span>
                </div>
              )}
            </For>
            <For each={snap().audit.slice(0, 50)}>
              {(a) => (
                <div class="bw-log-row">
                  <span class={`bw-log-status ${a.via}`}>{a.via}</span>
                  <code class="bw-mono">{a.key}</code>
                  <span class="s-row-desc">
                    Mission {a.mission_id.slice(0, 8)}
                    {a.paloma_project ? ` · ${a.paloma_project}` : ""} · {since(a.at)}
                  </span>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </section>
  );
}
