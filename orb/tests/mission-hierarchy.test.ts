import { beforeEach, expect, test } from "vitest";
import { configureParentResolver, mergeMission, observeMission, partialList, reconcileMissionList, reparentMission, resetMissionHierarchy, resolveParent, stickHierarchy, withHierarchy, type HierarchyFields, type Misses } from "../src/missionHierarchy";
import { nestMissions, type NestedMission } from "../src/missionTree";

type Row = HierarchyFields & { status: string; updated_at?: string; status_message?: string | null; [k: string]: unknown };
const row = (id: string, extra: Partial<Row> = {}): Row => ({ id, status: "active", title: id, tags: [], updated_at: "2026-10-20T00:00:00Z", ...extra });

beforeEach(() => resetMissionHierarchy());

test("a full row replaces the old one but never drops its parent links", () => {
  const child = row("c", { parent_mission_id: "p", callback_parent_mission_id: null, tags: ["worker-dispatch:x"], status_message: "busy" });
  const fresh = mergeMission(undefined, child);
  // A settings PATCH answer: no derived callback link, no tags, status_message cleared.
  const patched = mergeMission(fresh, { id: "c", status: "active", title: "c", parent_mission_id: null });
  expect(patched.parent_mission_id).toBe("p");
  expect(patched.tags).toContain("worker-dispatch:x");
  expect(patched.status_message).toBeUndefined();
});

test("a partial patch changes only the fields it names", () => {
  const prev = mergeMission(undefined, row("c", { callback_parent_mission_id: "p", status_message: "x" }));
  const next = mergeMission(prev, { id: "c", status: "running" }, "partial");
  expect(next).toMatchObject({ status: "running", status_message: "x", callback_parent_mission_id: "p" });
});

test("the derived callback link Core puts only on list/read answers sticks to later answers", () => {
  stickHierarchy(row("c", { callback_parent_mission_id: "p" }));
  const resumed = stickHierarchy(row("c", { status: "pending" }));
  expect(resumed.callback_parent_mission_id).toBe("p");
});

test("withHierarchy returns the same object when nothing is missing", () => {
  const r = row("c", { parent_mission_id: "p" });
  observeMission(r);
  expect(withHierarchy(r)).toBe(r);
});

test("only an explicit re-parent changes or clears a remembered parent", () => {
  observeMission(row("c", { parent_mission_id: "p" }));
  expect(withHierarchy(row("c")).parent_mission_id).toBe("p");
  reparentMission("c", { parent_mission_id: "q" });
  expect(withHierarchy(row("c")).parent_mission_id).toBe("q");
  reparentMission("c", { parent_mission_id: null });
  expect(withHierarchy(row("c")).parent_mission_id).toBeUndefined();
});

test("an orphan child is held under a placeholder, a confirmed-gone parent lets it go to the root", () => {
  const rows = [row("a"), row("c1", { parent_mission_id: "p" }), row("c2", { parent_mission_id: "p" })];
  const stand = (id: string) => ({ ...row(id), orb_placeholder: true });
  const held = nestMissions(rows, { placeholder: stand });
  expect(held.map(n => n.mission.id)).toEqual(["a", "p"]);
  expect(held[1].children.map(n => n.mission.id)).toEqual(["c1", "c2"]);
  const gone = nestMissions(rows, { placeholder: () => undefined });
  expect(gone.map(n => n.mission.id)).toEqual(["a", "c1", "c2"]);
});

test("the resolver fetches a missing parent, retries transient failures and accepts a 404 as gone", async () => {
  const calls: string[] = [];
  const timers: (() => void)[] = [];
  let fail = true;
  configureParentResolver(async id => {
    calls.push(id);
    if (id === "gone") return null;
    if (fail) { fail = false; throw new Error("offline"); }
    return row(id, { title: "Parent" });
  }, fn => { timers.push(fn); });
  expect(resolveParent("p")).toBe("loading");
  expect(resolveParent("gone")).toBe("loading");
  await new Promise(r => setTimeout(r, 0));
  expect(resolveParent("p")).toBe("loading");
  expect(resolveParent("gone")).toBe("gone");
  timers.shift()!();
  await new Promise(r => setTimeout(r, 0));
  expect(resolveParent("p")).toBe("found");
  expect(calls).toEqual(["p", "gone", "p"]);
});

// ---------------------------------------------------------------------------
// Property test: every ordering of the same events gives the same tree, and no
// frame ever shows a known child at the root.

const truth: Row[] = [
  row("P", { tags: ["orb-folder:"] }),
  row("C1", { parent_mission_id: "P", tags: ["worker-dispatch:a"] }),
  row("C2", { callback_parent_mission_id: "P" }),
  row("G", { parent_mission_id: "C1" }),
  row("Q"),
  row("X", { parent_mission_id: "OTHER" }), // parent filed in another project, never listed here
];
const truthById = new Map(truth.map(r => [r.id, r]));
const parentOf = (r: Row) => r.parent_mission_id || r.callback_parent_mission_id || undefined;

type Event = { kind: "full" | "stripped" | "status" | "page"; ids: string[] };
function events(): Event[] {
  const out: Event[] = [];
  for (const r of truth) {
    out.push({ kind: "full", ids: [r.id] });          // GET /missions/:id
    out.push({ kind: "stripped", ids: [r.id] });      // PATCH/resume answer without derived links or tags
    out.push({ kind: "status", ids: [r.id] });        // stream status stub
  }
  out.push({ kind: "page", ids: ["C1", "C2", "G", "X"] }); // a page whose parent fell off
  out.push({ kind: "page", ids: truth.map(r => r.id) });
  return out;
}
function rng(seed: number) { return () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }; }
function shuffle<T>(xs: T[], r: () => number): T[] { const a = [...xs]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; }

function apply(store: Map<string, Row>, e: Event, statusCounter: number) {
  for (const id of e.ids) {
    const t = truthById.get(id)!;
    if (e.kind === "full" || e.kind === "page") store.set(id, mergeMission(store.get(id), stickHierarchy({ ...t })));
    // A mutation answer: no tags; Core now attaches the callback link, but an
    // older Core did not, which the sticky store must cover once it saw the link.
    else if (e.kind === "stripped") store.set(id, mergeMission(store.get(id), stickHierarchy({ id, status: "pending", title: t.title, parent_mission_id: t.parent_mission_id ?? null, tags: [],
      ...(store.has(id) ? {} : { callback_parent_mission_id: t.callback_parent_mission_id ?? null }) })));
    // A stream status only updates a row the sidebar already lists.
    else if (store.has(id)) store.set(id, mergeMission(store.get(id), { id, status: statusCounter % 2 ? "running" : "active" }, "partial"));
  }
}
function parentMap(roots: NestedMission<Row>[], parent: string | undefined, out = new Map<string, string | undefined>()) {
  for (const n of roots) { out.set(n.mission.id, parent); parentMap(n.children, n.mission.id, out); }
  return out;
}

test("event order never changes the final tree, and no frame shows a known child at the root", () => {
  let reference: string | undefined;
  for (let seed = 1; seed <= 300; seed++) {
    resetMissionHierarchy();
    const store = new Map<string, Row>();
    const order = shuffle(events(), rng(seed));
    order.forEach((e, i) => {
      apply(store, e, i);
      const roots = nestMissions([...store.values()], { placeholder: id => ({ ...row(id), orb_placeholder: true }) });
      for (const root of roots) {
        // A row reaches the root only if Core says it has no parent.
        const real = truthById.get(root.mission.id);
        if (real && !root.mission.orb_placeholder) expect(parentOf(real), `seed ${seed} step ${i}: ${root.mission.id} at root`).toBeUndefined();
      }
    });
    // Converge on the full list (what the next poll delivers) and compare.
    apply(store, { kind: "page", ids: truth.map(r => r.id) }, 0);
    const map = parentMap(nestMissions([...store.values()], { placeholder: id => ({ ...row(id), orb_placeholder: true }) }), undefined);
    const canonical = JSON.stringify([...map].sort());
    reference ??= canonical;
    expect(canonical, `seed ${seed}`).toBe(reference);
  }
  expect(reference).toBe(JSON.stringify([["C1", "P"], ["C2", "P"], ["G", "C1"], ["OTHER", undefined], ["P", undefined], ["Q", undefined], ["X", "OTHER"]]));
});

test("a failed, empty or partial list never removes rows; two full misses over time do", () => {
  const misses: Misses = new Map();
  const h = [row("h1", { backend: "cloud_hermes" }), row("h2")];
  let shown = reconcileMissionList([], h, misses, false, 0);
  // Desktop journal only (Core unreachable): partial, never a miss.
  shown = reconcileMissionList(shown, partialList([row("local")]), misses, undefined, 1000);
  expect(shown.map(m => m.id).sort()).toEqual(["h1", "h2", "local"]);
  // A restart serves an empty list, twice within one poll: still kept.
  shown = reconcileMissionList(shown, [], misses, false, 2000);
  shown = reconcileMissionList(shown, [], misses, false, 2100);
  expect(shown.map(m => m.id).sort()).toEqual(["h1", "h2", "local"]);
  // A full answer that lists them resets the count.
  shown = reconcileMissionList(shown, h, misses, false, 3000);
  shown = reconcileMissionList(shown, [h[0]], misses, false, 4000);
  expect(shown.map(m => m.id)).toContain("h2");
  // Omitted by full answers over the window: gone.
  shown = reconcileMissionList(shown, [h[0]], misses, false, 9500);
  expect(shown.map(m => m.id)).toEqual(["h1"]);
});

test("reconciling keeps object identity for unchanged rows", () => {
  const misses: Misses = new Map();
  const a = row("a");
  const [kept] = reconcileMissionList([a], [{ ...a }], misses, false);
  expect(kept).toBe(a);
});
