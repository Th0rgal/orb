import { describe, expect, it, vi } from "vitest";

const moveMissions = vi.fn(async () => [] as { id: string; error: unknown }[]);
vi.mock("../src/missionMove", () => ({
  makeCutMission: (id: string) => `cut:${id}`,
  readCutMission: () => null,
  planMissionMoves: (ids: string[], _slug: string, folder: string) => ids.map(id => ({ id, from: "eth", folder })),
  moveMissions: (...args: unknown[]) => moveMissions(...(args as [])),
}));

import { createMissionMoves } from "../src/tree/moves";

const flush = () => new Promise(r => setTimeout(r, 0));

describe("sidebar move lock", () => {
  it("accepts the next move while the post-move list refresh is still loading", async () => {
    // Reproduces "moved into Audits once, then could not move it back": the
    // refresh of a large project list never settled, so `moving` stayed set
    // and every later drop was silently ignored.
    const leaveProjects = vi.fn();
    const moves = createMissionMoves({
      allKnownMissions: () => [],
      leaveProjects,
      revealDestination: () => {},
      loadMissions: () => new Promise<void>(() => {}),
      setActionError: () => {},
    });
    moves.moveDirect(["eth-lib"], "eth", "Audits");
    await flush();
    expect(moves.isMoving()).toBe(false);
    moves.moveDirect(["eth-lib"], "eth", "");
    await flush();
    expect(moveMissions).toHaveBeenCalledTimes(2);
    expect(moveMissions.mock.calls[1]![0]).toEqual([{ id: "eth-lib", from: "eth", folder: "" }]);
    // The source is only left once the destination listing has loaded.
    expect(leaveProjects).not.toHaveBeenCalled();
  });
});
