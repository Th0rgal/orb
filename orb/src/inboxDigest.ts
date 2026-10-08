import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, getJwt, isConnected, type Mission } from "./api";
import { backgroundWake as parseBackgroundWake } from "./backgroundWake";
import { formatToolDetail, isSyntheticUserMessage } from "./inboxModel";
import { inboxConfig } from "./inboxSettings";
import { messagePresentation as parseMessagePresentation } from "./messagePresentation";
import { remoteLog as parseRemoteLog } from "./remoteLog";
import { sideQuestionKey } from "./sideQuestionStorage";
import type { StreamItem } from "./transcriptModel";
import { workSummary } from "./workModel";

export type InboxVerdict = "succeeded" | "failed" | "waiting" | "needs_input";

export type InboxDigest = {
  goal?: string;
  task: string;
  outcome: string;
  verdict: InboxVerdict;
  model?: string;
  aiGenerated?: boolean;
  updatedMs: number;
};

const STORAGE_KEY = "orb:inbox-digest:v5";
const LEGACY_STORAGE_KEY = "orb:inbox-digest:v4";
const MAX_CACHE_ENTRIES = 160;
const MAX_CONCURRENT = 4;

const [inboxDigestVersion, setInboxDigestVersion] = createSignal(0);
export { inboxDigestVersion };

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
  try {
    const raw = localStorage.getItem(key) ?? localStorage.getItem(sideQuestionKey(LEGACY_STORAGE_KEY));
    memoryCache = raw ? (JSON.parse(raw) as Record<string, InboxDigest>) : {};
  } catch {
    memoryCache = {};
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
  setInboxDigestVersion((v) => v + 1);
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
  return pres.trim();
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
  "Generate a Google AI Overview-style summary of this coding agent mission for the operator's Inbox.",
  "Return ONLY a single-line JSON object with no markdown fences and no extra commentary:",
  '{"goal":"<concise 4-8 word headline of what the mission\'s goal is or evolved into>","task":"<concise 4-10 word summary of the user\'s latest follow-up request, or empty string if there was no follow-up or it repeats the goal>","outcome":"<2-3 sentences (30-65 words) summarizing what the agent did, concrete technical findings/files/PRs/tests, and the final result or exact blocker>","verdict":"succeeded|failed|waiting|needs_input"}',
  "Rules:",
  "- Write in the same language as the conversation.",
  "- \"goal\" must be a crisp, scannable 4-8 word title capturing the core mission objective (or what it evolved into), e.g. \"Morpho Midnight Solidity Import & EVM Parity\". Strip boilerplate like \"Complete the existing...\" or \"Mission to...\".",
  "- If there is no follow-up request different from the goal, or if the prompt was an automatic system resume, set \"task\" to \"\". Never write generic filler like \"Execute the mission goal\".",
  "- Write \"outcome\" like an executive AI Overview (2-3 clear sentences, 30-65 words): state what was accomplished or investigated, cite concrete details (commit hashes, PR numbers, files edited, test counts, root cause), and state the final status or specific blocker.",
  "- Never write vague boilerplate like \"Mission stopped and is currently blocked\" or \"Finished the task\".",
  "- Verdict must be one of: succeeded, failed, waiting, needs_input.",
].join("\n");

export function parseDigestJson(raw: string, updatedMs: number, model?: string): InboxDigest | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(trimmed.slice(start, end + 1)) as {
      goal?: unknown;
      task?: unknown;
      outcome?: unknown;
      overview?: unknown;
      verdict?: unknown;
    };
    const goal = typeof parsed.goal === "string" ? parsed.goal.trim() : "";
    const task = typeof parsed.task === "string" ? parsed.task.trim() : "";
    const outcomeRaw =
      typeof parsed.outcome === "string" && parsed.outcome.trim()
        ? parsed.outcome
        : typeof parsed.overview === "string"
          ? parsed.overview
          : "";
    const outcome = outcomeRaw.trim();
    if (!goal && !task && !outcome) return null;
    const rawVerdict = typeof parsed.verdict === "string" ? parsed.verdict.trim().toLowerCase() : "";
    const verdict: InboxVerdict =
      rawVerdict === "failed" || rawVerdict === "waiting" || rawVerdict === "needs_input"
        ? rawVerdict
        : "succeeded";
    return {
      ...(goal ? { goal } : {}),
      task,
      outcome,
      verdict,
      model,
      aiGenerated: true,
      updatedMs,
    };
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
  if (getExactCachedInboxDigest(mission.id, updatedMs, cfg.model)) return;
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
        const parsed = parseDigestJson(answer, updatedMs, resolvedModel || cfg.model);
        if (parsed) {
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
