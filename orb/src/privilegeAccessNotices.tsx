import { For, Show, createSignal } from "solid-js";
import { ApprovalCancelled } from "./deviceApproval";
import { CloseIcon } from "./icons";
import {
  approveAllPrivilegeAccess,
  approvePrivilegeAccess,
  batchApprovable,
  batchSummary,
  bunkerStateLabel,
  denyPrivilegeAccess,
  lifetimeLabel,
  requesterLabel,
  requestTitle,
  scopeUnlocks,
  unbunkerFleet,
  type PrivilegeRequest,
} from "./privilegeAccessApi";
import { FingerprintIcon } from "./secretRequestNotices";
import { useNow } from "./time";
import { dismissToast, notify } from "./toast";

/**
 * Pending privileged access requests share one bottom card, styled like the
 * mission access card: which mission wants what on which host, why, for how
 * long, and Deny / Allow (Touch ID). With several, "Approve all" signs one
 * challenge for exactly the requests on screen; root requests stay out of it
 * unless the approver ticks "Include root".
 */
const KEY = "privilege-access-requests";
const BUNKER_KEY = "bunker-mode-active";
const [pending, setPending] = createSignal<PrivilegeRequest[]>([]);
const [hidden, setHidden] = createSignal<ReadonlySet<string>>(new Set());
const [bunkerLevel, setBunkerLevel] = createSignal(0);
const [bunkerDismissedForLevel, setBunkerDismissedForLevel] = createSignal(0);
let openSettings = () => {};

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
const [includeRoot, setIncludeRoot] = createSignal(false);

export function syncPrivilegeAccessNotices(list: PrivilegeRequest[], open: () => void, bunkerState = 0) {
  openSettings = open;
  setPending(list);
  setBunkerLevel(bunkerState);
  if (bunkerState <= 0) {
    setBunkerDismissedForLevel(0);
    dismissToast(BUNKER_KEY);
  } else if (bunkerDismissedForLevel() !== bunkerState) {
    notify({ key: BUNKER_KEY, kind: "error", variant: "secret", title: "", content: () => <BunkerModeCard /> });
  }
  const live = new Set(list.map((r) => r.id));
  setHidden((prev) => new Set([...prev].filter((id) => live.has(id))));
  const ids = visible().map((r) => r.id).join(",");
  if (ids !== lastIds) { lastIds = ids; setChangedAt(Date.now()); setIncludeRoot(false); }
  if (!visible().length) return dismissToast(KEY);
  notify({ key: KEY, kind: "info", variant: "secret", title: "", content: () => <PrivilegeAccessCard /> });
}

function BunkerModeCard() {
  const close = () => {
    setBunkerDismissedForLevel(bunkerLevel());
    dismissToast(BUNKER_KEY);
  };
  const exitBunker = () => {
    void (async () => {
      try {
        await unbunkerFleet();
        setBunkerLevel(0);
        setBunkerDismissedForLevel(0);
        dismissToast(BUNKER_KEY);
      } catch (e) {
        if (e instanceof ApprovalCancelled) return;
        notify({
          kind: "error",
          title: "Could not exit Bunker Mode",
          message: e instanceof Error ? e.message : String(e),
        });
      }
    })();
  };
  return (
    <div class="secret-card access-card" data-testid="bunker-mode-notice-card">
      <div class="secret-card-top">
        <span class="toast-glyph" aria-hidden="true"><FingerprintIcon /></span>
        <div class="toast-body">
          <span class="toast-title">
            <strong>Fleet Bunker Mode: {bunkerStateLabel(bunkerLevel())}</strong>
          </span>
          <span class="toast-message">
            New privileged requests are locked and active root/deploy grants are revoked.
          </span>
        </div>
        <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={close}><CloseIcon size={13} /></button>
      </div>
      <div class="secret-bar">
        <span class="secret-grace">Touch ID required</span>
        <button type="button" class="toast-link" onClick={() => { close(); openSettings(); }}>Review</button>
        <button type="button" class="toast-btn primary" onClick={exitBunker}>
          <FingerprintIcon size={14} />Exit Bunker Mode
        </button>
      </div>
    </div>
  );
}

function act(r: PrivilegeRequest, approve: boolean) {
  hide([r.id], true);
  if (!visible().length) dismissToast(KEY);
  void (async () => {
    try {
      await (approve ? approvePrivilegeAccess(r) : denyPrivilegeAccess(r));
    } catch (e) {
      hide([r.id], false);
      syncPrivilegeAccessNotices(pending(), openSettings);
      if (e instanceof ApprovalCancelled) return;
      notify({
        kind: "error",
        title: approve ? "Could not approve the privileged access request" : "Could not deny the privileged access request",
        message: e instanceof Error ? e.message : String(e),
      });
    }
  })();
}

function actAll(rs: PrivilegeRequest[]) {
  const ids = rs.map((r) => r.id);
  hide(ids, true);
  if (!visible().length) dismissToast(KEY);
  void approveAllPrivilegeAccess(rs).catch((e) => {
    hide(ids, false);
    syncPrivilegeAccessNotices(pending(), openSettings);
    if (e instanceof ApprovalCancelled) return;
    notify({
      kind: "error",
      title: "Could not approve the privileged access requests",
      message: e instanceof Error ? e.message : String(e),
    });
  });
}

const what = requestTitle;

function PrivilegeAccessCard() {
  const now = useNow(250);
  const list = visible;
  const summary = () => batchSummary(list());
  const ready = () => batchApprovable(list(), includeRoot());
  const one = () => (list().length === 1 ? list()[0] : undefined);
  const close = () => { hide(list().map((r) => r.id), true); dismissToast(KEY); };
  return <div class="secret-card access-card" data-testid="privilege-access-card">
    <div class="secret-card-top">
      <span class="toast-glyph" aria-hidden="true"><FingerprintIcon /></span>
      <div class="toast-body">
        <span class="toast-title">
          <Show when={one()} fallback={<>{list().length} privileged access requests</>}>
            {(r) => <strong>{what(r())}</strong>}
          </Show>
          <Show when={one()}>{(r) => <span class="toast-sub" title={r().requester_mission_id}>asked by {requesterLabel(r())}</span>}</Show>
        </span>
        <Show when={one()}>
          {(r) => <>
            <Show when={r().reason}><span class="toast-message">{r().reason}</span></Show>
            <span class="access-scope">Allows {scopeUnlocks(r())} · {lifetimeLabel(r())}</span>
          </>}
        </Show>
      </div>
      <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={close}><CloseIcon size={13} /></button>
    </div>
    <Show when={!one()}>
      <div class="secret-rows">
        <For each={list()}>{(r) =>
          <div class="secret-row" classList={{ "privilege-root": r.scope === "root_exec" }} data-testid="privilege-access-row">
            <div class="toast-body">
              <strong class="secret-row-key">{what(r)}</strong>
              <span class="secret-row-reason" title={r.reason}>{requesterLabel(r)}: {r.reason}</span>
            </div>
            <button type="button" class="toast-btn" onClick={() => act(r, false)}>Deny</button>
            <button type="button" class="toast-btn primary secret-row-ok" title="Allow" aria-label="Allow" onClick={() => act(r, true)}><FingerprintIcon size={14} /></button>
          </div>}
        </For>
      </div>
      <div class="privilege-batch" data-testid="privilege-batch-summary">
        <span class="access-scope">{summary().tiers} · on {summary().hosts}</span>
        <span class="access-scope" title={summary().missions}>for {summary().missions}</span>
        <Show when={summary().root}>
          <label class="privilege-root-confirm">
            <input type="checkbox" checked={includeRoot()} onChange={(e) => setIncludeRoot(e.currentTarget.checked)} />
            Include {summary().root === 1 ? "the root request" : `${summary().root} root requests`} (any command as root)
          </label>
        </Show>
      </div>
    </Show>
    <div class="secret-bar">
      <span class="secret-grace">Touch ID required</span>
      <button type="button" class="toast-link" onClick={() => { close(); openSettings(); }}>Review</button>
      <Show when={one()}>
        {(r) => <>
          <button type="button" class="toast-btn" onClick={() => act(r(), false)}>Deny</button>
          <button type="button" class="toast-btn primary" onClick={() => act(r(), true)}><FingerprintIcon size={14} />Allow</button>
        </>}
      </Show>
      <Show when={!one() && ready().length}>
        <button type="button" class="toast-btn primary" disabled={now() - changedAt() < SETTLE_MS} onClick={() => {
          // Approve exactly what was on screen when the button became active.
          if (Date.now() - changedAt() >= SETTLE_MS) actAll(ready());
        }}>
          <FingerprintIcon size={14} />{ready().length === list().length ? "Approve all" : `Approve ${ready().length}`}
        </button>
      </Show>
    </div>
  </div>;
}
