import { describe, expect, it } from "vitest";
import { createMissionKeepAlivePool } from "../src/missionKeepAlive";

describe("createMissionKeepAlivePool", () => {
  it("keeps array identity and slot order stable when switching back and forth", () => {
    const pool = createMissionKeepAlivePool(4);
    pool.reconcile({ activeMissionId: "m-1", pendingLaunchKey: "" });
    pool.reconcile({ activeMissionId: "m-2", pendingLaunchKey: "" });
    const refBefore = pool.slots();
    expect(refBefore.map((s) => s.slotKey)).toEqual(["m-1", "m-2"]);

    // Switching back to m-1 updates LRU recency without reallocating or reordering slots.
    pool.reconcile({ activeMissionId: "m-1", pendingLaunchKey: "" });
    expect(pool.slots()).toBe(refBefore);
    expect(pool.slots().map((s) => s.slotKey)).toEqual(["m-1", "m-2"]);
  });

  it("evicts the least-recently-used inactive slot beyond capacity", () => {
    const pool = createMissionKeepAlivePool(3);
    pool.reconcile({ activeMissionId: "m-1", pendingLaunchKey: "" });
    pool.reconcile({ activeMissionId: "m-2", pendingLaunchKey: "" });
    pool.reconcile({ activeMissionId: "m-3", pendingLaunchKey: "" });
    // Revisit m-1 so m-2 becomes the oldest inactive slot.
    pool.reconcile({ activeMissionId: "m-1", pendingLaunchKey: "" });
    pool.reconcile({ activeMissionId: "m-4", pendingLaunchKey: "" });

    expect(pool.slots().map((s) => s.slotKey)).toEqual(["m-1", "m-3", "m-4"]);
  });

  it("adopts a launch preview slot in-place when the mission id arrives", () => {
    const pool = createMissionKeepAlivePool(4);
    pool.reconcile({ activeMissionId: null, pendingLaunchKey: "launch-uuid-1" });
    const launchSlot = pool.slots()[0];
    expect(launchSlot.kind).toBe("launch");
    expect(launchSlot.missionId()).toBe("");

    // Mission creation succeeds and adopts the same slot without unmounting.
    pool.reconcile({
      activeMissionId: "m-created",
      pendingLaunchKey: "",
      launchedSlotKey: "launch-uuid-1",
    });
    expect(pool.slots()).toHaveLength(1);
    expect(pool.slots()[0]).toBe(launchSlot);
    expect(launchSlot.missionId()).toBe("m-created");

    // Navigating to + New (`activeMissionId: null`) keeps the confirmed mission slot alive.
    pool.reconcile({ activeMissionId: null, pendingLaunchKey: "" });
    expect(pool.slots()).toHaveLength(1);
    expect(pool.slots()[0].missionId()).toBe("m-created");
  });

  it("drops an unconfirmed launch preview slot if launch fails or is cancelled", () => {
    const pool = createMissionKeepAlivePool(4);
    pool.reconcile({ activeMissionId: null, pendingLaunchKey: "launch-aborted" });
    expect(pool.slots()).toHaveLength(1);

    pool.reconcile({ activeMissionId: null, pendingLaunchKey: "" });
    expect(pool.slots()).toHaveLength(0);
  });

  it("evicts deleted missions and clears on reset", () => {
    const pool = createMissionKeepAlivePool(4);
    pool.reconcile({ activeMissionId: "m-1", pendingLaunchKey: "" });
    pool.reconcile({ activeMissionId: "m-2", pendingLaunchKey: "" });
    pool.evictMission("m-1");
    expect(pool.slots().map((s) => s.slotKey)).toEqual(["m-2"]);
    pool.clear();
    expect(pool.slots()).toHaveLength(0);
  });

  it("allocates a fresh slot instance when connection epoch clears and immediately reconciles the same active mission", async () => {
    const { createEffect, createRoot, createSignal } = await import("solid-js");
    const pool = createMissionKeepAlivePool(4);
    const [connVer, setConnVer] = createSignal(1);
    const [activeMissionId] = createSignal<string | null>("m-open");

    const dispose = createRoot((d) => {
      let prevEpoch = connVer();
      createEffect(() => {
        const epoch = connVer();
        if (epoch !== prevEpoch) {
          prevEpoch = epoch;
          pool.clear();
        }
        pool.reconcile({ activeMissionId: activeMissionId(), pendingLaunchKey: "" });
      });
      return d;
    });

    try {
      expect(pool.slots()).toHaveLength(1);
      const slotBefore = pool.slots()[0];
      expect(slotBefore.missionId()).toBe("m-open");

      // Bump connection epoch without changing activeMissionId -> pool clears and re-creates a new slot!
      setConnVer(2);
      expect(pool.slots()).toHaveLength(1);
      expect(pool.slots()[0].missionId()).toBe("m-open");
      expect(pool.slots()[0]).not.toBe(slotBefore);
    } finally {
      dispose();
    }
  });
});
