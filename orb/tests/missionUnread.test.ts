import { beforeEach, expect, it, vi } from "vitest";
const connection = vi.hoisted(() => ({ version: 0, connected: true, opened: vi.fn() }));
vi.mock("../src/api", () => ({
  connectionVersion: () => connection.version,
  getApiUrl: () => "https://read-test.invalid",
  isConnected: () => connection.connected,
  markMissionOpened: connection.opened,
}));
beforeEach(() => {
  vi.resetModules();
  localStorage.clear();
  connection.version++;
  connection.opened.mockReset().mockResolvedValue(undefined);
});
const mission = { id: "read-receipt", status: "completed", created_at: "2026-10-09T10:00:00Z", updated_at: "2026-10-09T10:01:00Z" };
it("marks a turn once when opened receipts are echoed back as status updates", async () => {
  const { markMissionRead, unreadVersion, markMissionsRead } = await import("../src/missionUnread");
  markMissionRead(mission);
  const version = unreadVersion();
  for (let i = 0; i < 20; i++) { markMissionRead({ ...mission }); markMissionsRead([mission]); }
  expect(connection.opened).toHaveBeenCalledTimes(1);
  expect(unreadVersion()).toBe(version);
  markMissionRead({ ...mission, updated_at: new Date(Date.now() + 1000).toISOString() });
  expect(connection.opened).toHaveBeenCalledTimes(2);
  expect(unreadVersion()).toBe(version + 1);
});
it("retries a failed opened receipt, and sends a fresh one after reconnection", async () => {
  connection.opened.mockRejectedValueOnce(new Error("offline"));
  const { markMissionRead } = await import("../src/missionUnread");
  markMissionRead(mission);
  await Promise.resolve();
  markMissionRead(mission);
  await Promise.resolve();
  markMissionRead(mission);
  expect(connection.opened).toHaveBeenCalledTimes(2);
  connection.version++;
  markMissionRead(mission);
  expect(connection.opened).toHaveBeenCalledTimes(3);
});
it("honors a manual unread flag without reposting an already acknowledged turn", async () => {
  const { markMissionRead, markMissionUnread, isMissionUnread } = await import("../src/missionUnread");
  markMissionRead(mission);
  markMissionUnread(mission);
  expect(isMissionUnread(mission)).toBe(true);
  markMissionRead(mission);
  expect(isMissionUnread(mission)).toBe(false);
  expect(connection.opened).toHaveBeenCalledTimes(1);
});
