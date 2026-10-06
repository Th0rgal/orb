import { expect, test } from "vitest";
import { countNested, holds, nestMissions, missionTreeRows, archiveOnlyRows, ARCHIVE_DAY_MS, ARCHIVE_WEEK_MS, filterArchivedMissionsByAge } from "../src/missionTree";

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

test("callback-created reviews nest under their verified source, with explicit ownership taking priority", () => {
 const roots=nestMissions([m("source"),m("owner"),{...m("review"),callback_parent_mission_id:"source"},{...m("explicit","owner"),callback_parent_mission_id:"source"}]);
 expect(roots.map(r=>r.mission.id)).toEqual(["source","owner"]);
 expect(roots[0].children.map(r=>r.mission.id)).toEqual(["review"]);
 expect(roots[1].children.map(r=>r.mission.id)).toEqual(["explicit"]);
});

test("archiving a parent does not turn its visible worker into a root conversation",()=>{
 const rows=[m('parent',undefined,'acknowledged'),m('child','parent'),m('archived',undefined,'acknowledged')];
 const roots=nestMissions(missionTreeRows(rows,m=>m.status!=='acknowledged'));
 expect(roots.map(r=>r.mission.id)).toEqual(['parent']);
 expect(roots[0].children.map(r=>r.mission.id)).toEqual(['child']);
 expect(roots[0].mission.status).toBe('acknowledged');
});

test("an archived ancestor is shown once and returns to archives when its last child is archived",()=>{
 const parent=m("parent",undefined,"acknowledged"), child=m("child","parent");
 const rows=[parent,child,m("other",undefined,"acknowledged")];
 expect(archiveOnlyRows(rows,missionTreeRows(rows,m=>m.status!=="acknowledged")).map(m=>m.id)).toEqual(["other"]);
 child.status="acknowledged";
 expect(archiveOnlyRows(rows,missionTreeRows(rows,m=>m.status!=="acknowledged")).map(m=>m.id)).toEqual(["parent","child","other"]);
});

test("filterArchivedMissionsByAge filters all, older than 1 day, and older than 1 week", () => {
  const now = Date.UTC(2026, 9, 6, 12, 0, 0);
  const rows = [
    { id: "fresh", updated_at: new Date(now - 2 * 60 * 60 * 1000).toISOString() },
    { id: "two-days", updated_at: new Date(now - 2 * ARCHIVE_DAY_MS).toISOString() },
    { id: "eight-days", updated_at: new Date(now - 8 * ARCHIVE_DAY_MS).toISOString() },
    { id: "created-fallback", updated_at: "", created_at: new Date(now - 10 * ARCHIVE_DAY_MS).toISOString() },
  ];
  expect(filterArchivedMissionsByAge(rows, undefined, now).map(r => r.id)).toEqual(["fresh", "two-days", "eight-days", "created-fallback"]);
  expect(filterArchivedMissionsByAge(rows, ARCHIVE_DAY_MS, now).map(r => r.id)).toEqual(["two-days", "eight-days", "created-fallback"]);
  expect(filterArchivedMissionsByAge(rows, ARCHIVE_WEEK_MS, now).map(r => r.id)).toEqual(["eight-days", "created-fallback"]);
});

