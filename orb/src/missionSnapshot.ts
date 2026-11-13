/**
 * Full mission snapshots (reads and list rows): which one wins, which
 * execution facts it owns, and what happens to an unacknowledged follow-up
 * when the mission ends. Spec: docs/ui/mission-status.md, fixture:
 * shared/orb-spec/fixtures/mission-terminal-reconcile.json.
 */
import { normalizeFollowupPrompt } from "./followupQueueState";

type Fenced = { updated_at?: string | null; run_generation?: number | null; state_revision?: number | null };

/** Execution facts a full snapshot owns: absent means cleared. */
export const SNAPSHOT_EXECUTION_FIELDS = ["remote_job", "queue_wait", "execution", "terminal_reason", "recovery"] as const;

const num = (value: unknown): number | undefined => typeof value === "number" && Number.isFinite(value) ? value : undefined;

/** Whether `next` is at least as new as `prev`: run generation, then state revision, then updated_at. */
export function snapshotAdmitted(prev: Fenced, next: Fenced): boolean {
  const prevGen = num(prev.run_generation), nextGen = num(next.run_generation);
  if (prevGen !== undefined && nextGen !== undefined && prevGen !== nextGen) return nextGen > prevGen;
  const prevRev = num(prev.state_revision), nextRev = num(next.state_revision);
  if (prevRev !== undefined && nextRev !== undefined && prevRev !== nextRev) return nextRev > prevRev;
  const prevTs = Date.parse(prev.updated_at || ""), nextTs = Date.parse(next.updated_at || "");
  return Number.isNaN(prevTs) || Number.isNaN(nextTs) || nextTs >= prevTs;
}

/** `next` with every execution fact it omits explicitly cleared. */
export function withOwnedExecution<M extends object>(next: M): M {
  const out = { ...next } as Record<string, unknown>;
  for (const key of SNAPSHOT_EXECUTION_FIELDS) if (out[key] === undefined) out[key] = null;
  return out as M;
}

export type FollowupFate = "keep" | "not_sent" | "discard";

/**
 * A follow-up Core has not acknowledged, seen against a terminal snapshot:
 * delivered after posting (same normalized content) is superseded; otherwise a
 * terminal snapshot newer than the send makes it "not sent". An acknowledged
 * one belongs to the queue.
 */
export function followupAfterTerminal(
  draft: { content: string; postedAt: number; acknowledged: boolean },
  terminalAt: number,
  delivered: readonly { content: string; at: number }[],
): FollowupFate {
  if (draft.acknowledged) return "keep";
  const text = normalizeFollowupPrompt(draft.content);
  if (delivered.some(entry => entry.at >= draft.postedAt && normalizeFollowupPrompt(entry.content) === text)) return "discard";
  return Number.isFinite(terminalAt) && terminalAt > draft.postedAt ? "not_sent" : "keep";
}
