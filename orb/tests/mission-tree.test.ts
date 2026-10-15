import { expect, test } from "vitest";
import { countNested, countVersions, forkTitle, missionParent, versionLabel, holds, nestMissions, missionSubtree, missionTreeRows, archiveOnlyRows, isSupersededMission, isSupersededInTree, ARCHIVE_DAY_MS, ARCHIVE_WEEK_MS, filterArchivedMissionsByAge, expandMissionDescendants } from "../src/missionTree";

const m = (id: string, parent?: string, status = "completed", tags?: string[]) => ({ id, parent_mission_id: parent, status, tags });

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

test("missionSubtree collects spawned subagents at any depth, including callback children, without looping", () => {
  const rows = [
    m("grandchild", "child"),
    { ...m("callback-child"), callback_parent_mission_id: "parent" },
    m("child", "parent"),
    m("parent"),
    m("unrelated"),
    m("loop-a", "loop-b"),
    m("loop-b", "loop-a"),
  ];
  expect(missionSubtree(rows, ["parent"]).map(r => r.id)).toEqual([
    "grandchild",
    "callback-child",
    "child",
    "parent",
  ]);
  expect(missionSubtree(rows, ["loop-a"]).map(r => r.id)).toEqual(["loop-a", "loop-b"]);
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

test("expandMissionDescendants transitively includes known children and callback reviews", () => {
  const rows = [
    m("root"),
    m("child-1", "root"),
    m("grandchild", "child-1"),
    { ...m("callback-child"), callback_parent_mission_id: "root" },
    m("unrelated"),
  ];
  expect(expandMissionDescendants(["root"], rows)).toEqual([
    "root",
    "child-1",
    "grandchild",
    "callback-child",
  ]);
});

test("superseded child missions and their stopped descendants are excluded unless selected or still running", () => {
  const rows = [
    m("yukon-all", undefined, "active"),
    m("tier1-superseded", "yukon-all", "interrupted", ["superseded", "superseded_by:yukon-all"]),
    m("tier1-failed-grandchild", "tier1-superseded", "failed"),
    m("tier1-hyphen", "yukon-all", "paused", ["superseded-by:yukon-all"]),
    m("tier1-still-running", "yukon-all", "running", ["superseded"]),
    m("tier1-live-child", "yukon-all", "completed"),
  ];
  const byId = new Map(rows.map(r => [r.id, r]));
  expect(isSupersededMission(rows[1])).toBe(true);
  expect(isSupersededMission(rows[4])).toBe(false);
  expect(isSupersededInTree(rows[2], byId)).toBe(true);

  const visible = missionTreeRows(rows, r => r.status !== "acknowledged" && !isSupersededInTree(r, byId));
  expect(visible.map(r => r.id)).toEqual(["yukon-all", "tier1-still-running", "tier1-live-child"]);

  const withSelected = missionTreeRows(
    rows,
    r => r.status !== "acknowledged" && (r.id === "tier1-superseded" || !isSupersededInTree(r, byId)),
  );
  expect(withSelected.map(r => r.id)).toEqual([
    "yukon-all",
    "tier1-superseded",
    "tier1-still-running",
    "tier1-live-child",
  ]);
});

test("the most recently active fork leads and earlier versions fold inside it", () => {
  const original = { id: "ev", title: "EV Bench", backend: "claudecode", model_override: "claude-opus-5-5", updated_at: "2026-10-14T10:00:00Z" };
  const legacyFork = { id: "ev-fork", parent_mission_id: "ev", title: "EV Bench · fork", backend: "codex", model_override: "gpt-6.1-sol", updated_at: "2026-10-14T12:00:00Z" };
  const worker = { id: "w", parent_mission_id: "ev-fork", title: "worker", updated_at: "2026-10-14T12:30:00Z" };
  const roots = nestMissions([original, legacyFork, worker, { id: "other", updated_at: "2026-10-13T00:00:00Z" }]);
  expect(roots.map(r => r.mission.id)).toEqual(["ev-fork", "other"]);
  expect(roots[0].children.map(c => [c.mission.id, !!c.version])).toEqual([["w", false], ["ev", true]]);
  expect(countNested(roots[0])).toBe(1);
  expect(countVersions(roots[0])).toBe(1);
  expect(versionLabel(original)).toBe("Claude Code · claude-opus-5-5");
  expect(forkTitle(legacyFork.title)).toBe("EV Bench");
  // Returning to the original makes it lead again.
  const back = nestMissions([{ ...original, updated_at: "2026-10-15T09:00:00Z" }, legacyFork]);
  expect(back.map(r => r.mission.id)).toEqual(["ev"]);
  expect(back[0].children.map(c => c.mission.id)).toEqual(["ev-fork"]);
});

test("a tagged fork of a worker stays inside the worker's parent", () => {
  const roots = nestMissions([
    { id: "boss", updated_at: "2026-10-14T09:00:00Z" },
    { id: "w", parent_mission_id: "boss", updated_at: "2026-10-14T10:00:00Z" },
    { id: "w2", tags: ["fork-of:w"], updated_at: "2026-10-14T11:00:00Z" },
  ]);
  expect(roots.map(r => r.mission.id)).toEqual(["boss"]);
  expect(roots[0].children.map(c => c.mission.id)).toEqual(["w2"]);
  expect(roots[0].children[0].children.map(c => [c.mission.id, c.version])).toEqual([["w", true]]);
  expect(missionParent({ id: "w2", tags: ["fork-of:w"] })).toBeUndefined();
});
