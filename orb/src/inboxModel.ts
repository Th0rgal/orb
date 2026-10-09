import { isBtwMission, type Mission, type ProjectSummary } from "./api";
import { backgroundWake as parseBackgroundWake } from "./backgroundWake";
import { DEFAULT_PROJECT } from "./defaultProject";
import { displayTitle } from "./goal";
import { messageImages } from "./messageImages";
import { messagePresentation as parseMessagePresentation } from "./messagePresentation";
import type { PendingInteraction } from "./missionAttention";
import { nodeLabel } from "./missionLaunch";
import { isMissionUnread, missionResponseTimestampMs } from "./missionUnread";
import { remoteLog as parseRemoteLog } from "./remoteLog";
import type { StreamEvent } from "./stream";
import { applyStreamEvent, type StreamItem } from "./transcriptModel";
import { toolArgs, toolName, workSummary } from "./workModel";

export const INBOX_SENTENCE_MAX_CHARS = 112;
export const INBOX_OVERVIEW_MAX_CHARS = 320;

export type InboxOption = {
  key: string;
  label: string;
  description?: string;
  action?: "accept" | "revise";
  questionKey?: string;
  questionText?: string;
  claudeFormat?: boolean;
};

export type InboxInteraction = {
  callId: string;
  toolName: string;
  remote: boolean;
  kind: "permission" | "plan" | "question";
  prompt: string;
  detail?: string;
  options: InboxOption[];
};

export type InboxTone = "amber" | "red" | "blue" | "green" | "muted";

export type InboxCategory = "needs_you" | "ready" | "working" | "hidden";

export type InboxPeekWorkReceipt = {
  summary: string;
  toolCount: number;
  failed?: boolean;
  details: string[];
};

export type InboxPeekTurn = {
  role: "user" | "assistant" | "error";
  text: string;
  markdown?: string;
  workReceipt?: InboxPeekWorkReceipt;
};

export type InboxPeekStream = {
  items: StreamItem[];
  hiddenTurnCount: number;
  totalTurnCount: number;
};

export type InboxChildFailure = {
  id: string;
  title: string;
  mission: Mission;
};

export type InboxChildSummary = {
  total: number;
  running: number;
  failed: number;
  completed: number;
  failedChildren: InboxChildFailure[];
  hasUnreadFailure: boolean;
};

export type InboxVerdict = "succeeded" | "failed" | "waiting" | "needs_input";

export type InboxItem = {
  id: string;
  mission: Mission;
  category: Exclude<InboxCategory, "hidden">;
  projectSlug: string;
  projectTitle: string;
  headline: string;
  goalSummary?: string;
  lastRequest?: string;
  workReceiptSummary?: string;
  verdict: InboxVerdict;
  summary: string;
  badge: string;
  tone: InboxTone;
  machine?: string;
  relativeTime: string;
  updatedMs: number;
  isGoal: boolean;
  unread: boolean;
  attention: boolean;
  canRetry: boolean;
  peekTurns: InboxPeekTurn[];
  allPeekTurns: InboxPeekTurn[];
  childSummary?: InboxChildSummary;
  interaction?: InboxInteraction;
};

export type InboxSections = {
  needsYou: InboxItem[];
  ready: InboxItem[];
  working: InboxItem[];
  totalActionable: number;
  unreadCount: number;
  attentionCount: number;
};

const WORKING_STATUSES = new Set([
  "active",
  "running",
  "starting",
  "pending",
  "queued",
  "resuming",
  "waiting_background",
]);

const HIDDEN_STATUSES = new Set([
  "acknowledged",
  "cancelled",
  "canceled",
  "deleted",
]);

const INTERACTIVE_TOOLS = new Set([
  "ui_native_request",
  "AskUserQuestion",
  "question",
]);

function extractCodeFenceSnippet(raw: string): string {
  const match = raw.match(/```([a-zA-Z0-9_-]*)\s*\n([\s\S]*?)```/);
  if (!match) return "";
  const lang = match[1]?.trim();
  const body = match[2]
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && l !== "{" && l !== "}" && l !== "[" && l !== "]")
    .slice(0, 2)
    .join(" ")
    .replace(/\s+/g, " ")
    .slice(0, 72);
  if (!body) return "";
  return lang ? `[${lang}: ${body}]` : `[${body}]`;
}

/** Strip markdown syntax into clean single-line prose suitable for a compact inbox preview. */
export function stripMarkdownToProse(raw: string): string {
  if (!raw) return "";
  const codeHint = extractCodeFenceSnippet(raw);
  let text = raw
    // Remove fenced code blocks, keeping a short inline hint if prose is otherwise empty or a bare lead-in
    .replace(/```[\s\S]*?```/g, " ")
    // Strip image attachment transport markers like [Image #1] or [Uploaded: /path/to/img.png]
    .replace(/\[Image #\d+\]/gi, " ")
    .replace(/\[Uploaded:\s*[^\]]+\]/gi, " ")
    // Remove markdown headings, blockquotes, horizontal rules
    .replace(/^\s*#{1,6}\s+/gm, "")
    .replace(/^\s*>\s?/gm, "")
    .replace(/^\s*[-*_]{3,}\s*$/gm, " ")
    // Strip bullet/numbered list prefixes
    .replace(/^\s*(?:[-*+]|\d+\.)\s+/gm, "")
    // Links [label](url) -> label
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    // Images ![alt](url) -> alt
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    // Inline code and bold/italic markers
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    // Collapse whitespace
    .replace(/\s+/g, " ")
    .trim();
  if (codeHint && (text.length < 36 || text.endsWith(":"))) {
    text = text ? `${text} ${codeHint}` : codeHint;
  }
  return text;
}

/**
 * Agentbox-style sentence-boundary clipper:
 * Keeps the summary under `maxChars` (default 112), preferring a clean sentence
 * break (`.`, `!`, `?`) when one exists after at least 24 characters, otherwise
 * clipping cleanly at a word boundary with `…`.
 */
export function clipToSentence(raw: string, maxChars = INBOX_SENTENCE_MAX_CHARS): string {
  const clean = stripMarkdownToProse(raw);
  if (!clean) return "";
  const hasCodeHint = Boolean(extractCodeFenceSnippet(raw));
  // Prefer the first complete sentence if it already fits within maxChars.
  const firstSentence = clean.match(/^(.+?[.!?])(?:\s|$)/);
  if (
    !hasCodeHint &&
    firstSentence &&
    firstSentence[1].length <= maxChars &&
    firstSentence[1].length >= 16
  ) {
    return firstSentence[1];
  }
  if (clean.length <= maxChars) return clean;

  const windowText = clean.slice(0, maxChars);
  // Look for the last sentence boundary within the budget
  let lastSentenceEnd = -1;
  if (!hasCodeHint) {
    for (let i = windowText.length - 1; i >= 24; i--) {
      const ch = windowText[i];
      const next = clean[i + 1];
      if ((ch === "." || ch === "!" || ch === "?") && (!next || /\s/.test(next))) {
        lastSentenceEnd = i + 1;
        break;
      }
    }
  }
  if (lastSentenceEnd > 0) {
    return windowText.slice(0, lastSentenceEnd).trim();
  }

  // Fallback to last word boundary
  const clipped = clean.slice(0, Math.max(1, maxChars - 1));
  const lastSpace = clipped.lastIndexOf(" ");
  if (lastSpace >= 24) {
    return clipped.slice(0, lastSpace).replace(/[,;:\-–—]+$/, "").trim() + "…";
  }
  return clipped.trim() + "…";
}

/**
 * Multi-sentence overview clipper for the wider mailbox view:
 * Preserves multiple complete sentences up to `maxChars` (default 320) instead of
 * stopping after the first sentence.
 */
export function clipToOverview(raw: string, maxChars = INBOX_OVERVIEW_MAX_CHARS): string {
  const clean = stripMarkdownToProse(raw);
  if (!clean) return "";
  if (clean.length <= maxChars) return clean;

  const windowText = clean.slice(0, maxChars);
  let lastSentenceEnd = -1;
  for (let i = windowText.length - 1; i >= 48; i--) {
    const ch = windowText[i];
    const next = clean[i + 1];
    if ((ch === "." || ch === "!" || ch === "?") && (!next || /\s/.test(next))) {
      lastSentenceEnd = i + 1;
      break;
    }
  }
  if (lastSentenceEnd > 0) {
    return windowText.slice(0, lastSentenceEnd).trim();
  }

  const clipped = clean.slice(0, Math.max(1, maxChars - 1));
  const lastSpace = clipped.lastIndexOf(" ");
  if (lastSpace >= 36) {
    return clipped.slice(0, lastSpace).replace(/[,;:\-–—]+$/, "").trim() + "…";
  }
  return clipped.trim() + "…";
}

export function formatRelativeTime(iso: string | undefined | null, nowMs = Date.now()): string {
  if (!iso) return "";
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return "";
  const deltaSec = Math.max(0, Math.floor((nowMs - parsed) / 1000));
  if (deltaSec < 45) return "now";
  if (deltaSec < 3600) return `${Math.floor(deltaSec / 60)}m`;
  if (deltaSec < 86_400) return `${Math.floor(deltaSec / 3600)}h`;
  if (deltaSec < 604_800) return `${Math.floor(deltaSec / 86_400)}d`;
  return `${Math.floor(deltaSec / 604_800)}w`;
}

type RawInteractionParams = {
  plan?: string;
  tool?: string;
  input?: { command?: string; file_path?: string; description?: string };
  questions?: Array<{
    id?: string;
    question?: string;
    header?: string;
    multiSelect?: boolean;
    options?: Array<{ label?: string; description?: string }>;
  }>;
};

/**
 * Inspects a mission's transcript items and live interaction observation to extract
 * a structured interactive prompt + up to 3 quick-action options (`1`, `2`, `3`).
 */
export function extractInboxInteraction(
  mission: Mission,
  items?: StreamItem[],
  observed?: PendingInteraction,
): InboxInteraction | undefined {
  if (HIDDEN_STATUSES.has(mission.status) || mission.status === "completed" || mission.status === "failed" || mission.status === "not_feasible") {
    return undefined;
  }
  const clientPlaced = Boolean(mission.tags?.includes("placement:client"));
  const unresolvedTool = items
    ?.slice()
    .reverse()
    .find(
      (item): item is Extract<StreamItem, { kind: "tool" }> =>
        item.kind === "tool" && !item.done && INTERACTIVE_TOOLS.has(item.name),
    );

  if (unresolvedTool) {
    const rawArgs = (unresolvedTool.args ?? {}) as {
      method?: string;
      params?: RawInteractionParams;
      questions?: RawInteractionParams["questions"];
      plan?: string;
      tool?: string;
      input?: RawInteractionParams["input"];
    };
    const method =
      rawArgs.method ??
      (unresolvedTool.name === "AskUserQuestion" ? "claude_questions" : "question");
    const params: RawInteractionParams = rawArgs.params ?? rawArgs;

    if (method === "permission") {
      const desc =
        params.input?.description ||
        params.input?.command ||
        params.input?.file_path ||
        params.tool ||
        "Allow this tool action?";
      return {
        callId: unresolvedTool.callId,
        toolName: unresolvedTool.name,
        remote: !clientPlaced,
        kind: "permission",
        prompt: clipToSentence(desc),
        detail: params.input?.command ?? params.input?.file_path,
        options: [
          { key: "1", label: "Approve", action: "accept" },
          { key: "2", label: "Decline", action: "revise" },
        ],
      };
    }

    if (method === "plan") {
      const planText = params.plan || "Review the proposed implementation plan.";
      return {
        callId: unresolvedTool.callId,
        toolName: unresolvedTool.name,
        remote: !clientPlaced,
        kind: "plan",
        prompt: clipToSentence(planText),
        detail: params.plan,
        options: [
          { key: "1", label: "Approve plan", action: "accept" },
          { key: "2", label: "Revise", action: "revise" },
        ],
      };
    }

    const questions = params.questions ?? [];
    const firstQ = questions[0];
    const qPrompt = firstQ?.question || "Waiting for your answer.";
    const canQuickPick = questions.length === 1 && !firstQ?.multiSelect && (firstQ?.options?.length ?? 0) > 0;
    const claudeFormat = method === "claude_questions" || unresolvedTool.name === "AskUserQuestion";
    const qKey = firstQ?.id ?? "0";
    const options: InboxOption[] = canQuickPick
      ? (firstQ!.options ?? [])
          .filter((o): o is { label: string; description?: string } => Boolean(o?.label?.trim()))
          .slice(0, 3)
          .map((opt, idx) => ({
            key: String(idx + 1),
            label: opt.label.trim(),
            description: opt.description,
            questionKey: qKey,
            questionText: firstQ?.question ?? "",
            claudeFormat,
          }))
      : [];

    return {
      callId: unresolvedTool.callId,
      toolName: unresolvedTool.name,
      remote: !clientPlaced,
      kind: "question",
      prompt: clipToSentence(qPrompt),
      options,
    };
  }

  if (observed) {
    const isPerm = observed.method === "permission";
    const isPlan = observed.method === "plan";
    const kind = isPerm ? "permission" : isPlan ? "plan" : "question";
    return {
      callId: observed.id,
      toolName: "ui_native_request",
      remote: !clientPlaced,
      kind,
      prompt: isPerm
        ? "Permission requested to run a tool action."
        : isPlan
          ? "Implementation plan is ready for your review."
          : "Waiting for your response to continue.",
      options:
        isPerm || isPlan
          ? [
              { key: "1", label: isPlan ? "Approve plan" : "Approve", action: "accept" },
              { key: "2", label: isPlan ? "Revise" : "Decline", action: "revise" },
            ]
          : [],
    };
  }

  return undefined;
}

/** Child worker missions belong nested inside their parent orchestrator in the sidebar, not as standalone Inbox items. */
export function isSubagentMission(
  mission: Pick<Mission, "title" | "parent_mission_id" | "callback_parent_mission_id" | "tags">,
): boolean {
  if (mission.parent_mission_id || mission.callback_parent_mission_id) return true;
  if (
    mission.tags?.some(
      (tag) =>
        tag.startsWith("worker-dispatch:") ||
        tag === "superseded" ||
        tag.startsWith("superseded-by:"),
    )
  ) {
    return true;
  }
  const rawTitle = (mission.title ?? "").trim();
  if (/^you are a sub-?agent\b/i.test(rawTitle)) {
    return true;
  }
  return false;
}

export function classifyInboxMission(
  mission: Mission,
  interaction?: InboxInteraction,
): InboxCategory {
  if (isBtwMission(mission)) return "hidden";
  const status = mission.status || "";
  if (HIDDEN_STATUSES.has(status)) return "hidden";
  // An active mission with a live pending interaction immediately surfaces in Needs You
  if (interaction) return "needs_you";
  if (isSubagentMission(mission)) return "hidden";
  if (WORKING_STATUSES.has(status)) return "working";
  if (
    status === "blocked" ||
    status === "failed" ||
    status === "not_feasible" ||
    status === "awaiting_user" ||
    status === "waiting_user"
  ) {
    return "needs_you";
  }
  if (status === "completed" || status === "succeeded" || status === "paused" || status === "interrupted") {
    return "ready";
  }
  return "hidden";
}

function humanizeStatusText(raw: string | null | undefined): string {
  const trimmed = (raw ?? "")
    .trim()
    .replace(/\s*diagnostics:\s*\d{4}-\d{2}-\d{2}T[\s\S]*$/i, "")
    .replace(/;\s*error:\s*command exited with (?:Some\()?(-?\d+)\)?/gi, "")
    .replace(/\(exit Some\((-?\d+)\)\)/g, "(exit $1)")
    .replace(/\bSome\((-?\d+)\)/g, "$1")
    .replace(/finished with state 'failed'\s*/gi, "failed ");
  if (!trimmed) return "";
  // Ignore internal snake_case enum tokens like "remote_node_job"
  if (/^[a-z0-9_]+$/.test(trimmed)) return "";
  // Strip noisy 36-char job UUIDs from remote node status messages so the actual outcome is visible
  const remoteMatch = trimmed.match(
    /^Remote\s+(\S+)\s+job\s+[0-9a-f-]{36}\s+on\s+node\s+'([^']+)'\s+([\s\S]+)$/i,
  );
  if (remoteMatch) {
    return `Remote ${remoteMatch[1]} run on ${nodeLabel(remoteMatch[2])} ${remoteMatch[3]}`;
  }
  const genericJobMatch = trimmed.match(
    /^Job\s+[0-9a-f-]{36}\s+on\s+node\s+'([^']+)'\s+([\s\S]+)$/i,
  );
  if (genericJobMatch) {
    return `Remote run on ${nodeLabel(genericJobMatch[1])} ${genericJobMatch[2]}`;
  }
  return trimmed;
}

function stripLeadingNarration(raw: string): string {
  const paragraphs = raw
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter(Boolean);
  if (paragraphs.length > 1) {
    const isProceduralOrClosing = (p: string) =>
      /^(no local repo\b|let me\b|i['’]ll\b|i will\b|je vais\b|je reprends\b|gh appears\b|the goal is paused\b|the objective was to\b|current status:?$|if you['’]?d? (?:like|want)\b|let me know if\b|would you like me to\b|si tu veux\b)/i.test(
        p,
      );
    const substantive = paragraphs.filter((p) => !isProceduralOrClosing(p) && p.length >= 28);
    if (substantive.length > 0) {
      // Combine the final substantive paragraphs so multi-sentence overviews capture both finding and details
      return substantive.slice(-2).join(" ");
    }
  }
  const stripped = raw.replace(
    /^(?:(?:No local repo\.|gh appears stuck\.|[^.!?\n]*\b(?:Let me|I['’]ll|I will)\b[^.!?\n]*[.!?])\s*)+/i,
    "",
  );
  return stripped.trim().length >= 24 ? stripped.trim() : raw;
}

function extractSummary(
  mission: Mission,
  items?: StreamItem[],
  interaction?: InboxInteraction,
): string {
  if (interaction?.prompt) return interaction.prompt;

  if (Array.isArray(mission.history) && mission.history.length > 0) {
    for (let i = mission.history.length - 1; i >= 0; i--) {
      const entry = mission.history[i];
      if (entry.role === "assistant" && entry.content?.trim()) {
        const cleanHist = humanizeStatusText(entry.content) || entry.content;
        const clipped = clipToOverview(stripLeadingNarration(cleanHist));
        if (clipped) return clipped;
      }
    }
  }

  if (items && items.length > 0) {
    let lastUserIdx = -1;
    for (let i = items.length - 1; i >= 0; i--) {
      const it = items[i];
      if (it.kind === "user" && !it.queued) {
        lastUserIdx = i;
        break;
      }
    }
    for (let i = items.length - 1; i > lastUserIdx; i--) {
      const item = items[i];
      if (item.kind === "error" && item.text.trim()) {
        const cleanErr = humanizeStatusText(item.text) || item.text;
        return clipToOverview(stripLeadingNarration(cleanErr));
      }
      if (item.kind === "text" && item.text.trim()) {
        const cleanTxt = humanizeStatusText(item.text) || item.text;
        return clipToOverview(stripLeadingNarration(cleanTxt));
      }
    }
  }

  const remoteErr = humanizeStatusText(mission.remote_job?.error);
  if (remoteErr) return clipToOverview(remoteErr);

  const statusMsg = humanizeStatusText(mission.status_message);
  if (statusMsg) return clipToOverview(statusMsg);

  const termReason = humanizeStatusText(mission.terminal_reason);
  if (termReason) return clipToOverview(termReason);

  switch (mission.status) {
    case "completed":
    case "succeeded":
      return "Finished the task and is ready for your review.";
    case "awaiting_user":
    case "waiting_user":
      return "Finished the turn and is waiting for your follow-up.";
    case "blocked":
      return "Blocked and needs your input to continue.";
    case "failed":
    case "not_feasible":
      return "Stopped with an error — open to inspect or resume.";
    case "active":
    case "running":
    case "starting":
      return "Working in the background…";
    default:
      return "Ready for your review.";
  }
}

function resolveBadgeAndTone(
  mission: Mission,
  summary: string,
  interaction?: InboxInteraction,
): { badge: string; tone: InboxTone } {
  if (interaction) {
    if (interaction.kind === "permission") return { badge: "Approval", tone: "amber" };
    if (interaction.kind === "plan") return { badge: "Plan review", tone: "amber" };
    return { badge: "Question", tone: "amber" };
  }
  switch (mission.status) {
    case "blocked":
      return { badge: "Blocked", tone: "amber" };
    case "failed":
      return { badge: "Failed", tone: "red" };
    case "not_feasible":
      return { badge: "Not feasible", tone: "red" };
    case "awaiting_user":
    case "waiting_user":
      return summary.trim().endsWith("?")
        ? { badge: "Question", tone: "blue" }
        : { badge: "Waiting", tone: "blue" };
    case "completed":
    case "succeeded":
      return { badge: "Completed", tone: "green" };
    case "paused":
    case "interrupted":
      return { badge: "Paused", tone: "muted" };
    default:
      return { badge: "Working", tone: "muted" };
  }
}

function resolveMachine(mission: Mission): string | undefined {
  if (mission.tags?.includes("placement:client")) return "This computer";
  if (mission.backend?.startsWith("cloud_")) {
    return (
      {
        cloud_chatgpt: "ChatGPT",
        cloud_grok_bot: "Grok Bot",
        cloud_cursor: "Cursor Cloud",
        cloud_hermes: "Paloma",
      } as Record<string, string>
    )[mission.backend];
  }
  const lastAssistant = mission.history
    ? [...mission.history].reverse().find((h) => h.role === "assistant")?.content
    : undefined;
  const nodeId =
    mission.remote_job?.node_id ??
    mission.remote_node_id ??
    mission.status_message?.match(/\bon node '([^']+)'/i)?.[1] ??
    lastAssistant?.match(/\bon node '([^']+)'/i)?.[1];
  if (nodeId) return nodeLabel(nodeId);
  return undefined;
}

function cleanUserMarkdown(raw: string): string {
  const pres = parseMessagePresentation(raw).text;
  const wake = parseBackgroundWake(pres);
  if (wake) {
    return `Background task \`${wake.task}\` (\`${wake.command}\`) finished.${wake.output ? `\n\n\`\`\`\n${wake.output.slice(0, 600)}\n\`\`\`` : ""}`;
  }
  return messageImages(pres).text.trim();
}

export function isSyntheticUserMessage(raw: string): boolean {
  const pres = parseMessagePresentation(raw).text.trim();
  if (!pres) return true;
  if (parseBackgroundWake(pres)) return true;
  return (
    /^\[automatic resume\b/i.test(pres) ||
    /^antigravity background task handoff\b/i.test(pres) ||
    /^background task\s+`[^`]+`\s+.*finished\b/i.test(pres) ||
    /^continue from where you left off\.?$/i.test(pres) ||
    /^\[system\b/i.test(pres)
  );
}

function cleanAssistantMarkdown(raw: string): string {
  return parseRemoteLog(raw)
    .text.replace(/\n*diagnostics:\s*\d{4}-\d{2}-\d{2}T[\s\S]*$/i, "")
    .trim();
}

export function formatToolDetail(tool: Extract<StreamItem, { kind: "tool" }>): string {
  const name = toolName(tool.name);
  const args = toolArgs(tool.args);
  if (!args) return name;
  const cmd = args.command ?? args.cmd;
  if (typeof cmd === "string" && cmd.trim()) {
    return `${name}: ${cmd.trim().replace(/\s+/g, " ").slice(0, 80)}`;
  }
  for (const k of ["file_path", "filePath", "path", "file", "pattern", "query"]) {
    const val = args[k];
    if (typeof val === "string" && val.trim()) {
      return `${name} ${val.trim().split("/").slice(-2).join("/")}`;
    }
  }
  return name;
}

function buildWorkReceipt(tools: Array<Extract<StreamItem, { kind: "tool" }>>): InboxPeekWorkReceipt | undefined {
  if (!tools.length) return undefined;
  const summary = workSummary(tools);
  const details = tools.slice(-6).map(formatToolDetail);
  return {
    summary,
    toolCount: tools.length,
    details,
  };
}

export function extractLastRequest(mission: Mission, items?: StreamItem[]): string | undefined {
  if (items && items.length > 0) {
    for (let i = items.length - 1; i >= 0; i--) {
      const it = items[i];
      if (it.kind === "user" && !it.queued && it.text.trim()) {
        if (isSyntheticUserMessage(it.text)) continue;
        const cleaned = cleanUserMarkdown(it.text);
        if (cleaned) return clipToSentence(cleaned, 120);
      }
    }
  }
  if (Array.isArray(mission.history) && mission.history.length > 0) {
    for (let i = mission.history.length - 1; i >= 0; i--) {
      const h = mission.history[i];
      if (h.role === "user" && h.content?.trim()) {
        if (isSyntheticUserMessage(h.content)) continue;
        const cleaned = cleanUserMarkdown(h.content);
        if (cleaned) return clipToSentence(cleaned, 120);
      }
    }
  }
  return undefined;
}

export function extractLatestWorkReceipt(items?: StreamItem[]): string | undefined {
  if (!items || !items.length) return undefined;
  let lastUserIdx = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued) {
      lastUserIdx = i;
      break;
    }
  }
  const tools: Array<Extract<StreamItem, { kind: "tool" }>> = [];
  for (let i = lastUserIdx + 1; i < items.length; i++) {
    const it = items[i];
    if (it.kind === "tool") tools.push(it);
  }
  if (!tools.length) return undefined;
  return workSummary(tools);
}

function resolveVerdict(
  mission: Mission,
  summary: string,
  interaction?: InboxInteraction,
): InboxVerdict {
  if (interaction) return "needs_input";
  if (mission.status === "failed" || mission.status === "not_feasible" || mission.status === "blocked") {
    return "failed";
  }
  if (mission.status === "awaiting_user" || mission.status === "waiting_user") {
    return summary.trim().endsWith("?") ? "needs_input" : "waiting";
  }
  if (WORKING_STATUSES.has(mission.status)) return "waiting";
  return "succeeded";
}

export function extractAllPeekTurns(
  mission: Mission,
  items?: StreamItem[],
  summaryFallback?: string,
  maxTurns = 24,
): InboxPeekTurn[] {
  const turns: InboxPeekTurn[] = [];
  if (items && items.length > 0) {
    let pendingTools: Array<Extract<StreamItem, { kind: "tool" }>> = [];
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.kind === "tool") {
        pendingTools.push(item);
        continue;
      }
      if (item.kind === "user" && !item.queued && item.text.trim()) {
        if (isSyntheticUserMessage(item.text)) {
          continue;
        }
        pendingTools = [];
        const md = cleanUserMarkdown(item.text);
        const clean = stripMarkdownToProse(md);
        if (clean || md) {
          turns.push({
            role: "user",
            text: clipToSentence(clean || md, 240),
            markdown: md,
          });
        }
      } else if (item.kind === "text" && item.text.trim()) {
        const md = cleanAssistantMarkdown(item.text);
        const clean = stripMarkdownToProse(humanizeStatusText(md) || md);
        const clipped = clipToSentence(clean || md, 240);
        const prev = turns.at(-1);
        const receipt = buildWorkReceipt(pendingTools);
        pendingTools = [];
        if (prev?.role === "assistant") {
          prev.text = clipped;
          prev.markdown = md;
          if (receipt) {
            if (prev.workReceipt) {
              prev.workReceipt.toolCount += receipt.toolCount;
              prev.workReceipt.details = [...prev.workReceipt.details, ...receipt.details].slice(-6);
            } else {
              prev.workReceipt = receipt;
            }
          }
        } else if (clean || md) {
          turns.push({
            role: "assistant",
            text: clipped,
            markdown: md,
            workReceipt: receipt,
          });
        }
      } else if (item.kind === "error" && item.text.trim()) {
        const md = cleanAssistantMarkdown(humanizeStatusText(item.text) || item.text.trim());
        const clean = stripMarkdownToProse(md);
        const receipt = buildWorkReceipt(pendingTools);
        const isActualError =
          /^(error|fatal|panic|remote\s+\S+\s+run|native\s+codex\s+goal\s+stopped|command\s+exited|failed\b)/i.test(
            clean,
          ) || md.length < 220;
        if (receipt && isActualError) receipt.failed = true;
        pendingTools = [];
        if (clean || md) {
          const clipped = clipToSentence(clean || md, 240);
          const role = isActualError ? "error" : "assistant";
          const prev = turns.at(-1);
          if (role === "assistant" && prev?.role === "assistant") {
            prev.text = clipped;
            prev.markdown = md;
            if (receipt) {
              if (prev.workReceipt) {
                prev.workReceipt.toolCount += receipt.toolCount;
                prev.workReceipt.details = [...prev.workReceipt.details, ...receipt.details].slice(-6);
              } else {
                prev.workReceipt = receipt;
              }
            }
          } else {
            turns.push({
              role,
              text: clipped,
              markdown: md,
              workReceipt: receipt,
            });
          }
        }
      }
    }
    const histLastAssistant = Array.isArray(mission.history)
      ? [...mission.history].reverse().find((h) => h.role === "assistant" && h.content?.trim())
      : undefined;
    if (histLastAssistant?.content) {
      const md = cleanAssistantMarkdown(histLastAssistant.content);
      const clean = stripMarkdownToProse(humanizeStatusText(md) || md);
      const clipped = clipToSentence(clean || md, 240);
      const receipt = buildWorkReceipt(pendingTools);
      pendingTools = [];
      const last = turns.at(-1);
      if (last?.role === "assistant") {
        last.text = clipped;
        last.markdown = md;
        if (receipt && !last.workReceipt) last.workReceipt = receipt;
      } else if (clean || md) {
        turns.push({
          role: "assistant",
          text: clipped,
          markdown: md,
          workReceipt: receipt,
        });
      }
    }
  } else if (Array.isArray(mission.history) && mission.history.length > 0) {
    for (let i = 0; i < mission.history.length; i++) {
      const entry = mission.history[i];
      if (!entry.content?.trim()) continue;
      if (entry.role === "user" && isSyntheticUserMessage(entry.content)) continue;
      if (entry.role === "user" || entry.role === "assistant") {
        const md =
          entry.role === "user"
            ? cleanUserMarkdown(entry.content)
            : cleanAssistantMarkdown(entry.content);
        const clean = stripMarkdownToProse(humanizeStatusText(md) || md);
        const clipped = clipToSentence(clean || md, 240);
        if ((clean || md) && turns.at(-1)?.text !== clipped) {
          turns.push({
            role: entry.role,
            text: clipped,
            markdown: md,
          });
        }
      }
    }
  }

  // When a single turn runs 100+ tool calls and pushes the initial user prompt outside the
  // 200-event tail window, synthesize the initial user prompt from goal_objective or title
  // so Peek always shows what was asked above the agent's response.
  if (items && items.length > 0 && turns.length > 0 && !turns.some((t) => t.role === "user")) {
    const fallbackPrompt = (mission.goal_objective || displayTitle(mission.title) || "").trim();
    if (fallbackPrompt && fallbackPrompt.toLowerCase() !== "untitled") {
      const md = cleanUserMarkdown(fallbackPrompt);
      const clean = stripMarkdownToProse(md);
      if (clean || md) {
        turns.unshift({
          role: "user",
          text: clipToSentence(clean || md, 240),
          markdown: md,
        });
      }
    }
  }

  const errDetail =
    humanizeStatusText(mission.remote_job?.error) ||
    humanizeStatusText(mission.status_message) ||
    humanizeStatusText(mission.terminal_reason);
  if (
    errDetail &&
    (mission.status === "failed" || mission.status === "blocked" || mission.status === "not_feasible") &&
    !turns.some((t) => t.role === "error")
  ) {
    const clippedErr = clipToSentence(errDetail, 240);
    const lastTurn = turns.at(-1);
    const lastText = (lastTurn?.markdown || lastTurn?.text || "").toLowerCase();
    const errPrefix = clippedErr.slice(0, 32).toLowerCase();
    if (!lastTurn || !errPrefix || !lastText.includes(errPrefix)) {
      turns.push({
        role: "error",
        text: clippedErr,
        markdown: errDetail,
      });
    }
  }

  if (turns.length === 0 && summaryFallback) {
    turns.push({
      role: mission.status === "failed" || mission.status === "blocked" ? "error" : "assistant",
      text: summaryFallback,
      markdown: summaryFallback,
    });
  }
  return turns.slice(-maxTurns);
}

export function extractPeekTurns(
  mission: Mission,
  items?: StreamItem[],
  summaryFallback?: string,
): InboxPeekTurn[] {
  return extractAllPeekTurns(mission, items, summaryFallback, 24).slice(-3);
}

/**
 * Build a stable StreamItem[] list for rendering the shared `<Transcript>` component
 * inside the Inbox Peek drawer. Preserves original StreamItem object references and keys
 * whenever possible so Solid's keyed store reconciliation updates without unmounting DOM nodes,
 * and keeps raw user message presentation/image markers intact so `<UserTurn>` renders
 * `<MessageImage>` thumbnails, `<Lightbox>`, `<GoalTag>`, and `Attached context` badges.
 */
export function buildPeekStreamItems(
  mission: Mission,
  rawItems?: StreamItem[],
  summaryFallback?: string,
  expanded = false,
  maxCollapsedBlocks = 6,
  liveEvents?: StreamEvent[],
): InboxPeekStream {
  let out: StreamItem[] = [];

  if (rawItems && rawItems.length > 0) {
    for (let i = 0; i < rawItems.length; i++) {
      const item = rawItems[i];
      if (item.kind === "user") {
        if (item.queued || !item.text.trim()) continue;
        const presText = parseMessagePresentation(item.text).text.trim();
        if (!parseBackgroundWake(presText) && isSyntheticUserMessage(item.text)) {
          continue;
        }
        out.push(item);
      } else if (item.kind === "error") {
        if (!item.text.trim()) continue;
        const md = cleanAssistantMarkdown(humanizeStatusText(item.text) || item.text.trim());
        const clean = stripMarkdownToProse(md);
        const isActualError =
          /^(error|fatal|panic|remote\s+\S+\s+run|native\s+codex\s+goal\s+stopped|command\s+exited|failed\b)/i.test(
            clean,
          ) || md.length < 220;
        if (!isActualError) {
          out.push({
            kind: "text",
            key: item.key || `err-text:${mission.id}:${i}`,
            text: md,
            live: false,
          });
        } else if (md !== item.text) {
          out.push({
            kind: "error",
            key: item.key || `err:${mission.id}:${i}`,
            text: md,
          });
        } else {
          out.push(item);
        }
      } else {
        out.push(item);
      }
    }

    // If the event log was empty or started mid-session (e.g. only live events after mission.history),
    // prepend any missing turns from mission.history so prior context never disappears.
    if (Array.isArray(mission.history) && mission.history.length > 0) {
      const firstHist = mission.history.find(
        (h) => h.role === "user" && h.content?.trim() && !isSyntheticUserMessage(h.content),
      );
      const hasFirstHistUser =
        !firstHist ||
        out.some((i) => i.kind === "user" && i.text.trim() === firstHist.content.trim());
      if (!hasFirstHistUser) {
        const prefix: StreamItem[] = [];
        for (let i = 0; i < mission.history.length; i++) {
          const entry = mission.history[i];
          if (!entry.content?.trim()) continue;
          if (entry.role === "user") {
            if (isSyntheticUserMessage(entry.content)) continue;
            if (out.some((it) => it.kind === "user" && it.text.trim() === entry.content.trim())) {
              continue;
            }
            prefix.push({
              kind: "user",
              key: `history:${mission.id}:${i}`,
              text: entry.content,
            });
          } else if (entry.role === "assistant") {
            const md = cleanAssistantMarkdown(entry.content);
            if (!md) continue;
            if (out.some((it) => it.kind === "text" && it.text.trim() === md.trim())) {
              continue;
            }
            prefix.push({
              kind: "text",
              key: `history:${mission.id}:${i}`,
              text: md,
              live: false,
            });
          }
        }
        if (prefix.length > 0) {
          out = [...prefix, ...out];
        }
      }
    }

    if (!out.some((i) => i.kind === "user")) {
      const firstHistUser = mission.history?.find(
        (h) => h.role === "user" && h.content?.trim() && !isSyntheticUserMessage(h.content),
      )?.content;
      const rawFallback =
        firstHistUser ||
        (mission.goal_mode && mission.goal_objective
          ? `/goal ${mission.goal_objective.replace(/^\/goal\s+/i, "")}`
          : (mission.goal_objective || displayTitle(mission.title) || "").trim());
      if (rawFallback && rawFallback.toLowerCase() !== "untitled") {
        out.unshift({
          kind: "user",
          key: `initial:${mission.id}`,
          text: rawFallback,
        });
      }
    }
    const histLastAssistant = Array.isArray(mission.history)
      ? [...mission.history].reverse().find((h) => h.role === "assistant" && h.content?.trim())
      : undefined;
    const histLastUser = Array.isArray(mission.history)
      ? [...mission.history].reverse().find((h) => h.role === "user" && h.content?.trim() && !isSyntheticUserMessage(h.content))
      : undefined;
    const lastOutUser = [...out].reverse().find((i) => i.kind === "user");
    const hasNewerUserAfterHistory =
      lastOutUser?.kind === "user" &&
      histLastUser?.content &&
      lastOutUser.text.trim() !== histLastUser.content.trim();
    if (histLastAssistant?.content && !out.some((i) => i.kind === "text") && !hasNewerUserAfterHistory) {
      const md = cleanAssistantMarkdown(histLastAssistant.content);
      if (md) {
        out.push({
          kind: "text",
          key: `history-tail:${mission.id}`,
          text: md,
          live: false,
        });
      }
    }
  } else if (Array.isArray(mission.history) && mission.history.length > 0) {
    for (let i = 0; i < mission.history.length; i++) {
      const entry = mission.history[i];
      if (!entry.content?.trim()) continue;
      if (entry.role === "user") {
        if (isSyntheticUserMessage(entry.content)) continue;
        out.push({
          kind: "user",
          key: `history:${mission.id}:${i}`,
          text: entry.content,
        });
      } else if (entry.role === "assistant") {
        const md = cleanAssistantMarkdown(entry.content);
        if (md) {
          out.push({
            kind: "text",
            key: `history:${mission.id}:${i}`,
            text: md,
            live: false,
          });
        }
      }
    }
  }

  if (liveEvents && liveEvents.length > 0) {
    let liveBase: StreamItem[] = [];
    for (const ev of liveEvents) {
      if (ev.type === "user_message") {
        const content = String(ev.data?.content ?? "").trim();
        if (
          content &&
          out.some(
            (i) => i.kind === "user" && i.text.trim() === content,
          )
        ) {
          continue;
        }
      }
      if (ev.type === "assistant_message" || ev.type === "text_delta") {
        const content = String(ev.data?.content ?? "").trim();
        if (
          content &&
          out.some(
            (i) => i.kind === "text" && !i.live && i.text.trim() === content,
          )
        ) {
          continue;
        }
      }
      liveBase = applyStreamEvent(liveBase, ev);
    }
    if (liveBase.length > 0) {
      out = [...out, ...liveBase];
    }
  }

  const errDetail =
    humanizeStatusText(mission.remote_job?.error) ||
    humanizeStatusText(mission.status_message) ||
    humanizeStatusText(mission.terminal_reason);
  if (
    errDetail &&
    (mission.status === "failed" ||
      mission.status === "blocked" ||
      mission.status === "not_feasible") &&
    !out.some((i) => i.kind === "error")
  ) {
    const clippedErr = clipToSentence(errDetail, 240);
    const lastTextItem = [...out].reverse().find((i) => i.kind === "text");
    const lastText = (lastTextItem?.kind === "text" ? lastTextItem.text : "").toLowerCase();
    const errPrefix = clippedErr.slice(0, 32).toLowerCase();
    if (!lastText || !errPrefix || !lastText.includes(errPrefix)) {
      out.push({
        kind: "error",
        key: `terminal-error:${mission.id}`,
        text: errDetail,
      });
    }
  }

  if (out.length === 0 && summaryFallback) {
    out.push(
      mission.status === "failed" || mission.status === "blocked"
        ? { kind: "error", key: `fallback:${mission.id}`, text: summaryFallback }
        : { kind: "text", key: `fallback:${mission.id}`, text: summaryFallback, live: false },
    );
  }

  // Partition `out` into logical blocks (each `user` message or `[work/tools + assistant text/error]` block)
  // so collapsed Peek shows the most recent blocks while keeping the latest user prompt visible.
  const blockStarts: number[] = [];
  let inWorkRun = false;
  for (let i = 0; i < out.length; i++) {
    const kind = out[i].kind;
    if (kind === "tool" || kind === "think") {
      if (!inWorkRun) {
        blockStarts.push(i);
        inWorkRun = true;
      }
    } else if (kind === "text" || kind === "error") {
      if (!inWorkRun) {
        blockStarts.push(i);
      }
      inWorkRun = false;
    } else {
      blockStarts.push(i);
      inWorkRun = false;
    }
  }

  const totalTurnCount = blockStarts.length;
  if (expanded || totalTurnCount <= maxCollapsedBlocks) {
    return {
      items: out,
      hiddenTurnCount: 0,
      totalTurnCount,
    };
  }

  const sliceStartBlockIdx = totalTurnCount - maxCollapsedBlocks;
  const sliceStartItemIdx = blockStarts[sliceStartBlockIdx];
  const tailSlice = out.slice(sliceStartItemIdx);

  // If the tail slice has no user prompt (e.g. a single prompt followed by many intermediate
  // narration steps), keep the latest user item at the top of Peek so the prompt & images stay visible.
  if (!tailSlice.some((i) => i.kind === "user")) {
    for (let i = sliceStartItemIdx - 1; i >= 0; i--) {
      if (out[i].kind === "user") {
        return {
          items: [out[i], ...tailSlice],
          hiddenTurnCount: Math.max(1, sliceStartBlockIdx - 1),
          totalTurnCount,
        };
      }
    }
  }

  return {
    items: tailSlice,
    hiddenTurnCount: sliceStartBlockIdx,
    totalTurnCount,
  };
}

const RETRYABLE_STATUSES = new Set(["failed", "interrupted", "blocked", "not_feasible"]);

export function condenseMissionHeadline(raw: string, projectTitle?: string): string {
  let s = raw.trim().replace(/^\/goal\s+/i, "").trim();
  if (!s) return "";
  // Strip verbose imperative boilerplate when the title is long
  if (s.length > 44) {
    s = s
      .replace(
        /^(?:please\s+)?(?:complete|continue|finish|execute|implement|resume|work\s+on)\s+(?:the\s+)?(?:existing\s+|current\s+|remaining\s+)?/i,
        "",
      )
      .replace(/\s+(?:mission|goal|objective|roadmap|task)\b(?:\s*[,:—-]\s*with\s+the.*|\s+with\s+the.*)?$/i, "")
      .replace(/[,;]\s+with\s+the\s+.*$/i, "")
      .trim();
    if (projectTitle) {
      const slugMatch = s.match(/^([a-z0-9_.-]+\/[a-z0-9_.-]+)\s+(.+)$/i);
      if (slugMatch) {
        const repoName = slugMatch[1].split("/")[1]?.toLowerCase() ?? "";
        const rest = slugMatch[2].replace(/\s+mission\b.*$/i, "").trim();
        if (rest.length >= 4) {
          if (repoName && projectTitle.toLowerCase().includes(repoName)) {
            s = rest;
          } else {
            s = `${slugMatch[1]} · ${rest}`;
          }
        }
      }
    }
    if (s.length > 0) {
      s = s.charAt(0).toUpperCase() + s.slice(1);
    }
  }
  return clipToSentence(s, 58);
}

function extractGoalSummary(
  mission: Mission,
  headline: string,
  firstUser?: string,
  lastRequest?: string,
): string | undefined {
  const candidates: string[] = [];
  if (mission.goal_objective?.trim()) {
    candidates.push(mission.goal_objective.trim());
  }
  if (firstUser?.trim() && !isSyntheticUserMessage(firstUser)) {
    const cleanFirst = clipToSentence(stripMarkdownToProse(cleanUserMarkdown(firstUser)), 110);
    // Only include firstUser as a separate goal summary if there was a later distinct lastRequest
    // or if the mission is explicitly a goal mission.
    if (
      (lastRequest && cleanFirst.toLowerCase() !== lastRequest.toLowerCase()) ||
      mission.goal_mode ||
      mission.title?.trim().startsWith("/goal")
    ) {
      candidates.push(firstUser.trim());
    }
  }
  const normHead = headline.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const normLast = (lastRequest ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  for (const raw of candidates) {
    const clean = clipToSentence(stripMarkdownToProse(cleanUserMarkdown(raw)), 110);
    if (!clean) continue;
    const norm = clean.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    if (!norm || norm === normHead || norm === normLast) continue;
    if (normHead.length >= 16 && norm.startsWith(normHead.slice(0, 16)) && Math.abs(norm.length - normHead.length) < 12) {
      continue;
    }
    return clean;
  }
  return undefined;
}

type CachedInboxItemBase = Omit<
  InboxItem,
  "mission" | "unread" | "attention" | "relativeTime" | "childSummary" | "peekTurns" | "allPeekTurns"
> & {
  missionRef: Mission;
  missionStatus: string;
  missionTitle: string | null | undefined;
  missionUpdatedAt: string;
  missionLastOutputAt: string | null | undefined;
  missionStatusMsg: string | null | undefined;
  missionTerminalReason: string | null | undefined;
  missionRemoteErr: string | null | undefined;
  historyLen: number;
  lastHistoryContent: string | undefined;
  itemsRef: StreamItem[] | undefined;
  itemsLen: number;
  observedKey: string;
  projectTitle: string;
  updatedIso: string;
  baseAttention: boolean;
  cachedAllPeekTurns?: InboxPeekTurn[];
  cachedPeekTurns?: InboxPeekTurn[];
};

const inboxItemBaseCache = new Map<string, CachedInboxItemBase>();

export function buildInboxItem(
  mission: Mission,
  projects: ReadonlyArray<ProjectSummary>,
  items?: StreamItem[],
  observed?: PendingInteraction,
  nowMs = Date.now(),
  selectedMissionId?: string | null,
  childSummary?: InboxChildSummary,
): InboxItem | null {
  const interaction = extractInboxInteraction(mission, items, observed);
  const category = classifyInboxMission(mission, interaction);
  if (category === "hidden") return null;

  const projectSlug = mission.project || DEFAULT_PROJECT.slug;
  const rawProjectTitle =
    projects.find((p) => p.slug === projectSlug)?.title ||
    (projectSlug === DEFAULT_PROJECT.slug ? DEFAULT_PROJECT.title : projectSlug);
  const projectTitle =
    projectSlug === "orb" && /^sandboxed(?:\.sh)?$/i.test(rawProjectTitle.trim())
      ? "Orb"
      : rawProjectTitle;

  const observedKey = interaction
    ? `${interaction.callId}:${interaction.kind}:${interaction.prompt}`
    : "";
  const historyLen = mission.history?.length ?? 0;
  const lastHistoryContent = historyLen > 0 ? mission.history?.[historyLen - 1]?.content : undefined;
  const itemsLen = items?.length ?? 0;

  let base = inboxItemBaseCache.get(mission.id);
  if (
    !base ||
    base.missionStatus !== mission.status ||
    base.missionTitle !== mission.title ||
    base.missionUpdatedAt !== mission.updated_at ||
    base.missionLastOutputAt !== mission.last_output_at ||
    base.missionStatusMsg !== mission.status_message ||
    base.missionTerminalReason !== mission.terminal_reason ||
    base.missionRemoteErr !== mission.remote_job?.error ||
    base.historyLen !== historyLen ||
    base.lastHistoryContent !== lastHistoryContent ||
    base.itemsRef !== items ||
    base.itemsLen !== itemsLen ||
    base.observedKey !== observedKey ||
    base.projectTitle !== projectTitle ||
    base.category !== category
  ) {
    const rawTitle = displayTitle(mission.title);
    const firstUserItem = items?.find(
      (i): i is Extract<StreamItem, { kind: "user" }> =>
        i.kind === "user" && !i.queued && Boolean(i.text.trim()),
    )?.text;
    const firstUser = firstUserItem || mission.history?.find((h) => h.role === "user")?.content;
    let expandedTitle = rawTitle;
    if (rawTitle && (rawTitle.endsWith("…") || rawTitle.endsWith("...")) && rawTitle.length <= 46) {
      const stem = rawTitle.replace(/(?:…|\.\.\.)$/, "").trim().toLowerCase();
      const candidateSource = String(mission.goal_objective || firstUser || "")
        .trim()
        .split(/\r?\n/, 1)[0]
        ?.trim();
      if (stem.length >= 16 && candidateSource && candidateSource.toLowerCase().startsWith(stem)) {
        expandedTitle = clipToSentence(candidateSource, 84);
      }
    }
    let headline =
      (expandedTitle ? condenseMissionHeadline(expandedTitle, projectTitle) : "") ||
      (firstUser ? condenseMissionHeadline(clipToSentence(firstUser, 84), projectTitle) : "") ||
      "Untitled conversation";

    const isGoal = Boolean(
      mission.goal_mode || (mission.title && mission.title.trim().startsWith("/goal")),
    );
    if (headline.trim().toLowerCase() === projectTitle.trim().toLowerCase()) {
      const goalLines = String(mission.goal_objective ?? firstUser ?? "")
        .split(/\r?\n/)
        .map((l: string) => stripMarkdownToProse(l))
        .filter((l: string) => Boolean(l) && l.toLowerCase() !== projectTitle.trim().toLowerCase());
      if (goalLines.length > 0) {
        headline = condenseMissionHeadline(goalLines[0], projectTitle);
      } else if (isGoal) {
        headline = `${projectTitle} objective`;
      }
    }

    const summary = extractSummary(mission, items, interaction);
    const lastRequest = extractLastRequest(mission, items);
    const goalSummary = extractGoalSummary(mission, headline, firstUser, lastRequest);
    const workReceiptSummary = extractLatestWorkReceipt(items);
    const verdict = resolveVerdict(mission, summary, interaction);
    const { badge, tone } = resolveBadgeAndTone(mission, summary, interaction);
    const updatedMs = missionResponseTimestampMs(mission);
    const updatedIso =
      updatedMs > 0
        ? new Date(updatedMs).toISOString()
        : mission.updated_at || mission.last_output_at || mission.created_at;
    const baseAttention =
      Boolean(interaction) ||
      mission.status === "blocked" ||
      mission.status === "failed" ||
      mission.status === "not_feasible";
    const canRetry = RETRYABLE_STATUSES.has(mission.status);

    base = {
      id: mission.id,
      missionRef: mission,
      missionStatus: mission.status,
      missionTitle: mission.title,
      missionUpdatedAt: mission.updated_at,
      missionLastOutputAt: mission.last_output_at,
      missionStatusMsg: mission.status_message,
      missionTerminalReason: mission.terminal_reason,
      missionRemoteErr: mission.remote_job?.error,
      historyLen,
      lastHistoryContent,
      itemsRef: items,
      itemsLen,
      observedKey,
      category,
      projectSlug,
      projectTitle,
      headline,
      goalSummary,
      lastRequest,
      workReceiptSummary,
      verdict,
      summary,
      badge,
      tone,
      machine: resolveMachine(mission),
      updatedMs,
      updatedIso,
      isGoal,
      baseAttention,
      canRetry,
      interaction,
    };
    inboxItemBaseCache.set(mission.id, base);
  } else {
    base.missionRef = mission;
    base.interaction = interaction;
  }

  const cachedBase = base;
  const unread =
    isMissionUnread(mission, selectedMissionId, Boolean(interaction)) ||
    Boolean(childSummary?.hasUnreadFailure);
  const attention =
    cachedBase.baseAttention || Boolean(childSummary && childSummary.failed > 0);

  return {
    id: cachedBase.id,
    mission,
    category: cachedBase.category,
    projectSlug: cachedBase.projectSlug,
    projectTitle: cachedBase.projectTitle,
    headline: cachedBase.headline,
    goalSummary: cachedBase.goalSummary,
    lastRequest: cachedBase.lastRequest,
    workReceiptSummary: cachedBase.workReceiptSummary,
    verdict: cachedBase.verdict,
    summary: cachedBase.summary,
    badge: cachedBase.badge,
    tone: cachedBase.tone,
    machine: cachedBase.machine,
    relativeTime: formatRelativeTime(cachedBase.updatedIso, nowMs),
    updatedMs: cachedBase.updatedMs,
    isGoal: cachedBase.isGoal,
    unread,
    attention,
    canRetry: cachedBase.canRetry,
    get allPeekTurns(): InboxPeekTurn[] {
      if (!cachedBase.cachedAllPeekTurns) {
        cachedBase.cachedAllPeekTurns = extractAllPeekTurns(
          cachedBase.missionRef,
          cachedBase.itemsRef,
          cachedBase.summary,
          24,
        );
      }
      return cachedBase.cachedAllPeekTurns;
    },
    get peekTurns(): InboxPeekTurn[] {
      if (!cachedBase.cachedPeekTurns) {
        const all =
          cachedBase.cachedAllPeekTurns ??
          (cachedBase.cachedAllPeekTurns = extractAllPeekTurns(
            cachedBase.missionRef,
            cachedBase.itemsRef,
            cachedBase.summary,
            24,
          ));
        cachedBase.cachedPeekTurns = all.slice(-3);
      }
      return cachedBase.cachedPeekTurns;
    },
    childSummary,
    interaction: cachedBase.interaction,
  };
}

function hasUnresolvedInteractiveTool(
  mission: Mission,
  items?: StreamItem[],
  observed?: PendingInteraction,
): boolean {
  if (
    HIDDEN_STATUSES.has(mission.status) ||
    mission.status === "completed" ||
    mission.status === "failed" ||
    mission.status === "not_feasible"
  ) {
    return false;
  }
  if (observed) return true;
  if (!items || !items.length) return false;
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "tool" && !item.done && INTERACTIVE_TOOLS.has(item.name)) {
      return true;
    }
  }
  return false;
}

export type UnreadInboxCandidate = {
  id: string;
  mission: Mission;
  category: "needs_you" | "ready";
  hasInteraction: boolean;
  updatedMs: number;
};

/**
 * Fast O(N) unread classifier that avoids running markdown/regex summarization
 * over every mission transcript during background polls or sidebar badge updates.
 */
export function listUnreadInboxCandidates(
  missions: ReadonlyArray<Mission>,
  projects: ReadonlyArray<ProjectSummary>,
  getTranscript?: (id: string) => StreamItem[] | undefined,
  getInteraction?: (id: string) => PendingInteraction | undefined,
  selectedMissionId?: string | null,
): UnreadInboxCandidate[] {
  const liveSlugs =
    projects.length > 0
      ? new Set([DEFAULT_PROJECT.slug, ...projects.map((p) => p.slug)])
      : null;

  const unreadFailureByParent = new Set<string>();
  for (const m of missions) {
    if (isBtwMission(m) || HIDDEN_STATUSES.has(m.status || "")) continue;
    if (m.tags?.some((t) => t === "superseded" || t.startsWith("superseded-by:"))) continue;
    const parentId = m.parent_mission_id || m.callback_parent_mission_id;
    if (!parentId) continue;
    if (
      (m.status === "failed" || m.status === "blocked" || m.status === "not_feasible") &&
      isMissionUnread(m, selectedMissionId, false)
    ) {
      unreadFailureByParent.add(parentId);
    }
  }

  const out: UnreadInboxCandidate[] = [];
  for (const mission of missions) {
    const rawSlug = mission.project?.trim();
    const observed = getInteraction?.(mission.id);
    if (liveSlugs) {
      if (!rawSlug && !mission.tags?.includes("placement:client") && !observed) {
        continue;
      }
      const slug = rawSlug || DEFAULT_PROJECT.slug;
      if (!liveSlugs.has(slug)) continue;
    }
    if (isBtwMission(mission)) continue;
    const status = mission.status || "";
    if (HIDDEN_STATUSES.has(status)) continue;

    const needsInteractionCheck =
      Boolean(observed) || WORKING_STATUSES.has(status) || isSubagentMission(mission);
    const hasInteraction = needsInteractionCheck
      ? hasUnresolvedInteractiveTool(mission, getTranscript?.(mission.id), observed)
      : false;

    let category: "needs_you" | "ready" | null = null;
    if (hasInteraction) {
      category = "needs_you";
    } else if (!isSubagentMission(mission) && !WORKING_STATUSES.has(status)) {
      if (
        status === "blocked" ||
        status === "failed" ||
        status === "not_feasible" ||
        status === "awaiting_user" ||
        status === "waiting_user"
      ) {
        category = "needs_you";
      } else if (
        status === "completed" ||
        status === "succeeded" ||
        status === "paused" ||
        status === "interrupted"
      ) {
        category = "ready";
      }
    }
    if (!category) continue;

    const unread =
      isMissionUnread(mission, selectedMissionId, hasInteraction) ||
      unreadFailureByParent.has(mission.id);
    if (!unread) continue;

    out.push({
      id: mission.id,
      mission,
      category,
      hasInteraction,
      updatedMs: missionResponseTimestampMs(mission),
    });
  }

  out.sort((a, b) => {
    if (a.category !== b.category) return a.category === "needs_you" ? -1 : 1;
    if (a.hasInteraction !== b.hasInteraction) return a.hasInteraction ? -1 : 1;
    return b.updatedMs - a.updatedMs;
  });
  return out;
}

export function countUnreadInboxMissions(
  missions: ReadonlyArray<Mission>,
  projects: ReadonlyArray<ProjectSummary>,
  getTranscript?: (id: string) => StreamItem[] | undefined,
  getInteraction?: (id: string) => PendingInteraction | undefined,
  selectedMissionId?: string | null,
): number {
  return listUnreadInboxCandidates(
    missions,
    projects,
    getTranscript,
    getInteraction,
    selectedMissionId,
  ).length;
}

function urgencyScore(item: InboxItem): number {
  if (item.interaction) {
    if (item.interaction.kind === "permission" || item.interaction.kind === "plan") return 0;
    return 1;
  }
  if (item.mission.status === "blocked") return 2;
  if (item.mission.status === "failed" || item.mission.status === "not_feasible") return 3;
  if (item.mission.status === "awaiting_user" || item.mission.status === "waiting_user") {
    return item.summary.endsWith("?") ? 4 : 5;
  }
  if (item.childSummary && item.childSummary.failed > 0) return 5.5;
  return 6;
}

function cleanChildTrackLabel(rawTitle: string | null | undefined): string {
  const raw = (displayTitle(rawTitle) || "").trim();
  if (!raw) return "Worker track";
  const withoutFork = raw.replace(/\s*·\s*fork$/i, "").trim();
  if (/^(i['’]ll|i will|let me|first,|now i|checking|reading)\b/i.test(withoutFork)) {
    return raw.toLowerCase().endsWith("· fork") ? "fork" : "Worker track";
  }
  return clipToSentence(raw, 36) || "Worker track";
}

export function buildInboxSections(
  missions: ReadonlyArray<Mission>,
  projects: ReadonlyArray<ProjectSummary>,
  getTranscript?: (id: string) => StreamItem[] | undefined,
  getInteraction?: (id: string) => PendingInteraction | undefined,
  nowMs = Date.now(),
  selectedMissionId?: string | null,
): InboxSections {
  const needsYou: InboxItem[] = [];
  const ready: InboxItem[] = [];
  const working: InboxItem[] = [];
  const liveSlugs =
    projects.length > 0
      ? new Set([DEFAULT_PROJECT.slug, ...projects.map((p) => p.slug)])
      : null;

  // Group child worker/track runs under their parent orchestrator mission so
  // parent cards can surface a compact track summary badge (e.g. "1 track failed").
  const childrenByParent = new Map<string, InboxChildSummary>();
  for (const m of missions) {
    if (isBtwMission(m) || HIDDEN_STATUSES.has(m.status || "")) continue;
    if (m.tags?.some((t) => t === "superseded" || t.startsWith("superseded-by:"))) continue;
    const parentId = m.parent_mission_id || m.callback_parent_mission_id;
    if (!parentId) continue;
    let group = childrenByParent.get(parentId);
    if (!group) {
      group = {
        total: 0,
        running: 0,
        failed: 0,
        completed: 0,
        failedChildren: [],
        hasUnreadFailure: false,
      };
      childrenByParent.set(parentId, group);
    }
    group.total++;
    if (WORKING_STATUSES.has(m.status)) {
      group.running++;
    } else if (m.status === "failed" || m.status === "blocked" || m.status === "not_feasible") {
      group.failed++;
      const childTitle = cleanChildTrackLabel(m.title);
      group.failedChildren.push({ id: m.id, title: childTitle, mission: m });
      if (isMissionUnread(m, selectedMissionId, false)) {
        group.hasUnreadFailure = true;
      }
    } else if (m.status === "completed" || m.status === "succeeded") {
      group.completed++;
    }
  }

  for (const mission of missions) {
    const rawSlug = mission.project?.trim();
    const observed = getInteraction?.(mission.id);
    if (liveSlugs) {
      // Exclude unassigned probe missions that don't belong to any project unless they are client-placed or asking a live question.
      if (!rawSlug && !mission.tags?.includes("placement:client") && !observed) {
        continue;
      }
      const slug = rawSlug || DEFAULT_PROJECT.slug;
      if (!liveSlugs.has(slug)) continue;
    }
    const item = buildInboxItem(
      mission,
      projects,
      getTranscript?.(mission.id),
      observed,
      nowMs,
      selectedMissionId,
      childrenByParent.get(mission.id),
    );
    if (!item) continue;
    if (item.category === "needs_you") needsYou.push(item);
    else if (item.category === "ready") ready.push(item);
    else if (item.category === "working") working.push(item);
  }

  needsYou.sort((a, b) => {
    const u = urgencyScore(a) - urgencyScore(b);
    if (u !== 0) return u;
    return b.updatedMs - a.updatedMs;
  });

  ready.sort((a, b) => b.updatedMs - a.updatedMs);
  working.sort((a, b) => b.updatedMs - a.updatedMs);

  let unreadCount = 0;
  let attentionCount = 0;
  for (const item of [...needsYou, ...ready]) {
    if (item.unread) unreadCount++;
    if (item.attention) attentionCount++;
  }

  return {
    needsYou,
    ready,
    working,
    totalActionable: needsYou.length + ready.length,
    unreadCount,
    attentionCount,
  };
}
