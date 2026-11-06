import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createMemo, createRoot } from "solid-js";
import { ApprovalTransferConfirmationRequiredError } from "../src/api";
import { LOCAL_PLACEMENT_CLIENT_ID, commitAuthoritativePlacements, resetMissionHierarchy, stickHierarchy, withHierarchy } from "../src/missionHierarchy";
import { applyServerPlacementEvent } from "../src/missionMove";
import { MOVE_CONFIRM_MS, deleteFileOptimistically, fileMoveKey, filesMovedAway, filesMovedInto, isFilePathPending, mergeArrivingMissions, missionMoveKey, missionsMovedInto, moveOptimistically, movedMission, movingOutOf, previewMove, resetMoves, settleMove, upsertMissionPreservingOrder, waitForFilePathSettled, withMovedMissions } from "../src/moves";

beforeEach(() => { resetMoves(); resetMissionHierarchy(); });
afterEach(() => { vi.useRealTimers(); resetMoves(); resetMissionHierarchy(); });
const deferred = () => { let resolve!: () => void, reject!: (e: unknown) => void; const promise = new Promise<void>((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const mission = { id: "m1", project: "alpha", folder: "old", placement_revision: 1, tags: ["keep"] };
const move = { kind: "mission" as const, fromProject: "alpha", toProject: "beta", path: "docs" };

it("shows a moved mission in its destination in every view before the server answers", () => {
  const request = deferred();
  createRoot(dispose => {
    const sidebar = createMemo(() => withMovedMissions([mission])[0]);
    void moveOptimistically(missionMoveKey("m1"), move, () => request.promise);
    expect(sidebar()).toEqual({ id: "m1", project: "beta", folder: "docs", placement_revision: 1, tags: ["keep"] });
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

it("rolls back silently without an error toast when approval confirmation is required", async () => {
  const done = moveOptimistically(missionMoveKey("m1"), move, async () => {
    throw new ApprovalTransferConfirmationRequiredError("Confirm secret transfer", "beta", [], []);
  });
  await expect(done).rejects.toBeInstanceOf(ApprovalTransferConfirmationRequiredError);
  expect(movedMission(mission)).toBe(mission);
  await Promise.resolve();
  expect(document.body.textContent).not.toContain("Confirm secret transfer");
});

it("retains committed placement across stale pre-move list refreshes without needing a 30s timer", async () => {
  await moveOptimistically(missionMoveKey("m1"), move, async (opId) => {
    commitAuthoritativePlacements(
      [{ mission_id: "m1", project: "beta", folder: "docs", placement_revision: 2 }],
      opId,
    );
  });
  // Pending overlay is cleared immediately on commit, while `withHierarchy` enforces revision 2.
  expect(movedMission(mission)).toBe(mission);
  expect(withHierarchy(mission)).toEqual({
    id: "m1",
    project: "beta",
    folder: "docs",
    placement_revision: 2,
    tags: ["keep"],
  });
});

it("clears file overlays after the confirmation timeout", async () => {
  vi.useFakeTimers();
  await moveOptimistically(fileMoveKey("alpha", "notes/plan.md"), {
    kind: "file",
    fromProject: "alpha",
    toProject: "beta",
    path: "inbox/plan.md",
    fromPath: "notes/plan.md",
  }, async () => {});
  expect([...filesMovedAway("alpha", "notes")]).toEqual(["plan.md"]);
  vi.advanceTimersByTime(MOVE_CONFIRM_MS);
  expect([...filesMovedAway("alpha", "notes")]).toEqual([]);
  settleMove(fileMoveKey("alpha", "notes/plan.md"));
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

it("resolves waitForFilePathSettled when an optimistic file rename settles", async () => {
  const request = deferred();
  const rename = moveOptimistically(
    fileMoveKey("alpha", "context.md"),
    { kind: "file", fromProject: "alpha", toProject: "alpha", path: "renamed.md", fromPath: "context.md" },
    () => request.promise,
  );
  let settled = false;
  const waiter = waitForFilePathSettled("alpha", "renamed.md").then(() => { settled = true; });
  await Promise.resolve();
  expect(settled).toBe(false);
  request.resolve();
  await rename;
  expect(settled).toBe(false);
  settleMove(fileMoveKey("alpha", "context.md"));
  await waiter;
  expect(settled).toBe(true);
});

it("patches intra-project placement updates in place and inserts cross-project arrivals in recency order", () => {
  const newer = { id: "m-new", project: "beta", folder: "", updated_at: "2026-11-06T01:30:00Z" };
  const middle = { id: "m-mid", project: "beta", folder: "old", updated_at: "2026-11-06T01:20:00Z" };
  const older = { id: "m-old", project: "beta", folder: "", updated_at: "2026-11-06T01:10:00Z" };
  const patchedInPlace = upsertMissionPreservingOrder(
    [newer, middle, older],
    { ...middle, folder: "renamed", placement_revision: 3 },
  );
  expect(patchedInPlace.map(m => m.id)).toEqual(["m-new", "m-mid", "m-old"]);
  expect(patchedInPlace[1]?.folder).toBe("renamed");

  const arrivingBetween = { id: "m-arrive", project: "beta", folder: "docs", updated_at: "2026-11-06T01:15:00Z" };
  const arrivedOldest = { id: "m-oldest", project: "beta", folder: "docs", updated_at: "2026-11-06T01:00:00Z" };
  const merged = mergeArrivingMissions([newer, middle, older], [arrivedOldest, arrivingBetween]);
  expect(merged.map(m => m.id)).toEqual(["m-new", "m-mid", "m-arrive", "m-old", "m-oldest"]);
});

it("scopes placement acknowledgements to LOCAL_PLACEMENT_CLIENT_ID across colliding client_op_id SSE events", async () => {
  // Seed authoritative revision 2 (`alpha/old`) in `missionHierarchy`.
  const seeded = { ...mission, placement_revision: 2 };
  stickHierarchy(seeded);
  const request = deferred();
  let capturedOpId = 0;
  const inFlight = moveOptimistically(missionMoveKey("m1"), move, async (opId) => {
    capturedOpId = opId;
    await request.promise;
  });
  expect(capturedOpId).toBe(1);
  expect(withHierarchy(seeded)).toMatchObject({ project: "beta", folder: "docs" });

  // Another client broadcasts `client_op_id: 1` at `placement_revision <= curRev` (`2`)
  // with a foreign `client_id` (e.g. a no-op/same-revision or slightly older ack on
  // another mission/session): WITHOUT `client_id` scoping (`ackOpId === pendingOpId`),
  // `orb_placement_merge_step` would treat it as our own ack (`incRev >= curRev`) and
  // prematurely clear `pendingOpId = 1` + overwrite `beta/docs` with `gamma/foreign`!
  // WITH `client_id` scoping (`ackOpId = 0`), it is fenced (`status = fenced_by_pending_op`)
  // and `pendingOpId = 1` stays intact so subsequent rollback works!
  expect(applyServerPlacementEvent(
    [{ mission_id: "m1", project: "gamma", folder: "foreign", placement_revision: 2 }],
    capturedOpId,
    "foreign-client-id",
  )).toEqual([]);
  expect(withHierarchy(seeded)).toMatchObject({ project: "beta", folder: "docs" });

  // When this client's in-flight move fails, rollback still works cleanly back to `alpha/old`!
  request.reject(new ApprovalTransferConfirmationRequiredError("Confirm secret transfer", "beta", [], []));
  await expect(inFlight).rejects.toBeInstanceOf(ApprovalTransferConfirmationRequiredError);
  expect(withHierarchy(seeded)).toMatchObject({
    id: "m1",
    project: "alpha",
    folder: "old",
    placement_revision: 2,
  });

  // Conversely, an event carrying `LOCAL_PLACEMENT_CLIENT_ID` at the same revision (`incRev == curRev`)
  // acknowledges and clears `pendingOpId`!
  await moveOptimistically(missionMoveKey("m1"), move, async (opId) => {
    applyServerPlacementEvent(
      [{ mission_id: "m1", project: "beta", folder: "docs", placement_revision: 2 }],
      opId,
      LOCAL_PLACEMENT_CLIENT_ID,
    );
  });
  expect(withHierarchy(seeded)).toMatchObject({
    id: "m1",
    project: "beta",
    folder: "docs",
    placement_revision: 2,
  });
});
