import { createSignal, type Accessor } from "solid-js";

export const MAX_KEPT_MISSION_VIEWS = 4;

export interface KeptMissionSlot {
  readonly slotKey: string;
  readonly kind: "mission" | "launch";
  readonly missionId: Accessor<string>;
  readonly setMissionId: (id: string) => void;
  lastUsed: number;
}

export function createKeptMissionSlot(
  slotKey: string,
  kind: "mission" | "launch",
  initialMissionId: string,
  lastUsed: number,
): KeptMissionSlot {
  const [missionId, setMissionId] = createSignal(initialMissionId);
  return { slotKey, kind, missionId, setMissionId, lastUsed };
}

export interface ReconcileKeptSlotsInput {
  activeMissionId: string | null;
  /** Non-empty only while `selected() === null && Boolean(launchPreview())`. */
  pendingLaunchKey: string;
  /** Launch view key recorded when `activeMissionId` was started in this window. */
  launchedSlotKey?: string;
  maxSlots?: number;
  isDeleting?: (missionId: string) => boolean;
}

export function createMissionKeepAlivePool(maxSlots = MAX_KEPT_MISSION_VIEWS) {
  let clock = 0;
  const [slots, setSlots] = createSignal<KeptMissionSlot[]>([]);

  const reconcile = (input: ReconcileKeptSlotsInput) => {
    const cap = Math.max(1, input.maxSlots ?? maxSlots);
    const { activeMissionId, pendingLaunchKey, launchedSlotKey, isDeleting } = input;
    setSlots((prev) => {
      let changed = false;
      const next: KeptMissionSlot[] = [];
      for (const slot of prev) {
        const mid = slot.missionId();
        if (mid && isDeleting?.(mid)) {
          changed = true;
          continue;
        }
        // Drop an unconfirmed launch preview slot as soon as the preview is cancelled.
        if (slot.kind === "launch" && !mid) {
          const adoptingNow = Boolean(activeMissionId && launchedSlotKey === slot.slotKey);
          const stillPreviewing = !activeMissionId && pendingLaunchKey === slot.slotKey;
          if (!adoptingNow && !stillPreviewing) {
            changed = true;
            continue;
          }
        }
        next.push(slot);
      }

      let activeSlotKey = "";
      if (activeMissionId && !isDeleting?.(activeMissionId)) {
        const existing = next.find(
          (s) =>
            s.missionId() === activeMissionId ||
            Boolean(launchedSlotKey && s.slotKey === launchedSlotKey),
        );
        if (existing) {
          if (existing.missionId() !== activeMissionId) {
            existing.setMissionId(activeMissionId);
          }
          existing.lastUsed = ++clock;
          activeSlotKey = existing.slotKey;
        } else {
          const slotKey = launchedSlotKey || activeMissionId;
          const kind = launchedSlotKey ? "launch" : "mission";
          const created = createKeptMissionSlot(slotKey, kind, activeMissionId, ++clock);
          next.push(created);
          activeSlotKey = created.slotKey;
          changed = true;
        }
      } else if (pendingLaunchKey) {
        const existing = next.find((s) => s.slotKey === pendingLaunchKey);
        if (existing) {
          existing.lastUsed = ++clock;
          activeSlotKey = existing.slotKey;
        } else {
          const created = createKeptMissionSlot(pendingLaunchKey, "launch", "", ++clock);
          next.push(created);
          activeSlotKey = created.slotKey;
          changed = true;
        }
      }

      while (next.length > cap) {
        let oldestIdx = -1;
        let oldestTick = Infinity;
        for (let i = 0; i < next.length; i++) {
          if (next[i].slotKey === activeSlotKey) continue;
          if (next[i].lastUsed < oldestTick) {
            oldestTick = next[i].lastUsed;
            oldestIdx = i;
          }
        }
        if (oldestIdx < 0) break;
        next.splice(oldestIdx, 1);
        changed = true;
      }

      return changed ? next : prev;
    });
  };

  const evictMission = (missionId: string) => {
    if (!missionId) return;
    setSlots((prev) => {
      const next = prev.filter((s) => s.missionId() !== missionId && s.slotKey !== missionId);
      return next.length === prev.length ? prev : next;
    });
  };

  const clear = () => {
    setSlots((prev) => (prev.length === 0 ? prev : []));
  };

  return { slots, reconcile, evictMission, clear };
}
