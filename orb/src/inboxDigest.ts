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
        memoryCache[cacheKey] = storageKey === key && schemaVersion === 7
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
  return digest?.schemaVersion === 7 && digest.updatedMs === updatedMs ? digest : undefined;
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

const DIGEST_PROMPT = [
  "Summarize this conversation for an operator deciding whether and how to reply.",
  "Use only the supplied snapshot. It is partial, and reports claims from the agent; you have not independently verified its work.",
  "Return ONLY one JSON object, without markdown fences:",
  '{"schemaVersion":7,"context":"<one sentence reminding the user of the current mission objective, at most 180 characters>","contextDetails":"<optional additional objective or scope, at most 420 characters>","outcome":"<one short result sentence, at most 280 characters>","unresolved":"<specific remaining issue, or empty>","decision":"<specific decision or input needed from the user, or empty>","suggestions":["<optional contextual reply draft>","<optional second reply draft>"],"sources":[{"quote":"<short exact excerpt from a user or agent message supporting the summary>"}]}',
  "Use the conversation's language. Do not generate a title, goal, task, verdict or generic status prose. Use context for the mission objective, not as a replacement title.",
  "Context answers what this mission is about and why, using the initial objective and user requests, adjusted only for explicit later scope changes. A latest request such as status or continue is not the mission objective. Do not invent missing context. Context details are optional and must add information, not repeat the context or result.",
  "Lead the outcome with the result the user cares about. Preserve uncertainty and distinguish the agent's reported work from verified evidence.",
  "Include an unresolved issue only when recorded. Request a decision only when needed; never invent an obligation to review, approve or continue.",
  "Provide zero to two short, specific reply drafts useful for this conversation, not generic next-step buttons. Suggestions are editable drafts, never actions.",
  "Do not suggest destructive operations, publishing, merging, deploying or opening a PR unless that action is explicitly requested in the user messages. Do not expand the user's authorization.",
  "Do not repeat the title, outcome or unresolved issue in the decision. Keep unresolved under 320 characters and decision/reply drafts under 240 each.",
  "Include one to three exact message excerpts (12–240 characters each). Copy punctuation, wording and whitespace exactly; never quote a metadata label or invent evidence.",
  "Do not force technical details, hashes or filenames into the result. Include them only when necessary to understand the result or decision.",
].join("\n");

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

let coreSupportsModelField: boolean | null = null;

async function fetchDigestFromBtw(
  missionId: string,
  context: string,
  model: string,
): Promise<{ answer: string; resolvedModel?: string }> {
  const version = connectionVersion();
  const url = `${getApiUrl()}/api/control/missions/${encodeURIComponent(missionId)}/btw`;
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${getJwt() ?? ""}`,
  };

  const isCustomModel = Boolean(model && model !== "builtin/smart");
  const sendReq = async (includeModel: boolean) =>
    fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        question: DIGEST_PROMPT,
        context,
        ...(includeModel && isCustomModel ? { model } : {}),
      }),
    });

  let response = await sendReq(isCustomModel && coreSupportsModelField !== false);
  if (response.status === 422 && isCustomModel && coreSupportsModelField !== false) {
    // Pre-deploy Core has #[serde(deny_unknown_fields)] without `model`; retry cleanly without `model`.
    coreSupportsModelField = false;
    response = await sendReq(false);
  } else if (response.ok && isCustomModel && coreSupportsModelField === null) {
    coreSupportsModelField = true;
  }

  if (!response.ok || !response.body) {
    throw new Error(`Inbox digest HTTP ${response.status}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let answer = "";
  let resolvedModel: string | undefined;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (connectionVersion() !== version) throw new Error("Connection changed");
      buffer += decoder.decode(value, { stream: !done });
      buffer = buffer.replace(/\r\n/g, "\n");
      let end: number;
      while ((end = buffer.indexOf("\n\n")) >= 0) {
        const frame = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        const data = frame
          .split("\n")
          .filter((l) => l.startsWith("data:"))
          .map((l) => l.slice(5).trimStart())
          .join("\n");
        if (!data) continue;
        const ev = JSON.parse(data) as
          | { type: "start"; model: string }
          | { type: "delta"; text: string }
          | { type: "done"; answer: string }
          | { type: "error"; message: string };
        if (ev.type === "start") resolvedModel = ev.model;
        else if (ev.type === "delta") answer += ev.text;
        else if (ev.type === "done") answer = ev.answer || answer;
        else if (ev.type === "error") throw new Error(ev.message);
      }
      if (done) break;
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }

  return { answer, resolvedModel };
}

export function requestInboxDigest(
  mission: Mission,
  items: StreamItem[] | undefined,
  updatedMs: number,
  priority = 50,
): void {
  if (!isConnected()) return;
  const cfg = inboxConfig();
  if (!cfg.aiSummary) return;
  const hasConversation =
    (items && items.some((i) => i.kind === "text" || i.kind === "user" || i.kind === "error")) ||
    (Array.isArray(mission.history) && mission.history.length > 0);
  if (!hasConversation) return;

  const cacheKey = makeCacheKey(mission.id, updatedMs, cfg.model);
  if (getCurrentInboxDigest(mission.id, updatedMs, cfg.model)) return;
  if (inFlight.has(cacheKey)) return;
  const lastFail = failedKeys.get(cacheKey);
  if (lastFail && Date.now() - lastFail < 60_000) return;

  inFlight.add(cacheKey);
  queue.push({
    priority,
    run: async () => {
      try {
        const context = buildDigestSnapshot(mission, items);
        const { answer, resolvedModel } = await fetchDigestFromBtw(mission.id, context, cfg.model);
        const parsed = parseDigestJson(answer, updatedMs, resolvedModel || cfg.model, context);
        if (parsed?.schemaVersion === 7) {
          storeInboxDigest(mission.id, updatedMs, cfg.model, parsed);
        } else {
          failedKeys.set(cacheKey, Date.now());
        }
      } catch {
        failedKeys.set(cacheKey, Date.now());
      } finally {
        inFlight.delete(cacheKey);
      }
    },
  });
  pumpQueue();
}
