import { Show } from "solid-js";
import type { ControllerJob } from "./api";
import { useNow } from "./time";

/** How a controller is doing, derived from its Hermes job record. */
export type CronState = "running" | "paused" | "attention" | "scheduled";

export function cronState(job: ControllerJob | null | undefined, running = false): CronState {
  if (!job) return "scheduled";
  if (!job.enabled || job.state === "paused") return "paused";
  if (running || job.state === "running") return "running";
  if (job.failure_streak > 0 || (job.last_status && job.last_status !== "ok")) return "attention";
  return "scheduled";
}

/** 0..1 progress from the last run to the next one. */
function tickProgress(job: ControllerJob | null | undefined, now: number): number {
  const next = job?.next_run_at ? Date.parse(job.next_run_at) : NaN;
  const last = job?.last_run_at ? Date.parse(job.last_run_at) : NaN;
  if (!Number.isFinite(next) || !Number.isFinite(last) || next <= last) return 0;
  return Math.max(0, Math.min(1, (now - last) / (next - last)));
}

/** Clock-ring glyph: the arc fills toward the next tick; spins while ticking. */
export function CronGlyph(p: { job: ControllerJob | null | undefined; running?: boolean; size?: number }) {
  const now = useNow(30000);
  const size = () => p.size ?? 16;
  const r = 6;
  const c = 2 * Math.PI * r;
  const state = () => cronState(p.job, p.running);
  return (
    <svg class={`cron-glyph ${state()}`} width={size()} height={size()} viewBox="0 0 16 16" fill="none">
      <circle cx="8" cy="8" r={r} stroke="currentColor" stroke-width="1.5" opacity="1" />
      <Show when={state() !== "paused"}>
        <circle
          cx="8"
          cy="8"
          r={r}
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-dasharray={`${c}`}
          stroke-dashoffset={`${state() === "running" ? c * 0.7 : c * (1 - tickProgress(p.job, now()))}`}
          transform="rotate(-90 8 8)"
        />
      </Show>
      <path class="cron-clock-hands" d="M8 5.2V8l1.8 1.2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" opacity="0.9" />
    </svg>
  );
}

export function untilLabel(iso: string | null | undefined, now: number): string {
  if (!iso) return "";
  const delta = Date.parse(iso) - now;
  if (!Number.isFinite(delta)) return "";
  if (delta <= 0) return "due";
  const mins = Math.round(delta / 60000);
  if (mins < 1) return "in <1m";
  if (mins < 60) return `in ${mins}m`;
  const hours = Math.floor(mins / 60);
  return `in ${hours}h ${mins % 60}m`;
}
