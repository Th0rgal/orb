import { createEffect, createMemo, For, Show } from "solid-js";
import type { Mission } from "./api";
import type { StreamItem } from "./transcriptModel";
import { getCachedInboxDigest, requestInboxDigest, inboxDigestVersion } from "./inboxDigest";
import { DONE_STATUSES, isFailedStatus } from "./missionStatus";
import { missionResponseTimestampMs } from "./missionUnread";
import { inboxConfig } from "./inboxSettings";

const tone: Record<string, string> = { succeeded: "Done", failed: "Failed", interrupted: "Interrupted", waiting: "Waiting", needs_input: "Needs you" };

/** End-of-turn recap under the last answer (Claude Code's next-step box), reusing the
 * Inbox AI summary for this exact response so it costs no extra model call when cached. */
export function TurnRecap(p: { mission?: Mission; items: StreamItem[]; busy: boolean; onDraft: (text: string) => void }) {
  const updatedMs = createMemo(() => (p.mission ? missionResponseTimestampMs(p.mission) : 0));
  const latestTurn = createMemo(() => {
    let lastUser = -1;
    for (let i = p.items.length - 1; i >= 0; i--) {
      const it = p.items[i];
      if (it.kind === "user" && !it.queued) { lastUser = i; break; }
    }
    return p.items.slice(lastUser + 1);
  });
  // Require real assistant prose in the latest turn: an error-only failed launch has no answer to recap.
  const answered = createMemo(() => latestTurn().some((i) => i.kind === "text" && !!i.text.trim()));
  const digest = createMemo(() => { inboxDigestVersion(); return p.mission && updatedMs() ? getCachedInboxDigest(p.mission.id, updatedMs()) : undefined; });
  // Only the summary of this response, never an older one.
  const current = createMemo(() => { const d = digest(); return d && d.updatedMs === updatedMs() ? d : undefined; });
  const verdict = createMemo(() => {
    const status = (p.mission?.status ?? "").toLowerCase();
    const turn = latestTurn();
    if (isFailedStatus(status) || turn.some((i) => i.kind === "error" && !i.cancelled)) return "failed";
    if (status === "interrupted" || status === "cancelled" || status === "canceled" || turn.some((i) => i.kind === "error" && i.cancelled)) return "interrupted";
    if (DONE_STATUSES.has(status)) return "succeeded";
    if (status === "blocked") return "needs_input";
    return current()?.verdict ?? "waiting";
  });
  createEffect(() => {
    if (!p.mission || p.busy || !answered() || !updatedMs() || !inboxConfig().aiSummary) return;
    requestInboxDigest(p.mission, p.items, updatedMs(), 20);
  });
  return (
    <Show when={!p.busy && answered() && current()}>{(d) => (
      <aside class={`turn-recap verdict-${verdict()}`} aria-label="Turn summary">
        <div class="turn-recap-head"><span class="turn-recap-dot" aria-hidden="true" />{tone[verdict()] ?? verdict()}</div>
        <p>{d().outcome}</p>
        <Show when={d().unresolved || d().decision}><p class="dim">{d().decision || d().unresolved}</p></Show>
        <Show when={verdict() !== "failed" && verdict() !== "interrupted" && d().suggestions?.length}>
          <div class="turn-recap-actions"><For each={d().suggestions!.slice(0, 2)}>{(s) => <button type="button" class="s-btn sm" title="Put in the message box" onClick={() => p.onDraft(s)}>{s}</button>}</For></div>
        </Show>
      </aside>
    )}</Show>
  );
}
