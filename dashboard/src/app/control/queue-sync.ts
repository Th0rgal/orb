// Serialize queue snapshots while retaining the latest refresh requested in flight.
export function createQueueSync<T>({
  fetchQueue, getMissionId, getMutationGeneration, apply, onError,
}: {
  fetchQueue: () => Promise<T>;
  getMissionId: () => string | null;
  getMutationGeneration: () => number;
  apply: (snapshot: T, missionId: string) => void;
  onError: (error: unknown) => void;
}) {
  let running = false;
  let pending: string | null = null;
  return async (missionId: string) => {
    if (!missionId || missionId !== getMissionId()) return;
    pending = missionId;
    if (running) return;
    running = true;
    try {
      while (pending !== null) {
        const target = pending;
        pending = null;
        if (target !== getMissionId()) continue;
        const generation = getMutationGeneration();
        try {
          const snapshot = await fetchQueue();
          if (target !== getMissionId() || generation !== getMutationGeneration()) continue;
          apply(snapshot, target);
        } catch (error) {
          onError(error);
        }
      }
    } finally {
      running = false;
    }
  };
}
