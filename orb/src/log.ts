/**
 * Structured client log. Entries go through `diagnostics.note`, so in the
 * desktop app they land in `~/.orb/logs/orb-<date>.jsonl` next to the
 * performance records. Each scope writes at most one entry per
 * `RATE_MS`; entries dropped in between are counted on the next one, so a
 * failure inside a 1 s poll cannot flood the log.
 */
import { note } from "./diagnostics";

export type LogLevel = "debug" | "warn" | "error";
export type LogData = Record<string, unknown>;

export const RATE_MS = 10_000;
const MAX_TEXT = 300;
const last = new Map<string, { at: number; dropped: number }>();

/** A short, serializable description of anything thrown. */
export function errorText(error: unknown): string {
  const text = error instanceof Error ? `${error.name === "Error" ? "" : `${error.name}: `}${error.message}` : typeof error === "string" ? error : (() => { try { return JSON.stringify(error); } catch { return String(error); } })();
  return (text ?? String(error)).slice(0, MAX_TEXT);
}

function write(level: LogLevel, scope: string, message: string, data?: LogData): boolean {
  const now = Date.now();
  const seen = last.get(scope);
  if (seen && now - seen.at < RATE_MS) { seen.dropped++; return false; }
  last.set(scope, { at: now, dropped: 0 });
  note(`log.${level}`, { scope, message: message.slice(0, MAX_TEXT), ...(data ? { data } : {}), ...(seen?.dropped ? { dropped: seen.dropped } : {}) });
  if (import.meta.env?.DEV && level !== "debug") console[level](`[${scope}] ${message}`, data ?? "");
  return true;
}

export const log = {
  debug: (scope: string, message: string, data?: LogData) => write("debug", scope, message, data),
  warn: (scope: string, message: string, data?: LogData) => write("warn", scope, message, data),
  error: (scope: string, message: string, data?: LogData) => write("error", scope, message, data),
};

/**
 * A `.catch` handler for failures that are deliberately not shown to the
 * user (best-effort saves, background refreshes): the promise still settles
 * to `undefined`, but the failure is recorded under `scope`.
 *
 *     void saveDraft(scope, draft).catch(swallow("composer.saveDraft", { scope }));
 */
export function swallow(scope: string, data?: LogData): (error: unknown) => undefined {
  return (error: unknown) => { write("warn", scope, errorText(error), data); return undefined; };
}

/** Test hook: forget the rate-limit window. */
export function resetLogForTests(): void { last.clear(); }
