import { missionAssignedNode, missionNode, nodeLabel } from "../machines/nodes";
import { followProjectFolder, seedDelivered, seededPrompt } from "../localFolder";
import { canForceSlot, executionPhaseLabel, isArchived, isFailedStatus, isLive, isRunning, isSettingsIdle, isWorking, remoteJobEnded } from "../missionStatus";
import { errorText, log, swallow } from "../log";
import { flushClientLink } from "../clientLink";
import {CodexSpeedPicker, missionSpeed} from '../CodexSpeedPicker';
import { MissionClaudePermission } from "../ClaudePermissionPicker";
import { ConfirmDialog } from "../Dialog";
import { Picker } from "../Picker";
import { Popover } from "../Popover";
import { RemoteQueue, type RemoteQueueHandle } from "../RemoteQueue";
import { MissionCyber, getCyber, requireCyberSupport } from "../cyberAccess";
import { EMPTY_GOAL_ERROR, goalDraft } from "../goal";
import {NextReminder} from "../AutomaticReminder";
import { LazyCloudConversation, peekCloudAgentsModule } from "../cloudAgentsLoader";
import {QueuedMessages} from "../QueuedMessages";
import {enqueueLocalMessage,queuedLocalMessages,acceptedLocalMessages,forgetAcceptedLocalMessages,sendQueuedNow,resumePrompt} from "../localMessageQueue";
import {createQueuedEdit} from "../queuedEdit";
import {messagePresentation} from "../messagePresentation";
import {createPlanProgress, type PlanProgressData} from "../PlanProgress";
import { SideQuestions, type SideQuestionsHandle } from "../SideQuestionPanel";
import { AgentActivity, activityShouldCollapse } from "../AgentActivity";
import { localRunKnown } from "../localAgents";
const ChangeMachine = lazy(() => import("../ChangeMachine").then(module => ({ default: module.ChangeMachine })));
const preloadMachineDestinations = (id: string) => { void import("../ChangeMachine").then(m => m.preloadMachineDestinations(id)); };
import { adoptTransferredWorkspace } from "../machineTransfer";
import { NativeInteraction } from "../NativeInteraction";
import { imagePrompt, stageLocalImages, stageRemoteImages, type DraftImage } from "../imageAttachments";
import { ErrorToast } from "../toast";
import { MissionFailure, LaunchStatus, MissionPending, missionPhase, rememberLaunch, recalledLaunch, missionDestination, withInitialPrompt, launchError, missionGoal, dockModelLabel, type LaunchReceipt } from "../missionLaunch";
import { chipToAttachment, loadAttachItems, mentionedChips, type AttachChip } from "../attach";
import { shallowEqual } from "../poll";
import { Show, Suspense, batch, createMemo, createSignal, createEffect, lazy, on, onCleanup, onMount } from "solid-js";
import { Portal } from "solid-js/web";
import * as Ic from "../icons";
import { observeTransferDestination, stopSource, transferForDestination } from "../forkTransfer";
const ForkMission = lazy(() => import("../ForkMission").then(module => ({ default: module.ForkMission })));
import { forkSource } from "../missionTree";
import { fullToolCall, heldAfterHistory, isMultiplexSyncActive, type StreamEvent } from "../stream";
import { localActivitiesToStreamItems } from "../workModel";
import { Chapters } from "../Chapters";
import { TurnRecap } from "../TurnRecap";
import { Transcript, UserTurn, applyStreamEvent, applyStreamEvents, type StreamItem } from "../Transcript";
import { cacheRemember } from "../pageCache";
import { antigravityBaseModel, defaultEffortLabel, effortLabel, normalizeEffort, supportedEfforts } from "../effort";
import {
  applyLiveEventsToTranscriptCache,
  applyWarmMissionPatch,
  attachMissionStream,
  clearWarmMissionSettingsPatch,
  extractMissionSettingsPatch,
  hasFreshNetworkTranscript,
  isMissionDirtyWhileUnfocused,
  isMissionWarmLive,
  loadOlderTranscript,
  loadTranscript,
  peekReadyTranscript,
  peekTranscript,
  peekTranscriptHeight,
  prepareTranscriptSearch,
  putTranscript,
  putTranscriptHeight,
  putTranscriptItems,
  refreshTranscript,
  retainTranscript,
  transcriptVersion,
} from "../missionCache";
import { ConversationSkeleton, DelayedTranscriptSkeleton, ActivitySkeleton } from "../Skeleton";
import { visibleTranscript, removeUsers, mapUsers, reuseUnchanged } from "../transcriptModel";
import { pollWhileVisible } from "../poll";
import { contextPct, contextWindow, estimateTokens, formatTokens } from "../missionContext";
import {
  bindWorkspace,
  localBinding,
  localLiveText,
  localActivities,
  localFailure,
  recordLocalFailure,
  localRunActive,
  reconcileLocalRun,
  materializeMentions,
  prepareProjectSkills,
  refreshLocalAgents,
  stopLocal,
  writeLocalFiles,
  listMissionCheckpoints,
  restoreMissionCheckpoint,
  type CheckpointMeta,
} from "../localAgents";
import { timed } from "../diagnostics";
import {
  getMission,
  isClientPlacement,
  isConnected,
  isMissionParticipant,
  modelPickerItems,
  shortModelLabel,
  cancelMission,
  forceMissionSlot,
  setClientMissionStatus,
  sendMissionMessage,
  ApiError,
  MessageRejectedError,
  connectionVersion,
  updateMissionSettings,
  type Mission,
  forkMission,
} from "../api";

import { harnessChoices, refreshHarnessChoices, refreshNodeAntigravityModels } from "../harnessPick";
import { Composer, floatingDock } from "../composer/Composer";
import { createPinnedScroll } from "./pinnedScroll";
import { JumpToLatest } from "./JumpToLatest";
import { deliverInOrder } from "./sendQueue";
import { missionActivity, beginHandoff, endHandoff, missionHandoff } from "../missionStatus";
import { createHandoffTracker } from "./handoff";
import { createOptimisticList } from "./optimisticList";
import {
  normalizeFollowupPrompt,
  stepFollowupEnqueueOptimistic,
  stepFollowupPollReconcile,
  stepFollowupTurnReconcile,
} from "../followupQueueState";
import { notify } from "../toast";
import { usageTelemetry } from "../usageTelemetry";
import { networkHealth, networkHealthSnapshot } from "../networkHealth";
import { fulfillSearchTarget, hasPendingSearchTarget, pendingSearchTarget } from "../searchTarget";

const inflightSettings = new Map<string, Promise<unknown>>();
function trackMissionSettings<T>(missionId: string, request: Promise<T>): Promise<T> {
  clearWarmMissionSettingsPatch(missionId);
  const prev = inflightSettings.get(missionId) ?? Promise.resolve();
  const chained = prev.catch(() => undefined).then(() => request);
  const tracked = chained.then(() => undefined, () => undefined).finally(() => {
    if (inflightSettings.get(missionId) === tracked) inflightSettings.delete(missionId);
  });
  inflightSettings.set(missionId, tracked);
  return chained;
}
export function mergeIncomingMission(prev: Mission | null, incoming: Mission): Mission {
  if (!prev || prev.id !== incoming.id) return incoming;
  const history = incoming.history?.length ? incoming.history : prev.history;
  const prevTs = Date.parse(prev.updated_at || "");
  const nextTs = Date.parse(incoming.updated_at || "");
  if (!Number.isNaN(prevTs) && !Number.isNaN(nextTs) && nextTs < prevTs) {
    return prev.history === history ? prev : { ...prev, history };
  }
  const staleActiveEndedJob =
    !isLive(prev.status) &&
    isLive(incoming.status) &&
    !!incoming.remote_job &&
    remoteJobEnded(incoming.remote_job) &&
    (!prev.remote_job?.job_id || prev.remote_job.job_id === incoming.remote_job.job_id);
  const merged = staleActiveEndedJob
    ? {
        ...prev,
        ...incoming,
        history,
        status: prev.status,
        terminal_reason: prev.terminal_reason ?? incoming.terminal_reason,
        status_message: prev.status_message ?? incoming.status_message,
      }
    : { ...prev, ...incoming, history };
  if (!inflightSettings.has(incoming.id)) return merged;
  return {
    ...merged,
    backend: prev.backend,
    agent: prev.agent,
    model_override: prev.model_override,
    model_effort: prev.model_effort,
    fast_mode: prev.fast_mode,
    service_tier: prev.service_tier,
    config_profile: prev.config_profile,
  };
}

function MissionDock(p: {
  mission: Mission | null;
  items: StreamItem[];
  usedTokens?: number;
  destination: string;
  syncing?: boolean;
  onMission?: (mission: Mission, authoritative?: boolean) => void;
  onError?: (message: string) => void;
  onFork?: (mission: Mission) => void;
}) {
  const [machineOpen, setMachineOpen] = createSignal(false);
  const [forkOpen, setForkOpen] = createSignal(false);
  const used = createMemo(() => p.usedTokens ?? estimateTokens(p.items));
  const windowSize = () => contextWindow(p.mission?.backend);
  const pct = () => contextPct(used(), windowSize());
  const [open, setOpen] = createSignal(false);
  const [modelOpen, setModelOpen] = createSignal(false);
  const [effortOpen, setEffortOpen] = createSignal(false);
  const [saving, setSaving] = createSignal(false);
  const catalogMachine = () => p.mission && localBinding(p.mission.id) ? "local" : p.mission?.remote_node_id ?? "core";
  const choice = () => harnessChoices(catalogMachine()).find((c) => c.backend.id === p.mission?.backend);
  const harnessName = () => choice()?.backend.name ?? p.mission?.backend ?? "";
  const modelId = () => (p.mission?.backend === "antigravity" ? antigravityBaseModel(p.mission?.model_override) : p.mission?.model_override) || "";
  const modelLabel = createMemo(() => {
    const id = modelId();
    const m = choice()?.models.find((x) => x.value === id || (p.mission?.backend === "antigravity" && antigravityBaseModel(x.value) === id));
    if (m) return dockModelLabel(harnessName(), shortModelLabel(m.label));
    return id ? dockModelLabel(harnessName(), shortModelLabel(id)) : "Default";
  });
  // Memos: a running mission is replaced on each poll; unchanged labels must
  // not rewrite the dock's attributes.
  const idle = createMemo(() => isSettingsIdle(p.mission?.status));
  const participant = createMemo(() => isMissionParticipant(p.mission));
  const models = () => choice()?.models ?? [];
  const canChangeModel = () => !participant() && !!p.mission && (models().length > 1 || (models().length === 1 && models()[0].value !== modelId()));
  // The mission's own stored effort, normalized against its harness: a mission
  // created before an effort was offered simply has none.
  const effort = () => normalizeEffort(p.mission?.model_effort, p.mission?.backend);
  const efforts = () => supportedEfforts(p.mission?.backend);
  // Effort can change during a turn: a running Claude session applies it at
  // once, any other mission from its next turn.
  const canChangeEffort = () => !participant() && !!p.mission && efforts().length > 0;
  const pickModel = async (value: string) => {
    const m = p.mission;
    if (!m || value === modelId() || saving()) { setModelOpen(false); return; }
    const previousModel = m.model_override;
    const previousUpdatedAt = m.updated_at;
    const optimisticAt = new Date(Math.max(Date.now(), Date.parse(m.updated_at || "") + 1 || Date.now())).toISOString();
    setSaving(true);
    setModelOpen(false);
    p.onMission?.({ ...m, model_override: value || null, updated_at: optimisticAt });
    try {
      const updated = await trackMissionSettings(m.id, updateMissionSettings(m.id, { model_override: value }));
      const latest = p.mission && p.mission.id === m.id ? p.mission : m;
      p.onMission?.(
        {
          ...latest,
          backend: updated.backend ?? latest.backend,
          agent: updated.agent ?? latest.agent,
          model_override: updated.model_override ?? null,
          model_effort: updated.model_effort ?? latest.model_effort,
          fast_mode: updated.fast_mode ?? latest.fast_mode,
          service_tier: updated.service_tier ?? latest.service_tier,
          config_profile: updated.config_profile ?? latest.config_profile,
          session_id: updated.session_id ?? latest.session_id,
          updated_at: updated.updated_at ?? latest.updated_at,
        },
        true,
      );
    } catch (e) {
      const latest = p.mission && p.mission.id === m.id ? p.mission : m;
      const revertedAt = latest.updated_at === optimisticAt ? previousUpdatedAt : latest.updated_at;
      p.onMission?.({ ...latest, model_override: previousModel, updated_at: revertedAt }, true);
      p.onError?.(e instanceof Error && e.message.includes("409") ? "Stop the current turn before switching models." : launchError(e));
    } finally { setSaving(false); }
  };
  /** Next-turn effort. "" is the core's documented clear back to the backend
   * default (`normalize_string_patch` trims it to a null). */
  const pickEffort = async (value: string) => {
    const m = p.mission;
    if (!m || value === (effort() ?? "") || saving()) { setEffortOpen(false); return; }
    const previousEffort = m.model_effort;
    const previousUpdatedAt = m.updated_at;
    const optimisticAt = new Date(Math.max(Date.now(), Date.parse(m.updated_at || "") + 1 || Date.now())).toISOString();
    setSaving(true);
    setEffortOpen(false);
    p.onMission?.({ ...m, model_effort: value || null, updated_at: optimisticAt });
    try {
      const updated = await trackMissionSettings(m.id, updateMissionSettings(m.id, { model_effort: value }));
      const latest = p.mission && p.mission.id === m.id ? p.mission : m;
      p.onMission?.(
        {
          ...latest,
          backend: updated.backend ?? latest.backend,
          agent: updated.agent ?? latest.agent,
          model_override: updated.model_override ?? latest.model_override,
          model_effort: updated.model_effort ?? null,
          fast_mode: updated.fast_mode ?? latest.fast_mode,
          service_tier: updated.service_tier ?? latest.service_tier,
          config_profile: updated.config_profile ?? latest.config_profile,
          session_id: updated.session_id ?? latest.session_id,
          updated_at: updated.updated_at ?? latest.updated_at,
        },
        true,
      );
    } catch (e) {
      const latest = p.mission && p.mission.id === m.id ? p.mission : m;
      const revertedAt = latest.updated_at === optimisticAt ? previousUpdatedAt : latest.updated_at;
      p.onMission?.({ ...latest, model_effort: previousEffort, updated_at: revertedAt }, true);
      p.onError?.(e instanceof Error && e.message.includes("409") ? "Stop the current turn before switching effort." : launchError(e));
    } finally { setSaving(false); }
  };
  // Warm the machine list once the conversation is idle so the menu opens filled.
  // A memo, not a bare accessor: `on` re-runs whenever its source re-runs, and
  // `p.mission` is replaced by every refresh even when the id is unchanged.
  const missionId = createMemo(() => p.mission?.id);
  const [showReconnecting, setShowReconnecting] = createSignal(false);
  createEffect(() => {
    if (networkHealth() === "reconnecting") {
      const timer = setTimeout(() => setShowReconnecting(true), 650);
      onCleanup(() => clearTimeout(timer));
    } else {
      setShowReconnecting(false);
    }
  });
  createEffect(on(missionId, id => {
    if (!id || participant()) return;
    if (catalogMachine() === "local") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(catalogMachine());
    const timer = setTimeout(() => preloadMachineDestinations(id), 1500);
    onCleanup(() => clearTimeout(timer));
  }));
  return (
    <div class="under">
      <div class="fork-anchor">
        <Show
          when={!participant()}
          fallback={
            <span class="under-loc">
              <Show when={p.destination !== "Core" && p.destination !== "This computer"} fallback={<Ic.LaptopIcon size={13} />}><Ic.CloudIcon /></Show>
              {p.destination}
            </span>
          }
        >
          <button class="under-loc fork-trigger" title="Change machine…" aria-label="Change machine" aria-haspopup="menu" aria-expanded={machineOpen()} disabled={!p.mission} onPointerEnter={() => p.mission && preloadMachineDestinations(p.mission.id)} onFocus={() => p.mission && preloadMachineDestinations(p.mission.id)} onClick={() => { setForkOpen(false); setMachineOpen(!machineOpen()); }}>
            <Show when={p.destination !== "Core" && p.destination !== "This computer"} fallback={<Ic.LaptopIcon size={13} />}><Ic.CloudIcon /></Show>
            {p.destination} <Ic.ChevronDown size={10} />
          </button>
          <Show when={machineOpen() && p.mission}>{m => <ChangeMachine mission={m()} choices={harnessChoices()} choicesFor={machine => harnessChoices(machine.kind === "client" ? "local" : machine.kind === "node" ? machine.id : "core")} onDestination={machine => { if (machine.kind === "client") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(machine.kind === "node" ? machine.id : "core"); }} onClose={() => setMachineOpen(false)} onMoved={mission => p.onMission?.(mission)} />}</Show>
        </Show>
      </div>
      <Show when={harnessName()}>
        <span class="under-sep" aria-hidden="true">·</span>
        <div class="fork-anchor">
          <Show when={!participant()} fallback={<span class="under-harness">{harnessName()}</span>}>
            <button class="under-harness fork-trigger" title="Transfer to another agent" aria-label="Transfer to another agent" onClick={() => setForkOpen(true)}>{harnessName()} <Ic.ChevronDown size={10} /></button>
            <Show when={forkOpen() && p.mission}>{m => <Suspense><ForkMission mission={m()} choices={harnessChoices(catalogMachine())} onOpen={() => { if (catalogMachine() === "local") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(catalogMachine()); }} destination={p.destination} onClose={() => setForkOpen(false)} onFork={forked => { setForkOpen(false); p.onFork?.(forked); }} /></Suspense>}</Show>
          </Show>
        </div>
        <span class="under-sep" aria-hidden="true">·</span>
        <div class="under-model-wrap">
          <Show
            when={canChangeModel()}
            fallback={
              <span class="under-model" title={modelLabel()}>
                {modelLabel()}
              </span>
            }
          >
            <button
              class={`under-model ${modelOpen() ? "on" : ""}`}
              disabled={saving()}
              title={isWorking(p.mission?.status) ? "Model · applies from the next turn" : "Model for the next turn"}
              onClick={() => {
                const opening = !modelOpen();
                setModelOpen(opening);
                if (opening && isConnected()) void refreshHarnessChoices();
                if (opening) {
                  if (catalogMachine() === "local") void refreshLocalAgents(false);
                  else void refreshNodeAntigravityModels(catalogMachine());
                }
              }}
            >
              {modelLabel()} <Ic.ChevronDown size={10} />
            </button>
            <Show when={modelOpen()}>
              <Picker label="Models" searchLabel="Search models" placement="top-start" selected={modelId()}
                items={modelPickerItems(models())}
                onClose={() => setModelOpen(false)} onSelect={value => void pickModel(value)}/>

            </Show>
          </Show>
        </div>
        <Show when={efforts().length > 0}>
          <span class="under-sep" aria-hidden="true">·</span>
          <div class="under-effort-wrap under-model-wrap">
            <Show
              when={canChangeEffort()}
              fallback={
                <span class="under-model" title={`Effort: ${effortLabel(effort(),p.mission?.backend,p.mission?.model_override)}`}>
                  {effortLabel(effort(),p.mission?.backend,p.mission?.model_override)}
                </span>
              }
            >
              <button
                class={`under-model ${effortOpen() ? "on" : ""}`}
                disabled={saving()}
                title={idle() ? "Reasoning effort for the next turn" : p.mission?.backend === "claudecode" ? "Reasoning effort · applies to the running session" : "Reasoning effort · applies from the next turn"}
                aria-label={`Reasoning effort: ${effortLabel(effort(),p.mission?.backend,p.mission?.model_override)}`}
                onClick={() => setEffortOpen(!effortOpen())}
              >
                {effortLabel(effort(),p.mission?.backend,p.mission?.model_override)} <Ic.ChevronDown size={10} />
              </button>
              <Show when={effortOpen()}>
                <Picker label="Reasoning effort" searchable={false} placement="top-start" selected={effort() ?? ""}
                  items={[{id:"",label:defaultEffortLabel(p.mission?.backend,p.mission?.model_override)},...efforts().map(e => ({id:e,label:effortLabel(e)}))]}
                  onClose={() => setEffortOpen(false)} onSelect={value => void pickEffort(value)}/>

              </Show>
            </Show>
          </div>
        </Show>
        <Show when={p.mission?.backend === "codex"}>
          <span class="under-sep" aria-hidden="true">·</span>
          <CodexSpeedPicker model={modelId()} value={missionSpeed(p.mission!)} missionId={p.mission!.id} local={catalogMachine()==="local"} disabled={saving() || participant()} onChange={tier=>{
            const mission=p.mission; if(!mission||saving()||participant())return;
            setSaving(true);
            void trackMissionSettings(mission.id, updateMissionSettings(mission.id,{service_tier:tier})).then(updated=>{if(missionSpeed(updated)!==tier)throw new Error('The backend did not save the selected speed. Update it before retrying.');const latest=p.mission&&p.mission.id===mission.id?p.mission:mission;p.onMission?.({...latest,service_tier:updated.service_tier,fast_mode:updated.fast_mode??latest.fast_mode,session_id:updated.session_id??latest.session_id,updated_at:updated.updated_at??latest.updated_at}, true);}).catch(e=>p.onError?.(launchError(e))).finally(()=>setSaving(false));
          }}/>
        </Show>
        <Show when={p.mission?.backend === "codex" && !participant()}><MissionCyber mission={p.mission!} onError={p.onError}/></Show>
        <Show when={p.mission?.backend === "claudecode" && !participant() ? p.mission : undefined}>{m => <MissionClaudePermission mission={m()} onMission={p.onMission} onError={p.onError} />}</Show>
      </Show>
      <Show when={isConnected() && ((networkHealth() === "reconnecting" && showReconnecting()) || (networkHealth() === "slow" && (p.syncing || isWorking(p.mission?.status))))}>
        <span
          class={`under-link-pill ${networkHealth()}`}
          role="status"
          title={
            networkHealth() === "reconnecting"
              ? "Reconnecting live sync — messages and output are buffered safely"
              : `High network latency (${networkHealthSnapshot().srttMs} ms) — prioritizing this conversation`
          }
        >
          <i aria-hidden="true" />
          <span class="under-link-label">
            {networkHealth() === "reconnecting" ? "Reconnecting" : "Slow link"}
          </span>
        </span>
      </Show>
      <div class="ctx-wrap">
        <button class="ctx" title="Context used" onClick={() => setOpen(!open())}>
          <Ic.ContextRing pct={pct()} /> {pct()}%
        </button>
        <Show when={open()}>
          <Popover class="ctx-panel" label="Context" placement="top-end" onClose={() => setOpen(false)}>
            <div class="ctx-panel-h">
              <span>Context</span>
              <span class="ctx-panel-meta">{pct()}% · ~{formatTokens(used())} / {formatTokens(windowSize())}</span>
            </div>
            <div class="ctx-bar" aria-hidden="true">
              <i style={{ width: `${pct()}%` }} />
            </div>
            <div class="ctx-row">
              <span>Conversation</span>
              <span>{formatTokens(used())}</span>
            </div>
          </Popover>
        </Show>
      </div>
    </div>
  );
}

/** `p.initial` re-runs on every sidebar poll (any mission changing replaces the
 * list) and each merge builds a new object; an unchanged mission must not
 * notify the whole conversation view, which rewrote dock/badge attributes and
 * re-ran catalog loads several times a minute. */
const sameMission = (a: Mission | null, b: Mission | null) => a === b || (!!a && !!b && shallowEqual(a, b));

export function MissionView(p: Parameters<typeof NativeMissionView>[0]) {
  const [resolved, setResolved] = createSignal<Mission | null>(
    applyWarmMissionPatch(p.initial, { preserveSettings: Boolean(p.id && inflightSettings.has(p.id)) }),
    { equals: sameMission },
  );
  const [error, setError] = createSignal("");
  createEffect(() => {
    const init = p.initial;
    if (init) {
      setResolved(prev =>
        applyWarmMissionPatch(mergeIncomingMission(prev, init), {
          preserveSettings: inflightSettings.has(init.id),
        }),
      );
    }
  });
  const handleMission = (next: Mission | null, authoritative = false) => {
    if (next) {
      if (authoritative) clearWarmMissionSettingsPatch(next.id);
      setResolved(prev => (authoritative ? { ...prev, ...next, history: next.history?.length ? next.history : (prev?.history ?? []) } : mergeIncomingMission(prev, next)));
    }
    p.onMission?.(next, authoritative);
  };
  onMount(() => {
    if (p.id) void loadTranscript(p.id).catch(swallow("mission.loadTranscript", { mission: p.id }));
    if (!resolved()) void getMission(p.id, { includeHistory: false }).then(setResolved).catch(e => setError(String(e)));
  });
  const canRenderBody = () => Boolean(resolved()) || (!error() && (transcriptVersion(), Boolean(peekTranscript(p.id)?.items.length)));
  return <Show when={canRenderBody()} fallback={<><ErrorToast error={error()} title="Couldn’t load the conversation" action={{ label: "Retry", run: () => { setError(""); return getMission(p.id, { includeHistory: false }).then(setResolved).catch(e => setError(String(e))); } }} onDismiss={() => setError("")} /><ConversationSkeleton /></>}><Show when={resolved()?.backend?.startsWith("cloud_")} fallback={<NativeMissionView {...p} initial={resolved() ?? undefined} onMission={handleMission} />}>{(() => { const mod = peekCloudAgentsModule(); return mod ? <mod.CloudConversation id={p.id} onMission={handleMission} onOpenMission={p.onFork} /> : <Suspense fallback={<ConversationSkeleton />}><LazyCloudConversation id={p.id} onMission={handleMission} onOpenMission={p.onFork} /></Suspense>; })()}</Show></Show>;
}

export function NativeMissionView(p: { id: string; launch?:LaunchReceipt; launchError?:string; onRetryLaunch?:()=>void; onPlan?: (id:string,data:PlanProgressData | undefined)=>void; onContext?: (id: string, pct: number | null) => void; initial?: Mission; onMission?: (mission: Mission | null, authoritative?: boolean) => void; onFork?: (mission: Mission) => void }) {
  const boundMissionId = p.id;
  const staleMission = () => disposed || Boolean(boundMissionId && p.id !== boundMissionId);
  const receipt = p.launch ?? recalledLaunch(p.id);
  let disposed=false;
  onCleanup(()=>{disposed=true;});
  createEffect(()=>{if(p.id)onCleanup(retainTranscript(p.id));});
  const cached = p.id ? peekReadyTranscript(p.id) ?? (peekTranscript(p.id)?.detailsPending ? peekTranscript(p.id) : undefined) : undefined;
  const [mission, setMission] = createSignal<Mission | null>(
    applyWarmMissionPatch(p.initial, { preserveSettings: Boolean(p.id && inflightSettings.has(p.id)) }),
    { equals: sameMission },
  );
  const participant = createMemo(() => isMissionParticipant(mission()));
  let authoritativeOnce = false;
  const applyDockMission = (next: Mission, authoritative = false) => {
    clearWarmMissionSettingsPatch(next.id);
    authoritativeOnce = authoritative;
    setMission(prev => (authoritative ? { ...prev, ...next, history: next.history?.length ? next.history : (prev?.history ?? []) } : next));
  };
  createEffect(()=>{
    const init = p.initial;
    if (init) {
      setMission(prev =>
        applyWarmMissionPatch(mergeIncomingMission(prev, init), {
          preserveSettings: inflightSettings.has(init.id),
        }),
      );
    }
  });
  createEffect(() => {
    const m = mission();
    const auth = authoritativeOnce;
    authoritativeOnce = false;
    p.onMission?.(m, auth);
  });
  onCleanup(() => p.onMission?.(null));
  const [items, setItems] = createSignal<StreamItem[]>(cached?.items ?? []);
  const [awaiting, setAwaiting] = createSignal(!cached || !!cached.detailsPending);
  createEffect(on(transcriptVersion, () => {
    if (!awaiting() || staleMission()) return;
    const ready = peekReadyTranscript(p.id);
    if (ready) {
      setItems(reuseUnchanged(items(), ready.items));
      setAwaiting(false);
      return;
    }
    const preview = peekTranscript(p.id);
    if (preview?.detailsPending) {
      const hadItems = items().length > 0;
      setItems(reuseUnchanged(items(), preview.items));
      if (!hadItems && preview.items.length > 0 && !hasPendingSearchTarget(p.id)) {
        queueMicrotask(() => { if (!disposed && !hasPendingSearchTarget(p.id)) landAtBottom(); });
      }
    }
  }));
  const [error, setError] = createSignal<string | null>(null);
  const [queueError, setQueueError] = createSignal<string | null>(cached?.queueError ?? null);
  const [sendError, setSendError] = createSignal<string | null>(null);
  const [checkpoints, setCheckpoints] = createSignal<CheckpointMeta[]>([]);
  const [pendingCheckpointRevert, setPendingCheckpointRevert] = createSignal<CheckpointMeta | null>(null);
  const [revertingCheckpoint, setRevertingCheckpoint] = createSignal(false);
  createEffect(() => {
    const id = p.id;
    const cwd = localBinding(id)?.cwd ?? mission()?.working_directory ?? "";
    const status = mission()?.status;
    if (!id || !cwd.trim()) {
      setCheckpoints([]);
      return;
    }
    let current = true;
    const timer = setTimeout(() => {
      if (!current) return;
      void listMissionCheckpoints(id, cwd)
        .then((rows) => { if (current && status !== undefined) setCheckpoints(rows); })
        .catch(() => { if (current) setCheckpoints([]); });
    }, 80);
    onCleanup(() => {
      current = false;
      clearTimeout(timer);
    });
  });
  const confirmRevertCheckpoint = async () => {
    const target = pendingCheckpointRevert();
    const id = boundMissionId || p.id;
    if (!target || !id || revertingCheckpoint()) return;
    setRevertingCheckpoint(true);
    try {
      const cwd = localBinding(id)?.cwd ?? mission()?.working_directory ?? undefined;
      await restoreMissionCheckpoint(id, target.ref, cwd);
      setPendingCheckpointRevert(null);
      window.dispatchEvent(new Event("orb:refresh"));
    } catch (e) {
      setSendError(e instanceof Error ? e.message : String(e));
    } finally {
      setRevertingCheckpoint(false);
    }
  };
  const drafts = createOptimisticList<{id:ReturnType<typeof crypto.randomUUID>;text:string; images:DraftImage[];waiting:boolean;postedAfterSeq:number;failed?:boolean;retry?:()=>void}>();
  const optimisticList = drafts.items;
  const optimistic = drafts.first;
  let sendingIds:ReturnType<typeof crypto.randomUUID>[]=[];
  let sendChain: Promise<void> = Promise.resolve();
  const countDeliveredUserTurns = () => {
    let count = 0;
    for (const item of items()) if (item.kind === "user" && !item.queued) count++;
    return count;
  };
  let pendingBeforeSendId: ReturnType<typeof crypto.randomUUID> | null = null;
  const beginSend = (draft:{text:string;images:DraftImage[];retry?:()=>void}|null) => {
    if (!draft) {
      if (pendingBeforeSendId) {
        const cancelledId = pendingBeforeSendId;
        pendingBeforeSendId = null;
        sendingIds = sendingIds.filter(id => id !== cancelledId);
        drafts.remove(cancelledId);
        if (p.id) endHandoff(p.id, cancelledId);
      }
      return;
    }
    const prevErr = sendError();
    const firstOpt = optimistic();
    const reused = Boolean(prevErr && firstOpt?.text === draft.text);
    const nextId = reused ? firstOpt!.id : crypto.randomUUID();
    const postedAfterSeq = reused ? firstOpt!.postedAfterSeq : countDeliveredUserTurns();
    const enqueueStep = stepFollowupEnqueueOptimistic({
      serverRev: 1,
      clientMsgId: nextId,
      trackedMsgId: reused ? undefined : firstOpt?.id,
      postedAfterSeq,
      alreadyDelivered: items().some(i => i.kind === "user" && !i.queued && i.messageId === nextId),
    });
    if (!enqueueStep.admitted && !reused) return;
    pendingBeforeSendId = nextId;
    sendingIds.push(nextId);
    setSendError(null);
    const waiting = busy() || drafts.inFlightOtherThan(nextId);
    drafts.upsert({ ...draft, id: nextId, waiting, postedAfterSeq });
    if (!waiting) {
      if (p.id && !clientPlaced() && !editingQueued()) beginHandoff(p.id, nextId);
      pin.pin();
    }
  };
  createEffect(()=>{
    const userItems = items().filter((i): i is Extract<StreamItem, { kind: "user" }> => i.kind === "user");
    const ids=new Set([
      ...userItems.map(i=>i.messageId??''),
      ...remoteQueuedIds(),
      ...queuedLocalMessages(p.id).map(row=>row.id),
      ...acceptedLocalMessages(p.id).map(row=>row.id),
    ]);
    let turnSeq = 0;
    for (const u of userItems) {
      if (u.queued) continue;
      turnSeq++;
      const normalizedTurn = normalizeFollowupPrompt(u.text);
      for (const opt of optimisticList()) {
        if (ids.has(opt.id)) continue;
        const step = stepFollowupTurnReconcile({
          clientMsgId: opt.id,
          deliveredMsgId: u.messageId ?? null,
          postedAfterSeq: opt.postedAfterSeq,
          turnSeq,
          contentMatched: normalizeFollowupPrompt(opt.text) === normalizedTurn,
        });
        if (step.retiredNow) ids.add(opt.id);
      }
    }
    // Remove the projection only after its canonical identity is visible.
    if (drafts.reconcile(ids) && !optimisticList().some(item => item.failed)) {
      if (retryMessage && ids.has(retryMessage.id)) retryMessage = null;
      setSendError(null);
    }
    forgetAcceptedLocalMessages(ids);
  });
  let sideQuestions: SideQuestionsHandle | undefined;
  let remoteQueue: RemoteQueueHandle | undefined;
  const [sideRevision,setSideRevision] = createSignal<{text:string;append:boolean}>();
  const queuedEdit = createQueuedEdit({setRevision:setSideRevision,onError:message=>setSendError(message)});
  const editingQueued = queuedEdit.editing;
  const sendQueueFromComposer = () => {
    if (editingQueued()) return;
    if (clientPlaced()) {
      if (!queuedLocalMessages(p.id).some(row => row.state === "queued" && row.waiting)) return;
      void sendQueuedNow(p.id).catch(e => setSendError(e instanceof Error ? e.message : String(e)));
      return;
    }
    if (remoteQueue?.hasQueued()) {
      void remoteQueue.sendNow().catch(e => setSendError(e instanceof Error ? e.message : String(e)));
    }
  };
  const editFirstQueued = () => {
    if (editingQueued()) return;
    if (clientPlaced()) {
      const first = queuedLocalMessages(p.id).find(row => row.waiting && row.state === "queued" && !row.error);
      if (first) void queuedEdit.start({ id: first.id, text: first.text });
      return;
    }
    remoteQueue?.editFirst();
  };
  // Waiting messages go first: they are what the user asked for next. With none, the agent continues its work.
  const resume = () => {
    if (queuedLocalMessages(p.id).length) return sendQueuedNow(p.id).catch(e => setSendError(e instanceof Error ? e.message : String(e)));
    return sendMsg(resumePrompt, [], []);
  };
  const [followAttach, setFollowAttach] = createSignal<AttachChip[]>([]);
  // Near the top, or too short to scroll at all (a page of folded tool rows or
  // an incomplete spine), keep fetching older pages: a scroll event alone never
  // fires otherwise. Also respond to upward wheel/key input at scrollTop <= 1.
  const older=(force=false)=>{
    const el=scroller;
    if(!el||hasPendingSearchTarget(p.id))return;
    const ready=peekReadyTranscript(p.id);
    const hasDeliveredUser=items().some(i=>i.kind==="user"&&!i.queued);
    const missingSpine=!hasDeliveredUser||(el.scrollHeight<=el.clientHeight&&ready?.spineComplete===false);
    const short=missingSpine&&el.scrollHeight<=el.clientHeight+800;
    if((force||short||(el.scrollTop<800&&el.scrollHeight>el.clientHeight))&&ready?.hasOlder)void loadOlder().then(()=>requestAnimationFrame(()=>older())).catch(e=>setError(String(e)));
  };
  const onScrollOlder=()=>older(false);
  const pin = createPinnedScroll({ key: () => p.id, onResize: () => older(false), onUpwardAtTop: () => older(true) });
  const { landAtBottom, scrollIfPinned } = pin;
  let scroller: HTMLDivElement | undefined;
  createEffect(()=>{if(p.id)cacheRemember(`m:${p.id}`);});
  pin.observe();
  onMount(() => {
    if (!scroller) return;
    scroller.addEventListener('scroll',onScrollOlder,{passive:true});onCleanup(()=>scroller?.removeEventListener('scroll',onScrollOlder));
  });

  // A stream status is newer than any mission read started before it: such a
  // read (possibly shared with an earlier caller) would put the previous turn's
  // failed status and ended job back for a moment, the red flash after a send.
  let statusSeen = 0;
  const refresh = async (fresh = false) => {
    if(!p.id)return;
    const since = statusSeen;
    try {
      if (mission()?.local_sync_local_only) {
        const local = (await import("../localOrigins").then(m => m.localOrigins(p.id)).catch(() => [])).find(m => m.id === p.id);
        if (local) {
          if (disposed || since !== statusSeen) return;
          setMission(prev => mergeIncomingMission(prev, local));
          setError(null);
          return;
        }
      }
      const next=await getMission(p.id, { fresh, includeHistory: false });
      if(disposed||since!==statusSeen)return;
      setMission(prev => mergeIncomingMission(prev, next));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  // Rebuild the transcript from the stored event log (initial load and
  // resync after stream lag). Stored rows map onto the live event shapes,
  // so the same reducer handles both.
  // Live events that arrive while a replay is in flight would be clobbered
  // by the replay's setItems; hold them and fold them in afterwards.
  const [remoteQueuedIds,setRemoteQueuedIds]=createSignal<string[]>([]);
  const [remoteLiveEdits,setRemoteLiveEdits]=createSignal<{id:string;content:string;at:number}[]>([]);
  let remoteLiveClock=0;
  const reconcileRemoteQueue=(ids:string[])=>{
    const removed=new Set(remoteQueuedIds().filter(id=>!ids.includes(id)));
    setRemoteQueuedIds(ids);
    if(!removed.size)return;
    setItems(previous=>removeUsers(previous,item=>!!item.queued&&!!item.messageId&&removed.has(item.messageId)));
    liveEvents=liveEvents.filter(event=>event.type!=="user_message"||!event.data?.queued||!removed.has(String(event.data?.id)));
    void resync(true);
  };
  let replaying = false;
  const [syncing, setSyncing] = createSignal(false);
  let refreshAgain = false;
  const [refreshing, setRefreshing] = createSignal(false);
  let held: StreamEvent[] = [];
  let liveEvents:StreamEvent[]=[];
  const applyLiveBatch = (evs: StreamEvent[]) => {
    if (!evs.length) return;
    const queuedUpdates: { id: string; content: string; at: number }[] = [];
    for (const ev of evs) {
      if (ev.type === "user_message" && ev.data?.queued === true && typeof ev.data.id === "string" && typeof ev.data.content === "string" && ev.data.id && ev.data.content) {
        queuedUpdates.push({ id: ev.data.id, content: ev.data.content, at: ++remoteLiveClock });
      }
    }
    if (queuedUpdates.length) setRemoteLiveEdits(previous => [...previous, ...queuedUpdates]);
    liveEvents.push(...evs);
    setItems((cur) => {
      const next = timed("reduce event", () => applyStreamEvents(cur, evs));
      applyLiveEventsToTranscriptCache(p.id, evs, next);
      if (next !== cur) {
        queueMicrotask(()=>{if(!disposed){scrollIfPinned();scroller?.dispatchEvent(new Event("orb:transcript-change",{bubbles:true}));}});
      }
      return next;
    });
  };
  const applyLive = (ev: StreamEvent) => applyLiveBatch([ev]);
  const resync = async (fresh = false) => {
    if(disposed||!p.id)return;
    if (replaying) { refreshAgain ||= fresh; return; }
    replaying = true;
    setSyncing(true);
    held = [];
    let history: StreamEvent[] = [];
    try {
      if (mission()?.local_sync_pending) {
        const localPendingRow = (await import("../localOrigins").then(m => m.localOrigins(p.id)).catch(() => [])).find(m => m.id === p.id);
        if (disposed) return;
        if (localPendingRow?.local_sync_pending) {
          const events: StreamEvent[] = localPendingRow.history.filter(row => row.content).map((row, index) => ({
            type: row.role === "user" ? "user_message" : "assistant_message",
            data: { id: `local:${p.id}:${index}`, content: row.content },
          }));
          setItems(reuseUnchanged(items(), applyStreamEvents([], events)));
          setQueueError(null);
          setError(null);
          return;
        }
      }
      const snap = await (fresh ? refreshTranscript(p.id) : loadTranscript(p.id));
      if(disposed)return;
      history = snap.stream;
      liveEvents=heldAfterHistory(history,liveEvents);
      // Absence from a queue snapshot is not proof of delivery: the event
      // logger can lag dequeue. Keep known pending entries until their ID is
      // explicitly delivered, including while a reconnect replay is in flight.
      const queuedUsers: StreamEvent[] = [];
      for (const item of items()) if (item.kind === "user" && item.queued && item.messageId) {
        queuedUsers.push({ type: "user_message", data: { id: item.messageId, content: item.text, queued: true, receipt: item.receipt, attached: item.attached } });
      }
      let next = applyStreamEvents(snap.items, [...liveEvents, ...queuedUsers]);
      next = reuseUnchanged(items(), next);
      setItems(next);
      putTranscript(p.id, { ...snap, items: next });
      setQueueError(snap.queueError ?? null);
      setError(null);
    } catch (e) {
      const local=(await import("../localOrigins").then(m=>m.localOrigins()).catch(()=>[])).find(m=>m.id===p.id);
      if(disposed)return;
      if(local){
        const events:StreamEvent[]=local.history.filter(row=>row.content).map((row,index)=>({type:row.role==="user"?"user_message":"assistant_message",data:{id:`local:${p.id}:${index}`,content:row.content}}));
        setItems(applyStreamEvents([], events));setError(null);
      }else setError(e instanceof Error ? e.message : String(e));
    } finally {
      replaying = false;
      setSyncing(false);
      if(disposed)return;
      setAwaiting(false);
      if (!hasPendingSearchTarget(p.id)) landAtBottom();
      const queued = held;
      held = [];
      applyLiveBatch(heldAfterHistory(history, queued));
      if (refreshAgain) { refreshAgain = false; void resync(true); }
    }
  };

  // A terminal snapshot from either SSE or polling reconciles durable output.
  createEffect(on(() => mission()?.status, (status, prev) => {
    if (p.id && status && prev && prev !== status && !missionPhase({status} as Mission, false).moving) void resync(true);
  }, { defer: true }));

  let olderPending:Promise<void>|undefined;
  const loadOlder=()=>{
    if(olderPending)return olderPending;
    olderPending=(async()=>{
      const snap=await loadOlderTranscript(p.id);
      if(disposed)return;
      const queuedUsers: StreamEvent[] = [];
      for(const item of items())if(item.kind==='user'&&item.queued&&item.messageId)queuedUsers.push({type:'user_message',data:{id:item.messageId,content:item.text,queued:true}});
      setItems(applyStreamEvents(snap.items, [...heldAfterHistory(snap.stream,liveEvents), ...queuedUsers]));
    })().finally(()=>olderPending=undefined);
    return olderPending;
  };
  const needsPrepareSearch=()=>{
    if(!p.id||disposed)return false;
    const ready=peekReadyTranscript(p.id);
    return Boolean(ready?.hasOlder&&!ready.spineComplete);
  };
  const prepareSearch=async(signal:AbortSignal)=>{
    if(!p.id||disposed||signal.aborted||!needsPrepareSearch())return;
    const snap=await prepareTranscriptSearch(p.id,signal);
    if(disposed||signal.aborted)return;
    let next=heldAfterHistory(snap.stream,liveEvents).reduce((state,event)=>applyStreamEvent(state,event),snap.items);
    for(const item of items())if(item.kind==='user'&&item.queued&&item.messageId)next=applyStreamEvent(next,{type:'user_message',data:{id:item.messageId,content:item.text,queued:true}});
    setItems(next);
  };
  // Core rewrites a local run's reply in place and never streams it, so a
  // transcript read mid-run stays partial. Re-read once the native worker
  // (2s cadence) has posted the final snapshot.
  // A memo notifies only on real transitions: rewriting the same inactive
  // state must not rerun the effect and cancel the pending re-reads.
  const localActive = createMemo(() => localRunActive(p.id));
  createEffect(on(localActive, (active, was) => {
    if (active || !was) return;
    const timers = [3000, 8000].map(ms => setTimeout(() => void resync(true), ms));
    onCleanup(() => timers.forEach(clearTimeout));
  }));

  createEffect(on(()=>p.id, id => {
    setRemoteLiveEdits([]);
    if(!id)return;
    const reload = async () => {
      if (refreshing()) return;
      setRefreshing(true);
      try { await Promise.all([refresh(), resync(true)]); }
      finally { setRefreshing(false); }
    };
    window.addEventListener("orb:refresh", reload);
    onCleanup(() => window.removeEventListener("orb:refresh", reload));
    setMission(old =>
      old ? applyWarmMissionPatch(old, { preserveSettings: inflightSettings.has(id) }) : old,
    );
    const warmLiveOnMount = isMissionWarmLive(id);
    const readyOnMount = peekReadyTranscript(id);
    const hasSettledOutputOnMount = (() => {
      if (!readyOnMount) return false;
      const list = readyOnMount.items;
      const lastUser = list.reduce((last, item, idx) => (item.kind === "user" && !item.queued ? idx : last), -1);
      if (lastUser < 0) return false;
      const status = mission()?.status ?? "";
      if (["completed", "done", "awaiting_user", "waiting_user"].includes(status)) {
        return list.slice(lastUser + 1).some((i) => i.kind === "text" && !i.live && !!i.text.trim());
      }
      return true;
    })();
    const cleanStaleOnMount =
      !warmLiveOnMount &&
      Boolean(readyOnMount) &&
      hasSettledOutputOnMount &&
      isMultiplexSyncActive() &&
      !isMissionDirtyWhileUnfocused(id) &&
      !missionPhase(mission(), false).moving;
    if (!mission() || (!warmLiveOnMount && !cleanStaleOnMount)) {
      void refresh();
    }
    // History must load even when the live connection has not opened yet,
    // unless the mission is already WarmLive or clean on an unbroken sync WS.
    let initialReady = true;
    let streamHealthy = warmLiveOnMount;
    const justFetchedFromNetwork = hasFreshNetworkTranscript(id);
    if (warmLiveOnMount || cleanStaleOnMount || justFetchedFromNetwork) {
      queueMicrotask(() => {
        if (!disposed && !hasPendingSearchTarget(p.id)) scrollIfPinned();
      });
    } else {
      void resync(true).then(() => { if (!hasPendingSearchTarget(p.id)) scrollIfPinned(); });
    }
    let stopStream = () => {};
    createEffect(() => {
      if (mission()?.local_sync_pending) {
        streamHealthy = false;
        return;
      }
      const detach = attachMissionStream(p.id, {
        onEvent: (ev) => {
          if (ev.type === "mission_settings_updated") {
            const patch = extractMissionSettingsPatch(ev.data);
            setMission(old => (old ? { ...old, ...patch } : old));
            return;
          }
          if (ev.type === "mission_status_changed" || ev.type === "status") {
            if (ev.type === "mission_status_changed" && typeof ev.data.status === "string") {
              const status = ev.data.status;
              statusSeen++;
              // A new turn started: the previous turn's ended job is history,
              // not a "Remote job stopped" failure, until the fresh read lands.
              setMission(old => ({ ...(old ?? {id:p.id,title:null,history:[],created_at:"",updated_at:""}), status,
                ...(isLive(status) && old?.remote_job && remoteJobEnded(old.remote_job) ? { remote_job: null, terminal_reason: null } : {}),
                status_message: typeof ev.data.summary === "string" ? ev.data.summary : old?.status_message }));
              if (!missionPhase({ status } as Mission, false).moving) void resync(true);
            }
            void refresh(true);
            return;
          }
          if (replaying) held.push(ev);
          else applyLive(ev);
        },
        onLagged: () => void resync(true),
        onReady: () => {
          streamHealthy = true;
          if (initialReady) {
            initialReady = false;
            if (!hasPendingSearchTarget(p.id)) scrollIfPinned();
            return;
          }
          if (!isMissionWarmLive(p.id)) {
            void resync(true).then(() => { if (!hasPendingSearchTarget(p.id)) scrollIfPinned(); });
          }
        },
        onBatch: (evs) => {
          if (replaying) held.push(...evs);
          else applyLiveBatch(evs);
        },
        onDisconnected: () => {
          streamHealthy = false;
        },
      });
      stopStream = detach;
      onCleanup(() => {
        detach();
        if (stopStream === detach) stopStream = () => {};
      });
    });
    // Slow status poll — the stream is authoritative for content, but the
    // composer busy state shouldn't depend on it alone.
    let settledEmptyVerified = false;
    const stopPoll = pollWhileVisible(async () => {
      const wasMoving = missionPhase(mission(), activity()).moving;
      await refresh();
      const nowMoving = missionPhase(mission(), activity()).moving;
      if (nowMoving) settledEmptyVerified = false;
      // Reconcile through completion even if the live stream misses output.
      const transcript = items();
      const lastUser = transcript.reduce((last, item, index) => item.kind === "user" && !item.queued ? index : last, -1);
      const status = mission()?.status ?? "";
      const isCompletedStatus = status === "completed" || status === "done";
      // Partial text, thinking, and tools are activity, not a final reply; a prior
      // interrupted turn's error row is not a final reply once completed.
      const hasFinalReply = transcript.slice(lastUser + 1).some(item =>
        (item.kind === "text" && !item.live && !!item.text.trim()) || (!isCompletedStatus && item.kind === "error"));
      const waitingForReply = ["awaiting_user", "waiting_user", "completed", "done"].includes(status)
        && !hasFinalReply
        && (viewItems().some(item => item.kind === "user" && !item.queued) || (!settledEmptyVerified && transcript.length === 0));
      // When `streamHealthy` is true and the mission is still actively moving,
      // live events are already streaming over `/api/control/sync` — re-paging
      // 400 KB raw event batches every 10 s would saturate slow links.
      const stoppedMoving = wasMoving && !nowMoving;
      if (((wasMoving || nowMoving) && !streamHealthy) || stoppedMoving || waitingForReply) {
        if (transcript.length === 0 && !nowMoving) settledEmptyVerified = true;
        await resync(true);
      }
      // Queue failures are recoverable independently of the mission stream.
      // A healthy stream must not leave a transient startup warning forever.
      if (queueError()) await resync(true);
    }, 10000, "mission.status");
    onCleanup(() => {
      if (scroller) putTranscriptHeight(p.id, scroller.scrollHeight);
      stopStream();
      stopPoll();
    });
  }));

  const localMissionId=createMemo(()=>isClientPlacement(mission())?p.id:null);
  createEffect(() => {
    const id=localMissionId();
    if(!id)return;
    const reconcile = async () => {
      await import("../localAgents").then(m => m.refreshLocalBindings());
      if (localBinding(id)) await reconcileLocalRun(id);
    };
    const refreshLocal = () => reconcile().catch(console.error);
    refreshLocal();
    const stopPoll = pollWhileVisible(reconcile, 2000, "mission.localReconcile");
    window.addEventListener('orb:queue-wake',refreshLocal);
    window.addEventListener('orb:refresh',refreshLocal);
    onCleanup(()=>{stopPoll();window.removeEventListener('orb:queue-wake',refreshLocal);window.removeEventListener('orb:refresh',refreshLocal);});
  });

  createEffect(() => {
    const transfer = mission()?.machine_transfer;
    if (transfer) void adoptTransferredWorkspace(transfer).catch(e => setSendError(String(e)));
  });
  const clientPlaced = () => isClientPlacement(mission());
  createEffect(() => {
    const status = mission()?.status;
    if (!p.id || !clientPlaced() || !status || !localFailure(p.id) || localRunActive(p.id)) return;
    if (!isFailedStatus(status) && !queuedLocalMessages(p.id).some(row => !!row.result && ((row.result.exit_code != null && row.result.exit_code !== 0) || !!row.result.error))) {
      recordLocalFailure(p.id, null);
    }
  });
  const [sendingImmediate, setSendingImmediate] = createSignal(false);
  // One answer for the Stop button, the Working row and the sidebar (missionStatus.ts).
  const runState = createMemo(() => missionActivity(mission(), items(), { localRun: localRunActive(p.id), nodeName: nodeLabel }));
  // Send now: one continuous "Sending… → Working…" from the click to the new
  // turn, across the stop in between (missionStatus.ts `handoff`).
  const handoff = () => missionHandoff(p.id);
  const handoffTracker = createHandoffTracker();
  createEffect(() => {
    const current = handoff(), m = mission();
    if (!current) { handoffTracker.reset(); return; }
    if (handoffTracker.observe(current, m)) endHandoff(p.id, current.id);
  });
  onCleanup(() => { if (p.id) endHandoff(p.id); });
  const localQueueActive = () => clientPlaced() && queuedLocalMessages(p.id).some(row => !row.error && !row.interrupted && (row.state === "queued" || row.state === "dispatching" || row.state === "accepted"));
  const busy = () => {
    if(!p.id)return !p.launchError;
    if (sendingImmediate()) return true;
    if (localRunActive(p.id)) return true;
    if(clientPlaced()&&localRunKnown(p.id))return queuedLocalMessages(p.id).some(row=>row.state==='dispatching');
    return runState().working;
  };

  /** Anything the agent has actually said or done in this turn. */
  const activity = () => {
    if (localRunActive(p.id) && localActivities(p.id).some(a => a.kind !== "status" && a.id !== "antigravity:status" && (a.kind !== "thinking" || !!a.detail?.trim()))) return true;
    const list = viewItems();
    const lastUser = list.reduce((last, item, index) => item.kind === "user" && !item.queued ? index : last, -1);
    return list.slice(lastUser + 1).some(i => (i.kind === "tool" || ((i.kind === "text" || i.kind === "think") && !!i.text.trim())));
  };
  /**
   * The mission is working and has produced nothing yet: the window where the
   * prompt animates instead of a banner. It stops the moment any output lands —
   * a tool call counts, not just text — and never runs for a state the user
   * has to act on, which keeps its own banner.
   */
  // A delivered follow-up whose turn has not started yet. Between the send
  // receipt and Core's user_message/status, neither the draft nor `busy()`
  // held the Working row: it unmounted for ~0.7 s and the transcript shifted
  // under the new bubble, then shifted back when the turn started.
  const awaitingTurn = () => {
    const list = items();
    for (let i = list.length - 1; i >= 0; i--) {
      const item = list[i];
      if (item.kind !== "user") return false;
      if (item.queued) continue;
      return item.receipt === true;
    }
    return false;
  };
  // A turn ended with messages still queued: Core delivers the next one in a
  // moment. Keep the Working row across that gap via deterministic `SM-24`
  // `orbFollowupQueueStep` reconciliation (clearing immediately when the new
  // turn starts, a failure lands, or all handover message IDs retire/cancel).
  const [queueHandoverState, setQueueHandoverState] = createSignal<{ ids: string[]; postedAfterSeq: number } | null>(null);
  createEffect(on(busy, (now, before) => {
    if (now) { setQueueHandoverState(null); return; }
    if (!before || clientPlaced() || isFailedStatus(mission()?.status)) return;
    const queuedTranscriptIds = items().flatMap(i => i.kind === "user" && i.queued && i.messageId ? [i.messageId] : []);
    const candidateIds = [...new Set([...remoteQueuedIds(), ...queuedTranscriptIds])];
    if (!candidateIds.length) return;
    setQueueHandoverState({ ids: candidateIds, postedAfterSeq: countDeliveredUserTurns() });
  }, { defer: true }));
  createEffect(() => {
    const handover = queueHandoverState();
    if (!handover) return;
    if (busy() || clientPlaced() || isFailedStatus(mission()?.status)) {
      setQueueHandoverState(null);
      return;
    }
    const serverSet = new Set(remoteQueuedIds());
    const queuedTranscriptSet = new Set(items().flatMap(i => i.kind === "user" && i.queued && i.messageId ? [i.messageId] : []));
    const deliveredSet = new Set(deliveredRemote());
    const currentTurnSeq = countDeliveredUserTurns();
    const stillHandingOver = handover.ids.some(id => {
      const serverListed = serverSet.has(id) || queuedTranscriptSet.has(id);
      const step = stepFollowupPollReconcile({
        serverRev: 1,
        incomingServerRev: 1,
        clientMsgId: id,
        postedAfterSeq: handover.postedAfterSeq,
        turnSeq: currentTurnSeq,
        optimisticSending: false,
        serverListed,
        alreadyDelivered: deliveredSet.has(id),
      });
      // `serverListed` keeps the handover active while Core claims the queued
      // follow-up; once unlisted (cancelled or delivered) and not yet driving
      // `busy()`, retire the handover deterministically without a timer.
      return serverListed && !step.retiredNow && !deliveredSet.has(id);
    });
    if (!stillHandingOver) setQueueHandoverState(null);
  });
  const working = () => {
    if(sendError())return false;
    if(queueHandoverState())return true;
    if(!p.id)return !p.launchError;
    if(sendingImmediate()&&!handoff())return false;
    if(clientPlaced() && !localRunActive(p.id) && (localFailure(p.id) || queuedLocalMessages(p.id).some(row=>row.interrupted)))return false;
    return busy() || optimisticList().some(item => !item.waiting && !item.failed) || awaitingTurn() || queuedLocalMessages(p.id).some(row=>!row.error && (!row.waiting || row.state==='dispatching' || row.state==='accepted'));
  };
  // Unified execution-derived phase label (`missionStatus.ts`): starting/transferred
  // missions say "Starting <Harness>" until execution or first output is confirmed.
  const transferStarting = () => Boolean(p.id && transferForDestination(p.id)?.stage === "destination_starting");
  createEffect(() => {
    observeTransferDestination(mission(), items(), Boolean(p.id && (transcriptVersion(), peekTranscript(p.id)?.activity)));
  });
  const phaseLabel = () => executionPhaseLabel(mission(), {
    activity: activity(),
    handoff: Boolean(handoff()),
    stopping: sendingImmediate(),
    transferStarting: transferStarting(),
  });
  const openOriginalSource = createMemo(() => {
    const sourceId = forkSource(mission() ?? {});
    if (!sourceId) return undefined;
    return () => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: `m:${sourceId}` }));
  });

  const viewItems = createMemo(() => {
    const ready = p.id ? peekReadyTranscript(p.id) : undefined;
    const spinePending = Boolean(ready?.hasOlder && ready.spineComplete === false);
    const canonical = withInitialPrompt(items(), mission(), receipt, awaiting() || spinePending);
    const outbox = [...acceptedLocalMessages(p.id), ...queuedLocalMessages(p.id).filter(row=>!row.error&&(!row.waiting||row.state==='accepted'||row.state==='dispatching'))];
    const drafts=optimisticList();
    let list = canonical;
    if (outbox.length || drafts.length) {
      const known = new Set<string | undefined>();
      for (const i of canonical) if (i.kind === 'user') known.add(i.messageId);
      const projected:StreamItem[]=[];
      for(const row of outbox){if(!known.has(row.id)){known.add(row.id);projected.push({kind:'user',key:`user:${row.id}`,messageId:row.id,text:row.text});}}
      for(const draft of drafts){if((!draft.waiting||draft.failed||sendError())&&!known.has(draft.id)){known.add(draft.id);projected.push({kind:'user',key:`user:${draft.id}`,messageId:draft.id,text:draft.text,images:draft.images});}}
      if (projected.length) list = [...canonical, ...projected];
    }
    const nativeTools = clientPlaced() ? localActivitiesToStreamItems(localActivities(p.id)) : [];
    let withNativeTools = list;
    if (nativeTools.length) {
      let lastUserIdx = -1;
      for (let i = list.length - 1; i >= 0; i--) { const it = list[i]; if (it.kind === "user" && !it.queued) { lastUserIdx = i; break; } }
      let hasCanonicalToolsAfterUser = false;
      for (let i = lastUserIdx + 1; i < list.length; i++) {
        if (list[i].kind === "tool" || list[i].kind === "think") { hasCanonicalToolsAfterUser = true; break; }
      }
      if (!hasCanonicalToolsAfterUser) {
        const copy = [...list];
        let insertAt = copy.length;
        for (let i = copy.length - 1; i > lastUserIdx; i--) {
          if (copy[i].kind === "text") insertAt = i;
          else break;
        }
        copy.splice(insertAt, 0, ...nativeTools);
        withNativeTools = copy;
      }
    }
    const live = localLiveText(p.id);
    // The server rewrites a local run's reply in place without re-emitting it,
    // so a transcript fetched mid-run holds a prefix of the live text.
    let stale = -1;
    for (let i = withNativeTools.length - 1; i >= 0 && withNativeTools[i].kind !== "user"; i--) {
      const item = withNativeTools[i];
      if (item.kind === "text" && live.startsWith(item.text)) { stale = i; break; }
    }
    const liveItem = { kind: "text" as const, key: `local:${p.id}`, text: live, live: localRunActive(p.id) };
    const withLive = !live || withNativeTools.some(item => item.kind === "text" && item.text === live) ? withNativeTools
      : stale >= 0 ? withNativeTools.map((item, i) => i === stale ? liveItem : item)
      : [...withNativeTools, liveItem];
    if (busy()) return withLive;
    // Terminal mission: force-close any bubble left open by a dropped
    // assistant_message finalizer.
    if (!withLive.some((i) => i.kind === "text" && i.live)) return withLive;
    return withLive.map((i) => (i.kind === "text" && i.live ? { ...i, live: false } : i));
  });

  const nonQueuedViewItems = createMemo(() => {
    const list = viewItems();
    for (let i = 0; i < list.length; i++) {
      if (list[i].kind === "user" && (list[i] as Extract<StreamItem, { kind: "user" }>).queued) {
        return list.filter((it) => it.kind !== "user" || !it.queued);
      }
    }
    return list;
  });
  const confirmedRemote = createMemo<Array<{id:string;content:string;attached?:boolean}>>(
    () => clientPlaced() ? [] : items().flatMap((item) => item.kind === "user" && item.queued === true && !!item.messageId ? [{ id: item.messageId, content: item.text, attached: item.attached }] : []),
    [],
    { equals: (a, b) => a.length === b.length && a.every((v, i) => v.id === b[i].id && v.content === b[i].content && v.attached === b[i].attached) },
  );
  const deliveredRemote = createMemo<string[]>(
    () => items().flatMap((item) => item.kind === "user" && !item.queued && item.messageId ? [item.messageId] : []),
    [],
    { equals: (a, b) => a.length === b.length && a.every((v, i) => v === b[i]) },
  );
  const visibleViewItems = createMemo(() => visibleTranscript(viewItems()));
  const planProgress = createPlanProgress({get mission(){return p.id;},get items(){return viewItems();},get active(){return clientPlaced()?localRunActive(p.id):busy();}});
  createEffect(()=>p.onPlan?.(p.id,planProgress()));
  const estimatedTokens = createMemo(() => estimateTokens(viewItems()));
  const titleContext = createMemo(() => awaiting() ? null : contextPct(estimatedTokens(), contextWindow(mission()?.backend)));
  createEffect(() => p.onContext?.(p.id, titleContext()));
  let fulfillingTargetId = 0;
  createEffect(() => {
    const target = pendingSearchTarget();
    if (!target || target.missionId !== p.id || awaiting() || syncing() || fulfillingTargetId === target.requestId) return;
    fulfillingTargetId = target.requestId;
    void fulfillSearchTarget({
      missionId: p.id,
      target,
      getItems: () => viewItems().filter(i => i.kind !== "user" || !i.queued),
      onHydrated: next => setItems(reuseUnchanged(items(), next)),
      getScroller: () => scroller,
      beginJump: pin.beginJump,
      endJump: pin.endJump,
    });
  });

  // Retrying an uncertain network result reuses the original message identity.
  // A different draft/selection, or a definitive rejection, starts a new attempt.
  let retryMessage: { key: string; id: string } | null = null;
  const sendMsgOnce = async (text: string, images: DraftImage[], chips: AttachChip[], attemptId: ReturnType<typeof crypto.randomUUID>, explicitId?: ReturnType<typeof crypto.randomUUID>, replace = false) => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || staleMission()) return false;
    const pendingSettings = inflightSettings.get(targetMissionId);
    if (pendingSettings) await pendingSettings;
    if (staleMission() || p.id !== targetMissionId) return false;
    const optEntry = drafts.find(attemptId);
    setSendError(null);
    if(explicitId&&optimisticList().length&&!drafts.has(explicitId))drafts.clear();
    if (clientPlaced()) {
      const sendVersion=connectionVersion(),sendMission=targetMissionId;
      try {
        await import("../localAgents").then(m => m.refreshLocalBindings());
      } catch (error) {
        if (!localBinding(sendMission)) {
          setSendError(`Couldn’t restore this computer’s session: ${error instanceof Error ? error.message : String(error)}. Your draft is kept.`);
          return false;
        }
      }
      if (!localBinding(sendMission)) {
        setSendError("This session runs on the computer that started it. Your draft is kept.");
        return false;
      }
      const project = mission()?.project;
      if (!project) {
        setSendError("This mission has no project, so its files cannot be copied. Your draft is kept.");
        return false;
      }
      try {
        const next = await followProjectFolder(sendMission, project);
        const binding = next?.binding;
        if (!binding) throw new Error("This session runs on the computer that started it. Your draft is kept.");
        if (binding.harness === "codex") {
          const goal = goalDraft(text);
          if (goal.kind === "empty") throw new Error(EMPTY_GOAL_ERROR);
          const cyber = await getCyber(sendMission);
          await requireCyberSupport({ model: mission()?.model_override ?? binding.model ?? "", mode: cyber.mode, remote: false, goal: goal.kind === "goal" });
        }
        const [plan, , imagePaths] = await Promise.all([
          materializeMentions(project, text, chips).then(async plan => {
            if (plan.files.length) await writeLocalFiles(binding.cwd, plan.files);
            return plan;
          }),
          prepareProjectSkills(project, binding.cwd, binding.harness, binding.bin),
          stageLocalImages(binding.cwd, images),
        ]);
        const sent = seededPrompt(imagePrompt(bindWorkspace(plan.prompt, binding.cwd), imagePaths, images), next?.seed);
        if(connectionVersion()!==sendVersion||staleMission()||p.id!==sendMission)throw new Error("Conversation changed. Your draft is kept.");
        if (optEntry && !drafts.has(attemptId)) return true;
        await enqueueLocalMessage({id:sendMission,harness:binding.harness,bin:binding.bin,cwd:binding.cwd,prompt:sent,model:mission()?.model_override ?? binding.model,effort:normalizeEffort(mission()?.model_effort,binding.harness) ?? undefined,service_tier:binding.harness === "codex" ? missionSpeed(mission()??{}) : undefined,imagePaths},imagePrompt(text,imagePaths,images),{id:attemptId,replace,waiting:explicitId ? busy() : optEntry?.waiting??busy()});
        if (next?.seed) seedDelivered(sendMission);
        drafts.remove(attemptId);
        if (chips === followAttach()) setFollowAttach([]);
        return true;
      } catch (e) {
        // Launch rejection belongs to the composer; it is not a second mission failure.
        recordLocalFailure(sendMission, null);
        setSendError(e instanceof Error ? e.message : String(e));
        return false;
      }
    }
    const attachments = chips.map(chipToAttachment);
    const key = JSON.stringify([connectionVersion(), targetMissionId, text, attachments, images.map(image => image.id)]);
    if (retryMessage?.key !== key) retryMessage = { key, id: attemptId };
    try {
      const sent = imagePrompt(text, await stageRemoteImages(images, mission()), images);
      if (staleMission() || p.id !== targetMissionId) throw new Error("Conversation changed. Your draft is kept.");
      const result = await sendMissionMessage(targetMissionId, sent, attachments, explicitId ?? retryMessage.id, mission());
      retryMessage = null;
      if (staleMission()) return true;
      if (result.replacement) {
        endHandoff(targetMissionId, attemptId);
        endHandoff(targetMissionId, result.id);
        const replacement = result.replacement;
        const nodeId = missionNode(replacement) ?? missionNode(mission()) ?? "";
        rememberLaunch(replacement.id, { prompt: sent, nodeId, destination: nodeLabel(nodeId), replacement: true });
        drafts.remove(attemptId);
        if (chips === followAttach()) setFollowAttach([]);
        // Core archived this mission as superseded by the replacement: it
        // leaves every list in the same batch the replacement joins them, so
        // the sidebar never shows the conversation twice.
        batch(() => {
          window.dispatchEvent(new CustomEvent("orb:mission-archived", { detail: { id: targetMissionId } }));
          p.onFork?.(replacement);
        });
        return true;
      }
      if (result.queued) {
        endHandoff(targetMissionId, attemptId);
        endHandoff(targetMissionId, result.id);
      }
      const event: StreamEvent = { type: "user_message", eventId: result.id, data: { id: result.id, content: sent, queued: result.queued, receipt: true, attached: chips.length > 0 } };
      if (replaying) held.push(event);
      else applyLive(event);
      drafts.remove(attemptId);
      if (chips === followAttach()) setFollowAttach([]);
      void refresh();
      return true;
    }
    catch (e) {
      endHandoff(targetMissionId, attemptId);
      if (explicitId) endHandoff(targetMissionId, explicitId);
      if (retryMessage?.id) endHandoff(targetMissionId, retryMessage.id);
      log.warn("mission.send", errorText(e), { mission: targetMissionId, message: explicitId ?? retryMessage?.id });
      if (e instanceof MessageRejectedError || (e instanceof ApiError && e.status < 500 && e.status !== 408)) retryMessage = null;
      if (!staleMission()) setSendError(launchError(e));
      return false;
    }
  };
  // A follow-up sent to a stopped mission: hide the stop notice until Core
  // reports a change (its updated_at moves), then normal failure display resumes.
  const [sentOverStop, setSentOverStop] = createSignal<string | null>(null);
  // A rejected send changed nothing: show the stop notice again.
  createEffect(() => { if (sendError()) setSentOverStop(null); });
  // Once the follow-up is queued, the queue itself keeps the notice hidden; when
  // that queue empties again (sent or cancelled) the suppression is no longer needed.
  let sawQueued = false;
  createEffect(() => {
    if (!sentOverStop()) { sawQueued = false; return; }
    const queued = localQueueActive() || remoteQueuedIds().length > 0 || items().some(i => i.kind === "user" && i.queued);
    if (queued) sawQueued = true;
    else if (sawQueued) setSentOverStop(null);
  });
  // Any status or update after the follow-up ends the suppression for good,
  // so a failure reported later (stream or poll) shows normally.
  createEffect(() => {
    const m = mission();
    const snap = sentOverStop();
    if (snap && m && `${m.status}|${m.updated_at}` !== snap) setSentOverStop(null);
  });
  const sendMsg = (text: string, images: DraftImage[] = [], chips: AttachChip[] = followAttach(), explicitId?: ReturnType<typeof crypto.randomUUID>, replace = false) => {
    setSentOverStop(mission() ? `${mission()!.status}|${mission()!.updated_at}` : null);
    if (!replace && working()) usageTelemetry.action("queue", "composer");
    const attemptId = explicitId ?? sendingIds.shift() ?? crypto.randomUUID();
    if (pendingBeforeSendId === attemptId) pendingBeforeSendId = null;
    if (p.id && !clientPlaced() && !replace && !busy() && !drafts.inFlightOtherThan(attemptId)) {
      beginHandoff(p.id, attemptId);
    }
    const run = sendChain.then(async () => {
      drafts.setFailed(attemptId, false);
      const accepted = await sendMsgOnce(text, images, chips, attemptId, explicitId, replace);
      if (!accepted) {
        if (p.id) endHandoff(p.id, attemptId);
        drafts.setFailed(attemptId, true);
      }
      return accepted;
    });
    sendChain = run.then(() => undefined, () => undefined);
    return run;
  };

  const [resend, setResend] = createSignal<{id:ReturnType<typeof crypto.randomUUID>;text:string;waiting:boolean;state:"sending"|"accepted"|"error";error?:string}>();
  const resendKnown = () => !!resend() && (items().some(i=>i.kind==='user'&&i.messageId===resend()!.id)||queuedLocalMessages(p.id).some(row=>row.id===resend()!.id));
  const deliverResend = async () => {
    const row=resend();if(!row||row.state==='sending')return;
    setResend({...row,state:"sending",error:undefined});
    const version=connectionVersion();
    try {
      const project=mission()?.project;
      const chips=project?mentionedChips(row.text,await loadAttachItems(project)):[];
      if(version!==connectionVersion()||staleMission())return;
      const accepted=await sendMsg(row.text,[],chips,row.id);
      if(version!==connectionVersion()||staleMission())return;
      setResend({...row,state:accepted?"accepted":"error",error:accepted?undefined:sendError()||"Couldn’t send. Retry uses the same message identity."});
      if(!accepted)setSendError(null);
    } catch(error) {
      if(version===connectionVersion()&&!staleMission())setResend({...row,state:"error",error:String(error)});
    }
  };
  const sendEditedPrompt = (text: string, messageId?: string) => {
    usageTelemetry.action("message_edit", "transcript");
    // A stored message is replaced, like Cursor: a new version of the
    // conversation keeps the history before it and continues with the new
    // text. The old version is stopped, not archived: it stays listed as an
    // earlier version of the conversation, so nothing jumps to the archive.
    const source = mission();
    if (messageId && p.id && source?.backend && p.onFork) return replaceFrom(source, messageId, text);
    // One pending resend owns its identity even across ambiguous network failures.
    if(resend()?.state==='sending')return true;
    if(resend()?.state==='error'&&!resendKnown())return false;
    setResend({id:crypto.randomUUID(),text,waiting:busy(),state:"accepted"});
    pin.pin();
    void deliverResend();
    return true;
  };

  const replaceFrom = async (source: Mission, messageId: string, text: string) => {
    try {
      const next = await forkMission(source.id, { backend: source.backend!, model_override: source.model_override ?? "", model_effort: source.model_effort ?? "", service_tier: source.backend === "codex" ? source.service_tier : undefined, idempotency_key: `edit:${source.id}:${messageId}:${crypto.randomUUID()}`, replace_message_id: messageId, replacement: text });
      p.onFork?.(next);
      void stopSource(source.id).catch(() => undefined);
      return true;
    } catch (e) {
      setSendError(e instanceof Error ? e.message : String(e));
      return false;
    }
  };

  const stopM = () => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId) return;
    if (clientPlaced()) {
      void stopLocal(targetMissionId).then(() => flushClientLink(targetMissionId)).then(() => setClientMissionStatus(targetMissionId, "interrupted")).then(() => refresh()).catch(e => setSendError(String(e)));
      return;
    }
    void cancelMission(targetMissionId)
      .catch(swallow("mission.cancel", { mission: targetMissionId }))
      .then(() => refresh());
  };

  const [recoveryPending, setRecoveryPending] = createSignal(false);
  const actOnRecovery = async (action: "resume" | "cancel") => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || recoveryPending()) return;
    setRecoveryPending(true);
    try {
      if (action === "resume") await resume();
      else { await cancelMission(targetMissionId); await refresh(); }
    } catch (error) { setSendError(launchError(error)); }
    finally { setRecoveryPending(false); }
  };

  const [forceSlotPending, setForceSlotPending] = createSignal(false);
  const forceStartSlot = async () => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || forceSlotPending()) return;
    setForceSlotPending(true);
    try {
      const updated = await forceMissionSlot(targetMissionId);
      if (!staleMission()) {
        statusSeen++;
        setMission(updated);
      }
    } catch (error) {
      if (!staleMission()) {
        notify({ kind: "error", key: `force-slot:${targetMissionId}`, title: "Couldn’t run immediately", message: launchError(error) });
      }
    } finally {
      setForceSlotPending(false);
    }
  };
  const forceSlotHandler = () => canForceSlot(mission()) ? () => void forceStartSlot() : undefined;

  const sendRemoteImmediate = async (
    ordered: { id: string; content: string; attached?: boolean }[],
    liveInjected?: { id: string; content: string; attached?: boolean }[],
  ) => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || staleMission()) return;
    if (liveInjected?.length) {
      beginHandoff(targetMissionId, liveInjected[0].id, Date.now(), true);
      for (const row of liveInjected) {
        const presented = messagePresentation(row.content);
        const event: StreamEvent = {
          type: "user_message",
          eventId: row.id,
          data: {
            id: row.id,
            content: presented.text,
            queued: false,
            receipt: true,
            attached: Boolean(row.attached || presented.attached),
          },
        };
        // Shown now even while a history replay is in flight: the replay
        // re-applies live events after its snapshot, so this is not lost, and
        // the queue row it replaces is leaving in this same batch.
        applyLive(event);
      }
    }
    if (!ordered.length) return;
    const wasBusy = busy();
    beginHandoff(targetMissionId, ordered[0].id, Date.now(), true);
    setSendingImmediate(true);
    setSendError(null);
    // Show the messages as sent right away: stopping a remote turn can take
    // several seconds, and the queue row has already disappeared.
    const projected = ordered.map(row => row.id as ReturnType<typeof crypto.randomUUID>);
    const basePostedAfterSeq = countDeliveredUserTurns();
    drafts.replaceAll(ordered.map(row => ({ id: row.id as ReturnType<typeof crypto.randomUUID>, text: messagePresentation(row.content).text, images: [], waiting: false, postedAfterSeq: basePostedAfterSeq })));
    pin.pin();
    try {
      if (wasBusy) {
        await cancelMission(targetMissionId).catch(swallow("mission.sendNow.cancel", { mission: targetMissionId }));
        for (let poll = 0; poll < 75; poll++) {
          if (staleMission() || p.id !== targetMissionId) return;
          try {
            const current = await getMission(targetMissionId, { includeHistory: false });
            if (staleMission() || p.id !== targetMissionId) return;
            setMission(current);
            const stillStopping =
              isRunning(current.status) ||
              current.execution?.state === "stopping" ||
              (!!current.remote_job && current.remote_job.phase !== "finished");
            if (!stillStopping) break;
          } catch {
            break;
          }
          await new Promise(r => setTimeout(r, 200));
        }
      }
      if (staleMission() || p.id !== targetMissionId) return;
      const project = mission()?.project;
      const attachItems = project ? await loadAttachItems(project).catch(() => []) : [];
      if (staleMission() || p.id !== targetMissionId) return;
      const stale = () => staleMission() || p.id !== targetMissionId;
      const outcome = await deliverInOrder({
        mission: targetMissionId,
        rows: ordered,
        attempts: wasBusy ? 30 : 1,
        send: sendMissionMessage,
        attachments: text => (project ? mentionedChips(text, attachItems) : []).map(chipToAttachment),
        stale,
        onReplacement: (replacement, text) => {
          const nodeId = missionNode(replacement) ?? missionNode(mission()) ?? "";
          rememberLaunch(replacement.id, { prompt: text, nodeId, destination: nodeLabel(nodeId), replacement: true });
        },
        onDelivered: (row, result, text, attachments) => {
          // Queued behind a turn that is still stopping is accepted delivery:
          // Core sends it next. Deleting and resending would risk losing it.
          drafts.remove(row.id);
          const event: StreamEvent = { type: "user_message", eventId: result.id, data: { id: result.id, content: text, queued: result.queued, receipt: true, attached: Boolean(row.attached || messagePresentation(row.content).attached || attachments.length > 0) } };
          if (replaying) held.push(event);
          else applyLive(event);
        },
      });
      if (outcome.kind === "stale") return;
      if (outcome.kind === "replaced") {
        if (outcome.forwardError) {
          log.warn("mission.forwardToReplacement", errorText(outcome.forwardError), { replacement: outcome.replacement.id, undelivered: outcome.undelivered.length });
          const count = outcome.undelivered.length;
          notify({ kind: "error", key: `forward:${outcome.replacement.id}`, title: `Couldn’t send ${count} queued message${count === 1 ? "" : "s"} to the new conversation`, message: `${launchError(outcome.forwardError)} Not sent: ${outcome.undelivered.map(row => `“${messagePresentation(row.content).text.slice(0, 80)}”`).join(", ")}` });
        }
        p.onFork?.(outcome.replacement);
        return;
      }
      if (!staleMission()) await refresh();
    } catch (e) {
      if (!staleMission()) setSendError(launchError(e));
      // Keep what was not delivered visible as failed rather than losing it.
      drafts.setFailed(projected, true);
      throw e;
    } finally {
      setSendingImmediate(false);
      { const sent = new Set<string>(projected); drafts.retain(item => !sent.has(item.id) || !!item.failed); }
    }
  };

  return (
    <>
      {/* Centred in the title-bar row, just left of its icons (Codex / ChatGPT desktop). */}
      <Show when={document.getElementById("tb-tools")}>{slot => <Portal mount={slot()}>
        <div class="mission-tools"><Chapters items={viewItems()} scroller={() => scroller} /></div>
      </Portal>}</Show>
      <div
        class="scroll"
        ref={el => { scroller = el; pin.ref(el); }}
        onScroll={pin.onScroll}
      >
        <div class="col" style={peekTranscriptHeight(p.id) && awaiting() ? { "min-height": `${peekTranscriptHeight(p.id)}px` } : undefined}>
          <Show
            when={!awaiting() || !!receipt || viewItems().length > 0}
            fallback={
              <>
                <Show when={receipt}>
                  {(r) => (
                    <>
                      <LaunchStatus destination={missionDestination(mission(), r())} mission={mission()} goal={missionGoal(mission(), r())} onForceSlot={forceSlotHandler()} forceSlotPending={forceSlotPending()} />
                      <UserTurn text={r().prompt} images={r().images} pending={working()} onSend={p.id && !participant() ? sendEditedPrompt : undefined} />
                      <Show when={working()}>
                        <MissionPending destination={missionDestination(mission(), r())} label={phaseLabel()} onForceSlot={forceSlotHandler()} forceSlotPending={forceSlotPending()} />
                      </Show>
                    </>
                  )}
                </Show>
                <DelayedTranscriptSkeleton />
              </>
            }
          >

            {/* A sent follow-up supersedes the previous run's banner: it must go
                with the send, not when the turn starts ~1 s later (a second
                shift of the transcript under the new message). */}
            <Show when={mission() && !(awaitingTurn() || optimisticList().some(item => !item.waiting && !item.failed)) && (!missionPhase(mission(), activity()).moving || ["Checking submission", "Checking remote job"].includes(missionPhase(mission(), activity()).label))}>
              <LaunchStatus destination={missionDestination(mission(), receipt)} mission={mission()} activity={activity()} goal={missionGoal(mission(), receipt)} onResume={() => void actOnRecovery("resume")} onCancelRecovery={() => void actOnRecovery("cancel")} onResetRedeemed={() => void refresh()} recoveryPending={recoveryPending()} onForceSlot={forceSlotHandler()} forceSlotPending={forceSlotPending()} />
            </Show>
            <Transcript sizeKey={p.id ? `m:${p.id}` : undefined} initialBottom={Boolean(p.id && !hasPendingSearchTarget(p.id))} backend={mission()?.backend} loadToolCall={p.id ? (callId => fullToolCall(p.id!, callId)) : undefined} sending={handoff()?.promoted ? handoff()?.id : undefined} working={working()} workingLabel={(awaiting() && p.id && (transcriptVersion(), peekTranscript(p.id)?.activity)) || `${phaseLabel()} on ${missionDestination(mission(), receipt)}…`} onForceSlot={forceSlotHandler()} forceSlotPending={forceSlotPending()} prepareSearch={prepareSearch} needsPrepareSearch={needsPrepareSearch} items={nonQueuedViewItems()} pending={working() && !activity()} onSend={p.id && !participant() ? sendEditedPrompt : undefined} onOpenSource={openOriginalSource()} onResume={!busy() && !localQueueActive() && (clientPlaced() || (!remoteQueuedIds().length && !items().some(i => i.kind === "user" && i.queued))) && ((missionPhase(mission(), false).failed && missionPhase(mission(), false).label !== "Cancelled") || visibleViewItems().some(item => item.kind === "error" && item.terminal)) ? resume : undefined} checkpoints={checkpoints()} onRestoreCheckpoint={!participant() ? setPendingCheckpointRevert : undefined} />
            <Show when={awaiting() && items().length > 0}><ActivitySkeleton /></Show>
            <TurnRecap mission={mission() ?? undefined} items={viewItems()} busy={busy()} onDraft={text=>setSideRevision({text,append:false})} />
            <ErrorToast
              error={!resendKnown() && resend()?.state === "error" ? resend()?.error : null}
              title="Couldn’t send your message"
              onDismiss={() => setResend(r => (r?.state === "error" ? { ...r, error: undefined } : r))}
              action={{ label: "Retry", primary: true, run: () => void deliverResend() }}
            />
            <Show when={!resendKnown() ? resend() : undefined}>{row=><div class="resend-feedback">
              <UserTurn text={row().text}/>
              <div class="resend-status" role="status">{row().state==='error' ? "Not sent" : row().state==='sending' ? (row().waiting ? "Sending · queued after the current turn…" : "Sending…") : row().waiting ? "Queued after the current turn" : "Sent"}
                <Show when={row().state==='error'}><button type="button" onClick={()=>void deliverResend()}>Retry</button></Show>
              </div>
            </div>}</Show>
            <Show when={clientPlaced() && localActivities(p.id).some(a => a.background || a.id.startsWith("task:"))}>
              <AgentActivity items={localActivities(p.id).filter(a => a.background || a.id.startsWith("task:"))} running={localRunActive(p.id)} completed={activityShouldCollapse(mission()?.status, localRunActive(p.id))} />
            </Show>
            <NativeInteraction mission={p.id} active={clientPlaced() ? localRunActive(p.id) : busy()} remote={!clientPlaced()} items={viewItems()} onSend={text => sendMsg(text, [], [])} />
            <Show when={!sendError()}>
              <MissionFailure mission={mission()} active={busy() || localQueueActive() || working() || !!sentOverStop() || (awaiting() && mission()?.status_message === "Model error") || (!clientPlaced() && (remoteQueuedIds().length > 0 || items().some(i => i.kind === "user" && i.queued)))} error={clientPlaced() ? localFailure(p.id) : undefined} onResume={resume} onOpenSource={openOriginalSource()} failureInTranscript={visibleViewItems().some(item => item.kind === "error")} />
            </Show>
          </Show>

          <NextReminder mission={p.id} busy={busy()} archived={isArchived(mission()?.status)} />
          <Show when={refreshing()}><div class="agent-wait-status" role="status">Refreshing conversation…</div></Show>
        </div>
      </div>
      <div class="dock" ref={floatingDock}>
        <JumpToLatest pinned={pin.pinned} onJump={pin.pin} />
        <div class="col">
          <Show when={p.id}><SideQuestions mission={p.id} items={viewItems()} ref={handle=>sideQuestions=handle} onTransfer={text=>setSideRevision({text,append:true})}/></Show>
          <RemoteQueue mission={p.id}
            ref={handle => remoteQueue = handle}
            editing={editingQueued()}
            onEdit={row => void queuedEdit.start(row)}
            onSendImmediate={sendRemoteImmediate}
            pending={!clientPlaced() && !sendError() ? optimisticList().filter(item => item.waiting && !item.failed).map(item => ({id:item.id,content:item.text})) : undefined}
            confirmed={confirmedRemote()}
            liveEdit={remoteLiveEdits()}
            delivered={deliveredRemote()}
            onRetract={id=>{
              endHandoff(p.id,id);
              setItems(previous=>removeUsers(previous,item=>!item.queued&&item.messageId===id));
              liveEvents=liveEvents.filter(event=>event.type!=="user_message"||event.data?.queued||event.data?.id!==id);
              held=held.filter(event=>event.type!=="user_message"||event.data?.queued||event.data?.id!==id);
            }}
            onSendNowAccepted={(id,live)=>{ if(live)endHandoff(p.id,id); }}
            onEdited={(id,content)=>{
              setItems(previous=>mapUsers(previous,item=>item.queued&&item.messageId===id?{...item,text:content}:item));
              liveEvents=liveEvents.map(event=>event.type==="user_message"&&event.data?.queued&&event.data?.id===id?{...event,data:{...event.data,content}}:event);
            }}
            onRows={reconcileRemoteQueue} onCancel={id=>{
            setItems(previous=>removeUsers(previous,item=>!!item.queued&&item.messageId===id));
            liveEvents=liveEvents.filter(event=>event.type!=="user_message"||!event.data?.queued||event.data?.id!==id);
          }}/>
          <QueuedMessages mission={p.id} editing={editingQueued()} pending={clientPlaced() && !sendError() && !editingQueued() ? optimisticList().filter(item => item.waiting && !item.failed).map(item => ({id:item.id,text:item.text})) : undefined} onCancelPending={id => drafts.remove(id)} onEdit={row=>void queuedEdit.start(row)}/>
          <Composer
            allowConcurrentSend
            revision={sideRevision()}
            onBtw={(question,images,files)=>sideQuestions?.ask(question,images,files)??false}
            onOpenBtw={()=>sideQuestions?.open()}
            placeholder="Send follow-up"
            disabled={!p.id}
            picker={false}
            busy={busy()}
            onPending={beginSend}
             retainFailedMessage={!editingQueued()}
            onSendError={setSendError}
            onSend={async (text,images)=>{
              const id=editingQueued();
              if(!id)return sendMsg(text,images);
              usageTelemetry.action("message_edit","queue");
              if(queuedEdit.editingRemote()&&remoteQueue){
                // Edit in place: the row updates now and keeps its id and place;
                // the chip clears at once and a refusal reverts with a toast.
                const queue=remoteQueue;
                // The composer projected this text as a new outgoing message;
                // an edit is not one.
                const projected=sendingIds.shift();
                if (projected) {
                  if (pendingBeforeSendId === projected) pendingBeforeSendId = null;
                  drafts.remove(projected);
                  if (p.id) endHandoff(p.id, projected);
                }
                if(images.length){
                  const saved=await queue.replaceEdited(
                    id,
                    ()=>sendMsg(text,images,followAttach()),
                    async after=>{
                      const project=mission()?.project;
                      const attachItems=project?await loadAttachItems(project).catch(()=>[]):[];
                      for(const r of after){
                        const cleanText=messagePresentation(r.content).text;
                        const chips=project?mentionedChips(cleanText,attachItems):[];
                        await sendMsg(cleanText,[],chips,crypto.randomUUID());
                      }
                    },
                  );
                  if(saved)queuedEdit.finish(false);
                  return saved;
                }
                const revertFinish=queuedEdit.finish(false);
                const result=await queue.editInPlace(id,text);
                if(result==="failed"){
                  revertFinish();
                  return false;
                }
                if(result!=="unsupported")return true;
                revertFinish();
                const saved=await queue.replaceEdited(
                  id,
                  ()=>sendMsg(text,images,followAttach()),
                  async after=>{
                    const project=mission()?.project;
                    const attachItems=project?await loadAttachItems(project).catch(()=>[]):[];
                    for(const r of after){
                      const cleanText=messagePresentation(r.content).text;
                      const chips=project?mentionedChips(cleanText,attachItems):[];
                      await sendMsg(cleanText,[],chips,crypto.randomUUID());
                    }
                  },
                );
                if(saved)queuedEdit.finish(false);
                return saved;
              }
              const saved=await sendMsg(text,images,followAttach(),id as ReturnType<typeof crypto.randomUUID>,true);
              if(saved)queuedEdit.finish(false);
              return saved;
            }}
            onDraft={queuedEdit.trackDraft}
            editingQueued={editingQueued()?{onCancel:()=>queuedEdit.finish(true)}:undefined}
            onEmptySubmit={sendQueueFromComposer}
            onEditFirstQueued={editFirstQueued}
            onStop={stopM}
            scope={`m:${p.id}`}
            uploadTarget={clientPlaced() ? "local" : missionAssignedNode(mission()) ?? "core"}
            backend={mission()?.backend}
            projectSlug={mission()?.project ?? undefined}
            workspaceId={mission()?.workspace_id && mission()?.workspace_id !== "00000000-0000-0000-0000-000000000000" ? mission()?.workspace_id : undefined}
            missionId={p.id}
            onAttachments={setFollowAttach}
          />
          <ErrorToast title="Couldn’t send your message" error={p.launchError} action={p.onRetryLaunch ? { label: "Retry", run: p.onRetryLaunch } : undefined} />
          <Show when={mission()?.local_sync_pending}>
            {(() => {
              const syncError = () => mission()?.local_sync_error;
              const activelySyncing = () =>
                !syncError() &&
                isConnected() &&
                !mission()?.local_sync_local_only &&
                networkHealth() !== "reconnecting";
              return (
                <div
                  class={`dock-sync-note${syncError() ? " is-error" : activelySyncing() ? " is-syncing" : ""}`}
                  role="status"
                >
                  <i class="dock-sync-dot" aria-hidden="true" />
                  <span>
                    {syncError() || (activelySyncing() ? "Saved on this computer · syncing to Core…" : "Saved on this computer")}
                  </span>
                </div>
              );
            })()}
          </Show>
          <ErrorToast error={sendError()} title="Couldn’t send your message" onDismiss={() => setSendError(null)}
            action={optimistic() ? { label: "Retry", run: () => { const draft = optimistic(); if (draft?.retry) draft.retry(); else if (draft) void sendMsg(draft.text, draft.images, followAttach(), draft.id); } } : undefined} />
          <ErrorToast error={error() || queueError()} title="Couldn’t load the conversation" action={{ label: "Retry", run: () => { setError(null); setQueueError(null); return Promise.all([refresh(true), resync(true)]); } }} onDismiss={() => { setError(null); setQueueError(null); }} />
          <MissionDock mission={mission()} items={viewItems()} usedTokens={estimatedTokens()} destination={missionDestination(mission(), receipt)} syncing={syncing()} onMission={applyDockMission} onError={setError} onFork={p.onFork} />
        </div>
      </div>
      <Show when={pendingCheckpointRevert()}>
        {(cp) => (
          <ConfirmDialog
            title={`Revert workspace to Turn ${cp().turn}?`}
            description={`Uncommitted changes since Turn ${cp().turn} (${cp().commit.slice(0, 7)}) will be replaced. Orb saves an automatic backup ref before restoring.`}
            action={revertingCheckpoint() ? "Reverting…" : "Revert workspace"}
            destructive
            onConfirm={() => void confirmRevertCheckpoint()}
            onClose={() => { if (!revertingCheckpoint()) setPendingCheckpointRevert(null); }}
          />
        )}
      </Show>
    </>
  );
}

