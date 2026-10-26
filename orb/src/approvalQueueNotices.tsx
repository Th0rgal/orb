import { For, Show, createSignal } from "solid-js";
import {
  approveItems,
  batchApprovable,
  denyItem,
  itemDetail,
  itemRequester,
  itemTitle,
  queueSummary,
  type ApprovalItem,
} from "./approvalQueue";
import { ApprovalCancelled } from "./deviceApproval";
import { CloseIcon } from "./icons";
import { FingerprintIcon } from "./approvalIcons";
import { useNow } from "./time";
import { dismissToast, notify } from "./toast";

/**
 * Every pending approval (secret, privileged and mission access) shares one
 * bottom card, centred on the composer. One request shows its title, who
 * asks, why, and Deny / Allow; several show one row each, a summary by risk,
 * and "Approve all", which signs exactly the rows on screen. Critical rows
 * (root, secret delete or move) stand out and stay out of "Approve all"
 * unless ticked.
 */
const KEY = "approval-queue";
const [pending, setPending] = createSignal<ApprovalItem[]>([]);
/** Closed with the X, or being answered right now. */
const [hidden, setHidden] = createSignal<ReadonlySet<string>>(new Set());
const [includeCritical, setIncludeCritical] = createSignal(false);
/** When the visible set last changed: a batch must not catch a request that just appeared. */
const [changedAt, setChangedAt] = createSignal(0);
const SETTLE_MS = 1500;
let lastKeys = "";
let openReview = () => {};

const key = (i: Pick<ApprovalItem, "kind" | "id">) => `${i.kind}:${i.id}`;
const visible = () => pending().filter((i) => !hidden().has(key(i)));
const hide = (items: ApprovalItem[], on: boolean) =>
  setHidden((prev) => {
    const next = new Set(prev);
    for (const i of items) on ? next.add(key(i)) : next.delete(key(i));
    return next;
  });

export function syncApprovalQueue(items: ApprovalItem[], review: () => void) {
  openReview = review;
  setPending(items);
  const live = new Set(items.map(key));
  setHidden((prev) => new Set([...prev].filter((k) => live.has(k))));
  // A changed item (new digest) counts as a change too.
  const keys = visible().map((i) => `${key(i)}:${i.digest}`).join(",");
  if (keys !== lastKeys) { lastKeys = keys; setChangedAt(Date.now()); setIncludeCritical(false); }
  if (!visible().length) return dismissToast(KEY);
  notify({ key: KEY, kind: "info", variant: "secret", title: "", content: () => <ApprovalQueueCard /> });
}

function act(items: ApprovalItem[], approve: boolean) {
  hide(items, true);
  if (!visible().length) dismissToast(KEY);
  void (async () => {
    try {
      if (approve) await approveItems(items);
      else for (const i of items) await denyItem(i);
    } catch (e) {
      hide(items, false);
      syncApprovalQueue(pending(), openReview);
      if (e instanceof ApprovalCancelled) return;
      notify({
        kind: "error",
        title: approve ? "Could not approve" : "Could not deny",
        message: e instanceof Error ? e.message : String(e),
      });
    }
  })();
}

function ApprovalQueueCard() {
  const now = useNow(250);
  const list = visible;
  const one = () => (list().length === 1 ? list()[0] : undefined);
  const summary = () => queueSummary(list());
  const ready = () => batchApprovable(list(), includeCritical());
  const close = () => { hide(list(), true); dismissToast(KEY); };
  return <div class="secret-card access-card" data-testid="approval-queue-card">
    <div class="secret-card-top">
      <span class="toast-glyph" aria-hidden="true"><FingerprintIcon /></span>
      <div class="toast-body">
        <span class="toast-title">
          <Show when={one()} fallback={<>{list().length} approval requests</>}>
            {(i) => <strong classList={{ "approval-critical": i().risk === "critical" }}>{itemTitle(i())}</strong>}
          </Show>
          <Show when={one()}>{(i) => <span class="toast-sub" title={i().requester_mission_id}>asked by {itemRequester(i())}</span>}</Show>
        </span>
        <Show when={one()?.reason}><span class="toast-message">{one()!.reason}</span></Show>
        <Show when={one() && itemDetail(one()!)}><span class="access-scope">{itemDetail(one()!)}</span></Show>
      </div>
      <button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss" onClick={close}><CloseIcon size={13} /></button>
    </div>
    <Show when={!one()}>
      <div class="secret-rows">
        <For each={list()}>{(i) =>
          <div class="secret-row" classList={{ "approval-critical": i.risk === "critical" }} data-testid="approval-queue-row">
            <div class="toast-body">
              <strong class="secret-row-key">{itemTitle(i)}</strong>
              <span class="secret-row-reason" title={i.reason}>{itemRequester(i)}{i.reason ? `: ${i.reason}` : ""}</span>
            </div>
            <button type="button" class="toast-btn" onClick={() => act([i], false)}>Deny</button>
            <button type="button" class="toast-btn primary secret-row-ok" title="Allow" aria-label="Allow" onClick={() => act([i], true)}><FingerprintIcon size={14} /></button>
          </div>}
        </For>
      </div>
      <div class="approval-batch" data-testid="approval-queue-summary">
        <span class="access-scope">{summary().risks}</span>
        <span class="access-scope" title={summary().missions}>for {summary().missions}</span>
        <Show when={summary().critical}>
          <label class="approval-critical-confirm">
            <input type="checkbox" checked={includeCritical()} onChange={(e) => setIncludeCritical(e.currentTarget.checked)} />
            Include {summary().critical === 1 ? "the critical request" : `${summary().critical} critical requests`} (root, secret delete or move)
          </label>
        </Show>
      </div>
    </Show>
    <div class="secret-bar">
      <span class="secret-grace">Touch ID required</span>
      <button type="button" class="toast-link" onClick={() => { close(); openReview(); }}>Review</button>
      <Show when={one()} fallback={<button type="button" class="toast-btn" onClick={() => act(list(), false)}>Deny all</button>}>
        {(i) => <>
          <button type="button" class="toast-btn" onClick={() => act([i()], false)}>Deny</button>
          <button type="button" class="toast-btn primary" onClick={() => act([i()], true)}><FingerprintIcon size={14} />Allow</button>
        </>}
      </Show>
      <Show when={!one() && ready().length}>
        <button type="button" class="toast-btn primary" disabled={now() - changedAt() < SETTLE_MS} onClick={() => {
          // Approve exactly what was on screen when the button became active.
          if (Date.now() - changedAt() >= SETTLE_MS) act(ready(), true);
        }}>
          <FingerprintIcon size={14} />{ready().length === list().length ? "Approve all" : `Approve ${ready().length}`}
        </button>
      </Show>
    </div>
  </div>;
}
