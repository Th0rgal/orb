/** When an assistant turn completed and how long it worked, for the response action row. */

/** Parse an ISO timestamp or epoch ms; undefined when absent or invalid. */
export function toMs(value: string | number | undefined): number | undefined {
  if (value === undefined) return undefined;
  const ms = typeof value === "number" ? value : Date.parse(value);
  return Number.isFinite(ms) ? ms : undefined;
}

export type TurnTiming = { completedAt: number; workedMs?: number };

/** Completion time plus duration from the turn's start, when both ends are known and ordered. */
export function turnTiming(startedAt: string | number | undefined, completedAt: string | number | undefined): TurnTiming | undefined {
  const end = toMs(completedAt);
  if (end === undefined) return undefined;
  const start = toMs(startedAt);
  return start !== undefined && start <= end ? { completedAt: end, workedMs: end - start } : { completedAt: end };
}

/** "just now", "5m ago", "2h ago", "6d ago", then a short date ("Oct 16") from 30 days. */
export function turnAgo(completedAt: number, now = Date.now(), locale?: string): string {
  const minutes = Math.floor(Math.max(0, now - completedAt) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const date = new Date(completedAt);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return date.toLocaleDateString(locale, sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" });
}

/** Absolute local date and time: "Oct 16, 2026, 5:30 AM". */
export function turnDate(completedAt: number, locale?: string, timeZone?: string): string {
  return new Date(completedAt).toLocaleString(locale, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", ...(timeZone ? { timeZone } : {}) });
}

/** Compact work duration: "42s", "3m 5s", "12h 6m", "2d 3h". */
export function workedFor(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return s % 60 ? `${m}m ${s % 60}s` : `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}d ${h % 24}h` : `${d}d`;
}
