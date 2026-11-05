import { beforeEach, expect, it, vi } from "vitest";
import {
  allocatePlacementOpId,
  authoritativePlacement,
  commitAuthoritativePlacements,
  mergeMission,
  normalizeMissionFolder,
  resetMissionHierarchy,
  rollbackOptimisticPlacement,
  stageOptimisticPlacement,
  stickHierarchy,
  withHierarchy,
} from "../src/missionHierarchy";

vi.mock("../src/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/api")>();
  return {
    ApprovalTransferConfirmationRequiredError: actual.ApprovalTransferConfirmationRequiredError,
    applyAncestorCachePlacements: vi.fn(),
    btwParentId: (m: { tags?: readonly string[] | null }) =>
      m.tags?.find(t => t.startsWith("btw-parent:"))?.slice("btw-parent:".length),
    commitAuthoritativePlacements,
    connectionVersion: () => 0,
    getApiUrl: () => "https://core",
    moveMissionsBatch: vi.fn(),
    normalizeMissionFolder,
    allocatePlacementOpId,
    stageOptimisticPlacement,
    rollbackOptimisticPlacement,
  };
});

import { moveMissionsBatch } from "../src/api";
import { deleteDescendants, descendantsSentence, pausedMissionIds, requiresDescendantOptIn, runningWorkerIds } from "../src/deleteRunning";
import { moveMission, moveMissions, planMissionMoves, readCutMission } from "../src/missionMove";
import { movedMission, pendingMoves, previewMove, resetMoves, missionMoveKey } from "../src/moves";
import { missionIdFromTreeId, missionTreeId } from "../src/tree/TreeView";

const id = "524754fe-3acc-42c1-ba7f-89ee2d296bcb";
beforeEach(() => {
  vi.clearAllMocks();
  resetMoves();
  resetMissionHierarchy();
});

it("accepts only a mission cut from the same backend", () => {
  expect(readCutMission("orb:cut-mission:" + JSON.stringify({ id, backend: "https://core" }), "https://core")).toBe(id);
  expect(readCutMission("orb:cut-mission:" + JSON.stringify({ id, backend: "https://other" }), "https://core")).toBeNull();
  expect(readCutMission("ordinary text", "https://core")).toBeNull();
  expect(readCutMission("orb:cut-mission:{", "https://core")).toBeNull();
});

it("sends first-class folder via POST /api/control/missions/move without pre-fetching GET /missions/:id", async () => {
  vi.mocked(moveMissionsBatch).mockResolvedValueOnce({
    moved: [{ mission_id: id, project: "other-project", folder: "notes/review", placement_revision: 2 }],
  });
  await moveMission(id, "other-project", "/notes/review/");
  expect(moveMissionsBatch).toHaveBeenCalledTimes(1);
  expect(vi.mocked(moveMissionsBatch).mock.calls[0][0]).toMatchObject({
    mission_ids: [id],
    project: "other-project",
    folder: "notes/review",
    approval_policy: "check",
  });
  expect(authoritativePlacement(id)).toMatchObject({
    project: "other-project",
    folder: "notes/review",
    rev: 2,
  });
});

it("clears folder when pasting at project root and rolls back cleanly on rejection", async () => {
  vi.mocked(moveMissionsBatch).mockRejectedValueOnce(new Error("busy"));
  await expect(moveMission(id, "project", "")).rejects.toThrow("busy");
  expect(vi.mocked(moveMissionsBatch).mock.calls[0][0]).toMatchObject({
    mission_ids: [id],
    project: "project",
    folder: "",
    approval_policy: "check",
  });
  expect(pendingMoves().size).toBe(0);
});

const P = "11111111-1111-1111-1111-111111111111";
const F = "22222222-2222-2222-2222-222222222222";
const C = "33333333-3333-3333-3333-333333333333";
const G = "44444444-4444-4444-4444-444444444444";
const known = [
  { id: P, project: "verity" },
  { id: F, project: "verity" },
  { id: C, project: "verity", parent_mission_id: P },
  { id: G, project: "verity", parent_mission_id: C },
];

it("plans selected roots into one batch; clean intra-project children stay nested without extra steps", () => {
  expect(planMissionMoves([P, F], "verity", "Audits", known)).toEqual([
    { id: P, from: "verity", folder: "Audits" },
    { id: F, from: "verity", folder: "Audits" },
  ]);
});

it("moves the whole subtree to another project and never re-roots a selected child", () => {
  const plan = planMissionMoves([P, C, F], "other", "Audits", known);
  expect(plan.map(s => s.id)).toEqual([P, F, C, G]);
  expect(plan.find(s => s.id === C)!.folder).toBe("");
});

it("batches multiple roots targeting the same folder into a single atomic moveMissionsBatch request", async () => {
  let release!: () => void;
  const gate = new Promise<void>(r => { release = r; });
  vi.mocked(moveMissionsBatch).mockImplementation(async (body) => {
    await gate;
    return {
      moved: body.mission_ids.map((mid, i) => ({
        mission_id: mid,
        project: body.project ?? "verity",
        folder: body.folder ?? "",
        placement_revision: i + 1,
      })),
      client_op_id: body.client_op_id,
    };
  });
  const done = moveMissions(planMissionMoves([P, F], "verity", "Audits", known), "verity");
  await vi.waitFor(() => expect(moveMissionsBatch).toHaveBeenCalledTimes(1));
  expect([...pendingMoves().keys()].sort()).toEqual([`mission:${P}`, `mission:${F}`].sort());
  release();
  expect(await done).toEqual([]);
  expect(pendingMoves().size).toBe(0);
  expect(vi.mocked(moveMissionsBatch).mock.calls[0][0]).toMatchObject({
    mission_ids: [P, F],
    project: "verity",
    folder: "Audits",
  });
});

it("reads the running worker, paused mission, and descendant opt-in hints from Core’s 409 delete refusals", () => {
  expect(runningWorkerIds(`Cannot delete a running mission or worker (${C}). Cancel it first.`)).toEqual([C]);
  expect(runningWorkerIds("Mission is locked")).toEqual([]);
  expect(pausedMissionIds(`Cannot delete a paused mission (${C}). Resume or cancel it first.`)).toEqual([C]);
  expect(pausedMissionIds(`Cannot delete a running mission or worker (${C}). Cancel it first.`)).toEqual([]);
  expect(requiresDescendantOptIn(`Mission ${P} has 2 descendant sessions: a (completed), b (completed). Pass ?include_descendants=true to delete them with it.`)).toBe(true);
  expect(requiresDescendantOptIn("Mission is locked")).toBe(false);
});

it("lists every session a delete takes with it, flagging running ones", () => {
  const rows = [
    { id: "ev", title: "EV Bench", status: "completed" },
    { id: "b", title: "Benchmarks", status: "active", parent_mission_id: "ev" },
    { id: "btw", title: "EV Bench · btw", status: "completed", callback_parent_mission_id: "ev" },
    { id: "x", title: "Other", status: "active" },
  ];
  const list = deleteDescendants(["ev"], rows);
  expect(list.map(d => d.id)).toEqual(["b", "btw"]);
  expect(descendantsSentence(list)).toBe("This also deletes 2 sessions: Benchmarks (running), EV Bench · btw.");
  expect(descendantsSentence([])).toBe("");
  expect(descendantsSentence(Array.from({ length: 8 }, (_, i) => ({ id: `${i}`, title: `S${i}`, running: false })), 3)).toBe("This also deletes 8 sessions: S0, S1, S2, and 5 more.");
});

it("forwards callback descendant_ids and emits orb:mission-placement-changed for the full family", async () => {
  const CB = "55555555-5555-5555-5555-555555555555";
  const crossKnown = [...known, { id: CB, project: "verity", callback_parent_mission_id: P }];
  const crossPlan = planMissionMoves([P], "other", "Audits", crossKnown);
  expect(crossPlan[0]).toEqual({ id: P, from: "verity", folder: "Audits", includeDescendants: true, descendantIds: [CB] });
  expect(crossPlan.slice(1).every(s => s.viaRootId === P)).toBe(true);

  const placementEvents: Array<{ moves: Array<{ mission_id: string }> }> = [];
  const onPlacement = (e: Event) => placementEvents.push((e as CustomEvent).detail);
  window.addEventListener("orb:mission-placement-changed", onPlacement);
  let release!: () => void;
  const gate = new Promise<void>(r => { release = r; });
  vi.mocked(moveMissionsBatch).mockImplementation(async (body) => {
    await gate;
    return {
      moved: [
        { mission_id: P, project: "other", folder: "Audits", placement_revision: 3 },
        { mission_id: C, project: "other", folder: "", placement_revision: 2 },
        { mission_id: G, project: "other", folder: "", placement_revision: 2 },
        { mission_id: CB, project: "other", folder: "", placement_revision: 2 },
      ],
      client_op_id: body.client_op_id,
    };
  });
  const done = moveMissions(crossPlan, "other");
  await vi.waitFor(() => expect(moveMissionsBatch).toHaveBeenCalledTimes(1));
  expect([...pendingMoves().keys()].sort()).toEqual([P, C, G, CB].map(m => `mission:${m}`).sort());
  release();
  expect(await done).toEqual([]);
  window.removeEventListener("orb:mission-placement-changed", onPlacement);
  expect(placementEvents[0]?.moves.map(m => m.mission_id)).toEqual([P, C, G, CB]);
  expect(vi.mocked(moveMissionsBatch).mock.calls[0][0]).toMatchObject({
    mission_ids: [P],
    project: "other",
    folder: "Audits",
    descendant_ids: [CB],
  });

  // On failure, root and all child projections roll back together.
  resetMoves();
  vi.clearAllMocks();
  vi.mocked(moveMissionsBatch).mockRejectedValueOnce(new Error("writer_conflict"));
  const failed = await moveMissions(crossPlan, "other");
  expect(moveMissionsBatch).toHaveBeenCalledTimes(1);
  expect(failed.map(f => f.id)).toEqual([P, C, G, CB]);
  expect(pendingMoves().size).toBe(0);
});

it("assigns distinct tree IDs to cross-project placeholder parents while resolving canonical mission IDs", () => {
  expect(missionTreeId(P)).toBe(`m:${P}`);
  expect(missionTreeId(P, "verity-core")).toBe(`mp:verity-core:${P}`);
  expect(missionTreeId(P, "archive:verity-core")).toBe(`mp:archive:verity-core:${P}`);
  expect(missionIdFromTreeId(`m:${P}`)).toBe(P);
  expect(missionIdFromTreeId(`mp:verity-core:${P}`)).toBe(P);
  expect(missionIdFromTreeId(`mp:archive:verity-core:${P}`)).toBe(P);
  expect(missionIdFromTreeId("pf:verity-core:Audits")).toBeNull();
});

it("replays incident 9f559751: co-located archived root + fork leader + /btw + children move together and stale pre-move poll cannot revert", () => {
  const ROOT_9F = "9f559751-f14e-4016-94d0-9caf1458778d";
  const FORK_06 = "06203bdc-1111-4111-8111-222222222222";
  const WORKER = "d450d33d-1111-4111-8111-111111111111";
  const BTW = "b7777777-1111-4111-8111-333333333333";
  const OTHER = "66666666-6666-4666-8666-666666666666";
  const forkKnown = [
    { id: ROOT_9F, project: "assistant", folder: "", placement_revision: 1, status: "acknowledged", updated_at: "2026-10-28T00:00:00Z" },
    { id: WORKER, project: "assistant", folder: "", placement_revision: 1, parent_mission_id: ROOT_9F, status: "completed" },
    { id: FORK_06, project: "assistant", folder: "", placement_revision: 1, tags: [`fork-of:${ROOT_9F}`], status: "paused", updated_at: "2026-10-30T01:00:00Z" },
    { id: BTW, project: "assistant", folder: "", placement_revision: 1, tags: [`btw-parent:${FORK_06}`], status: "completed" },
    { id: OTHER, project: "elsewhere", folder: "", placement_revision: 1, tags: [`fork-of:${ROOT_9F}`], status: "completed", updated_at: "2026-10-29T05:00:00Z" },
  ];
  for (const row of forkKnown) stickHierarchy(row);

  const leaderPlan = planMissionMoves([FORK_06], "default", "crons", forkKnown);
  const rootIds = leaderPlan.filter(s => !s.viaRootId).map(s => s.id);
  expect(rootIds).toEqual([FORK_06, ROOT_9F]);
  expect(rootIds).not.toContain(OTHER);
  expect(leaderPlan.find(s => s.id === WORKER)).toEqual({ id: WORKER, from: "assistant", folder: "", viaRootId: ROOT_9F });
  expect(leaderPlan.find(s => s.id === BTW)).toEqual({ id: BTW, from: "assistant", folder: "", viaRootId: FORK_06 });

  // Commit server placement_revision = 2 for the moved family:
  commitAuthoritativePlacements([
    { mission_id: FORK_06, project: "default", folder: "crons", placement_revision: 2 },
    { mission_id: ROOT_9F, project: "default", folder: "crons", placement_revision: 2 },
    { mission_id: WORKER, project: "default", folder: "", placement_revision: 2 },
    { mission_id: BTW, project: "default", folder: "", placement_revision: 2 },
  ]);

  // A delayed pre-move poll (`placement_revision: 1, project: "assistant"`) is rejected by `orb_placement_merge_step`:
  const stalePollRoot = stickHierarchy({ id: ROOT_9F, project: "assistant", folder: "", placement_revision: 1, status: "acknowledged" });
  const stalePollWorker = stickHierarchy({ id: WORKER, project: "assistant", folder: "old", placement_revision: 1, parent_mission_id: ROOT_9F, status: "completed" });
  expect(withHierarchy(stalePollRoot)).toMatchObject({ project: "default", folder: "crons", placement_revision: 2 });
  expect(withHierarchy(stalePollWorker)).toMatchObject({ project: "default", folder: "", placement_revision: 2 });
});

it("preserves folders on legacy title-based ` · fork` versions across stickHierarchy and payload-free placement events", () => {
  const LEGACY_FORK = "legacy-fork-7777";
  const observed = stickHierarchy({
    id: LEGACY_FORK,
    parent_mission_id: P,
    title: "Audit plan · fork",
    project: "verity",
    folder: "Specs/Formal",
    placement_revision: 1,
    status: "completed",
  });
  expect(observed.folder).toBe("Specs/Formal");

  commitAuthoritativePlacements([
    { mission_id: LEGACY_FORK, project: "verity", folder: "Specs/Verified", placement_revision: 2 },
  ]);
  expect(withHierarchy({ id: LEGACY_FORK })).toMatchObject({
    project: "verity",
    folder: "Specs/Verified",
    placement_revision: 2,
  });
});

it("keeps pendingOpId and rollback intact when merging projected rows for the currently open conversation", () => {
  const OPEN_ID = "open-mission-8888";
  const listed = stickHierarchy({
    id: OPEN_ID,
    project: "assistant",
    folder: "OldFolder",
    placement_revision: 3,
    status: "active",
  });
  const opId = allocatePlacementOpId();
  stageOptimisticPlacement(OPEN_ID, "assistant", "NewFolder", opId, {
    project: "assistant",
    folder: "OldFolder",
    placement_revision: 3,
  });
  previewMove(missionMoveKey(OPEN_ID), {
    kind: "mission",
    fromProject: "assistant",
    toProject: "assistant",
    path: "NewFolder",
    opId,
  });

  // Replay `ProjectFiles.tsx` `visibleMissions`: `withHierarchy(movedMission(listed))` merged with unchanged `currentMission`.
  const projectedListed = withHierarchy(movedMission(listed));
  const unchangedOpenDetail = {
    id: OPEN_ID,
    project: "assistant",
    folder: "OldFolder",
    placement_revision: 3,
    status: "running",
  };
  const merged = mergeMission(projectedListed, unchangedOpenDetail, "partial");

  expect(merged.folder).toBe("NewFolder");
  expect(merged.status).toBe("running");
  expect(authoritativePlacement(OPEN_ID)?.pendingOpId).toBe(opId);

  // Subsequent rollback on HTTP failure MUST succeed and restore `OldFolder`:
  expect(rollbackOptimisticPlacement(OPEN_ID, opId)).toBe(true);
  expect(authoritativePlacement(OPEN_ID)).toMatchObject({
    project: "assistant",
    folder: "OldFolder",
    rev: 3,
    pendingOpId: 0,
  });
});

it("preserves newer optimistic move when an earlier overlapping move acknowledgement arrives", () => {
  const RAPID_ID = "rapid-move-9999";
  stickHierarchy({
    id: RAPID_ID,
    project: "assistant",
    folder: "",
    placement_revision: 0,
    status: "active",
  });
  const op1 = allocatePlacementOpId();
  stageOptimisticPlacement(RAPID_ID, "assistant", "FolderA", op1);
  const op2 = allocatePlacementOpId();
  stageOptimisticPlacement(RAPID_ID, "assistant", "FolderB", op2);
  expect(op2).toBeGreaterThan(op1);

  // Move 1 (`op1`) completes at `placement_revision: 1` while `op2` is still in flight:
  const accepted1 = commitAuthoritativePlacements(
    [{ mission_id: RAPID_ID, project: "assistant", folder: "FolderA", placement_revision: 1 }],
    op1,
  );
  expect(accepted1).toEqual([]);
  expect(authoritativePlacement(RAPID_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    rev: 1,
    pendingOpId: op2,
    rollback: { project: "assistant", folder: "FolderA", rev: 1 },
  });

  // Stale poll at `placement_revision: 1` (`FolderA`) stays fenced while `op2` is pending:
  const pollAt1 = stickHierarchy({
    id: RAPID_ID,
    project: "assistant",
    folder: "FolderA",
    placement_revision: 1,
    status: "active",
  });
  expect(withHierarchy(pollAt1)).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    placement_revision: 1,
  });

  // If `op2` later fails, rollback restores Move 1's committed `FolderA` at `rev: 1`:
  expect(rollbackOptimisticPlacement(RAPID_ID, op2)).toBe(true);
  expect(authoritativePlacement(RAPID_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderA",
    rev: 1,
    pendingOpId: 0,
  });
});

it("preserves newer optimistic move when an intermediate poll arrives before the first move's ack", () => {
  const POLL_FIRST_ID = "poll-before-ack-1000";
  stickHierarchy({
    id: POLL_FIRST_ID,
    project: "assistant",
    folder: "",
    placement_revision: 0,
    status: "active",
  });
  const op1 = allocatePlacementOpId();
  stageOptimisticPlacement(POLL_FIRST_ID, "assistant", "FolderA", op1);
  const op2 = allocatePlacementOpId();
  stageOptimisticPlacement(POLL_FIRST_ID, "assistant", "FolderB", op2);

  // Poll observes Move 1 (`FolderA`, `placement_revision: 1`) BEFORE Move 1's HTTP/SSE ack arrives:
  const pollBeforeAck = stickHierarchy({
    id: POLL_FIRST_ID,
    project: "assistant",
    folder: "FolderA",
    placement_revision: 1,
    status: "active",
  });
  expect(pollBeforeAck).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    placement_revision: 1,
  });
  expect(authoritativePlacement(POLL_FIRST_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    rev: 1,
    pendingOpId: op2,
    rollback: { project: "assistant", folder: "FolderA", rev: 1 },
  });

  // Move 1's HTTP ack arrives afterwards at `placement_revision: 1` and remains fenced:
  expect(
    commitAuthoritativePlacements(
      [{ mission_id: POLL_FIRST_ID, project: "assistant", folder: "FolderA", placement_revision: 1 }],
      op1,
    ),
  ).toEqual([]);
  expect(authoritativePlacement(POLL_FIRST_ID)?.pendingOpId).toBe(op2);

  // Rolling back `op2` restores the intermediate snapshot (`FolderA`, `rev: 1`):
  expect(rollbackOptimisticPlacement(POLL_FIRST_ID, op2)).toBe(true);
  expect(authoritativePlacement(POLL_FIRST_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderA",
    rev: 1,
    pendingOpId: 0,
  });

  // Also verify superseded local ack: if a poll observes a newer remote move (`FolderC`, `rev: 3`)
  // before `op3`'s `rev: 2` HTTP ack arrives, `op3`'s late ack settles cleanly onto `FolderC` (`rev: 3`).
  const op3 = allocatePlacementOpId();
  stageOptimisticPlacement(POLL_FIRST_ID, "assistant", "FolderB", op3);
  const remotePoll = stickHierarchy({
    id: POLL_FIRST_ID,
    project: "default",
    folder: "FolderC",
    placement_revision: 3,
    status: "active",
  });
  expect(remotePoll.folder).toBe("FolderB");
  const settledFromSupersededAck = commitAuthoritativePlacements(
    [{ mission_id: POLL_FIRST_ID, project: "assistant", folder: "FolderB", placement_revision: 2 }],
    op3,
  );
  expect(settledFromSupersededAck).toEqual([
    { mission_id: POLL_FIRST_ID, project: "default", folder: "FolderC", placement_revision: 3 },
  ]);
  expect(authoritativePlacement(POLL_FIRST_ID)).toMatchObject({
    project: "default",
    folder: "FolderC",
    rev: 3,
    pendingOpId: 0,
  });
});

it("keeps return-to-origin (A -> B -> A) moves pending across a pre-move poll at the origin", () => {
  const RETURN_ID = "return-origin-1001";
  stickHierarchy({
    id: RETURN_ID,
    project: "assistant",
    folder: "Origin",
    placement_revision: 0,
    status: "active",
  });
  const op1 = allocatePlacementOpId();
  stageOptimisticPlacement(RETURN_ID, "assistant", "FolderB", op1);
  const op2 = allocatePlacementOpId();
  stageOptimisticPlacement(RETURN_ID, "assistant", "Origin", op2);

  // Delayed pre-move poll still showing `Origin` at `placement_revision: 0` (`matchesOptimistic = true`)
  // MUST NOT clear `pendingOpId = op2`, otherwise Move 1's ack for `FolderB` would overwrite `Origin`!
  const delayedOriginPoll = stickHierarchy({
    id: RETURN_ID,
    project: "assistant",
    folder: "Origin",
    placement_revision: 0,
    status: "active",
  });
  expect(delayedOriginPoll.folder).toBe("Origin");
  expect(authoritativePlacement(RETURN_ID)?.pendingOpId).toBe(op2);

  // Move 1 (`op1 -> FolderB`) commits at `placement_revision: 1` while `op2` (`-> Origin`) is still running:
  expect(
    commitAuthoritativePlacements(
      [{ mission_id: RETURN_ID, project: "assistant", folder: "FolderB", placement_revision: 1 }],
      op1,
    ),
  ).toEqual([]);
  expect(authoritativePlacement(RETURN_ID)).toMatchObject({
    project: "assistant",
    folder: "Origin",
    rev: 1,
    pendingOpId: op2,
    rollback: { project: "assistant", folder: "FolderB", rev: 1 },
  });

  // Move 2 (`op2 -> Origin`) commits at `placement_revision: 2` and settles cleanly:
  expect(
    commitAuthoritativePlacements(
      [{ mission_id: RETURN_ID, project: "assistant", folder: "Origin", placement_revision: 2 }],
      op2,
    ),
  ).toEqual([{ mission_id: RETURN_ID, project: "assistant", folder: "Origin", placement_revision: 2 }]);
  expect(authoritativePlacement(RETURN_ID)).toMatchObject({
    project: "assistant",
    folder: "Origin",
    rev: 2,
    pendingOpId: 0,
  });
});

it("preserves newer pending move across repeated-destination (A -> B -> C -> B) older acks and intermediate polls", () => {
  // Case 1: Move 1's HTTP ack (`FolderB`, `rev: 1`) arrives while Move 2 (`-> FolderC`) and Move 3 (`-> FolderB`) are pending.
  const REPEAT_ACK_ID = "repeat-dest-ack-1002";
  stickHierarchy({
    id: REPEAT_ACK_ID,
    project: "assistant",
    folder: "FolderA",
    placement_revision: 0,
    status: "active",
  });
  const op1 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_ACK_ID, "assistant", "FolderB", op1);
  const op2 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_ACK_ID, "assistant", "FolderC", op2);
  const op3 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_ACK_ID, "assistant", "FolderB", op3);

  expect(
    commitAuthoritativePlacements(
      [{ mission_id: REPEAT_ACK_ID, project: "assistant", folder: "FolderB", placement_revision: 1 }],
      op1,
    ),
  ).toEqual([]);
  expect(authoritativePlacement(REPEAT_ACK_ID)?.pendingOpId).toBe(op3);

  // Move 2's ack (`FolderC`, `rev: 2`) MUST NOT overwrite `FolderB` while `op3` is still pending:
  expect(
    commitAuthoritativePlacements(
      [{ mission_id: REPEAT_ACK_ID, project: "assistant", folder: "FolderC", placement_revision: 2 }],
      op2,
    ),
  ).toEqual([]);
  expect(authoritativePlacement(REPEAT_ACK_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    rev: 2,
    pendingOpId: op3,
    rollback: { project: "assistant", folder: "FolderC", rev: 2 },
  });

  // Move 3's ack (`FolderB`, `rev: 3`) settles `pendingOpId` to `0`:
  expect(
    commitAuthoritativePlacements(
      [{ mission_id: REPEAT_ACK_ID, project: "assistant", folder: "FolderB", placement_revision: 3 }],
      op3,
    ),
  ).toEqual([{ mission_id: REPEAT_ACK_ID, project: "assistant", folder: "FolderB", placement_revision: 3 }]);
  expect(authoritativePlacement(REPEAT_ACK_ID)).toMatchObject({
    project: "assistant",
    folder: "FolderB",
    rev: 3,
    pendingOpId: 0,
  });

  // Case 2: Intermediate poll at `rev: 1` (`FolderB`) arrives before Move 1's ack during `A -> B -> C -> B`.
  const REPEAT_POLL_ID = "repeat-dest-poll-1003";
  stickHierarchy({
    id: REPEAT_POLL_ID,
    project: "assistant",
    folder: "FolderA",
    placement_revision: 0,
    status: "active",
  });
  const pOp1 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_POLL_ID, "assistant", "FolderB", pOp1);
  const pOp2 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_POLL_ID, "assistant", "FolderC", pOp2);
  const pOp3 = allocatePlacementOpId();
  stageOptimisticPlacement(REPEAT_POLL_ID, "assistant", "FolderB", pOp3);

  const pollAt1 = stickHierarchy({
    id: REPEAT_POLL_ID,
    project: "assistant",
    folder: "FolderB",
    placement_revision: 1,
    status: "active",
  });
  expect(pollAt1.folder).toBe("FolderB");
  expect(authoritativePlacement(REPEAT_POLL_ID)?.pendingOpId).toBe(pOp3);

  expect(
    commitAuthoritativePlacements(
      [{ mission_id: REPEAT_POLL_ID, project: "assistant", folder: "FolderC", placement_revision: 2 }],
      pOp2,
    ),
  ).toEqual([]);
  expect(authoritativePlacement(REPEAT_POLL_ID)?.folder).toBe("FolderB");
  expect(authoritativePlacement(REPEAT_POLL_ID)?.pendingOpId).toBe(pOp3);

  expect(
    commitAuthoritativePlacements(
      [{ mission_id: REPEAT_POLL_ID, project: "assistant", folder: "FolderB", placement_revision: 3 }],
      pOp3,
    ),
  ).toEqual([{ mission_id: REPEAT_POLL_ID, project: "assistant", folder: "FolderB", placement_revision: 3 }]);
  expect(authoritativePlacement(REPEAT_POLL_ID)?.pendingOpId).toBe(0);
});
