import { afterEach, describe, expect, it, vi } from "vitest";
import type { Mission } from "../src/api";
import {
  applyPendingFileMoves,
  createNativeChromeSyncer,
  installNativeChromeWindowHandlers,
  serializeNativeChromeMission,
  withLiveExecution,
  type NativeChromeSyncSnapshot,
} from "../src/nativeChromeBridge";

const base = { id: "m1", title: "T", status: "failed", created_at: "2026-11-19T00:00:00Z" } as Mission;

const makeSnap = (overrides: Partial<NativeChromeSyncSnapshot> = {}): NativeChromeSyncSnapshot => ({
  scope: "https://orb.example:1",
  selected: "m:m1",
  onSettings: false,
  isAdmin: true,
  inboxEnabled: true,
  inboxUnread: 0,
  settingsBadge: 0,
  settingsDots: [],
  projects: [],
  missions: [base],
  completedMissions: [],
  projectMissions: {},
  ...overrides,
});

afterEach(() => {
  vi.useRealTimers();
  delete (window as unknown as Record<string, unknown>).__ORB_NATIVE_SYNC_BRIDGE__;
  delete (window as unknown as Record<string, unknown>).webkit;
});

describe("serializeNativeChromeMission", () => {
  it("marks a mission tagged archived as acknowledged", () => {
    expect(serializeNativeChromeMission({ ...base, tags: ["pr-writer", "archived"] }).acknowledged).toBe(true);
  });
  it("keeps an untagged failed mission visible", () => {
    expect(serializeNativeChromeMission({ ...base, tags: ["pr-writer"] }).acknowledged).toBe(false);
  });
});

describe("withLiveExecution", () => {
  it("propagates fresher renamed title from live owner onto stale per-project copy", () => {
    const staleProjectCopy = {
      ...base,
      title: "Razr 60 Ultra AirDrop",
      updated_at: "2026-11-24T18:53:51Z",
    } as Mission;
    const liveOwner = {
      ...base,
      title: "airdrop",
      status: "active",
      updated_at: "2026-11-24T18:53:51Z",
      metadata_updated_at: "2026-11-26T08:59:23Z",
    } as Mission;
    const [merged] = withLiveExecution([staleProjectCopy], new Map([["m1", liveOwner]]));
    expect(merged.title).toBe("airdrop");
    expect(merged.status).toBe("active");
    expect(merged.metadata_updated_at).toBe("2026-11-26T08:59:23Z");
  });
});

describe("createNativeChromeSyncer", () => {
  it("flushes selection and immediate rename changes synchronously without waiting for 16ms timer", async () => {
    vi.useFakeTimers();
    const calls: Array<Record<string, unknown>> = [];
    const invoke = vi.fn(async (_cmd: string, args?: Record<string, unknown>) => {
      calls.push(args ?? {});
      return { applied: true };
    });
    const syncer = createNativeChromeSyncer(invoke as never, 100);
    syncer.schedule(makeSnap({ selected: "m:m1" }));
    expect(calls).toHaveLength(1);
    expect(calls[0].selected).toBe("m:m1");

    // Switching selected mission flushes immediately without advancing timers.
    syncer.schedule(makeSnap({ selected: "m:m2" }));
    await Promise.resolve();
    expect(calls).toHaveLength(2);
    expect(calls[1].selected).toBe("m:m2");

    // Identical snapshot is deduplicated.
    syncer.schedule(makeSnap({ selected: "m:m2" }));
    vi.advanceTimersByTime(20);
    await Promise.resolve();
    expect(calls).toHaveLength(2);

    // Immediate rename flushes synchronously without waiting 16ms.
    syncer.schedule(makeSnap({ selected: "m:m2", missions: [{ ...base, title: "airdrop" }] }), true);
    await Promise.resolve();
    expect(calls).toHaveLength(3);
    expect((calls[2].missions as Array<{ title: string }>)[0].title).toBe("airdrop");
    syncer.dispose();
  });

  it("coalesces concurrent schedules behind a single in-flight RPC", async () => {
    let resolveFirst!: () => void;
    const calls: Array<Record<string, unknown>> = [];
    let count = 0;
    const invoke = vi.fn((_cmd: string, args?: Record<string, unknown>) => {
      calls.push(args ?? {});
      count += 1;
      if (count === 1) {
        return new Promise((res) => {
          resolveFirst = () => res({ applied: true });
        });
      }
      return Promise.resolve({ applied: true });
    });
    const syncer = createNativeChromeSyncer(invoke as never, 200);
    syncer.schedule(makeSnap({ selected: "m:first" }));
    expect(calls).toHaveLength(1);

    // Rapid updates while first RPC is in flight must NOT open additional concurrent RPCs.
    syncer.schedule(makeSnap({ selected: "m:second" }));
    syncer.schedule(makeSnap({ selected: "m:third" }));
    expect(calls).toHaveLength(1);

    resolveFirst();
    await Promise.resolve();
    await Promise.resolve();
    expect(calls).toHaveLength(2);
    expect(calls[1].selected).toBe("m:third");
    syncer.dispose();
  });

  it("uses orbNative postMessage fast path when __ORB_NATIVE_SYNC_BRIDGE__ is enabled", () => {
    const posted: Array<Record<string, unknown>> = [];
    (window as unknown as Record<string, unknown>).__ORB_NATIVE_SYNC_BRIDGE__ = true;
    (window as unknown as Record<string, unknown>).webkit = {
      messageHandlers: {
        orbNative: {
          postMessage: (msg: Record<string, unknown>) => posted.push(msg),
        },
      },
    };
    const syncer = createNativeChromeSyncer(undefined, 300);
    syncer.schedule(makeSnap({ selected: "m:d186" }));
    expect(posted).toHaveLength(1);
    expect(posted[0].command).toBe("native_chrome_sync_state");
    const parsed = JSON.parse(String(posted[0].args));
    expect(parsed.command).toBe("native_chrome_sync_state");
    expect(parsed.args.selected).toBe("m:d186");
    expect(parsed.args.revision).toBe(301);
    syncer.dispose();
  });
});

describe("applyPendingFileMoves and cancel-cut", () => {
  it("optimistically moves cut folders, nested subfolders, and files into destination", () => {
    const folders = { ethereum: ["audits", "audits/pareto", "audits/pareto/notes"], perso: ["rzr"] };
    const files = { ethereum: ["audits/pareto/report.md", "readme.md"], perso: [] };
    const moves = new Map([
      [
        "file:ethereum:audits/pareto",
        {
          kind: "file" as const,
          fromProject: "ethereum",
          toProject: "perso",
          fromPath: "audits/pareto",
          path: "rzr/pareto",
          directory: true,
        },
      ],
    ]);
    const next = applyPendingFileMoves(folders, files, moves);
    expect(next.folders.ethereum).toEqual(["audits"]);
    expect(next.folders.perso).toEqual(["rzr", "rzr/pareto", "rzr/pareto/notes"]);
    expect(next.files.ethereum).toEqual(["readme.md"]);
    expect(next.files.perso).toEqual(["rzr/pareto/report.md"]);
  });

  it("dispatches cancel-cut through __ORB_NATIVE_PROJECT_ACTION__", () => {
    const actions: Array<{ action: string; slug: string }> = [];
    const cleanup = installNativeChromeWindowHandlers({
      open: () => true,
      leaveSettings: () => {},
      getSidebarOpen: () => true,
      setSidebarOpen: () => {},
      projectAction: (action, slug) => {
        actions.push({ action, slug });
        return true;
      },
    });
    const win = window as unknown as { __ORB_NATIVE_PROJECT_ACTION__?: (a: string, s: string) => boolean };
    expect(win.__ORB_NATIVE_PROJECT_ACTION__?.("cancel-cut", "_")).toBe(true);
    expect(actions).toEqual([{ action: "cancel-cut", slug: "_" }]);
    cleanup();
  });
});
