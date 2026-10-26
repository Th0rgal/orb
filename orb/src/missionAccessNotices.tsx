import { For, Show, createSignal } from "solid-js";
import { ApprovalCancelled } from "./deviceApproval";
import { CloseIcon } from "./icons";
import { approveMissionAccess, denyMissionAccess, missionLabel, type MissionAccessRequest } from "./missionAccessApi";
import { EyeIcon, FingerprintIcon } from "./secretRequestNotices";
import { dismissToast, notify } from "./toast";

/**
 * Pending mission access requests share one bottom card, styled like the
 * secret request card: who wants to read what, why, and Deny / Allow (Touch ID).
 */
const KEY = "mission-access-requests";
const [pending, setPending] = createSignal<MissionAccessRequest[]>([]);
const [hidden, setHidden] = createSignal<ReadonlySet<string>>(new Set());
let openSettings = () => {};

const visible = () => pending().filter((r) => !hidden().has(r.id));
const hide = (ids: string[], on: boolean) =>
  setHidden((prev) => {
    const next = new Set(prev);
    for (const id of ids) on ? next.add(id) : next.delete(id);
    return next;
  });

export function syncMissionAccessNotices(list: MissionAccessRequest[], open: () => void) {
  openSettings = open;
  setPending(list);
  const live = new Set(list.map((r) => r.id));
  setHidden((prev) => new Set([...prev].filter((id) => live.has(id))));
  if (!visible().length) return dismissToast(KEY);
  notify({ key: KEY, kind: "info", variant: "secret", title: "", content: () => <MissionAccessCard /> });
}

function act(r: MissionAccessRequest, approve: boolean) {
  hide([r.id], true);
  if (!visible().length) dismissToast(KEY);
  void (async () => {
    try {
      await (approve ? approveMissionAccess(r) : denyMissionAccess(r));
    } catch (e) {
      hide([r.id], false);
      syncMissionAccessNotices(pending(), openSettings);
      if (e instanceof ApprovalCancelled) return;
      notify({
        kind: "error",
        title: approve ? "Could not approve the access request" : "Could not deny the access request",
        message: e instanceof Error ? e.message : String(e),
      });
    }
  })();
}

const who = (r: MissionAccessRequest) => missionLabel(r.requester_title, r.requester_mission_id);
const target = (r: MissionAccessRequest) => missionLabel(r.target_title, r.target_mission_id);

function MissionAccessCard() {
  const list = visible;
  const one = () => (list().length === 1 ? list()[0] : undefined);
  const close = () => { hide(list().map((r) => r.id), true); dismissToast(KEY); };
  return <div class="secret-card access-card" data-testid="mission-access-card">
    <div class="secret-card-top">
      <span class="toast-glyph" aria-hidden="true"><FingerprintIcon /></span>
      <div class="toast-body">
        <span class="toast-title">
          <Show when={one()} fallback={<>{list().length} mission access requests</>}>
            {(r) => <span class="access-target">Read <strong>{target(r())}</strong></span>}
          </Show>
          <Show when={one()}>{(r) => <span class="toast-sub" title={r().requester_mission_id}>asked by {who(r())}</span>}</Show>
        </span>
        <Show when={one()}>
          {(r) => <>
            <Show when={r().reason}><span class="toast-message">{r().reason}</span></Show>
            <span class="access-scope">Read only · {r().ttl_hours} h · no messages, cancel or resume</span>
          </>}
        </Show>
      </div>
      <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={close}><CloseIcon size={13} /></button>
    </div>
    <Show when={!one()}>
      <div class="secret-rows">
        <For each={list()}>{(r) =>
          <div class="secret-row">
            <span class="secret-kind" title="Read" aria-label="Read"><EyeIcon /></span>
            <div class="toast-body">
              <strong class="secret-row-key">{target(r)}</strong>
              <span class="secret-row-reason" title={r.reason}>{who(r)}: {r.reason}</span>
            </div>
            <button type="button" class="toast-btn" onClick={() => act(r, false)}>Deny</button>
            <button type="button" class="toast-btn primary secret-row-ok" title="Allow read" aria-label="Allow read" onClick={() => act(r, true)}><FingerprintIcon size={14} /></button>
          </div>}
        </For>
      </div>
    </Show>
    <div class="secret-bar">
      <span class="secret-grace">Touch ID required</span>
      <button type="button" class="toast-link" onClick={() => { close(); openSettings(); }}>Review</button>
      <Show when={one()}>
        {(r) => <>
          <button type="button" class="toast-btn" onClick={() => act(r(), false)}>Deny</button>
          <button type="button" class="toast-btn primary" onClick={() => act(r(), true)}><FingerprintIcon size={14} />Allow read</button>
        </>}
      </Show>
    </div>
  </div>;
}
