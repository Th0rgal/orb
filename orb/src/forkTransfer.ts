import { DONE_STATUSES, isArchivable, isFailedStatus, isReady, remoteJobEnded, remoteJobFailed } from "./missionStatus";
import { api, ApiError, archiveMission, cancelMission, forkMission, getMission, type CodexServiceTier, type Mission } from "./api";
import { createSignal } from "solid-js";
import { peekTranscript } from "./missionCache";
import { getMissionEventPage, storedToStream } from "./stream";
import { dismissToast, notify } from "./toast";
import { buildTranscript, type StreamItem } from "./transcriptModel";

export type TransferStage = "preparing" | "source_stopped" | "destination_starting" | "running" | "failed";
export type TransferArchiveState = "idle" | "archiving" | "archived" | "failed";

export type HarnessTransfer = {
  sourceId: string;
  targetSignature: string;
  payload: Parameters<typeof forkMission>[1];
  stage: TransferStage;
  archiveState: TransferArchiveState;
  destination?: Mission;
  error?: string;
};

const [transfers, setTransfers] = createSignal<Readonly<Record<string, HarnessTransfer>>>({});
const watchTimers = new Map<string, ReturnType<typeof setTimeout>>();

export function putTransfer(next: HarnessTransfer) {
  setTransfers(all => ({ ...all, [next.sourceId]: next }));
}

export function updateTransfer(sourceId: string, fn: (current: HarnessTransfer) => HarnessTransfer | undefined) {
  setTransfers(all => {
    const current = all[sourceId];
    if (!current) return all;
    const updated = fn(current);
    if (!updated) {
      const copy = { ...all };
      delete copy[sourceId];
      return copy;
    }
    return { ...all, [sourceId]: updated };
  });
}

function stopWatcher(sourceId: string) {
  const timer = watchTimers.get(sourceId);
  if (timer !== undefined) {
    clearTimeout(timer);
    watchTimers.delete(sourceId);
  }
}

export function resetTransfersForTest(): void {
  for (const sourceId of [...watchTimers.keys()]) stopWatcher(sourceId);
  setTransfers({});
}

export const transferForSource = (sourceId: string | null | undefined): HarnessTransfer | undefined =>
  sourceId ? transfers()[sourceId] : undefined;

export const transferForDestination = (destinationId: string | null | undefined): HarnessTransfer | undefined => {
  if (!destinationId) return undefined;
  return Object.values(transfers()).find(t => t.destination?.id === destinationId);
};

export const targetKey = (backend: string, model: string, effort: string, speed?: CodexServiceTier, remoteNodeId?: string | null) =>
  JSON.stringify([backend, model, effort, backend === "codex" ? (speed ?? "standard") : "", remoteNodeId ?? ""]);

export function destinationStartupOutcome(
  mission: Mission | null | undefined,
  items: readonly StreamItem[] = [],
  liveActivity = false,
): "pending" | "running" | "failed" {
  let lastUser = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i];
    if (it.kind === "user" && !it.queued) { lastUser = i; break; }
  }
  const afterUser = items.slice(lastUser + 1);
  const hasOutput = liveActivity || afterUser.some(item =>
    item.kind === "tool" || ((item.kind === "text" || item.kind === "think") && !!item.text.trim()),
  );
  if (hasOutput) return "running";

  const status = (mission?.status ?? "").toLowerCase();
  const hasError = afterUser.some(item => item.kind === "error");
  const job = mission?.remote_job;
  const jobFailed = !!job && remoteJobEnded(job) && remoteJobFailed(job);
  if (!hasError && !jobFailed && (DONE_STATUSES.has(status) || (isReady(status) && status !== "acknowledged"))) {
    return "running";
  }
  if (hasError || jobFailed || isFailedStatus(status) || status === "interrupted" || status === "cancelled" || status === "canceled") {
    return "failed";
  }
  return "pending";
}

export async function retryTransferArchive(sourceId: string): Promise<boolean> {
  const current = transferForSource(sourceId);
  if (!current || current.stage !== "running" || current.archiveState === "archiving" || current.archiveState === "archived") {
    return current?.archiveState === "archived";
  }
  putTransfer({ ...current, archiveState: "archiving", error: undefined });
  window.dispatchEvent(new CustomEvent("orb:mission-archived", { detail: { id: sourceId } }));
  try {
    const src = await getMission(sourceId, { fresh: true });
    if (src.status !== "acknowledged" && src.status !== "archived") {
      await archiveMission(sourceId);
    }
    updateTransfer(sourceId, t => ({ ...t, stage: "running", archiveState: "archived", error: undefined }));
    dismissToast(`transfer-archive:${sourceId}`);
    window.dispatchEvent(new CustomEvent("orb:mission-archived", { detail: { id: sourceId } }));
    return true;
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    updateTransfer(sourceId, t => ({ ...t, stage: "running", archiveState: "failed", error: message }));
    window.dispatchEvent(new CustomEvent("orb:mission-archive-failed", { detail: { id: sourceId } }));
    notify({
      kind: "error",
      key: `transfer-archive:${sourceId}`,
      title: "The new agent is running, but the original conversation could not be archived",
      message,
      actions: [{ label: "Retry archiving", primary: true, run: () => { void retryTransferArchive(sourceId); } }],
    });
    return false;
  }
}

export function observeTransferDestination(
  mission: Mission | null | undefined,
  items: readonly StreamItem[] = [],
  liveActivity = false,
): void {
  const destinationId = mission?.id;
  if (!destinationId) return;
  const current = transferForDestination(destinationId);
  if (!current || current.stage !== "destination_starting") return;
  const outcome = destinationStartupOutcome(mission, items, liveActivity);
  if (outcome === "running") {
    stopWatcher(current.sourceId);
    putTransfer({ ...current, destination: mission ?? current.destination, stage: "running", archiveState: "idle", error: undefined });
    void retryTransferArchive(current.sourceId);
    return;
  }
  if (outcome === "failed") {
    stopWatcher(current.sourceId);
    putTransfer({ ...current, destination: mission ?? current.destination, stage: "failed", archiveState: "idle", error: undefined });
    return;
  }
  if (mission && mission !== current.destination) {
    putTransfer({ ...current, destination: mission });
  }
}

export function watchTransferDestination(sourceId: string, destinationId: string) {
  stopWatcher(sourceId);
  const delays = [60, 200, 500, 1000, 2000, 3500, 5000, 5000, 5000, 5000];
  let step = 0;
  const tick = () => {
    const current = transferForSource(sourceId);
    if (!current || current.stage !== "destination_starting" || current.destination?.id !== destinationId) {
      stopWatcher(sourceId);
      return;
    }
    const timer = setTimeout(async () => {
      watchTimers.delete(sourceId);
      const active = transferForSource(sourceId);
      if (!active || active.stage !== "destination_starting" || active.destination?.id !== destinationId) return;
      try {
        const cached = peekTranscript(destinationId)?.items;
        const [freshMission, page] = await Promise.all([
          getMission(destinationId, { fresh: true, includeHistory: false }).catch(() => null),
          cached?.length ? Promise.resolve(null) : getMissionEventPage(destinationId, { limit: 20 }).catch(() => null),
        ]);
        const items = cached?.length
          ? cached
          : page?.events?.length
            ? buildTranscript(page.events.map(storedToStream).filter((ev): ev is NonNullable<typeof ev> => ev !== null))
            : [];
        if (freshMission || items.length) observeTransferDestination(freshMission ?? active.destination, items);
      } finally {
        step++;
        if (step < delays.length && transferForSource(sourceId)?.stage === "destination_starting") tick();
      }
    }, delays[step]);
    (timer as unknown as { unref?: () => void }).unref?.();
    watchTimers.set(sourceId, timer);
  };
  tick();
}

export function isDefinitiveRefusal(error: unknown): boolean {
  return error instanceof ApiError && error.status >= 400 && error.status < 500 && error.status !== 408 && error.status !== 429;
}

/** Stops a conversation that another version replaces, if it is still running. */
export async function stopSource(id: string): Promise<void> {
  const current = await getMission(id, { includeHistory: false });
  if (sourceStopped(current)) return;
  if (current.backend?.startsWith("cloud_")) {
    await api(`/api/control/missions/${encodeURIComponent(id)}/cloud/cancel`, { method: "POST" });
  } else {
    await cancelMission(id);
  }
  for (let i = 0; i < 20; i++) {
    const m = await getMission(id, { includeHistory: false });
    if (sourceStopped(m)) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("The original agent has not stopped yet. Wait and retry the transfer.");
}

function sourceStopped(m: Mission): boolean {
  return (isArchivable(m.status) || m.status === "acknowledged") && m.execution?.state !== "running"
    && !["queued", "running"].includes(m.remote_job?.node_state ?? "");
}
