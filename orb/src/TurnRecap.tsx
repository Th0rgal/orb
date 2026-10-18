import { createEffect, createMemo, For, Show } from "solid-js";
import type { Mission } from "./api";
import type { StreamItem } from "./transcriptModel";
import { getCachedInboxDigest, requestInboxDigest, inboxDigestVersion } from "./inboxDigest";
import { missionResponseTimestampMs } from "./missionUnread";
import { inboxConfig } from "./inboxSettings";

const tone: Record<string, string> = { succeeded: "Done", failed: "Failed", waiting: "Waiting", needs_input: "Needs you" };

/** End-of-turn recap under the last answer (Claude Code's next-step box), reusing the
 * Inbox AI summary for this exact response so it costs no extra model call when cached. */
export function TurnRecap(p: { mission?: Mission; items: StreamItem[]; busy: boolean; onDraft: (text: string) => void }) {
  const updatedMs = createMemo(() => (p.mission ? missionResponseTimestampMs(p.mission) : 0));
  const answered = createMemo(() => { const last = [...p.items].reverse().find((i) => i.kind !== "think"); return !!last && last.kind !== "user"; });
  createEffect(() => {
    if (!p.mission || p.busy || !answered() || !updatedMs() || !inboxConfig().aiSummary) return;
    requestInboxDigest(p.mission, p.items, updatedMs(), 20);
  });
  const digest = createMemo(() => { inboxDigestVersion(); return p.mission && updatedMs() ? getCachedInboxDigest(p.mission.id, updatedMs()) : undefined; });
  // Only the summary of this response, never an older one.
  const current = createMemo(() => { const d = digest(); return d && d.updatedMs === updatedMs() ? d : undefined; });
  return (
    <Show when={!p.busy && answered() && current()}>{(d) => (
      <aside class={`turn-recap verdict-${d().verdict}`} aria-label="Turn summary">
        <div class="turn-recap-head"><span class="turn-recap-dot" aria-hidden="true" />{tone[d().verdict] ?? d().verdict}</div>
        <p>{d().outcome}</p>
        <Show when={d().unresolved || d().decision}><p class="dim">{d().decision || d().unresolved}</p></Show>
        <Show when={d().suggestions?.length}>
          <div class="turn-recap-actions"><For each={d().suggestions!.slice(0, 2)}>{(s) => <button type="button" class="s-btn sm" title="Put in the message box" onClick={() => p.onDraft(s)}>{s}</button>}</For></div>
        </Show>
      </aside>
    )}</Show>
  );
}
