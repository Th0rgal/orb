import { expect, test } from "vitest";
import { countNested, holds, nestMissions } from "../src/missionTree";

const m = (id: string, parent?: string, status = "completed") => ({ id, parent_mission_id: parent, status });

test("missions are placed inside the mission that launched them", () => {
  const roots = nestMissions([m("boss"), m("w1", "boss", "active"), m("other"), m("w2", "boss"), m("w1a", "w1", "active")]);
  expect(roots.map(r => r.mission.id)).toEqual(["boss", "other"]);
  expect(roots[0].children.map(c => c.mission.id)).toEqual(["w1", "w2"]);
  expect(roots[0].children[0].children.map(c => c.mission.id)).toEqual(["w1a"]);
  expect(countNested(roots[0])).toBe(3);
  expect(countNested(roots[0], mission => mission.status === "active")).toBe(2);
  expect(holds(roots[0], "w1a")).toBe(true);
  expect(holds(roots[1], "w1a")).toBe(false);
});

test("a mission whose parent is absent, or that would close a loop, stays at the top", () => {
  expect(nestMissions([m("orphan", "archived-boss")]).map(r => r.mission.id)).toEqual(["orphan"]);
  const loop = nestMissions([m("a", "b"), m("b", "a"), m("self", "self")]);
  const all = (nodes: typeof loop): string[] => nodes.flatMap(n => [n.mission.id, ...all(n.children)]);
  expect(all(loop).sort()).toEqual(["a", "b", "self"]);
  expect(loop.map(r => r.mission.id)).toContain("self");
});
