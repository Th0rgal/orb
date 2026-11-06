import { Show, createSignal } from "solid-js";
import { isConnected } from "./api";
import { ErrorToast } from "./toast";
import { ApprovalDevicesPanel } from "./ApprovalDevicesPanel";
import { PrivilegeAccessPanel } from "./PrivilegeAccessPanel";
import { MissionAccessPanel } from "./MissionAccessPanel";

/** Security → Access: approval devices, Fleet Bunker Mode and privileged access. */
export function SecuritySettings() {
  const [error, setError] = createSignal("");
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <ErrorToast error={error()} title="Security" onDismiss={() => setError("")} />
        <Show when={isConnected()} fallback={<p class="s-lead">Connect to Core on the Account page to manage approvals and access.</p>}>
          <ApprovalDevicesPanel onError={setError} />
          <PrivilegeAccessPanel onError={setError} />
          <MissionAccessPanel onError={setError} />
        </Show>
      </div>
    </div>
  );
}
