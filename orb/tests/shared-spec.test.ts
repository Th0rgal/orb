/**
 * The desktop vocabulary must agree with the state table and fixtures the
 * iOS and Android apps load from shared/orb-spec. Labels are not compared:
 * the desktop keeps its own wording ("Running", "Ready for a follow-up").
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { STATUS_CATEGORIES, isFailedStatus, isTerminalStatus, isWorking, statusCategory, statusPresentation, statusSortRank } from "../src/missionStatus";
import { archiveOnlyRows, isSupersededInTree, missionTreeRows } from "../src/missionTree";
import { taskCardView } from "../src/taskList";
import { compactAgo } from "../src/time";
import { narrationKeys } from "../src/workModel";

const SPEC_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec");
const spec = <T>(path: string): T => JSON.parse(readFileSync(join(SPEC_DIR, path), "utf8")) as T;

type Flags = { live: boolean; terminal: boolean; needsAttention: boolean; unreadResponse: boolean; canRetry: boolean };
type StateSpec = { label: string; category: string; sortRank: number; flags: Flags };
const states = spec<{ categories: string[]; unknown: { category: string; sortRank: number }; states: Record<string, StateSpec> }>("mission-states.json");
const relative = spec<{ cases: Array<{ secondsAgo: number; expected: string }> }>("fixtures/relative-time.json");
const projection = spec<{
  workfold_cases: Array<{
    name: string;
    input: { is_text: boolean; cumulative: boolean; non_empty: boolean; tool_ahead: boolean; fold_has_tool: boolean; next_is_tool: boolean };
    expected: { fold: boolean; next_fold_has_tool: boolean };
  }>;
  taskcard_cases: Array<{
    name: string;
    input: { ended: boolean; all_done_or_cancelled: boolean; outcome_finished: boolean; has_open_tasks: boolean };
    expected: { state: "live" | "done" | "stale" | "stopped"; mark_open_stale: boolean; clear_in_progress: boolean };
  }>;
  sidebar_visibility_cases: Array<{
    name: string;
    input: { is_archived: boolean; has_visible_descendant: boolean; is_working: boolean; is_selected: boolean; is_superseded: boolean; ancestor_superseded: boolean };
    expected: { show_in_main_tree: boolean; show_in_archive_only: boolean };
  }>;
}>("fixtures/projection-invariants.json");

describe("shared/orb-spec/mission-states.json", () => {
  it("has the same categories in the same order", () => {
    expect([...STATUS_CATEGORIES]).toEqual(states.categories);
  });

  for (const [status, s] of Object.entries(states.states)) {
    it(`${status}: category ${s.category}, rank ${s.sortRank}`, () => {
      expect(statusCategory(status)).toBe(s.category);
      expect(statusCategory(status.toUpperCase())).toBe(s.category);
      expect(statusSortRank(status)).toBe(s.sortRank);
      // The shared `live` flag covers queued and running: desktop's isWorking.
      expect(isWorking(status)).toBe(s.flags.live);
      expect(isFailedStatus(status)).toBe(s.category === "failed");
      expect(isTerminalStatus(status)).toBe(s.flags.terminal);
      const tone = statusPresentation(status).tone;
      if (s.category === "blocked" || s.category === "failed") expect(tone).toBe("attention");
      if (s.category === "done") expect(tone).toBe("success");
      if (s.category === "live") expect(tone).toBe("running");
    });
  }

  it("classifies unknown statuses like the mobile apps", () => {
    expect(statusCategory("something_new")).toBe(states.unknown.category);
    expect(statusSortRank("something_new")).toBe(states.unknown.sortRank);
    expect(statusSortRank(undefined)).toBe(states.unknown.sortRank);
    expect(isWorking("something_new")).toBe(false);
  });
});

describe("shared/orb-spec/fixtures/relative-time.json", () => {
  const now = Date.UTC(2026, 9, 18, 12);
  for (const c of relative.cases) {
    it(`${c.secondsAgo} s ago → ${c.expected}`, () => {
      expect(compactAgo(now - c.secondsAgo * 1000, now)).toBe(c.expected);
    });
  }
});

describe("shared/orb-spec/fixtures/projection-invariants.json", () => {
  for (const c of projection.workfold_cases) {
    it(`workfold: ${c.name}`, () => {
      const items = [
        ...(c.input.fold_has_tool ? [{ kind: "tool" as const, key: "prev-tool", callId: "p", name: "bash", args: {}, done: true }] : []),
        { kind: "text" as const, key: "target", text: c.input.non_empty ? "hello" : "  ", live: false, cumulative: c.input.cumulative },
        ...(!c.input.next_is_tool && c.input.tool_ahead ? [{ kind: "tool" as const, key: "orch", callId: "o", name: "start_mission", args: {}, done: true }] : []),
        ...(c.input.tool_ahead ? [{ kind: "tool" as const, key: "next-tool", callId: "n", name: "bash", args: {}, done: true }] : []),
      ];
      const keys = narrationKeys(items, name => name === "start_mission");
      expect(keys.has("target")).toBe(c.expected.fold);
    });
  }

  for (const c of projection.taskcard_cases) {
    it(`taskcard: ${c.name}`, () => {
      const tasks = c.input.all_done_or_cancelled
        ? [{ text: "step 1", status: "completed" as const }, { text: "step 2", status: "cancelled" as const }]
        : [{ text: "step 1", status: "completed" as const }, { text: "step 2", status: "in_progress" as const }];
      const view = taskCardView(tasks, c.input.ended, c.input.outcome_finished ? "finished" : "stopped");
      expect(view.state).toBe(c.expected.state);
      expect(view.tasks.some(t => t.status === "stale")).toBe(c.expected.mark_open_stale);
      if (c.expected.clear_in_progress) {
        expect(view.tasks.some(t => t.status === "in_progress")).toBe(false);
      }
    });
  }

  for (const c of projection.sidebar_visibility_cases) {
    it(`sidebar_visibility: ${c.name}`, () => {
      const parent = {
        id: "parent",
        status: "completed",
        tags: c.input.ancestor_superseded ? ["superseded"] : [],
      };
      const target = {
        id: "target",
        parent_mission_id: c.input.ancestor_superseded ? "parent" : undefined,
        status: c.input.is_working ? "running" : c.input.is_archived ? "acknowledged" : "completed",
        tags: c.input.is_superseded ? ["superseded"] : [],
      };
      const child = {
        id: "child",
        parent_mission_id: "target",
        status: "completed",
        tags: [] as string[],
      };
      const rows = [
        ...(c.input.ancestor_superseded ? [parent] : []),
        target,
        ...(c.input.has_visible_descendant ? [child] : []),
      ];
      const byId = new Map(rows.map(r => [r.id, r]));
      const main = missionTreeRows(
        rows,
        r => r.status !== "acknowledged" && ((c.input.is_selected && r.id === "target") || !isSupersededInTree(r, byId)),
      );
      const archiveOnly = archiveOnlyRows(rows.filter(r => r.status === "acknowledged"), main);
      expect(main.some(r => r.id === "target")).toBe(c.expected.show_in_main_tree);
      expect(archiveOnly.some(r => r.id === "target")).toBe(c.expected.show_in_archive_only);
    });
  }
});
