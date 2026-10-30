export type InboxSummaryMode = "standard" | "on_open" | "eco";
export type InboxSummarySurface = "inbox" | "background" | "recap";

export type InboxConfig = {
  inboxEnabled: boolean;
  aiSummary: boolean;
  summaryMode: InboxSummaryMode;
  includeAutonomous: boolean;
  model: string;
};

export const ECO_QUIET_MS = 3_600_000;

export const DEFAULT_INBOX_CONFIG: InboxConfig = {
  inboxEnabled: true,
  aiSummary: true,
  summaryMode: "standard",
  includeAutonomous: false,
  model: "builtin/smart",
};

export function normalizeSummaryMode(raw: unknown): InboxSummaryMode {
  return raw === "on_open" || raw === "eco" ? raw : "standard";
}

export function normalizeInboxConfig(raw: unknown): InboxConfig {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { ...DEFAULT_INBOX_CONFIG };
  }
  const p = raw as Partial<Record<keyof InboxConfig, unknown>>;
  return {
    inboxEnabled: typeof p.inboxEnabled === "boolean" ? p.inboxEnabled : DEFAULT_INBOX_CONFIG.inboxEnabled,
    includeAutonomous: p.includeAutonomous === true,
    aiSummary: typeof p.aiSummary === "boolean" ? p.aiSummary : DEFAULT_INBOX_CONFIG.aiSummary,
    summaryMode: normalizeSummaryMode(p.summaryMode),
    model: typeof p.model === "string" && p.model.trim() ? p.model.trim() : DEFAULT_INBOX_CONFIG.model,
  };
}

export function shouldRequestInboxDigest(
  prefs: Partial<Pick<InboxConfig, "inboxEnabled" | "aiSummary" | "summaryMode">>,
  surface: InboxSummarySurface,
  isLive: boolean,
  updatedMs: number,
  nowMs = Date.now(),
): boolean {
  const inboxEnabled = prefs.inboxEnabled ?? true;
  const aiSummary = prefs.aiSummary ?? true;
  const mode = normalizeSummaryMode(prefs.summaryMode);
  if (!inboxEnabled || !aiSummary) return false;
  if (mode === "standard") return true;
  if (surface !== "inbox" || isLive) return false;
  if (mode === "on_open") return true;
  return updatedMs > 0 && nowMs - updatedMs >= ECO_QUIET_MS;
}

export function formatInboxSummaryBadge(cfg: Partial<InboxConfig>): string {
  const normalized = normalizeInboxConfig(cfg);
  if (!normalized.inboxEnabled) return "Inbox off";
  if (!normalized.aiSummary) return "AI summary off";
  if (normalized.summaryMode === "eco") return `Eco · ${normalized.model}`;
  if (normalized.summaryMode === "on_open") return `On open · ${normalized.model}`;
  return `AI · ${normalized.model}`;
}
