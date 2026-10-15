import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import {
  approveSecretRequest,
  getSecretBroker,
  rejectSecretRequest,
  revokeSecretGrant,
  type BitwardenProject,
  type SecretAccessRequest,
  type SecretBrokerSnapshot,
  type SecretGrant,
} from "./bitwardenApi";
import * as Ic from "./icons";

const POLL_MS = 5000;

function ago(raw?: string | null): string {
  const ts = raw ? Date.parse(raw) : NaN;
  if (!Number.isFinite(ts)) return "";
  const m = Math.round((Date.now() - ts) / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
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
    const t = setInterval(() => void load(), POLL_MS);
    onCleanup(() => clearInterval(t));
  });

  const pending = createMemo(() => snap().requests.filter((r) => r.status === "pending"));
  const recent = createMemo(() => snap().requests.filter((r) => r.status !== "pending").slice(0, 8));

  const describe = (r: SecretAccessRequest) => {
    if (r.kind === "write") return `store ${r.key} in ${projectName(r.project_id)}`;
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

  const act = async (id: string, reason: string, run: () => Promise<unknown>, secretsChanged = false) => {
    if (busy()) return;
    if (!(await p.requireBiometric(reason))) return;
    setBusy(id);
    try {
      await run();
      await load();
      if (secretsChanged) p.onSecretsChanged();
    } catch (e) {
      p.onError(e instanceof Error ? e.message : String(e));
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

      <Show when={pending().length > 0}>
        <div class="s-card bw-requests" role="region" aria-label="Pending secret requests">
          <For each={pending()}>
            {(r) => (
              <div class="bw-request-row">
                <div class="bw-request-main">
                  <div class="bw-request-title">
                    <span class={`bw-kind ${r.kind}`}>{r.kind === "write" ? "Store" : "Read"}</span>
                    {describe(r)}
                  </div>
                  <div class="s-row-desc">
                    {who(r)} · {ago(r.created_at)}
                  </div>
                  <Show when={r.reason}>
                    <div class="bw-request-reason">“{r.reason}”</div>
                  </Show>
                </div>
                <div class="bw-request-actions">
                  <Show
                    when={r.kind === "read"}
                    fallback={
                      <button
                        class="s-btn primary"
                        disabled={!!busy()}
                        onClick={() =>
                          void act(r.id, `store secret ${r.key}`, () => approveSecretRequest(r.id), true)
                        }
                      >
                        Approve
                      </button>
                    }
                  >
                    <Show when={r.key}>
                      <button
                        class="s-btn primary"
                        disabled={!!busy()}
                        title="Allow only this secret for this mission (24 h)"
                        onClick={() => void act(r.id, `give a mission ${r.key}`, () => approveSecretRequest(r.id, "secret"))}
                      >
                        Allow secret
                      </button>
                    </Show>
                    <Show when={r.project_id}>
                      <button
                        class="s-btn"
                        disabled={!!busy()}
                        title="Allow the whole Bitwarden project for this mission (24 h)"
                        onClick={() =>
                          void act(r.id, `give a mission project ${projectName(r.project_id)}`, () =>
                            approveSecretRequest(r.id, "project"),
                          )
                        }
                      >
                        Allow project
                      </button>
                    </Show>
                    <button
                      class="s-btn"
                      disabled={!!busy()}
                      title="Allow every project for this mission (24 h)"
                      onClick={() =>
                        void act(r.id, "give a mission every secret project", () => approveSecretRequest(r.id, "all"))
                      }
                    >
                      Allow all
                    </button>
                  </Show>
                  <button
                    class="s-btn bw-danger-btn"
                    disabled={!!busy()}
                    onClick={async () => {
                      setBusy(r.id);
                      try {
                        await rejectSecretRequest(r.id);
                        await load();
                      } catch (e) {
                        p.onError(e instanceof Error ? e.message : String(e));
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    Decline
                  </button>
                </div>
              </div>
            )}
          </For>
        </div>
      </Show>

      <div class="s-card">
        <Show
          when={snap().grants.length > 0}
          fallback={
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-desc">
                  {pending().length ? "No grants yet." : "No pending requests and no extra grants."}
                </div>
              </div>
            </div>
          }
        >
          <For each={snap().grants}>
            {(g) => (
              <div class="s-row">
                <div class="s-row-text">
                  <div class="s-row-title">{scopeLabel(g)}</div>
                  <div class="s-row-desc">
                    {who(g)} · {until(g.expires_at)}
                  </div>
                </div>
                <div class="s-row-ctrl">
                  <button
                    class="s-btn"
                    disabled={!!busy()}
                    onClick={async () => {
                      setBusy(g.id);
                      try {
                        await revokeSecretGrant(g.id);
                        await load();
                      } catch (e) {
                        p.onError(e instanceof Error ? e.message : String(e));
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    Revoke
                  </button>
                </div>
              </div>
            )}
          </For>
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
                    {who(r)} · {ago(r.resolved_at || r.created_at)}
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
                    {a.paloma_project ? ` · ${a.paloma_project}` : ""} · {ago(a.at)}
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
