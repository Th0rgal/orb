import { beforeEach, expect, it, vi } from "vitest";
const connection = vi.hoisted(() => ({ version: 0, connected: true, token: "test-token", opened: vi.fn() }));
vi.mock("../src/api", () => ({
  connectionVersion: () => connection.version,
  getJwt: () => connection.token,
  getApiUrl: () => "https://read-test.invalid",
  isConnected: () => connection.connected,
  markMissionOpened: connection.opened,
}));
beforeEach(() => {
  connection.token = "test-token";
  vi.resetModules();
  localStorage.clear();
  connection.version++;
  connection.opened.mockReset().mockResolvedValue(undefined);
  vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
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

it("shares manual unread without changing the mission acknowledgement, and expires it on the next turn", async () => {
  const { applySharedInboxSeen, isMissionUnread } = await import("../src/missionUnread");
  const acknowledged = { ...mission, first_viewed_at: "2026-10-09T10:02:00Z" };
  applySharedInboxSeen({ ["seen:" + mission.id]: -Date.parse(mission.updated_at) });
  expect(isMissionUnread(acknowledged)).toBe(true);
  expect(connection.opened).not.toHaveBeenCalled();
  expect(isMissionUnread({ ...acknowledged, updated_at: "2026-10-09T10:05:00Z" })).toBe(true);
  applySharedInboxSeen({ ["seen:" + mission.id]: Date.parse("2026-10-09T10:06:00Z") });
  expect(isMissionUnread({ ...acknowledged, updated_at: "2026-10-09T10:05:00Z" })).toBe(false);
});

it("migrates legacy read and unread receipts once without sharing them with another account", async () => {
  const token = (sub: string) => `header.${btoa(JSON.stringify({ sub }))}.signature`;
  connection.token = token("alice");
  localStorage.setItem("orb.missionSeenV2:https://read-test.invalid", JSON.stringify({ [mission.id]: Date.parse(mission.updated_at), manual: -Date.parse(mission.updated_at) }));
  const { isMissionUnread } = await import("../src/missionUnread");
  expect(isMissionUnread(mission)).toBe(false);
  expect(isMissionUnread({ ...mission, id: "manual", first_viewed_at: mission.updated_at })).toBe(true);
  connection.token = token("bob"); connection.version++;
  expect(isMissionUnread(mission)).toBe(true);
  connection.token = token("alice"); connection.version++;
  expect(isMissionUnread(mission)).toBe(false);
});
