import { isBtwMission, type Mission, type ProjectSummary } from "./api";
import { DEFAULT_PROJECT } from "./defaultProject";
import { displayTitle } from "./goal";
import type { PendingInteraction } from "./missionAttention";
import { nodeLabel } from "./missionLaunch";
import { isMissionUnread, missionResponseTimestampMs } from "./missionUnread";
import type { StreamItem } from "./transcriptModel";

export const INBOX_SENTENCE_MAX_CHARS = 112;

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

export type InboxItem = {
  id: string;
  mission: Mission;
  category: Exclude<InboxCategory, "hidden">;
  projectSlug: string;
  projectTitle: string;
  headline: string;
  summary: string;
  badge: string;
  tone: InboxTone;
  machine?: string;
  relativeTime: string;
  updatedMs: number;
  isGoal: boolean;
  unread: boolean;
  attention: boolean;
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

/** Strip markdown syntax into clean single-line prose suitable for a compact inbox preview. */
export function stripMarkdownToProse(raw: string): string {
  if (!raw) return "";
  let text = raw
    // Remove fenced code blocks, keeping a short inline hint if prose is otherwise empty
    .replace(/```[\s\S]*?```/g, " ")
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
  // Prefer the first complete sentence if it already fits within maxChars.
  const firstSentence = clean.match(/^(.+?[.!?])(?:\s|$)/);
  if (firstSentence && firstSentence[1].length <= maxChars && firstSentence[1].length >= 16) {
    return firstSentence[1];
  }
  if (clean.length <= maxChars) return clean;

  const windowText = clean.slice(0, maxChars);
  // Look for the last sentence boundary within the budget
  let lastSentenceEnd = -1;
  for (let i = windowText.length - 1; i >= 24; i--) {
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

  // Fallback to last word boundary
  const clipped = clean.slice(0, Math.max(1, maxChars - 1));
  const lastSpace = clipped.lastIndexOf(" ");
  if (lastSpace >= 24) {
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

function extractSummary(
  mission: Mission,
  items?: StreamItem[],
  interaction?: InboxInteraction,
): string {
  if (interaction?.prompt) return interaction.prompt;

  if (items && items.length > 0) {
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      if (item.kind === "error" && item.text.trim()) {
        const cleanErr = humanizeStatusText(item.text) || item.text;
        return clipToSentence(cleanErr);
      }
      if (item.kind === "text" && item.text.trim()) {
        const cleanTxt = humanizeStatusText(item.text) || item.text;
        return clipToSentence(cleanTxt);
      }
    }
  }

  if (Array.isArray(mission.history) && mission.history.length > 0) {
    for (let i = mission.history.length - 1; i >= 0; i--) {
      const entry = mission.history[i];
      if (entry.role === "assistant" && entry.content?.trim()) {
        const cleanHist = humanizeStatusText(entry.content) || entry.content;
        return clipToSentence(cleanHist);
      }
    }
  }

  const remoteErr = humanizeStatusText(mission.remote_job?.error);
  if (remoteErr) return clipToSentence(remoteErr);

  const statusMsg = humanizeStatusText(mission.status_message);
  if (statusMsg) return clipToSentence(statusMsg);

  const termReason = humanizeStatusText(mission.terminal_reason);
  if (termReason) return clipToSentence(termReason);

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

export function buildInboxItem(
  mission: Mission,
  projects: ReadonlyArray<ProjectSummary>,
  items?: StreamItem[],
  observed?: PendingInteraction,
  nowMs = Date.now(),
  selectedMissionId?: string | null,
): InboxItem | null {
  const interaction = extractInboxInteraction(mission, items, observed);
  const category = classifyInboxMission(mission, interaction);
  if (category === "hidden") return null;

  const projectSlug = mission.project || DEFAULT_PROJECT.slug;
  const projectTitle =
    projects.find((p) => p.slug === projectSlug)?.title ||
    (projectSlug === DEFAULT_PROJECT.slug ? DEFAULT_PROJECT.title : projectSlug);

  const rawTitle = displayTitle(mission.title);
  const firstUser = mission.history?.find((h) => h.role === "user")?.content;
  let headline =
    rawTitle ||
    (firstUser ? clipToSentence(firstUser, 56) : "") ||
    "Untitled conversation";

  const isGoal = Boolean(
    mission.goal_mode || (mission.title && mission.title.trim().startsWith("/goal")),
  );
  if (headline.trim().toLowerCase() === projectTitle.trim().toLowerCase()) {
    const goalLines = (mission.goal_objective ?? firstUser ?? "")
      .split(/\r?\n/)
      .map((l) => stripMarkdownToProse(l))
      .filter((l) => l && l.toLowerCase() !== projectTitle.trim().toLowerCase());
    if (goalLines.length > 0) {
      headline = clipToSentence(goalLines[0], 56);
    } else if (isGoal) {
      headline = `${projectTitle} objective`;
    }
  }

  const summary = extractSummary(mission, items, interaction);
  const { badge, tone } = resolveBadgeAndTone(mission, summary, interaction);
  const updatedMs = missionResponseTimestampMs(mission);
  const updatedIso =
    updatedMs > 0
      ? new Date(updatedMs).toISOString()
      : mission.updated_at || mission.last_output_at || mission.created_at;
  const unread = isMissionUnread(mission, selectedMissionId, Boolean(interaction));
  const attention =
    Boolean(interaction) ||
    mission.status === "blocked" ||
    mission.status === "failed" ||
    mission.status === "not_feasible";

  return {
    id: mission.id,
    mission,
    category,
    projectSlug,
    projectTitle,
    headline,
    summary,
    badge,
    tone,
    machine: resolveMachine(mission),
    relativeTime: formatRelativeTime(updatedIso, nowMs),
    updatedMs,
    isGoal,
    unread,
    attention,
    interaction,
  };
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
  return 6;
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
