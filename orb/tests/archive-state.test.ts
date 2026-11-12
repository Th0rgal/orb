import { describe, expect, it } from "vitest";
import { archiveStateTargets } from "../src/archiveState";
import type { Mission } from "../src/api";

const m = (id: string, status: string, parent?: string): Mission =>
  ({ id, status, title: id, history: [], created_at: "", updated_at: "", ...(parent ? { parent_mission_id: parent } : {}) }) as Mission;

describe("archiveStateTargets", () => {
  it("restores every archived member of the subtree, not only the root", () => {
    const known = [m("root", "acknowledged"), m("child", "acknowledged", "root"), m("live", "completed", "root"), m("other", "acknowledged")];
    expect(archiveStateTargets(known[0], known, true).map(x => x.id)).toEqual(["root", "child"]);
  });

  it("archives the non-archived subtree and refuses running work", () => {
    const known = [m("root", "completed"), m("child", "completed", "root"), m("old", "acknowledged", "root")];
    expect(archiveStateTargets(known[0], known, false).map(x => x.id).sort()).toEqual(["child", "root"]);
    expect(() => archiveStateTargets(known[0], [...known, m("busy", "running", "root")], false)).toThrow(/Stop or finish/);
  });
});
