import { approveSecretRequest, type SecretAccessRequest } from "./bitwardenApi";
import { ApprovalCancelled } from "./deviceApproval";
import { dismissToast, notify } from "./toast";

/**
 * Pending mission secret requests appear as the app's usual bottom
 * notifications, once each: Allow (this secret, signed with Touch ID when the
 * Mac is enrolled) or Review on the Secrets page.
 */
const shown = new Set<string>();

export function syncSecretRequestNotices(pending: SecretAccessRequest[], openSecrets: () => void) {
  const live = new Set(pending.map((r) => r.id));
  for (const id of [...shown]) {
    if (!live.has(id)) {
      dismissToast(`secret-request-${id}`);
      shown.delete(id);
    }
  }
  for (const r of pending) {
    if (shown.has(r.id)) continue;
    shown.add(r.id);
    const mission = r.mission_title || `Mission ${r.mission_id.slice(0, 8)}`;
    const what =
      r.kind === "write" ? <>Store <strong>{r.key}</strong></>
      : r.key ? <strong>{r.key}</strong>
      : r.all_projects ? <>Every secret project</>
      : <>A whole secret project</>;
    const key = `secret-request-${r.id}`;
    notify({
      key,
      kind: "info",
      variant: "secret",
      icon: <FingerprintIcon />,
      title: <>{what}<span class="toast-sub" title={mission}>{mission}</span></>,
      message: r.reason || undefined,
      actions: [
        ...(r.kind === "read" && r.key
          ? [{
              label: "Allow",
              primary: true,
              run: () => {
                dismissToast(key);
                void approveSecretRequest(r.id, "secret").catch((e) => {
                  shown.delete(r.id); // still pending: show it again on the next poll
                  if (e instanceof ApprovalCancelled) return;
                  notify({ kind: "error", title: "Could not approve the request", message: e instanceof Error ? e.message : String(e) });
                });
              },
            }]
          : []),
        { label: "Review", run: () => { dismissToast(key); openSecrets(); } },
      ],
    });
  }
}

function FingerprintIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M6.8 5.2A8 8 0 0 1 20 11.5c0 1.5-.1 3-.4 4.4" />
    <path d="M4 15.5a8 8 0 0 1-.1-4.1 8 8 0 0 1 1-2.6" />
    <path d="M8.2 18.6A12 12 0 0 0 9.5 12a2.5 2.5 0 0 1 5 0c0 2.6-.4 5-1.2 7.3" />
    <path d="M6.4 12a5.6 5.6 0 0 1 11.2 0c0 1.9-.2 3.7-.6 5.4" />
    <path d="M12 12c0 3.4-.7 6.4-2 9" />
  </svg>;
}
