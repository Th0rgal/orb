import { expect, test } from "vitest";
import { nestMissions, withAncestors, missingParentIds } from "../src/missionTree";

const row = (id: string, updated: number, parent?: string) => ({ id, parent_mission_id: parent ?? null, status: "active", updated_at: new Date(Date.UTC(2026, 9, 20, 0, updated)).toISOString() });

test("a parent with 150 newer children that fell off the page is fetched and nests them", async () => {
  const parent = row("boss", 0);
  // Newest-first page of 100 rows: only children, the parent is older than all of them.
  const page = Array.from({ length: 100 }, (_, i) => row(`w${i}`, 200 - i, "boss"));
  expect(missingParentIds(page)).toEqual(["boss"]);
  const fetched: string[] = [];
  const rows = await withAncestors(page, async id => { fetched.push(id); return id === "boss" ? parent : null; });
  expect(fetched).toEqual(["boss"]);
  const roots = nestMissions(rows);
  expect(roots.map(r => r.mission.id)).toEqual(["boss"]);
  expect(roots[0].children).toHaveLength(100);
});

test("grandparents are fetched too, a deleted parent leaves workers at the top", async () => {
  const db: Record<string, ReturnType<typeof row>> = { mid: row("mid", 1, "top"), top: row("top", 0) };
  const rows = await withAncestors([row("other", 9), row("w", 5, "mid")], async id => db[id] ?? null);
  expect(rows.map(r => r.id)).toEqual(["other", "top", "mid", "w"]);
  expect(nestMissions(rows).map(r => r.mission.id)).toEqual(["other", "top"]);
  const gone = await withAncestors([row("w", 5, "deleted")], async () => null);
  expect(nestMissions(gone).map(r => r.mission.id)).toEqual(["w"]);
  const failing = await withAncestors([row("w", 5, "x")], async () => { throw new Error("offline"); });
  expect(failing.map(r => r.id)).toEqual(["w"]);
});
