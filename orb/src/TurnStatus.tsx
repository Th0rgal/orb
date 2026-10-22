import { formatElapsed, useNow } from "./time";
import { isRecord, readJson, writeJson } from "./storage";
import { createMemo, Show } from "solid-js";
import type { StreamItem } from "./transcriptModel";
import { latestTaskList } from "./taskList";

// Live events and cached transcripts carry no timestamp. Remember when each message was first
// seen (its send time when observed live) so leaving and reopening a mission keeps the count.
const SEEN_KEY = "orb.turn-started:v1";
function seenStore(): Record<string, number> {
  return readJson<Record<string, number>>(SEEN_KEY, {}, isRecord);
}
export function rememberTurnStart(key: string, now = Date.now()): number {
  const store = seenStore();
  if (store[key]) return store[key];
  store[key] = now;
  const keys = Object.keys(store);
  if (keys.length > 200) for (const k of keys.sort((a, b) => store[a] - store[b]).slice(0, keys.length - 200)) delete store[k];
  writeJson(SEEN_KEY, store);
  return now;
}

/** When a message was first seen, without recording it. */
export function seenTurnStart(key: string): number | undefined {
  return seenStore()[key] || undefined;
}
/** Turn start: the latest delivered user message's server time, else when it was first seen. */
export function turnStartedAt(items: StreamItem[]): number | undefined {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) {
      const t = item.at ? Date.parse(item.at) : NaN;
      if (Number.isFinite(t)) return t;
      return rememberTurnStart(item.messageId ?? item.key);
    }
  }
}
/** A short activity for a running tool. The transcript row just above already shows the
 * full command or path, so the status line names the kind of work, not the step again. */
export function toolActivity(name: string): string {
  const n = name.replace(/^functions\./, "").replace(/^mcp__[^_]+(?:__|_)/, "").toLowerCase();
  if (/bash|shell|exec|command|terminal|run_command/.test(n)) return "Running a command";
  if (/edit|write|replace|patch|apply|create_file|multi_?edit/.test(n)) return "Editing files";
  if (/grep|glob|search|find|codebase/.test(n)) return "Searching";
  if (/read|view|cat|open|list|ls/.test(n)) return "Reading files";
  if (/web|fetch|browse|navigate|http|url/.test(n)) return "Browsing";
  if (/task|agent|delegate|spawn/.test(n)) return "Delegating";
  if (/todo|plan/.test(n)) return "Planning";
  return "Working";
}
/** What the agent is doing right now, from the newest unfinished item. */
export function currentStep(items: StreamItem[]): string {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) break;
    if (item.kind === "tool" && !item.done) return toolActivity(item.name);
    if (item.kind === "think" && !item.done) return "Thinking";
    if (item.kind === "text" && item.live) return "Writing";
  }
  return "Working";
}
export { formatElapsed };

/** Compact live status above the composer (Codex goal chip / Claude Code spinner):
 * elapsed turn time, the current step and checklist progress, without scrolling. */
export function TurnStatus(p: { items: StreamItem[] }) {
  const now = useNow(1000);
  const seen = Date.now();
  const started = createMemo(() => turnStartedAt(p.items) ?? seen);
  const checklist = createMemo(() => latestTaskList(p.items));
  const done = () => checklist()?.tasks.filter((t) => t.status === "completed").length ?? 0;
  return (
    <div class="turn-status" role="status" aria-live="off">
      <span class="turn-status-dot" aria-hidden="true" />
      <span class="turn-status-step shimmer">{currentStep(p.items)}</span>
      <span class="turn-status-meta">{formatElapsed(now() - started())}</span>
      <Show when={checklist()?.tasks.length}>
        <span class="turn-status-meta">· {done()}/{checklist()!.tasks.length} tasks</span>
      </Show>
    </div>
  );
}
