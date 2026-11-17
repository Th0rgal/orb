/** Lossless structured event envelope. This does not advertise goal capability
 * or derive mission completion from a transport event. Integration is separate. */
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
