import { useNow } from "./time";
import { For, Show, createSignal } from "solid-js";
import { approveSecretRequest, listBitwardenProjects, rejectSecretRequest, secretChangeVerb, type SecretAccessRequest } from "./bitwardenApi";
import { ApprovalCancelled, graceUntil } from "./deviceApproval";
import { CloseIcon, PencilIcon, TrashIcon } from "./icons";
import { dismissToast, notify } from "./toast";

/**
 * Pending mission secret requests share one bottom card. With one request it
 * shows the key and the reason; with several, one row each. The action bar
 * approves (one Touch ID, then fingerprint-free for the grace shown there) or
 * denies everything visible; rows act on their own request.
 */
const KEY = "secret-requests";
const [pending, setPending] = createSignal<SecretAccessRequest[]>([]);
/** Closed with the X, or being approved/denied right now. */
const [hidden, setHidden] = createSignal<ReadonlySet<string>>(new Set());
let openSecretsPage = () => {};
/** Bitwarden project names, loaded once a delete or move needs them. */
const [projectNames, setProjectNames] = createSignal<Record<string, string> | null>(null);
let projectsLoading = false;
const projectLabel = (id?: string | null) => (id && projectNames()?.[id]) || (id ? id.slice(0, 8) : "unknown project");

const visible = () => pending().filter((r) => !hidden().has(r.id));
const hide = (ids: string[], on: boolean) =>
  setHidden((prev) => {
    const next = new Set(prev);
    for (const id of ids) on ? next.add(id) : next.delete(id);
    return next;
  });

/** When the visible set last changed: a batch approve must not catch a request that just appeared. */
const [changedAt, setChangedAt] = createSignal(0);
const SETTLE_MS = 1500;
let lastIds = "";

export function syncSecretRequestNotices(list: SecretAccessRequest[], openSecrets: () => void) {
  openSecretsPage = openSecrets;
  setPending(list);
  if (!projectsLoading && list.some((r) => !bulkApprovable(r))) {
    projectsLoading = true;
    listBitwardenProjects()
      .then((ps) => setProjectNames(Object.fromEntries(ps.map((p) => [p.id, p.name]))))
      .catch(() => { projectsLoading = false; });
  }
  const live = new Set(list.map((r) => r.id));
  setHidden((prev) => new Set([...prev].filter((id) => live.has(id))));
  const ids = visible().map((r) => r.id).join(",");
  if (ids !== lastIds) { lastIds = ids; setChangedAt(Date.now()); }
  if (!visible().length) return dismissToast(KEY);
  notify({ key: KEY, kind: "info", variant: "secret", title: "", content: () => <SecretRequestsCard /> });
}

/** Every request is approvable here, with the Secrets page's default scope. */
const approvable = (_r: SecretAccessRequest) => true;
/** Deletes and moves are approved one by one, never through "Approve all". */
const bulkApprovable = (r: SecretAccessRequest) => r.kind === "read" || r.kind === "write";
const readScope = (r: SecretAccessRequest) => (r.key ? "secret" : r.project_id ? "project" : "all");

function act(requests: SecretAccessRequest[], approve: boolean) {
  const ids = requests.map((r) => r.id);
  hide(ids, true);
  if (!visible().length) dismissToast(KEY);
  void (async () => {
    // Sequential: the first approval asks for Touch ID and opens the grace
    // window the others then use.
    for (const r of requests) {
      try {
        if (!approve) await rejectSecretRequest(r.id);
        else if (secretChangeVerb(r)) await approveSecretRequest(r.id);
        else await approveSecretRequest(r.id, readScope(r));
      } catch (e) {
        hide([r.id], false); // still pending: show it again
        syncSecretRequestNotices(pending(), openSecretsPage);
        if (e instanceof ApprovalCancelled) return;
        notify({
          kind: "error",
          title: approve ? "Could not approve the request" : "Could not deny the request",
          message: e instanceof Error ? e.message : String(e),
        });
        return;
      }
    }
  })();
}

function label(r: SecretAccessRequest) {
  if (r.key && r.kind === "delete") return `${r.key} from ${projectLabel(r.project_id)}`;
  if (r.key && r.kind === "move") return `${r.key} from ${projectLabel(r.project_id)} to ${projectLabel(r.target_project_id)}`;
  if (r.key) return r.key;
  return r.all_projects ? "Every secret project" : "A whole secret project";
}

function SecretRequestsCard() {
  const now = useNow(250);
  const list = visible;
  const one = () => list().length === 1 ? list()[0] : undefined;
  const missions = () => [...new Set(list().map((r) => r.mission_title || `Mission ${r.mission_id.slice(0, 8)}`))];
  const ready = () => list().length === 1 ? list().filter(approvable) : list().filter(bulkApprovable);
  const graceLeft = () => Math.max(0, Math.floor(graceUntil() - now() / 1000));
  const graceText = () => {
    const s = graceLeft();
    return s ? `Touch ID · ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")} left` : "Touch ID required";
  };
  const close = () => { hide(list().map((r) => r.id), true); dismissToast(KEY); };
  return <div class="secret-card">
    <div class="secret-card-top">
      <span class="toast-glyph" aria-hidden="true"><FingerprintIcon /></span>
      <div class="toast-body">
        <span class="toast-title">
          <Show when={one()} fallback={<>{list().length} secret requests</>}>
            {(r) => <>{secretChangeVerb(r()) ? `${secretChangeVerb(r())} ` : ""}<strong>{label(r())}</strong></>}
          </Show>
          <span class="toast-sub" title={missions().join(", ")}>{missions().length === 1 ? missions()[0] : `${missions().length} missions`}</span>
        </span>
        <Show when={one()?.reason}><span class="toast-message">{one()!.reason}</span></Show>
      </div>
      <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={close}><CloseIcon size={13} /></button>
    </div>
    <Show when={!one()}>
      <div class="secret-rows">
        <For each={list()}>{(r) =>
          <div class="secret-row">
            <SecretKindIcon request={r} />
            <div class="toast-body">
              <strong class="secret-row-key">{label(r)}</strong>
              <Show when={r.reason}><span class="secret-row-reason" title={r.reason}>{r.reason}</span></Show>
            </div>
            <button type="button" class="toast-btn" onClick={() => act([r], false)}>Deny</button>
            <Show when={approvable(r)}>
              <button type="button" class="toast-btn primary secret-row-ok" title={secretChangeVerb(r) ?? "Allow"} aria-label={secretChangeVerb(r) ?? "Allow"} onClick={() => act([r], true)}><FingerprintIcon size={14} /></button>
            </Show>
          </div>}
        </For>
      </div>
    </Show>
    <div class="secret-bar">
      <span class="secret-grace" title="Approvals of a single secret skip the fingerprint until this runs out">{graceText()}</span>
      <button type="button" class="toast-link" onClick={() => { close(); openSecretsPage(); }}>Review</button>
      <button type="button" class="toast-btn" onClick={() => act(list(), false)}>{one() ? "Deny" : "Deny all"}</button>
      <Show when={ready().length}>
        <button type="button" class="toast-btn primary" disabled={now() - changedAt() < SETTLE_MS} onClick={() => {
          // Approve exactly what was on screen when the button became active.
          if (Date.now() - changedAt() >= SETTLE_MS) act(ready(), true);
        }}>
          <FingerprintIcon size={14} />{one() ? (secretChangeVerb(one()!) ?? "Allow") : "Approve all"}
        </button>
      </Show>
    </div>
  </div>;
}

export function EyeIcon() {
  return <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" /><circle cx="8" cy="8" r="2" /></svg>;
}

/** Read, write, delete or move, as an icon with its label. */
export function SecretKindIcon(p: { request: SecretAccessRequest }) {
  const title = () => ({ write: "Write", delete: "Delete", move: "Move" } as Record<string, string>)[p.request.kind] ?? "Read";
  return <span class="secret-kind" title={title()} aria-label={title()}>
    {p.request.kind === "delete" ? <TrashIcon /> : p.request.kind === "read" ? <EyeIcon /> : <PencilIcon />}
  </span>;
}

export function FingerprintIcon(p: { size?: number }) {
  const size = p.size ?? 16;
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M6.8 5.2A8 8 0 0 1 20 11.5c0 1.5-.1 3-.4 4.4" />
    <path d="M4 15.5a8 8 0 0 1-.1-4.1 8 8 0 0 1 1-2.6" />
    <path d="M8.2 18.6A12 12 0 0 0 9.5 12a2.5 2.5 0 0 1 5 0c0 2.6-.4 5-1.2 7.3" />
    <path d="M6.4 12a5.6 5.6 0 0 1 11.2 0c0 1.9-.2 3.7-.6 5.4" />
    <path d="M12 12c0 3.4-.7 6.4-2 9" />
  </svg>;
}
