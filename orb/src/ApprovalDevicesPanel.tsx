import { For, Show, createSignal, onMount } from "solid-js";
import {
  ApprovalCancelled,
  enrollThisDevice,
  listApprovalDevices,
  localApprovalKey,
  replaceLocalKey,
  signedApi,
  thisDeviceEnrollment,
  type ApprovalDevice,
  type ApprovalDevices,
  type ApprovalMode,
} from "./deviceApproval";

const MODE_LABEL: Record<ApprovalMode, string> = {
  off: "Off — any signed-in client can approve",
  warn: "Warn — unsigned approvals are logged but accepted",
  enforce: "Enforced — only enrolled devices can approve",
};

/**
 * Devices whose hardware keys may approve secret access. Core checks the
 * signature; Touch ID / Face ID / fingerprint unlock the key on the device.
 */
export function ApprovalDevicesPanel(p: { onError: (message: string) => void }) {
  const [state, setState] = createSignal<ApprovalDevices | null>(null);
  const [mine, setMine] = createSignal<ApprovalDevice | null>(null);
  const [available, setAvailable] = createSignal(false);
  const [code, setCode] = createSignal("");
  const [busy, setBusy] = createSignal(false);

  const load = async () => {
    try {
      const s = await listApprovalDevices();
      setState(s);
      setMine(await thisDeviceEnrollment(s.devices));
      setAvailable((await localApprovalKey()).available);
    } catch (e) {
      p.onError(e instanceof Error ? e.message : String(e));
    }
  };
  onMount(() => void load());

  const run = async (fn: () => Promise<unknown>) => {
    if (busy()) return;
    setBusy(true);
    try {
      await fn();
      await load();
      window.dispatchEvent(new Event("orb:approval-devices-changed"));
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) p.onError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const hostName = () => {
    const ua = navigator.userAgent.includes("Mac") ? "Mac" : "Desktop";
    return `Orb on ${ua}`;
  };

  return (
    <section class="s-sec">
      <div class="bw-section-head">
        <h3>Approval devices</h3>
        <span class="s-row-desc">{state() ? MODE_LABEL[state()!.mode] : "Loading…"}</span>
      </div>
      <div class="s-card">
        <For each={state()?.devices ?? []}>
          {(d) => (
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">
                  {d.name}
                  <Show when={mine()?.id === d.id}>
                    <span class="bw-badge">this Mac</span>
                  </Show>
                </div>
                <div class="s-row-desc">
                  {d.platform} · enrolled {new Date(d.created_at).toLocaleDateString()}
                  {d.last_used_at ? ` · last used ${new Date(d.last_used_at).toLocaleString()}` : ""}
                </div>
              </div>
              <div class="s-row-ctrl">
                <button
                  class="s-btn bw-danger-btn"
                  disabled={busy()}
                  onClick={() =>
                    void run(() =>
                      signedApi("DELETE", `/api/approvals/devices/${encodeURIComponent(d.id)}`, undefined, `remove approval device ${d.name}`),
                    )
                  }
                >
                  Remove
                </button>
              </div>
            </div>
          )}
        </For>

        <Show when={mine() && available()}>
          <div class="s-row">
            <div class="s-row-text">
              <div class="s-row-title">Replace this Mac's key</div>
              <div class="s-row-desc">
                Needed if Touch ID fingers changed (the old key stops working). Creates a new key; enroll it again with a
                one-time code, then remove the old entry.
              </div>
            </div>
            <div class="s-row-ctrl">
              <button class="s-btn" disabled={busy()} onClick={() => void run(async () => { await replaceLocalKey(); })}>
                Replace key
              </button>
            </div>
          </div>
        </Show>

        <Show when={!mine() && available()}>
          <div class="s-row">
            <div class="s-row-text">
              <div class="s-row-title">Enroll this Mac</div>
              <div class="s-row-desc">
                Creates a Secure Enclave key that signs only after Touch ID. Enter the one-time code created on the
                Core host (`approval_enrollment_code`).
              </div>
            </div>
            <div class="s-row-ctrl bw-binding-ctrl">
              <input
                class="s-input bw-mono"
                placeholder="One-time code"
                value={code()}
                onInput={(e) => setCode(e.currentTarget.value)}
              />
              <button
                class="s-btn primary"
                disabled={busy() || code().trim().length < 8}
                onClick={() => void run(async () => {
                  await enrollThisDevice(hostName(), code());
                  setCode("");
                })}
              >
                Enroll
              </button>
            </div>
          </div>
        </Show>

        <Show when={mine()}>
          <div class="s-row">
            <div class="s-row-text">
              <div class="s-row-title">Enforcement</div>
              <div class="s-row-desc">
                Enforce once every device you use is enrolled. Changing it needs Touch ID.
              </div>
            </div>
            <div class="s-row-ctrl">
              <For each={["warn", "enforce"] as ApprovalMode[]}>
                {(m) => (
                  <button
                    class={`s-btn ${state()?.mode === m ? "primary" : ""}`}
                    disabled={busy() || state()?.mode === m}
                    onClick={() => void run(() => signedApi("PUT", "/api/approvals/mode", { mode: m }, `set approval mode to ${m}`))}
                  >
                    {m === "warn" ? "Warn" : "Enforce"}
                  </button>
                )}
              </For>
            </div>
          </div>
        </Show>
      </div>
    </section>
  );
}
