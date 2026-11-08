import { api } from "./api";

export interface MissionShareEntry {
  user_id: string;
  username: string;
  created_at?: string;
}

export interface UserDirectoryEntry {
  id: string;
  username: string;
}

export async function listMissionShares(missionId: string): Promise<MissionShareEntry[]> {
  const data = await api<MissionShareEntry[] | { shares?: MissionShareEntry[] }>(
    `/api/control/missions/${encodeURIComponent(missionId)}/shares`,
  );
  if (Array.isArray(data)) return data;
  return Array.isArray(data?.shares) ? data.shares : [];
}

export async function addMissionShare(
  missionId: string,
  target: { username?: string; user_id?: string },
): Promise<MissionShareEntry[]> {
  const data = await api<MissionShareEntry[] | { shares?: MissionShareEntry[] }>(
    `/api/control/missions/${encodeURIComponent(missionId)}/shares`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(target),
    },
  );
  if (Array.isArray(data)) return data;
  return Array.isArray(data?.shares) ? data.shares : [];
}

export async function removeMissionShare(missionId: string, userId: string): Promise<void> {
  await api(`/api/control/missions/${encodeURIComponent(missionId)}/shares/${encodeURIComponent(userId)}`, {
    method: "DELETE",
  });
}

export async function listUserDirectory(): Promise<UserDirectoryEntry[]> {
  const data = await api<UserDirectoryEntry[] | { users?: UserDirectoryEntry[] }>("/api/users/directory");
  if (Array.isArray(data)) return data;
  return Array.isArray(data?.users) ? data.users : [];
}

export function formatUsdFromCents(cents: number | null | undefined): string {
  const safe = typeof cents === "number" && Number.isFinite(cents) ? Math.max(0, cents) : 0;
  return `$${(safe / 100).toFixed(2)}`;
}

/** Parse an optional USD string (`"12.50"` -> `1250` cents, `""` -> `null`). Returns `undefined` when invalid. */
export function parseUsdToCents(raw: string): number | null | undefined {
  const trimmed = raw.trim().replace(/^\$/, "");
  if (!trimmed) return null;
  if (!/^\d+(?:\.\d{1,2})?$/.test(trimmed)) return undefined;
  const n = Number(trimmed);
  if (!Number.isFinite(n) || n < 0 || n > 10_000_000) return undefined;
  return Math.round(n * 100);
}
