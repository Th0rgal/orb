import { execFileSync } from "node:child_process";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Mission, ProjectSummary } from "../src/api";
import { clearConnection, setConnection, listProjects, listMissions, listCompletedMissions, listProjectMissions } from "../src/api";
import { inboxMissionUnion, listUnreadInboxCandidates } from "../src/inboxUnread";
import { applySharedInboxSeen } from "../src/missionUnread";

const session = vi.hoisted(() => ({ user: "" }));
vi.mock("../src/sideQuestionStorage", () => ({
  sideQuestionKey: (name: string) => session.user + "/" + name,
}));

const time = "2026-11-01T00:00:00Z";
const stamp = Date.parse(time);
const mission = (id: string, fields: Partial<Mission> = {}): Mission =>
  ({ id, title: id, status: "completed", project: "live", created_at: time, ...fields } as Mission);
const projects = [{ slug: "live" }, { slug: "retired-project", status: "archived" }] as ProjectSummary[];
const missions = [
  mission("early"),
  mission("tagged", { tags: ["archived"] }),
  mission("unknown", { project: "orphan" }),
  mission("unplaced", { project: null }),
  mission("typed-client", { project: null, placement_kind: "client:desktop" }),
  mission("typed-other", { project: null, origin: "orb-client", placement_kind: "managed" }),
  mission("legacy-client", { project: null, tags: ["placement:client"] }),
  mission("origin-client", { project: null, origin: "orb-client" }),
  mission("btw-grandchild", { parent_mission_id: "btw-child" }),
  mission("revived-parent"),
  mission("failed-child", { status: "failed", callback_parent_mission_id: "revived-parent" }),
  mission("scheduled", { status: "interrupted", terminal_reason: "usage_limit_wait", recovery: {} } as Partial<Mission>),
  mission("manual", { first_viewed_at: time }),
  mission("viewed", { first_viewed_at: time }),
  mission("bad-view", { first_viewed_at: "invalid" }),
  mission("new-output", { last_output_at: "2026-11-02T00:00:00Z" }),
  mission("selected"),
  ...Array.from({ length: 390 }, (_, i) => mission("working-" + i, { status: "active" })),
  mission("old-question", { status: "awaiting_user" }),
  mission("old-waiting", { status: "waiting_user" }),
  mission("btw-child", { callback_parent_mission_id: "btw-root" }),
  mission("btw-root", { status: "acknowledged", tags: ["btw-parent:main"] }),
  mission("fork", { parent_mission_id: "btw-root", tags: ["fork-of:btw-root"] }),
  mission("gone", { status: "acknowledged" }),
  mission("retired", { superseded_by_mission_id: "early" }),
];

// The native reader gets one summary collection over the same rows used by the GTK loaders.
const native = `
import json, sys
sys.path.insert(0, '../lean/OrbDesktop/OrbDesktop')
import live_transport as live
f = json.load(sys.stdin)
class Core:
    def get(self, path, cap, *, deadline):
        assert 0 < deadline <= 4
        if path == live.INBOX_PATH:
            return f['state']
        prefix = '/api/control/missions?all=true&limit=1000&offset='
        if path.startswith(prefix):
            start = int(path[len(prefix):])
            return f['missions'][start:start+1000]
        raise AssertionError(path)
rows = live.inbox_snapshot(Core(), f['projects'], f['selected'])
print(json.dumps([r[1] for r in rows if r[0] == 'U']))
`;

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); });

async function gtkSnapshot(user: string, input = missions) {
  setConnection("https://fixture.test", user);
  vi.stubGlobal("fetch", async (raw: string, init?: RequestInit) => {
    const url = new URL(raw);
    const q = url.searchParams;
    expect(init?.method ?? "GET").toBe("GET");
    let result: unknown;
    if (url.pathname === "/api/projects") result = { projects };
    else if (url.pathname === "/api/control/missions") {
      const offset = Number(q.get("offset"));
      const rows = input.filter(m =>
        (!q.has("project") || m.project === q.get("project")) &&
        (q.has("status") ? m.status === q.get("status") : q.has("all") || m.status !== "acknowledged"));
      result = rows.slice(offset, offset + Number(q.get("limit")));
    } else {
      expect(q.get("include_history")).toBe("false");
      result = input.find(m => url.pathname === "/api/control/missions/" + m.id);
      expect(result).toBeDefined();
    }
    return Response.json(result);
  });
  const live = await listProjects(true);
  const current = await listMissions(200);
  const completed = await listCompletedMissions(100);
  const byProject: Record<string, Mission[]> = {};
  for (const p of live) byProject[p.slug] = await listProjectMissions(p.slug);
  return { live, rows: inboxMissionUnion(byProject, completed!, current, () => false) };
}

describe("LeanUI and Solid Inbox candidate IDs", () => {
  for (const [user, includeAutonomous, expected] of [
    ["Thomas", true, ["failed-child", "old-question", "new-output", "tagged", "revived-parent",
      "manual", "typed-client", "legacy-client", "origin-client"]],
    ["Ben", false, ["new-output", "early", "tagged", "typed-client", "legacy-client", "origin-client"]],
  ] as const) {
    it(user + " sees the same ordered IDs on the GTK source projection", async () => {
      session.user = user;
      const state = {
        preferences: { includeAutonomous, aiSummary: false, model: "" },
        "seen:revived-parent": stamp,
        "seen:manual": user === "Thomas" ? -stamp : stamp,
        "seen:new-output": stamp,
        ["seen:" + (user === "Thomas" ? "early" : "old-question")]: stamp,
      };
      applySharedInboxSeen(state);
      const gtk = await gtkSnapshot(user);
      expect(gtk.rows.some(m => m.id === "old-waiting")).toBe(false);
      expect(gtk.rows.some(m => m.id === "old-question")).toBe(true);
      const solid = listUnreadInboxCandidates(gtk.rows, gtk.live, undefined, undefined, "selected", { includeAutonomous });
      const ids = solid.map(row => row.id);
      expect(ids).toEqual(expected);
      const output = execFileSync("python3", ["-I", "-c", native], {
        input: JSON.stringify({ missions, projects, state, selected: "selected" }), encoding: "utf8",
      });
      expect(JSON.parse(output)).toEqual(ids);
    });
  }
  it("excludes both unplaced candidates from a six-mission member account", async () => {
    session.user = "member-six";
    const input = [
      mission("belongs"), mission("unplaced-1", { project: null }), mission("unplaced-2", { project: null }),
      mission("running", { status: "active" }), mission("read"), mission("ack", { status: "acknowledged" }),
    ];
    const state = { "seen:read": stamp };
    applySharedInboxSeen(state);
    const gtk = await gtkSnapshot(session.user, input);
    const ids = listUnreadInboxCandidates(gtk.rows, gtk.live).map(row => row.id);
    expect(ids).toEqual(["belongs"]);
    const output = execFileSync("python3", ["-I", "-c", native], {
      input: JSON.stringify({ missions: input, projects, state, selected: "" }), encoding: "utf8",
    });
    expect(JSON.parse(output)).toEqual(ids);
  });
});
