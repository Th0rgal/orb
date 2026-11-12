import { describe, expect, it, vi } from "vitest";
import {
  buildNativeChromeSyncArgs,
  createNativeChromeSyncer,
  installNativeChromeWindowHandlers,
  isNativeChromeEnabled,
  serializeNativeChromeMission,
  type NativeChromeSyncSnapshot,
} from "../src/nativeChromeBridge";
import type { Mission, ProjectSummary } from "../src/api";

function makeMission(overrides: Partial<Mission> = {}): Mission {
  return {
    id: "m-1",
    status: "active",
    title: "Fast SQLite Cache",
    history: [],
    created_at: "2026-11-11T10:00:00Z",
    updated_at: "2026-11-11T10:05:00Z",
    project: "orb",
    folder: "desktop/perf",
    ...overrides,
  };
}

describe("nativeChromeBridge", () => {
  it("enables native chrome only when the desktop shell sets window.__ORB_NATIVE_CHROME__ = true", () => {
    expect(isNativeChromeEnabled({ location: { search: "" } } as unknown as Window)).toBe(false);
    expect(
      isNativeChromeEnabled({
        __ORB_NATIVE_CHROME__: true,
        location: { search: "" },
      } as unknown as Window),
    ).toBe(true);
    expect(
      isNativeChromeEnabled({
        location: { search: "?chrome=native" },
      } as unknown as Window),
    ).toBe(false);
    expect(
      isNativeChromeEnabled({
        __ORB_NATIVE_CHROME__: false,
        location: { search: "?chrome=native" },
      } as unknown as Window),
    ).toBe(false);
  });

  it("serializes mission metadata and monotonic sync payload cleanly", () => {
    const m = makeMission({ parent_mission_id: "m-0" });
    const wire = serializeNativeChromeMission(m);
    expect(wire.id).toBe("m-1");
    expect(wire.project).toBe("orb");
    expect(wire.folder).toBe("desktop/perf");
    expect(wire.parent_mission_id).toBe("m-0");
    expect(wire.fork_of).toBe("");
    expect(wire.is_fork).toBe(false);
    expect(wire.is_btw).toBe(false);
    expect(wire.created_at_ms).toBe(Date.parse("2026-11-11T10:00:00Z"));
    expect(wire.updated_at_ms).toBe(Date.parse("2026-11-11T10:05:00Z"));

    const forkedWorker = makeMission({
      id: "m-2",
      parent_mission_id: "m-1",
      tags: ["fork-of:m-1"],
      project: undefined,
    });
    const forkedWire = serializeNativeChromeMission(forkedWorker);
    expect(forkedWire.fork_of).toBe("m-1");
    expect(forkedWire.is_fork).toBe(true);
    expect(forkedWire.parent_mission_id).toBe("");
    expect("project" in forkedWire).toBe(false);

    const unassignedRoot = makeMission({
      id: "m-root-unassigned",
      project: null,
      folder: "",
    });
    const unassignedWire = serializeNativeChromeMission(unassignedRoot);
    expect(unassignedWire.project).toBeNull();
    expect(unassignedWire.folder).toBe("");

    const btwSession = makeMission({
      id: "m-btw",
      tags: ["btw-parent:m-1"],
    });
    expect(serializeNativeChromeMission(btwSession).is_btw).toBe(true);

    const proj: ProjectSummary = {
      slug: "orb",
      title: "Orb Core",
      status: "active",
      updated_at: "2026-11-11T10:00:00Z",
    };
    const snap: NativeChromeSyncSnapshot = {
      scope: "scope:test:1",
      selected: "m:m-1",
      onSettings: false,
      isAdmin: true,
      inboxEnabled: true,
      inboxUnread: 4,
      settingsBadge: 1,
      settingsDots: ["security"],
      projects: [proj],
      projectColors: { orb: "blue" },
      missions: [m],
      completedMissions: [],
      projectMissions: {},
    };
    const args = buildNativeChromeSyncArgs(snap, 7);
    expect(args.revision).toBe(7);
    expect(args.scope).toBe("scope:test:1");
    expect(args.selected).toBe("m:m-1");
    expect(args.inbox_unread).toBe(4);
    expect((args.projects as Array<{ name: string; color?: string }>)[0]?.name).toBe("Orb Core");
    expect((args.projects as Array<{ name: string; color?: string }>)[0]?.color).toBe("blue");
  });

  it("installs window.__ORB_SELECT_MISSION__, __ORB_NATIVE_NAV__, and __ORB_TOGGLE_NATIVE_SIDEBAR__", () => {
    const opened: Array<string | null> = [];
    const projects: string[] = [];
    const toggledFolders: string[] = [];
    let leftSettings = 0;
    let sbOpen = true;
    const fakeWin = {} as Window & {
      __ORB_SELECT_MISSION__?: (id: string) => boolean;
      __ORB_NATIVE_NAV__?: (t: string) => boolean;
      __ORB_TOGGLE_NATIVE_SIDEBAR__?: (o?: boolean) => boolean;
    };
    const cleanup = installNativeChromeWindowHandlers(
      {
        open: (id) => {
          opened.push(id);
          return true;
        },
        leaveSettings: () => {
          leftSettings += 1;
        },
        getSidebarOpen: () => sbOpen,
        setSidebarOpen: (next) => {
          sbOpen = next;
        },
        selectProject: (slug) => projects.push(slug),
        toggleFolderExpand: (rowId) => toggledFolders.push(rowId),
      },
      fakeWin,
    );

    expect(fakeWin.__ORB_SELECT_MISSION__?.("abc")).toBe(true);
    expect(fakeWin.__ORB_SELECT_MISSION__?.("m:xyz")).toBe(true);
    expect(fakeWin.__ORB_NATIVE_NAV__?.("new-agent")).toBe(true);
    expect(fakeWin.__ORB_NATIVE_NAV__?.("inbox")).toBe(true);
    expect(fakeWin.__ORB_NATIVE_NAV__?.("project:orb")).toBe(true);
    expect(fakeWin.__ORB_NATIVE_NAV__?.("folder:orb:audits/2026")).toBe(true);
    expect(fakeWin.__ORB_NATIVE_NAV__?.("settings-back")).toBe(true);
    expect(fakeWin.__ORB_TOGGLE_NATIVE_SIDEBAR__?.()).toBe(false);
    expect(sbOpen).toBe(false);

    expect(opened).toEqual(["m:abc", "m:xyz", null, "inbox", null]);
    expect(projects).toEqual(["orb"]);
    expect(toggledFolders).toEqual(["folder:orb:audits/2026"]);
    expect(leftSettings).toBe(1);

    cleanup();
    expect(fakeWin.__ORB_SELECT_MISSION__).toBeUndefined();
    expect(fakeWin.__ORB_NATIVE_NAV__).toBeUndefined();
  });

  it("coalesces rapid schedule calls with strictly monotonic revisions", async () => {
    vi.useFakeTimers();
    try {
      const calls: Array<{ cmd: string; args: Record<string, unknown> }> = [];
      const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
        calls.push({ cmd, args: args ?? {} });
        return { applied: true };
      });
      const syncer = createNativeChromeSyncer(invoke, 0);
      const baseSnap: NativeChromeSyncSnapshot = {
        scope: "scope:1",
        selected: null,
        onSettings: false,
        isAdmin: true,
        inboxEnabled: true,
        inboxUnread: 0,
        settingsBadge: 0,
        settingsDots: [],
        projects: [],
        missions: [],
        completedMissions: [],
        projectMissions: {},
      };
      syncer.schedule({ ...baseSnap, inboxUnread: 1 });
      syncer.schedule({ ...baseSnap, inboxUnread: 2 });
      expect(calls).toHaveLength(0);
      await vi.advanceTimersByTimeAsync(20);
      expect(calls).toHaveLength(1);
      expect(calls[0]?.args.revision).toBe(1);
      expect(calls[0]?.args.inbox_unread).toBe(2);

      syncer.schedule({ ...baseSnap, inboxUnread: 5 }, true);
      await Promise.resolve();
      expect(calls).toHaveLength(2);
      expect(calls[1]?.args.revision).toBe(2);
      expect(calls[1]?.args.inbox_unread).toBe(5);
      syncer.dispose();

      // A fresh syncer created after a WebView reload starts strictly above prior wall-clock revisions.
      vi.setSystemTime(new Date("2026-11-12T04:30:00Z"));
      const reloadedA = createNativeChromeSyncer(invoke);
      reloadedA.schedule(baseSnap, true);
      await Promise.resolve();
      const revBeforeReload = calls[2]?.args.revision as number;
      expect(revBeforeReload).toBeGreaterThan(1_000_000_000_000);
      reloadedA.dispose();

      vi.setSystemTime(new Date("2026-11-12T04:30:01Z"));
      const reloadedB = createNativeChromeSyncer(invoke);
      reloadedB.schedule(baseSnap, true);
      await Promise.resolve();
      const revAfterReload = calls[3]?.args.revision as number;
      expect(revAfterReload).toBeGreaterThan(revBeforeReload);
      reloadedB.dispose();
    } finally {
      vi.useRealTimers();
    }
  });
});
