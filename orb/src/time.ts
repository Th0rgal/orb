/** Relative times, durations and one shared clock per resolution. */
import { createSignal, getOwner, onCleanup, type Accessor } from "solid-js";
import { orbRelativeTimeString } from "./orbKernel";

/**
 * "just now", "12 min ago", "3 h ago" for a timestamp in milliseconds.
 * `round` rounds instead of truncating; `days` switches to days from 48 h.
 */
export function ago(timestampMs: number, now = Date.now(), opts: { round?: boolean; days?: boolean } = {}): string {
  const step = opts.round ? Math.round : Math.floor;
  const minutes = step((now - timestampMs) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = step(minutes / 60);
  return opts.days && hours >= 48 ? `${Math.round(hours / 24)} days ago` : `${hours} h ago`;
}

/**
 * Compact relative time for dense lists: "now", "5m", "3h", "2d", "1w".
 * Shared with the iOS and Android apps (shared/orb-spec/fixtures/relative-time.json):
 * under 45 s is "now", minutes clamp to at least 1, then hours, days, and
 * weeks from 7 days. A future timestamp counts as 0 s.
 */
export function compactAgo(timestampMs: number, now = Date.now()): string {
  return orbRelativeTimeString((now - timestampMs) / 1000);
}

/** "42 s", "3 min 05 s", "2 h 07". */
export function formatElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ${String(s % 60).padStart(2, "0")} s`;
  return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`;
}

type Clock = { now: Accessor<number>; set: (value: number) => void; users: number; timer?: ReturnType<typeof setInterval> };
const clocks = new Map<number, Clock>();

/**
 * The current time, refreshed every `resolutionMs`. Components that ask for
 * the same resolution share one timer, which stops when the last of them is
 * disposed. Outside a reactive owner the clock keeps running.
 */
export function useNow(resolutionMs: number): Accessor<number> {
  let clock = clocks.get(resolutionMs);
  if (!clock) {
    const [now, set] = createSignal(Date.now());
    clock = { now, set, users: 0 };
    clocks.set(resolutionMs, clock);
  }
  const c = clock;
  c.set(Date.now());
  if (c.users++ === 0) c.timer = setInterval(() => c.set(Date.now()), resolutionMs);
  if (getOwner()) onCleanup(() => {
    if (--c.users > 0) return;
    clearInterval(c.timer);
    c.timer = undefined;
  });
  return c.now;
}
