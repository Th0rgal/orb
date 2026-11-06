import { isRecord, readJson } from "./storage";
import { writeInboxState } from "./inboxState";
import { createSignal } from "solid-js";
import { sideQuestionKey } from "./sideQuestionStorage";
import {
  DEFAULT_INBOX_CONFIG,
  ECO_QUIET_MS,
  formatInboxSummaryBadge,
  normalizeInboxConfig,
  normalizeSummaryMode,
  shouldRequestInboxDigest,
  type InboxConfig,
  type InboxSummaryMode,
  type InboxSummarySurface,
} from "./inboxPolicy";

export {
  DEFAULT_INBOX_CONFIG,
  ECO_QUIET_MS,
  formatInboxSummaryBadge,
  normalizeInboxConfig,
  normalizeSummaryMode,
  shouldRequestInboxDigest,
  type InboxConfig,
  type InboxSummaryMode,
  type InboxSummarySurface,
};

const [inboxConfigVersion, setInboxConfigVersion] = createSignal(0);
export { inboxConfigVersion };

export function inboxConfig(): InboxConfig {
  inboxConfigVersion();
  try {
    const parsed = readJson<Partial<InboxConfig> | null>(sideQuestionKey("settings:inbox"), null, isRecord);
    return normalizeInboxConfig(parsed);
  } catch {
    return { ...DEFAULT_INBOX_CONFIG };
  }
}

export function saveInboxConfig(
  next: Partial<InboxConfig> & Pick<InboxConfig, "aiSummary" | "model">,
  sync = true,
): boolean {
  try {
    const current = inboxConfig();
    const normalized = normalizeInboxConfig({
      ...current,
      ...next,
      model: next.model.trim() || DEFAULT_INBOX_CONFIG.model,
    });
    localStorage.setItem(sideQuestionKey("settings:inbox"), JSON.stringify(normalized));
    setInboxConfigVersion((v) => v + 1);
    if (sync) writeInboxState("preferences", normalized);
    return true;
  } catch {
    return false;
  }
}

/** Empty selection means Off and never overwrites the remembered model. */
export function inboxSummaryChoice(model: string, choice: string) {
  const selected = choice.trim();
  return { aiSummary: selected.length > 0, model: selected || model };
}

export function applySharedInboxPreferences(prefs: unknown): void {
  if (prefs === undefined || prefs === null) {
    writeInboxState("preferences", inboxConfig());
    return;
  }
  if (typeof prefs !== "object" || Array.isArray(prefs)) return;
  const p = prefs as Partial<InboxConfig>;
  if (typeof p.aiSummary !== "boolean" || typeof p.includeAutonomous !== "boolean" || typeof p.model !== "string" || !p.model.trim()) return;
  const normalized = normalizeInboxConfig(p);
  if (JSON.stringify(inboxConfig()) !== JSON.stringify(normalized)) saveInboxConfig(normalized, false);
}
