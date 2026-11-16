import { afterEach, expect, it, vi } from "vitest";
import { getMissionBoard, getProject, getProjectBoard, getProjectBoards, setConnection, setProjectControllerMission } from "../src/api";
import { resetMissionHierarchy, observeMission, commitAuthoritativePlacements } from "../src/missionHierarchy";
import { boardPlacementSnapshot, staleBoardListing } from "../src/missionBoard";
afterEach(() => vi.restoreAllMocks());
const connect = () => setConnection("https://board.test", "board-token");
it("reads project controller fields and encodes the slug", async () => {
  connect();
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ slug: "a/b", controller_mission_id: "m1", board_updated_at: "now" }));
  expect((await getProject("a/b"))?.controller_mission_id).toBe("m1");
  expect(String(fetch.mock.calls[0][0])).toBe("https://board.test/api/projects/a%2Fb");
});
it("reads board text and attribution without changing content", async () => {
  connect();
  const board = { text: "# Plan\n<script>raw text</script>", updated_at: "2026-11-15T10:00:00Z", updated_by_mission_id: "m1", controller_mission_id: "m1" };
  vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json(board));
  expect(await getProjectBoard("notes")).toEqual(board);
});
for (const missionId of ["m1", null]) it(`sets controller to ${missionId} with the exact PUT body`, async () => {
  connect();
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 204 }));
  expect(await setProjectControllerMission("a/b", missionId)).toBe(true);
  expect(String(fetch.mock.calls[0][0])).toBe("https://board.test/api/projects/a%2Fb/controller-mission");
  expect(fetch.mock.calls[0][1]?.method).toBe("PUT");
  expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({ mission_id: missionId });
});
it("tolerates 404 for all new routes", async () => {
  connect(); vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("Not found", { status: 404 }));
  expect(await getProject("old")).toBeNull();
  expect(await getProjectBoard("old")).toBeNull();
  expect(await setProjectControllerMission("old", null)).toBe(false);
});
it("treats missing fields as unsupported", async () => {
  connect(); vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({ slug: "old" }));
  expect(await getProject("old")).toBeNull(); expect(await getProjectBoard("old")).toBeNull();
});
it("keeps authorization errors available to the caller", async () => {
  connect(); vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("Owner only", { status: 403 }));
  await expect(setProjectControllerMission("notes", "m1")).rejects.toMatchObject({ status: 403 });
});
it("reads mission boards and project metadata boards", async () => {
  connect();
  const fetch = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) =>
    String(input).endsWith("/boards")
      ? Response.json({ project: "notes", boards: [{ mission_id: "m1", title: "Plan", status: "active", parent_mission_id: null, updated_at: "t", bytes: 3, text_sha256: "abc" }] })
      : Response.json({ mission_id: "m1", text: "one", updated_at: "t", updated_by_mission_id: "m1", text_sha256: "abc" }),
  );
  expect((await getMissionBoard("m1"))?.text_sha256).toBe("abc");
  expect((await getProjectBoards("notes"))?.boards[0].mission_id).toBe("m1");
  expect(String(fetch.mock.calls[0][0])).toContain("/api/control/missions/m1/board");
});
it("discards a listing whose returned mission moved while it was in flight", () => {
  resetMissionHierarchy();
  observeMission({ id: "m1", project: "old", placement_revision: 1 });
  const snapshot = boardPlacementSnapshot();
  commitAuthoritativePlacements([{ mission_id: "m1", project: "new", folder: "", placement_revision: 2 }]);
  expect(staleBoardListing(snapshot, [{ mission_id: "m1" } as any])).toBe(true);
});
