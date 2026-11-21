import { execFileSync } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import type { Mission, ProjectSummary } from "../src/api";
import { listUnreadInboxCandidates } from "../src/inboxUnread";
import { applySharedInboxSeen } from "../src/missionUnread";

const session = vi.hoisted(() => ({ user: "" }));
vi.mock("../src/sideQuestionStorage", () => ({
  sideQuestionKey: (name: string) => session.user + "/" + name,
}));

const time = "2026-11-01T00:00:00Z";
const stamp = Date.parse(time);
const mission = (id: string, fields: Partial<Mission> = {}): Mission =>
  ({ id, title: id, status: "completed", project: "live", created_at: time, ...fields } as Mission);
const projects = [{ slug: "live" }] as ProjectSummary[];
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
  mission("old-question", { status: "waiting_user" }),
  mission("btw-child", { callback_parent_mission_id: "btw-root" }),
  mission("btw-root", { status: "acknowledged", tags: ["btw-parent:main"] }),
  mission("fork", { parent_mission_id: "btw-root", tags: ["fork-of:btw-root"] }),
  mission("gone", { status: "acknowledged" }),
  mission("retired", { superseded_by_mission_id: "early" }),
];

// Use the actual paged transport entry point and reject every unexpected path.
const native = `
import json, sys
sys.path.insert(0, '../lean/OrbDesktop/OrbDesktop')
import live_transport as live
f = json.load(sys.stdin)
class Core:
    def get(self, path):
        if path == live.INBOX_PATH:
            return f['state']
        prefix = '/api/control/missions?all=true&limit=200&offset='
        assert path.startswith(prefix), path
        start = int(path[len(prefix):])
        return f['missions'][start:start + 200]
rows = live.inbox_snapshot(Core(), f['projects'], f['selected'])
print(json.dumps([r[1] for r in rows if r[0] == 'U']))
`;

describe("LeanUI and Solid Inbox candidate IDs", () => {
  for (const [user, includeAutonomous, expected] of [
    ["Thomas", true, ["failed-child", "old-question", "new-output", "tagged", "typed-client",
      "legacy-client", "origin-client", "revived-parent", "manual", "fork"]],
    ["Ben", false, ["new-output", "early", "tagged", "typed-client", "legacy-client", "origin-client", "fork"]],
  ] as const) {
    it(user + " sees the same ordered IDs across all three summary pages", () => {
      session.user = user;
      const state = {
        preferences: { includeAutonomous, aiSummary: false, model: "" },
        "seen:revived-parent": stamp,
        "seen:manual": user === "Thomas" ? -stamp : stamp,
        "seen:new-output": stamp,
        ["seen:" + (user === "Thomas" ? "early" : "old-question")]: stamp,
      };
      applySharedInboxSeen(state);
      const solid = listUnreadInboxCandidates(missions, projects, undefined, undefined, "selected", { includeAutonomous });
      const ids = solid.map(row => row.id);
      expect(ids).toEqual(expected);
      const output = execFileSync("python3", ["-I", "-c", native], {
        input: JSON.stringify({ missions, projects, state, selected: "selected" }), encoding: "utf8",
      });
      expect(JSON.parse(output)).toEqual(ids);
    });
  }
});
