import { Show } from "solid-js";
import { Dialog, DialogButton } from "./Dialog";
import type { ApprovalConfirmationPrompt } from "./tree/moves";

export default function ApprovalTransferDialog(p: {
  prompt: ApprovalConfirmationPrompt;
  onDismiss: () => void;
}) {
  const err = () => p.prompt.error;
  const secretNames = () => [...new Set([
    ...err().grants.map(g => g.secret_name),
    ...err().pendingRequests.map(r => r.secret_name),
  ].filter(Boolean))];
  const close = () => {
    const cur = p.prompt;
    p.onDismiss();
    cur.cancel();
  };
  const choose = (policy: "revoke" | "keep") => {
    const cur = p.prompt;
    p.onDismiss();
    cur.confirm(policy);
  };
  return (
    <Dialog
      size="compact"
      title="Move with active secret approvals?"
      description={`Moving to ${err().targetProject} affects ${err().grants.length} active secret ${err().grants.length === 1 ? "grant" : "grants"} and ${err().pendingRequests.length} pending ${err().pendingRequests.length === 1 ? "request" : "requests"}.`}
      onClose={close}
      footer={<>
        <DialogButton onClick={close}>Cancel</DialogButton>
        <DialogButton variant="secondary" onClick={() => choose("keep")}>Move &amp; keep approvals</DialogButton>
        <DialogButton variant="primary" onClick={() => choose("revoke")}>Move &amp; revoke approvals</DialogButton>
      </>}
    >
      <Show when={secretNames().length > 0}>
        <p style={{ margin: "0", color: "var(--fg-2)", "font-size": "12px", "line-height": "1.5" }}>
          Affected secrets: <code>{secretNames().join(", ")}</code>
        </p>
      </Show>
    </Dialog>
  );
}
