import { missionParent } from "./missionTree";
import { hasTypedSuperseded, isBtwMission, isClientPlacement, type Mission, type ProjectSummary } from "./api";
import { backgroundWake as parseBackgroundWake } from "./backgroundWake";
import { DEFAULT_PROJECT } from "./defaultProject";
import { messagePresentation as parseMessagePresentation } from "./messagePresentation";
import type { PendingInteraction } from "./missionAttention";
import { isRecoveryScheduled } from "./missionLaunch";
import { isMissionUnread, missionResponseTimestampMs } from "./missionUnread";
import type { StreamItem } from "./transcriptModel";
import { toolArgs, toolName } from "./workModel";

export const WORKING_STATUSES = new Set([
  "active",
  "running",
  "starting",
  "pending",
  "queued",
  "resuming",
  "waiting_background",
]);

export const HIDDEN_STATUSES = new Set([
  "acknowledged",
  "cancelled",
  "canceled",
  "deleted",
]);

export const INTERACTIVE_TOOLS = new Set([
  "ui_native_request",
  "AskUserQuestion",
  "question",
]);

export type InboxScope = { includeAutonomous?: boolean };

export type UnreadInboxCandidate = {
  id: string;
  mission: Mission;
  category: "needs_you" | "ready";
  hasInteraction: boolean;
  updatedMs: number;
};

/** Child worker missions belong nested inside their parent orchestrator in the sidebar, not as standalone Inbox items. */
export function isSubagentMission(
  mission: Pick<Mission, "title" | "parent_mission_id" | "callback_parent_mission_id" | "tags" | "status" | "superseded_by_mission_id">,
): boolean {
  if (missionParent(mission)) return true;
  if (hasTypedSuperseded(mission)) return true;
  if (mission.tags?.some((tag) => tag.startsWith("worker-dispatch:"))) {
    return true;
  }
  const rawTitle = (mission.title ?? "").trim();
  if (/^you are a sub-?agent\b/i.test(rawTitle)) {
    return true;
  }
  return false;
}

/** Creation provenance, not the source of the latest message (which may be a watchdog). */
export function isAutonomousInboxMission(mission: Mission): boolean {
  return isSubagentMission(mission) || mission.origin === "hermes" ||
    Boolean(mission.tags?.some((tag) => tag === "origin:hermes" || tag === "origin:hermes-assistant"));
}

export function isInInboxScope(mission: Mission, scope: InboxScope): boolean {
  if (hasTypedSuperseded(mission)) {
    return false;
  }
  return Boolean(scope.includeAutonomous) || !isAutonomousInboxMission(mission);
}

/** Working missions the Inbox hides because autonomous agents are filtered out. */
export function hiddenAutonomousWorking(missions: ReadonlyArray<Mission>, includeAutonomous: boolean): number {
  if (includeAutonomous) return 0;
  return missions.filter((m) => WORKING_STATUSES.has(m.status) && isAutonomousInboxMission(m) && isInInboxScope(m, { includeAutonomous: true })).length;
}

export function isSyntheticUserMessage(raw: string): boolean {
  const pres = parseMessagePresentation(raw).text.trim();
  if (!pres) return true;
  if (parseBackgroundWake(pres)) return true;
  return (
    /^\[automatic (?:resume|recovery)\b/i.test(pres) ||
    /^antigravity background task handoff\b/i.test(pres) ||
    /^background task\s+`[^`]+`\s+.*finished\b/i.test(pres) ||
    /^continue from where you left off\.?$/i.test(pres) ||
    /^\[system\b/i.test(pres)
  );
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

export function hasUnresolvedInteractiveTool(
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
  scope: InboxScope = {},
): UnreadInboxCandidate[] {
  const liveSlugs =
    projects.length > 0
      ? new Set([DEFAULT_PROJECT.slug, ...projects.map((p) => p.slug)])
      : null;

  const byId = new Map(missions.map((m) => [m.id, m]));
  const unreadFailureByParent = new Set<string>();
  for (const m of missions) {
    if (!scope.includeAutonomous) break;
    if (isBtwMission(m, byId) || HIDDEN_STATUSES.has(m.status || "")) continue;
    if (hasTypedSuperseded(m)) continue;
    const parentId = missionParent(m);
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
    if (!isInInboxScope(mission, scope)) continue;
    const rawSlug = mission.project?.trim();
    const observed = getInteraction?.(mission.id);
    if (liveSlugs) {
      if (!rawSlug && !isClientPlacement(mission) && !observed) {
        continue;
      }
      const slug = rawSlug || DEFAULT_PROJECT.slug;
      if (!liveSlugs.has(slug)) continue;
    }
    if (isBtwMission(mission, byId)) continue;
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
    } else if (!WORKING_STATUSES.has(status) && !isRecoveryScheduled(mission)) {
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
  scope: InboxScope = {},
): number {
  return listUnreadInboxCandidates(
    missions,
    projects,
    getTranscript,
    getInteraction,
    selectedMissionId,
    scope,
  ).length;
}
