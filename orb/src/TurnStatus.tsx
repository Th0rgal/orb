import { createMemo, createSignal, onCleanup, Show } from "solid-js";
import type { StreamItem } from "./transcriptModel";
import { latestTaskList } from "./taskList";
import { toolTarget } from "./Transcript";

/** Turn start: the latest delivered user message's server time. */
export function turnStartedAt(items: StreamItem[]): number | undefined {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) { const t = item.at ? Date.parse(item.at) : NaN; return Number.isFinite(t) ? t : undefined; }
  }
}
/** What the agent is doing right now, from the newest unfinished item. */
export function currentStep(items: StreamItem[]): string {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) break;
    if (item.kind === "tool" && !item.done) return `${item.name.replace(/^functions\./, "")} ${toolTarget(item.name, item.args) ?? ""}`.trim();
    if (item.kind === "think" && !item.done) return "Thinking";
    if (item.kind === "text" && item.live) return "Writing";
  }
  return "Working";
}
export function formatElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ${String(s % 60).padStart(2, "0")} s`;
  return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`;
}

/** Compact live status above the composer (Codex goal chip / Claude Code spinner):
 * elapsed turn time, the current step and checklist progress, without scrolling. */
export function TurnStatus(p: { items: StreamItem[] }) {
  const [now, setNow] = createSignal(Date.now());
  const seen = Date.now();
  const timer = setInterval(() => setNow(Date.now()), 1000);
  onCleanup(() => clearInterval(timer));
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
