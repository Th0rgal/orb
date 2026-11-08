import { isHarness } from "./harnesses";
import { CodexSpeedPicker, missionSpeed, requireSpeedSupport } from "./CodexSpeedPicker";
import { localBinding } from "./localAgents";
import { forkMission, shortModelLabel, type CodexServiceTier, type HarnessChoice, type Mission } from "./api";
import { ErrorNotice } from "./ErrorNotice";
import { For, Show, createEffect, createMemo, createSignal, on, onMount } from "solid-js";
import { effortLabel, supportedEfforts } from "./effort";
import { Menu } from "./Menu";
import { usageTelemetry } from "./usageTelemetry";
import {
  destinationStartupOutcome,
  isDefinitiveRefusal,
  observeTransferDestination,
  putTransfer,
  resetTransfersForTest,
  retryTransferArchive,
  stopSource,
  targetKey,
  transferForDestination,
  transferForSource,
  updateTransfer,
  watchTransferDestination,
  type HarnessTransfer,
  type TransferArchiveState,
  type TransferStage,
} from "./forkTransfer";

export {
  destinationStartupOutcome,
  observeTransferDestination,
  resetTransfersForTest,
  retryTransferArchive,
  stopSource,
  transferForDestination,
  transferForSource,
  type HarnessTransfer,
  type TransferArchiveState,
  type TransferStage,
};

export type CloudHandoffTarget = { id: string; label: string; remoteNodeId: string | null };

export function ForkMission(p: {
  mission: Mission;
  choices: HarnessChoice[];
  destination: string;
  targets?: CloudHandoffTarget[];
  targetId?: string;
  onTargetChange?: (id: string) => void;
  anchor?: HTMLElement;
  onOpen?: () => void;
  onClose: () => void;
  onFork: (mission: Mission) => void;
}) {
  const isCloudSource = () => Boolean(p.mission.backend?.startsWith("cloud_"));
  const initialBackend = () => (!isCloudSource() && p.mission.backend ? p.mission.backend : p.choices[0]?.backend.id ?? "");
  const [backend, setBackend] = createSignal(initialBackend());
  const [speed, setSpeed] = createSignal<CodexServiceTier>(missionSpeed(p.mission));
  const [model, setModel] = createSignal(isCloudSource() ? "" : (p.mission.model_override ?? ""));
  const [modelAnchor, setModelAnchor] = createSignal<HTMLButtonElement>();
  const [effortAnchor, setEffortAnchor] = createSignal<HTMLButtonElement>();
  const [busy, setBusy] = createSignal(false), [error, setError] = createSignal("");
  const [localTargetId, setLocalTargetId] = createSignal(p.targetId ?? p.targets?.[0]?.id ?? "");
  createEffect(() => { if (p.targetId !== undefined) setLocalTargetId(p.targetId); });
  const activeTargetId = () => p.targetId !== undefined ? p.targetId : localTargetId();
  const selectedTarget = () => p.targets?.find(t => t.id === activeTargetId()) ?? p.targets?.[0];
  const remoteTargetNodeId = () => isCloudSource() ? (selectedTarget()?.remoteNodeId ?? null) : p.mission.remote_node_id;
  const choices = () => p.choices.find(choice => choice.backend.id === backend())?.models ?? [];
  const unavailable = (id: string) => !!remoteTargetNodeId() && !isHarness(id);
  const menuTitle = () => isCloudSource() ? "Continue in workspace" : "Transfer to another agent";
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
    const targetNodeId = remoteTargetNodeId();
    const sig = retryingUncertain ? current.targetSignature : targetKey(backend(), model(), effort, speed(), targetNodeId);
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
        const nextPayload = {
          backend: backend(),
          model_override: model(),
          model_effort: effort,
          service_tier: backend() === "codex" ? speed() : undefined,
          ...(isCloudSource() && targetNodeId ? { remote_node_id: targetNodeId } : {}),
          idempotency_key: pendingKey,
        };
        putTransfer({
          sourceId: p.mission.id,
          targetSignature: sig,
          payload: nextPayload,
          stage: "preparing",
          archiveState: "idle",
        });
        if (backend() === "codex") await requireSpeedSupport(model(), speed(), undefined, !!localBinding(p.mission.id));
        await stopSource(p.mission.id);
        payload = nextPayload;
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
  const effectiveDestination = () => selectedTarget()?.label ?? p.destination;

  return <Menu label={menuTitle()} class="fork-harnesses" anchor={p.anchor} placement={p.anchor ? "right-start" : "top-start"} busy={busy()} onClose={() => { if (!busy()) p.onClose(); }}>
    <Show when={!p.anchor}><div class="menu-group">{menuTitle()}</div></Show>
    <Show when={isCloudSource() && (p.targets?.length ?? 0) > 1}>
      <div class="menu-group">Destination</div>
      <For each={p.targets ?? []}>{target => <button type="button" class={`menu-item ${selectedTarget()?.id === target.id ? "on" : ""}`} role="menuitemradio" aria-checked={selectedTarget()?.id === target.id} disabled={busy() || lockedSubmitted()}
        onClick={() => { if (!busy() && !lockedSubmitted()) { setLocalTargetId(target.id); setEffortAnchor(undefined); setModelAnchor(undefined); p.onTargetChange?.(target.id); } }}>
        {target.label}
      </button>}</For>
      <div class="menu-sep" />
    </Show>
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
          title={isCloudSource() ? `Continue with ${shortModelLabel(choice.label)} · fresh workspace on ${effectiveDestination()}` : `Transfer to ${shortModelLabel(choice.label)} · same workspace on ${effectiveDestination()}`}
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
    <Show when={busy()}><div class="menu-group" role="status">{isCloudSource() ? "Starting workspace…" : "Transferring…"}</div></Show>
  </Menu>;
}
