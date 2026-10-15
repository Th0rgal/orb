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
      r.kind === "write" ? <>wants to store <strong>{r.key}</strong></>
      : r.key ? <>wants <strong>{r.key}</strong></>
      : r.all_projects ? <>wants every secret project</>
      : <>wants a whole secret project</>;
    const key = `secret-request-${r.id}`;
    notify({
      key,
      kind: "info",
      title: <><strong>{mission}</strong> {what}</>,
      message: r.reason || undefined,
      actions: [
        ...(r.kind === "read" && r.key
          ? [{
              label: "Allow",
              run: () => {
                dismissToast(key);
                void approveSecretRequest(r.id, "secret").catch((e) => {
                  if (e instanceof ApprovalCancelled) {
                    shown.delete(r.id); // ask again on the next poll
                    return;
                  }
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
