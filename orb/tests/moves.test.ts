import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createMemo, createRoot } from "solid-js";
import { MOVE_CONFIRM_MS, deleteFileOptimistically, fileMoveKey, filesMovedAway, filesMovedInto, isFilePathPending, missionMoveKey, missionsMovedInto, moveOptimistically, movedMission, movingOutOf, previewMove, resetMoves, settleMove, withMovedMissions } from "../src/moves";

beforeEach(() => resetMoves());
afterEach(() => { vi.useRealTimers(); resetMoves(); });
const deferred = () => { let resolve!: () => void, reject!: (e: unknown) => void; const promise = new Promise<void>((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const mission = { id: "m1", project: "alpha", tags: ["orb-folder:old", "keep"] };
const move = { kind: "mission" as const, fromProject: "alpha", toProject: "beta", path: "docs" };

it("shows a moved mission in its destination in every view before the server answers", () => {
  const request = deferred();
  createRoot(dispose => {
    const sidebar = createMemo(() => withMovedMissions([mission])[0]);
    void moveOptimistically(missionMoveKey("m1"), move, () => request.promise);
    expect(sidebar()).toEqual({ id: "m1", project: "beta", tags: ["keep", "orb-folder:docs"] });
    expect(movingOutOf("m1", "alpha")).toBe(true);
    expect(missionsMovedInto("beta", [mission]).map(m => m.id)).toEqual(["m1"]);
    expect(missionsMovedInto("alpha", [mission])).toEqual([]);
    dispose();
  });
  request.resolve();
});

it("moves it back and shows an error toast when the request fails", async () => {
  const request = deferred();
  const done = moveOptimistically(missionMoveKey("m1"), move, () => request.promise);
  expect(movedMission(mission).project).toBe("beta");
  request.reject(new Error("403 forbidden"));
  await expect(done).rejects.toThrow("403 forbidden");
  expect(movedMission(mission)).toBe(mission);
  await Promise.resolve();
  expect(document.body.textContent).toContain("Couldn’t move the conversation");
  expect(document.body.textContent).toContain("403 forbidden");
});

it("does not mistake a projected destination for acknowledgement", async () => {
  vi.useFakeTimers();
  await moveOptimistically(missionMoveKey("m1"), move, async () => {});
  // A list fetched before the move landed still says alpha.
  expect(withMovedMissions([mission])[0].project).toBe("beta");
  // Even a matching row may be the output of our own projection.
  const confirmed = { id: "m1", project: "beta", tags: ["keep", "orb-folder:docs"] };
  expect(movedMission(confirmed)).toBe(confirmed);
  await Promise.resolve();
  expect(movedMission(mission).project).toBe("beta");
  settleMove(missionMoveKey("m1"));
  expect(movedMission({ ...mission, project: "gamma" }).project).toBe("gamma");
});

it("stops overriding after the confirmation timeout", async () => {
  vi.useFakeTimers();
  await moveOptimistically(missionMoveKey("m1"), move, async () => {});
  vi.advanceTimersByTime(MOVE_CONFIRM_MS);
  expect(movedMission(mission)).toBe(mission);
});

it("moves files and folders between project listings at once", () => {
  previewMove(fileMoveKey("alpha", "notes/plan.md"), { kind: "file", fromProject: "alpha", toProject: "beta", path: "inbox/plan.md", fromPath: "notes/plan.md" });
  previewMove(fileMoveKey("alpha", "drafts"), { kind: "file", fromProject: "alpha", toProject: "beta", path: "drafts", fromPath: "drafts", directory: true });
  expect([...filesMovedAway("alpha", "notes")]).toEqual(["plan.md"]);
  expect([...filesMovedAway("alpha", "")]).toEqual(["drafts"]);
  expect(filesMovedInto("beta", "inbox")).toEqual([{ name: "plan.md", kind: "file" }]);
  expect(filesMovedInto("beta", "")).toEqual([{ name: "drafts", kind: "dir" }]);
  expect(filesMovedInto("alpha", "notes")).toEqual([]);
});

it("keeps row identity when nothing is moving", () => {
  const rows = [mission];
  expect(withMovedMissions(rows)).toBe(rows);
});

it("hides a deleted folder optimistically without projecting a destination and restores it on failure", async () => {
  const request = deferred();
  const done = deleteFileOptimistically("alpha", "Audits", true, () => request.promise, "Audits");
  expect([...filesMovedAway("alpha", "")]).toEqual(["Audits"]);
  expect(filesMovedInto("alpha", "")).toEqual([]);
  expect(filesMovedInto("", "")).toEqual([]);
  request.reject(new Error("Move the agents out of this folder before deleting it."));
  await expect(done).rejects.toThrow("Move the agents");
  expect([...filesMovedAway("alpha", "")]).toEqual([]);
  await Promise.resolve();
  expect(document.body.textContent).toContain("Couldn’t delete Audits");
  expect(document.body.textContent).toContain("Move the agents out of this folder before deleting it.");
});

it("marks pending folder sources, destinations, ancestors, and descendants until settled", async () => {
  await moveOptimistically(
    fileMoveKey("alpha", "old/sub"),
    { kind: "file", fromProject: "alpha", toProject: "alpha", path: "new/sub", fromPath: "old/sub", directory: true },
    async () => {},
  );
  expect(isFilePathPending("alpha", "old/sub")).toBe(true);
  expect(isFilePathPending("alpha", "old/sub/file.md")).toBe(true);
  expect(isFilePathPending("alpha", "old")).toBe(true);
  expect(isFilePathPending("alpha", "new/sub")).toBe(true);
  expect(isFilePathPending("alpha", "new/sub/file.md")).toBe(true);
  expect(isFilePathPending("alpha", "new")).toBe(true);
  expect(isFilePathPending("alpha", "unrelated")).toBe(false);
  expect(isFilePathPending("beta", "new/sub")).toBe(false);
  settleMove(fileMoveKey("alpha", "old/sub"));
  expect(isFilePathPending("alpha", "new/sub")).toBe(false);
});
