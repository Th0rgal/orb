import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, getJwt, isConnected, type Mission } from "./api";
import { backgroundWake as parseBackgroundWake } from "./backgroundWake";
import { formatToolDetail, isSyntheticUserMessage } from "./inboxModel";
import { inboxConfig } from "./inboxSettings";
import { messageImages } from "./messageImages";
import { messagePresentation as parseMessagePresentation } from "./messagePresentation";
import { remoteLog as parseRemoteLog } from "./remoteLog";
import { sideQuestionKey } from "./sideQuestionStorage";
import type { StreamItem } from "./transcriptModel";
import { workSummary } from "./workModel";

export type InboxVerdict = "succeeded" | "failed" | "waiting" | "needs_input";

export type InboxDigest = {
  /** Legacy summaries may contain a generated title; new summaries never replace the mission title. */
  goal?: string;
  task: string;
  outcome: string;
  verdict: InboxVerdict;
  model?: string;
  aiGenerated?: boolean;
  updatedMs: number;
  schemaVersion?: 7;
  sourceUpdatedAt?: string;
  sourceRevision?: string;
  generatedAt?: string;
  context?: string;
  contextDetails?: string;
  unresolved?: string;
  decision?: string;
  suggestions?: string[];
  sources?: Array<{ quote: string }>;
};

const STORAGE_KEY = "orb:inbox-digest:v7";
const LEGACY_STORAGE_KEYS = ["orb:inbox-digest:v4", "orb:inbox-digest:v5", "orb:inbox-digest:v6"];
const MAX_CACHE_ENTRIES = 160;
const MAX_CONCURRENT = 6;

const [inboxDigestVersion, setInboxDigestVersion] = createSignal(0);
export { inboxDigestVersion };

let digestBumpTimer: ReturnType<typeof setTimeout> | undefined;
function bumpDigestVersion() {
  if (digestBumpTimer !== undefined) return;
  digestBumpTimer = setTimeout(() => {
    digestBumpTimer = undefined;
    setInboxDigestVersion((v) => v + 1);
  }, 40);
}

let memoryCache: Record<string, InboxDigest> | null = null;
let loadedStorageKey: string | null = null;
const inFlight = new Set<string>();
const failedKeys = new Map<string, number>();
const queue: Array<{ priority: number; run: () => Promise<void> }> = [];
let activeCount = 0;

function currentStorageKey(): string {
  return sideQuestionKey(STORAGE_KEY);
}

function ensureCacheLoaded(): Record<string, InboxDigest> {
  const key = currentStorageKey();
  if (memoryCache && loadedStorageKey === key) return memoryCache;
  loadedStorageKey = key;
  memoryCache = {};
  // Old summaries keep the first paint useful, but must never suppress a new-schema request.
  for (const storageKey of [...LEGACY_STORAGE_KEYS.map(sideQuestionKey), key]) {
    try {
      const raw = JSON.parse(localStorage.getItem(storageKey) ?? "{}");
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
      for (const [cacheKey, value] of Object.entries(raw)) {
        if (!value || typeof value !== "object") continue;
        const digest = value as InboxDigest;
        if (typeof digest.outcome !== "string" || !Number.isFinite(digest.updatedMs)) continue;
        const { schemaVersion, context, contextDetails, unresolved, decision, suggestions, sources, ...legacy } = digest;
        memoryCache[cacheKey] = storageKey === key && schemaVersion === 7 && Boolean(digest.sourceRevision)
          ? digest
          : legacy;
      }
    } catch {
      // A damaged legacy cache must not hide a valid current cache.
    }
  }
  return memoryCache!;
}

function persistCache(cache: Record<string, InboxDigest>): void {
  try {
    const keys = Object.keys(cache);
    if (keys.length > MAX_CACHE_ENTRIES) {
      const sorted = keys.sort((a, b) => (cache[b]?.updatedMs ?? 0) - (cache[a]?.updatedMs ?? 0));
      const trimmed: Record<string, InboxDigest> = {};
      for (const k of sorted.slice(0, MAX_CACHE_ENTRIES)) {
        trimmed[k] = cache[k];
      }
      memoryCache = trimmed;
      localStorage.setItem(currentStorageKey(), JSON.stringify(trimmed));
      return;
    }
    localStorage.setItem(currentStorageKey(), JSON.stringify(cache));
  } catch {
    // Ignore storage quota errors
  }
}

function makeCacheKey(missionId: string, updatedMs: number, model: string): string {
  return `${missionId}:${updatedMs}:${model}`;
}

export function getExactCachedInboxDigest(
  missionId: string,
  updatedMs: number,
  model = inboxConfig().model,
): InboxDigest | undefined {
  inboxDigestVersion();
  const cache = ensureCacheLoaded();
  const exact = cache[makeCacheKey(missionId, updatedMs, model)];
  if (exact) return exact;
  const prefix = `${missionId}:${updatedMs}:`;
  for (const [k, v] of Object.entries(cache)) {
    if (k.startsWith(prefix)) return v;
  }
  return undefined;
}

/** Only exact, current-schema results can provide actionable reply context. */
export function getCurrentInboxDigest(
  missionId: string,
  updatedMs: number,
  model = inboxConfig().model,
): InboxDigest | undefined {
  inboxDigestVersion();
  const digest = ensureCacheLoaded()[makeCacheKey(missionId, updatedMs, model)];
  return digest?.schemaVersion === 7 && Boolean(digest.sourceRevision) && digest.updatedMs === updatedMs && Date.parse(digest.sourceUpdatedAt ?? "") + 2000 >= updatedMs ? digest : undefined;
}

export function getCachedInboxDigest(
  missionId: string,
  updatedMs: number,
  model = inboxConfig().model,
): InboxDigest | undefined {
  const exact = getExactCachedInboxDigest(missionId, updatedMs, model);
  if (exact) return exact;
  // Stale-while-revalidate fallback: return the most recent cached digest for this missionId
  // so rows render stably on frame 1 even if updatedMs shifted slightly on a poll.
  const cache = ensureCacheLoaded();
  const missionPrefix = `${missionId}:`;
  let latest: InboxDigest | undefined;
  for (const [k, v] of Object.entries(cache)) {
    if (k.startsWith(missionPrefix) && (!latest || (v.updatedMs ?? 0) >= (latest.updatedMs ?? 0))) {
      latest = v;
    }
  }
  return latest;
}

export function storeInboxDigest(
  missionId: string,
  updatedMs: number,
  model: string,
  digest: InboxDigest,
): void {
  const cache = ensureCacheLoaded();
  cache[makeCacheKey(missionId, updatedMs, model)] = digest;
  persistCache(cache);
  bumpDigestVersion();
}

function pumpQueue(): void {
  while (activeCount < MAX_CONCURRENT && queue.length > 0) {
    queue.sort((a, b) => a.priority - b.priority);
    const next = queue.shift()!;
    activeCount++;
    void next.run().finally(() => {
      activeCount--;
      pumpQueue();
    });
  }
}

function cleanUserText(raw: string): string {
  const pres = parseMessagePresentation(raw).text;
  const wake = parseBackgroundWake(pres);
  if (wake) {
    return `Background task \`${wake.task}\` (${wake.command}) finished${wake.killed ? " (killed)" : ""}`;
  }
  return messageImages(pres).text.replace(/\[Image #\d+\]/gi, "").trim();
}

function cleanAssistantText(raw: string): string {
  return parseRemoteLog(raw)
    .text.replace(/\n*diagnostics:\s*\d{4}-\d{2}-\d{2}T[\s\S]*$/i, "")
    .trim();
}

export function buildDigestSnapshot(mission: Mission, items?: StreamItem[]): string {
  const lines: string[] = [];
  lines.push(`Mission title: ${mission.title ?? "Untitled"}`);
  if (mission.goal_objective && mission.goal_objective !== mission.title) {
    lines.push(`Initial goal objective: ${mission.goal_objective.slice(0, 600)}`);
  }
  lines.push(`Mission status: ${mission.status}`);
  if (mission.terminal_reason) lines.push(`Terminal reason: ${mission.terminal_reason}`);
  if (mission.status_message) lines.push(`Status message: ${mission.status_message}`);
  if (mission.remote_job?.error) lines.push(`Remote error: ${mission.remote_job.error}`);

  let firstUser = "";
  let lastUser = "";
  const assistantBlocks: string[] = [];
  let lastError = "";
  const recentTools: Array<Extract<StreamItem, { kind: "tool" }>> = [];

  if (items && items.length > 0) {
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it.kind === "user" && !it.queued && it.text.trim() && !isSyntheticUserMessage(it.text)) {
        firstUser = cleanUserText(it.text);
        break;
      }
    }
    let lastUserIdx = -1;
    for (let i = items.length - 1; i >= 0; i--) {
      const it = items[i];
      if (it.kind === "user" && !it.queued && it.text.trim()) {
        if (!isSyntheticUserMessage(it.text) && !lastUser) {
          lastUser = cleanUserText(it.text);
        }
        if (lastUserIdx < 0) lastUserIdx = i;
      }
    }
    const startIdx = lastUserIdx >= 0 ? lastUserIdx + 1 : 0;
    for (let i = startIdx; i < items.length; i++) {
      const it = items[i];
      if (it.kind === "tool") recentTools.push(it);
      else if (it.kind === "text" && it.text.trim()) {
        const cleaned = cleanAssistantText(it.text);
        if (cleaned) assistantBlocks.push(cleaned);
      } else if (it.kind === "error" && it.text.trim()) {
        const cleaned = cleanAssistantText(it.text);
        if (cleaned.length >= 220) {
          assistantBlocks.push(cleaned);
        } else {
          lastError = cleaned;
        }
      }
    }
  }

  if (Array.isArray(mission.history)) {
    for (let i = 0; i < mission.history.length; i++) {
      const h = mission.history[i];
      if (h.role === "user" && h.content?.trim() && !isSyntheticUserMessage(h.content)) {
        firstUser = firstUser || cleanUserText(h.content);
        break;
      }
    }
    for (let i = mission.history.length - 1; i >= 0; i--) {
      const h = mission.history[i];
      if (!lastUser && h.role === "user" && h.content?.trim() && !isSyntheticUserMessage(h.content)) {
        lastUser = cleanUserText(h.content);
      }
      if (h.role === "assistant" && h.content?.trim()) {
        const cleaned = cleanAssistantText(h.content);
        if (cleaned && !assistantBlocks.includes(cleaned)) {
          assistantBlocks.push(cleaned);
          break;
        }
      }
    }
  }

  if (firstUser && firstUser !== lastUser) {
    lines.push(`Initial user request:\n${firstUser.slice(0, 500)}`);
  }
  if (lastUser) lines.push(`Latest user request:\n${lastUser.slice(0, 700)}`);
  if (recentTools.length > 0) {
    const details = recentTools.slice(-8).map(formatToolDetail).join("; ");
    lines.push(
      `Tools executed in latest turn: ${workSummary(recentTools)}${details ? ` (${details})` : ""}`,
    );
  }
  if (lastError) lines.push(`Recorded error:\n${lastError.slice(0, 500)}`);
  if (assistantBlocks.length > 0) {
    const combined = assistantBlocks.slice(-3).join("\n\n");
    lines.push(`Latest agent response:\n${combined.slice(-2400)}`);
  }

  return lines.join("\n\n");
}


function boundedText(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text && text.length <= limit ? text : undefined;
}

function groundedSources(value: unknown, snapshot: string): Array<{ quote: string }> {
  if (!Array.isArray(value)) return [];
  // Ground links in message excerpts, not mission metadata or the summarizer's instructions.
  const headers = "Initial user request|Latest user request|Latest agent response|Recorded error";
  const sections = snapshot.matchAll(new RegExp(
    `(?:^|\\n\\n)(?:${headers}):\\n([\\s\\S]*?)(?=\\n\\n(?:${headers}|Tools executed in latest turn):|$)`,
    "g",
  ));
  const messages = [...sections].map((match) => match[1]);
  const quotes = new Set<string>();
  for (const source of value) {
    if (!source || typeof source !== "object") continue;
    const quote = boundedText((source as { quote?: unknown }).quote, 240);
    if (quote && quote.length >= 12 && messages.some((message) => message.includes(quote))) {
      quotes.add(quote);
    }
    if (quotes.size === 3) break;
  }
  return [...quotes].map((quote) => ({ quote }));
}

export function parseDigestJson(
  raw: string,
  updatedMs: number,
  model?: string,
  snapshot?: string,
): InboxDigest | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(trimmed.slice(start, end + 1)) as Record<string, unknown>;
    if (!parsed || Array.isArray(parsed)) return null;
    if (parsed.schemaVersion === 7) {
      if (!snapshot) return null;
      const outcome = boundedText(parsed.outcome, 420);
      const sources = groundedSources(parsed.sources, snapshot);
      if (!outcome || !sources.length) return null;
      const context = boundedText(parsed.context, 180);
      const contextDetails = boundedText(parsed.contextDetails, 420);
      const unresolved = boundedText(parsed.unresolved, 320);
      const decision = boundedText(parsed.decision, 240);
      const suggestions = Array.isArray(parsed.suggestions)
        ? [...new Set(parsed.suggestions
            .map((value) => boundedText(value, 240))
            .filter((value): value is string => Boolean(value)))].slice(0, 2)
        : [];
      return {
        schemaVersion: 7,
        task: "",
        outcome,
        // Kept for older consumers; mission state, never the summary, drives triage.
        verdict: "waiting",
        model,
        aiGenerated: true,
        updatedMs,
        ...(context ? { context } : {}),
        ...(contextDetails ? { contextDetails } : {}),
        ...(unresolved ? { unresolved } : {}),
        ...(decision ? { decision } : {}),
        ...(suggestions.length ? { suggestions } : {}),
        sources,
      };
    }
    // Kept for persisted v4/v5 summaries and older clients. Generation only accepts v7 below.
    const goal = boundedText(parsed.goal, 500);
    const task = boundedText(parsed.task, 1000) ?? "";
    const outcome = boundedText(parsed.outcome, 4000) ?? boundedText(parsed.overview, 4000) ?? "";
    if (!goal && !task && !outcome) return null;
    const rawVerdict = typeof parsed.verdict === "string" ? parsed.verdict.trim().toLowerCase() : "";
    const verdict: InboxVerdict = rawVerdict === "failed" || rawVerdict === "waiting" || rawVerdict === "needs_input"
      ? rawVerdict : "succeeded";
    return { ...(goal ? { goal } : {}), task, outcome, verdict, model, aiGenerated: true, updatedMs };
  } catch {
    return null;
  }
}

async function fetchSharedDigest(missionId: string, model: string, updatedMs: number): Promise<InboxDigest> {
  const version = connectionVersion();
  const response = await fetch(`${getApiUrl()}/api/control/missions/${encodeURIComponent(missionId)}/inbox-digest`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${getJwt() ?? ""}` },
    body: JSON.stringify({ model }), signal: AbortSignal.timeout(100_000),
  });
  if (!response.ok) throw new Error(`Inbox summary HTTP ${response.status}`);
  const digest = await response.json() as InboxDigest;
  if (connectionVersion() !== version) throw new Error("Connection changed");
  if (digest.schemaVersion !== 7 || !digest.outcome || !digest.sources?.length || !digest.sourceRevision) throw new Error("Invalid shared summary");
  if (!(Date.parse(digest.sourceUpdatedAt ?? "") + 2000 >= updatedMs)) throw new Error("Core summary is behind this conversation");
  return { ...digest, task: "", verdict: "waiting", aiGenerated: true, updatedMs };
}

export function inboxSummaryState(missionId: string, updatedMs: number): string | undefined {
  inboxDigestVersion();
  const cfg = inboxConfig();
  if (!cfg.aiSummary) return;
  const key = `${currentStorageKey()}:${makeCacheKey(missionId, updatedMs, cfg.model)}`;
  if (inFlight.has(key)) return "Generating summary…";
  if (failedKeys.has(key)) return "Summary unavailable";
}

export function requestInboxDigest(
  mission: Mission,
  _items: StreamItem[] | undefined,
  updatedMs: number,
  priority = 50,
): void {
  if (!isConnected()) return;
  const cfg = inboxConfig();
  if (!cfg.aiSummary) return;
  const cacheKey = makeCacheKey(mission.id, updatedMs, cfg.model);
  if (getCurrentInboxDigest(mission.id, updatedMs, cfg.model)) return;
  const scopeKey = `${currentStorageKey()}:${cacheKey}`;
  const requestVersion = connectionVersion();
  if (inFlight.has(scopeKey)) return;
  const lastFail = failedKeys.get(scopeKey);
  if (lastFail && Date.now() - lastFail < 60_000) return;

  inFlight.add(scopeKey);
  bumpDigestVersion();
  queue.push({
    priority,
    run: async () => {
      try {
        if (connectionVersion() !== requestVersion) return;
        const parsed = await fetchSharedDigest(mission.id, cfg.model, updatedMs);
        if (parsed?.schemaVersion === 7) {
          failedKeys.delete(scopeKey);
          storeInboxDigest(mission.id, updatedMs, cfg.model, parsed);
        } else {
          failedKeys.set(scopeKey, Date.now());
        }
      } catch {
        failedKeys.set(scopeKey, Date.now());
      } finally {
        inFlight.delete(scopeKey);
        bumpDigestVersion();
      }
    },
  });
  pumpQueue();
}
