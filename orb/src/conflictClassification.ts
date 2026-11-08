import type {
  ConflictClassification,
  ConflictDispositionTag,
} from "./api";

export type { ConflictClassification, ConflictDispositionTag };

function normalizeConflictCodeToken(raw: string): ConflictDispositionTag | undefined {
  const clean = raw.trim().toLowerCase();
  if (clean === "stopping" || clean === "remote_job_still_running" || clean === "turn_stopping") return "stopping";
  if (clean === "non_terminal_run" || clean === "already_running" || clean === "run_in_progress") return "non_terminal_run";
  if (clean === "already_ended" || clean === "run_already_ended" || clean === "mission_ended") return "already_ended";
  if (clean === "moved" || clean === "transferred" || clean === "mission_moved") return "moved";
  if (clean === "stale_receipt" || clean === "fenced_receipt" || clean === "stale_epoch") return "stale_receipt";
  return undefined;
}

function parseLegacyConflictPhrase(text: string): ConflictDispositionTag | undefined {
  if (/REMOTE_JOB_STILL_RUNNING|\bstopping\b/i.test(text)) return "stopping";
  if (/\balready running\b|\bnon[_ -]?terminal\b/i.test(text)) return "non_terminal_run";
  if (/\balready ended\b|\balready finished\b|\balready completed\b/i.test(text)) return "already_ended";
  if (/\bmoved\b|\btransferred\b|\bno longer runs on this computer\b/i.test(text)) return "moved";
  if (/\bstale[_ -]?receipt\b|\bfenced[_ -]?receipt\b|\bstale[_ -]?epoch\b|\breceipt is stale\b/i.test(text)) return "stale_receipt";
  return undefined;
}

export function parseConflictCodeFromDetail(detail: string): ConflictDispositionTag | undefined {
  const trimmed = detail.trim();
  if (!trimmed) return undefined;
  if (trimmed.startsWith("{")) {
    try {
      const parsed = JSON.parse(trimmed) as { code?: unknown; conflict_code?: unknown; error?: unknown; reason?: unknown; detail?: unknown };
      for (const candidate of [parsed.conflict_code, parsed.code, parsed.reason, parsed.error]) {
        if (typeof candidate === "string") {
          const direct = normalizeConflictCodeToken(candidate);
          if (direct) return direct;
        }
      }
      if (typeof parsed.detail === "string") {
        const nested = parseLegacyConflictPhrase(parsed.detail);
        if (nested) return nested;
      }
    } catch {
      // Fall through to legacy detail token inspection.
    }
  }
  const directToken = normalizeConflictCodeToken(trimmed.split(/[:\s]/, 1)[0] ?? "");
  if (directToken) return directToken;
  return parseLegacyConflictPhrase(trimmed);
}

/** Classify HTTP `409` or native invoke conflict errors into typed retryable vs terminal dispositions (`SM-23`, `SM-26`). */
export function classifyConflictError(error: unknown): ConflictClassification | null {
  let tag: ConflictDispositionTag | undefined;
  const status = (error as { status?: unknown } | null)?.status;
  const conflictCode = (error as { conflictCode?: unknown } | null)?.conflictCode;
  if (typeof conflictCode === "string") {
    tag = normalizeConflictCodeToken(conflictCode);
  }
  if (!tag && status === 409) {
    const detail = (error as { detail?: unknown } | null)?.detail;
    if (typeof detail === "string") {
      tag = parseConflictCodeFromDetail(detail);
    }
  }
  if (!tag) {
    const rawCode = (error as { conflict_code?: unknown; code?: unknown } | null)?.conflict_code ?? (error as { code?: unknown } | null)?.code;
    if (typeof rawCode === "string") {
      tag = normalizeConflictCodeToken(rawCode);
    }
  }
  if (!tag) {
    const msg = error instanceof Error ? error.message : String(error ?? "");
    if (status === 409 || /\b409\b/.test(msg) || /\balready running\b|\balready ended\b|\bstale[_ -]?receipt\b|\breceipt is stale\b|\bno longer runs on this computer\b/i.test(msg)) {
      tag = parseConflictCodeFromDetail(msg.replace(/^409\s+/, ""));
    }
  }
  if (!tag && status === 409) return null;
  if (!tag) return null;
  const retryable = tag === "stopping" || tag === "non_terminal_run";
  return { tag, retryable };
}
