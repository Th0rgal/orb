import { isHarness } from "./harnesses";
import { DONE_STATUSES, isArchivable, isFailedStatus, isReady, remoteJobEnded } from "./missionStatus";
import { CodexSpeedPicker, missionSpeed, requireSpeedSupport } from "./CodexSpeedPicker";
import { localBinding } from "./localAgents";
import { ApiError, archiveMission, cancelMission, forkMission, getMission, shortModelLabel, type CodexServiceTier, type HarnessChoice, type Mission } from "./api";
import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createEffect, createMemo, createSignal, on, onMount } from "solid-js";
import { effortLabel, supportedEfforts } from "./effort";
import { Menu } from "./Menu";
import { peekTranscript } from "./missionCache";
import { getMissionEventPage, storedToStream } from "./stream";
import { dismissToast, notify } from "./toast";
import { buildTranscript, type StreamItem } from "./transcriptModel";
import { usageTelemetry } from "./usageTelemetry";

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

function putTransfer(next: HarnessTransfer) {
  setTransfers(all => ({ ...all, [next.sourceId]: next }));
}

function updateTransfer(sourceId: string, fn: (current: HarnessTransfer) => HarnessTransfer | undefined) {
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

const targetKey = (backend: string, model: string, effort: string, speed?: CodexServiceTier) =>
  JSON.stringify([backend, model, effort, backend === "codex" ? (speed ?? "standard") : ""]);

const FAILED_NODE_STATES = new Set(["failed", "lost", "cancelled", "canceled"]);

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
  const jobFailed = !!job && remoteJobEnded(job) && (
    !!job.terminal_reason ||
    FAILED_NODE_STATES.has(job.node_state ?? "") ||
    (job.exit_code != null && job.exit_code !== 0)
  );
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

function watchTransferDestination(sourceId: string, destinationId: string) {
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
          getMission(destinationId, { fresh: true }).catch(() => null),
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

function isDefinitiveRefusal(error: unknown): boolean {
  return error instanceof ApiError && error.status >= 400 && error.status < 500 && error.status !== 408 && error.status !== 429;
}

export function ForkMission(p: { mission: Mission; choices: HarnessChoice[]; destination: string; anchor?: HTMLElement; onOpen?: () => void; onClose: () => void; onFork: (mission: Mission) => void }) {
  const [backend, setBackend] = createSignal(p.mission.backend ?? p.choices[0]?.backend.id ?? "");
  const [speed, setSpeed] = createSignal<CodexServiceTier>(missionSpeed(p.mission));
  const [model, setModel] = createSignal(p.mission.model_override ?? "");
  const [modelAnchor, setModelAnchor] = createSignal<HTMLButtonElement>();
  const [effortAnchor, setEffortAnchor] = createSignal<HTMLButtonElement>();
  const [busy, setBusy] = createSignal(false), [error, setError] = createSignal("");
  const choices = () => p.choices.find(choice => choice.backend.id === backend())?.models ?? [];
  const unavailable = (id: string) => !!p.mission.remote_node_id && !isHarness(id);
  const existing = createMemo(() => transferForSource(p.mission.id));
  const lockedSubmitted = createMemo(() => {
    const t = existing();
    return !!t && (t.stage === "preparing" || t.stage === "source_stopped" || t.stage === "destination_starting" || (t.stage === "running" && t.archiveState === "failed"));
  });
  let pendingKey = crypto.randomUUID();
  let pendingSignature = "";

  onMount(() => p.onOpen?.());
  // The harness catalog refreshes while the menu is open (e.g. late Antigravity models),
  // which re-renders the rows. Hand open submenus the live row so they stay beside it.
  const live = (anchor: HTMLButtonElement | undefined, selector: string) => anchor && !anchor.isConnected ? anchor.closest('[role="menu"]')?.querySelector<HTMLButtonElement>(selector) ?? document.querySelector<HTMLButtonElement>(selector) ?? undefined : anchor;
  createEffect(on(() => p.choices, () => queueMicrotask(() => {
    setModelAnchor(a => live(a, `.fork-harnesses [data-backend="${CSS.escape(backend())}"]`));
    setEffortAnchor(a => live(a, `.fork-models [data-model="${CSS.escape(model())}"]`));
  }), { defer: true }));

  const fork = async (effort = "") => {
    const current = existing();
    if (busy()) return;
    if (current?.stage === "running" && current.archiveState === "failed") {
      setBusy(true); setError("");
      try {
        const archived = await retryTransferArchive(p.mission.id);
        if (archived && current.destination) p.onFork(current.destination);
        else if (!archived) setError(transferForSource(p.mission.id)?.error ?? "Could not archive the original conversation.");
      } finally { setBusy(false); }
      return;
    }
    if (current?.stage === "destination_starting" && current.destination) {
      p.onFork(current.destination);
      return;
    }
    const retryingUncertain = current?.stage === "source_stopped";
    if (!retryingUncertain && (!backend() || unavailable(backend()) || !choices().some(choice => choice.value === model()))) return;
    const sig = retryingUncertain ? current.targetSignature : targetKey(backend(), model(), effort, speed());
    // If an earlier transfer to this exact target already created a destination that failed
    // before starting, reuse that receipt and open it instead of spawning a duplicate writer.
    if (!retryingUncertain && current?.stage === "failed" && current.targetSignature === sig && current.destination) {
      p.onFork(current.destination);
      return;
    }

    setBusy(true); setError("");
    try {
      let payload = retryingUncertain ? current.payload : undefined;
      if (!payload) {
        if (pendingSignature !== sig) { pendingSignature = sig; pendingKey = crypto.randomUUID(); }
        putTransfer({
          sourceId: p.mission.id,
          targetSignature: sig,
          payload: { backend: backend(), model_override: model(), model_effort: effort, service_tier: backend() === "codex" ? speed() : undefined, idempotency_key: pendingKey },
          stage: "preparing",
          archiveState: "idle",
        });
        if (backend() === "codex") await requireSpeedSupport(model(), speed(), undefined, !!localBinding(p.mission.id));
        await stopSource(p.mission.id);
        payload = { backend: backend(), model_override: model(), model_effort: effort, service_tier: backend() === "codex" ? speed() : undefined, idempotency_key: pendingKey };
        putTransfer({ sourceId: p.mission.id, targetSignature: sig, payload, stage: "source_stopped", archiveState: "idle" });
      }
      const next = await forkMission(p.mission.id, payload);
      const immediate = destinationStartupOutcome(next, []);
      if (immediate === "running") {
        putTransfer({ sourceId: p.mission.id, targetSignature: sig, payload, destination: next, stage: "running", archiveState: "idle" });
        void retryTransferArchive(p.mission.id);
      } else if (immediate === "failed") {
        putTransfer({ sourceId: p.mission.id, targetSignature: sig, payload, destination: next, stage: "failed", archiveState: "idle" });
      } else {
        putTransfer({ sourceId: p.mission.id, targetSignature: sig, payload, destination: next, stage: "destination_starting", archiveState: "idle" });
        watchTransferDestination(p.mission.id, next.id);
      }
      p.onFork(next);
      usageTelemetry.action("fork", "mission");
    } catch (e) {
      const message = (e instanceof Error ? e.message : String(e))
        .replace("The original mission has not been changed.", "The original conversation is retained; it may have been stopped.");
      const latest = transferForSource(p.mission.id);
      if (latest?.stage === "preparing" || (latest?.stage === "source_stopped" && isDefinitiveRefusal(e))) {
        updateTransfer(p.mission.id, () => undefined);
      } else if (latest?.stage === "source_stopped") {
        putTransfer({ ...latest, error: message });
      }
      setError(message);
      setEffortAnchor(undefined);
      setModelAnchor(undefined);
    } finally {
      setBusy(false);
    }
  };

  const openModels = (id: string, anchor: HTMLButtonElement) => {
    if (busy() || lockedSubmitted() || unavailable(id)) return;
    if (id !== backend()) setSpeed("standard");
    setBackend(id); setEffortAnchor(undefined); setModelAnchor(anchor);
  };
  const showArchiveRetry = () => existing()?.stage === "running" && existing()?.archiveState === "failed";
  const displayError = () => error() || (showArchiveRetry() ? existing()?.error ?? "" : "");

  return <Menu label="Transfer to another agent" class="fork-harnesses" anchor={p.anchor} placement={p.anchor ? "right-start" : "top-start"} busy={busy()} onClose={() => { if (!busy()) p.onClose(); }}>
    <Show when={!p.anchor}><div class="menu-group">Transfer to another agent</div></Show>
    <For each={p.choices}>{choice => <button type="button" class="menu-item" role="menuitem" data-backend={choice.backend.id} aria-haspopup="menu" aria-expanded={!!modelAnchor() && backend() === choice.backend.id} disabled={busy() || lockedSubmitted() || unavailable(choice.backend.id)}
      title={unavailable(choice.backend.id) ? "Not supported on this remote workspace" : choice.backend.name}
      onMouseEnter={e => openModels(choice.backend.id, e.currentTarget)} onClick={e => openModels(choice.backend.id, e.currentTarget)}
      onKeyDown={e => { if (e.key === "ArrowRight") { e.preventDefault(); e.stopPropagation(); openModels(choice.backend.id, e.currentTarget); } }}>
      {choice.backend.name}<span class="menu-chevron" aria-hidden="true">›</span>
    </button>}</For>
    <Show when={modelAnchor()}>{anchor => <Menu label="Choose a model" class="fork-models" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => { if (!busy()) setModelAnchor(undefined); }}>
      <For each={choices()}>{choice => {
        const choose = (anchor: HTMLButtonElement) => { if (busy() || lockedSubmitted()) return; setModel(choice.value); if (supportedEfforts(backend()).length) setEffortAnchor(anchor); else void fork(); };
        return <button type="button" class="menu-item" role="menuitem" data-model={choice.value} disabled={busy() || lockedSubmitted()} aria-haspopup={supportedEfforts(backend()).length ? "menu" : undefined}
          title={`Transfer to ${shortModelLabel(choice.label)} · same workspace on ${p.destination}`}
          onClick={e => choose(e.currentTarget)} onMouseEnter={e => { if (!busy() && !lockedSubmitted() && supportedEfforts(backend()).length) { setModel(choice.value); setEffortAnchor(e.currentTarget); } }}
          onKeyDown={e => { if (e.key === "ArrowRight" && supportedEfforts(backend()).length) { e.preventDefault(); e.stopPropagation(); choose(e.currentTarget); } }}>
          {shortModelLabel(choice.label)}<Show when={supportedEfforts(backend()).length}><span class="menu-chevron" aria-hidden="true">›</span></Show>
        </button>;
      }}</For>
      <Show when={!choices().length}><div class="menu-group">No models available</div></Show>
      <Show when={effortAnchor()}>{anchor => <Menu label="Choose effort" class="fork-effort-menu" anchor={anchor()} placement="right-start" busy={busy()} onClose={() => { if (!busy()) setEffortAnchor(undefined); }}>
        <Show when={backend() === "codex"}><CodexSpeedPicker model={model()} value={speed()} local={!!localBinding(p.mission.id)} disabled={busy() || lockedSubmitted()} onChange={setSpeed} /></Show>
        <For each={["", ...supportedEfforts(backend())]}>{effort => <button type="button" role="menuitem" class="menu-item" disabled={busy()} onClick={() => void fork(effort)}>{effortLabel(effort || undefined, backend(), model())}</button>}</For>
        <Show when={displayError()}><ErrorNotice error={displayError()} /></Show>
      </Menu>}</Show>
      <Show when={displayError() && !effortAnchor()}><ErrorNotice error={displayError()} /></Show>
    </Menu>}</Show>
    <Show when={existing()?.stage === "source_stopped" && !busy()}><button type="button" class="menu-item" role="menuitem" onClick={() => void fork()}>Retry transfer</button></Show>
    <Show when={showArchiveRetry()}>
      <div class="menu-group" role="status">The new agent is ready. Finish archiving the original.</div>
      <button type="button" class="menu-item" role="menuitem" disabled={busy()} onClick={() => void fork()}>Retry archiving</button>
      <Show when={existing()?.destination}>{dest => <button type="button" class="menu-item" role="menuitem" disabled={busy()} onClick={() => p.onFork(dest())}>Open transferred conversation</button>}</Show>
    </Show>
    <Show when={displayError() && !modelAnchor()}><ErrorNotice error={displayError()} /></Show>
    <Show when={busy()}><div class="menu-group" role="status">Transferring…</div></Show>
  </Menu>;
}

/** Stops a conversation that another version replaces, if it is still running. */
export async function stopSource(id: string): Promise<void> {
  const current = await getMission(id);
  if (sourceStopped(current)) return;
  await cancelMission(id);
  for (let i = 0; i < 20; i++) {
    const m = await getMission(id);
    if (sourceStopped(m)) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("The original agent has not stopped yet. Wait and retry the transfer.");
}

function sourceStopped(m: Mission): boolean {
  return (isArchivable(m.status) || m.status === "acknowledged") && m.execution?.state !== "running"
    && !["queued", "running"].includes(m.remote_job?.node_state ?? "");
}
