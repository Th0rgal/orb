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
  const phase: RemoteGoalPhase = status === "complete" ? "complete" : status === "stopped" ? "stopped" : status === "blocked" ? "blocked" : status === "paused" ? "paused" : previous.phase === "complete" || previous.phase === "stopped" ? previous.phase : "active";
  return {
    phase,
    objective: typeof data.objective === "string" ? data.objective : previous.objective,
    iteration: typeof data.iteration === "number" ? data.iteration : previous.iteration,
    ...(typeof data.summary === "string" ? { detail: data.summary } : {}),
  };
}

export function remoteGoalStopLabel(projection: RemoteGoalProjection): string {
  return projection.phase === "active" ? "Stop Goal" : "Goal stopped";
}

export function remoteGoalStatusLabel(projection: RemoteGoalProjection): string {
  if (projection.phase === "complete") return "Goal complete";
  if (projection.phase === "stopped") return "Goal stopped";
  if (projection.phase === "blocked") return "Goal blocked";
  if (projection.phase === "paused") return "Goal paused";
  return projection.iteration > 0 ? `Goal in progress · iteration ${projection.iteration}` : "Goal in progress";
}
