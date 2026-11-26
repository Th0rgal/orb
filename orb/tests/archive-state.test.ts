import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ARCHIVE_CONFIRM_MS,
  archiveStateTargets,
  confirmPendingArchive,
  isArchivePending,
  pendingArchiveStatus,
  resetPendingArchives,
  rollbackPendingArchive,
  stagePendingArchive,
  withArchiveStatuses,
} from "../src/archiveState";
import { withLiveExecution } from "../src/nativeChromeBridge";
import type { Mission } from "../src/api";

const m = (id: string, status: string, parent?: string): Mission =>
  ({ id, status, title: id, history: [], created_at: "", updated_at: "", ...(parent ? { parent_mission_id: parent } : {}) }) as Mission;

afterEach(() => {
  resetPendingArchives();
  vi.useRealTimers();
});

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

describe("optimistic archive/restore overlay", () => {
  it("stages optimistic status immediately, settles after confirm, and rolls back cleanly", () => {
    vi.useFakeTimers();
    const rows = [m("a", "completed"), m("b", "paused")];
    expect(withArchiveStatuses(rows)).toBe(rows);

    const staged = stagePendingArchive(["a"], "acknowledged");
    expect(isArchivePending("a")).toBe(true);
    expect(pendingArchiveStatus("a")).toBe("acknowledged");
    const projected = withArchiveStatuses(rows);
    expect(projected[0].status).toBe("acknowledged");
    expect(projected[1]).toBe(rows[1]);

    // Confirming clears the in-flight lock so a follow-up restore is allowed immediately,
    // while keeping the overlay active until ARCHIVE_CONFIRM_MS elapses.
    confirmPendingArchive(staged);
    expect(isArchivePending("a")).toBe(false);
    expect(withArchiveStatuses(rows)[0].status).toBe("acknowledged");

    vi.advanceTimersByTime(ARCHIVE_CONFIRM_MS + 1);
    expect(pendingArchiveStatus("a")).toBeUndefined();
    expect(withArchiveStatuses(rows)).toBe(rows);
  });

  it("reverts immediately on rollback without clobbering a newer transition", () => {
    const rows = [m("a", "completed")];
    const first = stagePendingArchive(["a"], "acknowledged");
    expect(withArchiveStatuses(rows)[0].status).toBe("acknowledged");

    rollbackPendingArchive(first);
    expect(isArchivePending("a")).toBe(false);
    expect(withArchiveStatuses(rows)).toBe(rows);

    // A superseded rollback token cannot undo a newer transition.
    const s1 = stagePendingArchive(["a"], "acknowledged");
    const s2 = stagePendingArchive(["a"], "paused");
    rollbackPendingArchive(s1);
    expect(pendingArchiveStatus("a")).toBe("paused");
    rollbackPendingArchive(s2);
    expect(pendingArchiveStatus("a")).toBeUndefined();
  });

  it("wins over stale live-list statuses in the native chrome sync pipeline", () => {
    const liveRow = m("a", "completed");
    const archivedCopy = m("a", "acknowledged");
    const live = new Map([[liveRow.id, liveRow]]);

    stagePendingArchive(["a"], "acknowledged");
    const synced = withArchiveStatuses(withLiveExecution([liveRow, archivedCopy], live));
    expect(synced.every(r => r.status === "acknowledged")).toBe(true);
  });
});
