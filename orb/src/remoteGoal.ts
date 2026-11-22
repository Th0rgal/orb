/** Lossless structured event envelope plus the client projection of a remote Goal. */
export type RemoteGoalEvent = {
  type: "goal_status" | "goal_iteration";
  data: Record<string, unknown>;
};

export function remoteGoalEvent(value: unknown): RemoteGoalEvent | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const event = value as Record<string, unknown>;
  if (event.type !== "goal_status" && event.type !== "goal_iteration") return null;
  if (!event.data || typeof event.data !== "object" || Array.isArray(event.data)) return null;
  return { type: event.type, data: { ...event.data as Record<string, unknown> } };
}

export type RemoteGoalPhase = "active" | "complete" | "stopped" | "paused" | "blocked";
export type RemoteGoalProjection = { phase: RemoteGoalPhase; objective: string; iteration: number; detail?: string };

export function applyRemoteGoalEvent(previous: RemoteGoalProjection, value: unknown): RemoteGoalProjection {
  const event = remoteGoalEvent(value);
  if (!event) return previous;
  const data = event.data;
  const status = typeof data.status === "string" ? data.status : undefined;
  const phase: RemoteGoalPhase = status === "complete" || status === "stopped" || status === "paused" || status === "blocked" ? status : status === "active" && previous.phase !== "complete" && previous.phase !== "stopped" ? "active" : previous.phase;
  return {
    phase,
    objective: typeof data.objective === "string" ? data.objective : previous.objective,
    iteration: typeof data.iteration === "number" ? data.iteration : previous.iteration,
    detail: typeof data.summary === "string" ? data.summary : previous.detail,
  };
}

export function remoteGoalPhase(status: string | undefined, reason: string | null | undefined): RemoteGoalPhase {
  if (reason === "remote_goal_complete") return "complete";
  if (reason === "remote_goal_stopped" || status === "cancelled") return "stopped";
  if (status === "active" || status === "pending" || reason === "remote_goal_continuation" || reason === "awaiting_wakeup") return "active";
  return status === "paused" ? "paused" : "blocked";
}

export function remoteGoalStatusLabel(projection: RemoteGoalProjection): string {
  if (projection.phase === "complete") return "Goal complete";
  if (projection.phase === "stopped") return "Goal stopped";
  if (projection.phase === "blocked") return "Goal blocked";
  if (projection.phase === "paused") return "Goal paused";
  return projection.iteration > 0 ? `Goal in progress · iteration ${projection.iteration}` : "Goal in progress";
}

const completionLine = "<!-- GOAL_COMPLETE -->";

/** Same standalone line and Markdown fence boundaries as Core's RemoteGoal.hasCompletionMarker. */
export function confirmedGoalAnswer(raw: string): string | undefined {
  const lines = raw.trimEnd().split(/\r?\n/);
  if (lines.pop() !== completionLine) return undefined;
  let fence = "";
  for (const line of lines) {
    const match = /^\s*(`{3,}|~{3,})(.*)$/.exec(line);
    if (!match) continue;
    const [, delimiter, tail] = match;
    if (!fence) fence = delimiter;
    else if (delimiter.startsWith(fence) && !tail.trim()) fence = "";
  }
  if (fence) return undefined;
  const markerStart = raw.lastIndexOf(completionLine);
  return raw.slice(0, markerStart).replace(/\r?\n$/, "");
}

/** Older summaries may flatten the same final response onto a single line. */
export function confirmedGoalRecap(outcome: string, raw: string | undefined): string {
  if (!raw) return outcome;
  const flatten = (text: string) => text.trim().replace(/\s+/g, " ");
  if (flatten(outcome) !== flatten(raw)) return outcome;
  return outcome.trimEnd().slice(0, -completionLine.length).trimEnd();
}
