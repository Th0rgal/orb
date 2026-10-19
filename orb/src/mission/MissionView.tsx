import { missionAssignedNode, missionNode, nodeLabel } from "../machines/nodes";
import { followProjectFolder } from "../localFolder";
import { isFailedStatus, isRunning, isSettingsIdle } from "../missionStatus";
import { errorText, log, swallow } from "../log";
import { flushClientLink } from "../clientLink";
import {CodexSpeedPicker, missionSpeed} from '../CodexSpeedPicker';
import { Picker } from "../Picker";
import { Popover } from "../Popover";
import { RemoteQueue, type RemoteQueueHandle } from "../RemoteQueue";
import { MissionCyber } from "../cyberAccess";
import {NextReminder} from "../AutomaticReminder";
import { CloudConversation } from "../CloudAgents";
import {QueuedMessages} from "../QueuedMessages";
import {enqueueLocalMessage,queuedLocalMessages,acceptedLocalMessages,forgetAcceptedLocalMessages,sendQueuedNow,resumePrompt} from "../localMessageQueue";
import {createQueuedEdit} from "../queuedEdit";
import {messagePresentation} from "../messagePresentation";
import {createPlanProgress, type PlanProgressData} from "../PlanProgress";
import { SideQuestions, type SideQuestionsHandle } from "../SideQuestionPanel";
import { AgentActivity, activityShouldCollapse } from "../AgentActivity";
import { localRunKnown } from "../localAgents";
import { ChangeMachine, preloadMachineDestinations } from "../ChangeMachine";
import { adoptTransferredWorkspace } from "../machineTransfer";
import { NativeInteraction } from "../NativeInteraction";
import { imagePrompt, stageLocalImages, stageRemoteImages, type DraftImage } from "../imageAttachments";
import { ErrorToast } from "../toast";
import { MissionFailure, LaunchStatus, MissionPending, missionPhase, rememberLaunch, recalledLaunch, missionDestination, withInitialPrompt, launchError, missionGoal, dockModelLabel, type LaunchReceipt } from "../missionLaunch";
import { chipToAttachment, loadAttachItems, mentionedChips, type AttachChip } from "../attach";
import { Show, createMemo, createSignal, createEffect, on, onCleanup, onMount } from "solid-js";
import * as Ic from "../icons";
import { ForkMission } from "../ForkMission";
import { streamMission, heldAfterHistory, type StreamEvent } from "../stream";
import { localActivitiesToStreamItems } from "../workModel";
import { Chapters } from "../Chapters";
import { Changes } from "../Changes";
import { TurnRecap } from "../TurnRecap";
import { Transcript, UserTurn, applyStreamEvent, type StreamItem } from "../Transcript";
import { cacheRemember } from "../pageCache";
import { antigravityBaseModel, defaultEffortLabel, effortLabel, normalizeEffort, supportedEfforts } from "../effort";
import { retainTranscript, loadOlderTranscript, refreshTranscript, loadTranscript, peekReadyTranscript, peekTranscriptHeight, putTranscript, putTranscriptHeight, putTranscriptItems } from "../missionCache";
import { ConversationSkeleton, DelayedTranscriptSkeleton } from "../Skeleton";
import { visibleTranscript } from "../transcriptModel";
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
} from "../localAgents";
import { timed } from "../diagnostics";
import {
  getMission,
  shortModelLabel,
  cancelMission,
  setClientMissionStatus,
  sendMissionMessage,
  ApiError,
  MessageRejectedError,
  connectionVersion,
  updateMissionSettings,
  type Mission,
} from "../api";

import { harnessChoices, refreshNodeAntigravityModels } from "../harnessPick";
import { Composer, floatingDock } from "../composer/Composer";
import { deliverInOrder } from "./sendQueue";
import { missionActivity } from "../missionStatus";
import { createOptimisticList } from "./optimisticList";
import { notify } from "../toast";

function MissionDock(p: {
  mission: Mission | null;
  items: StreamItem[];
  destination: string;
  onMission?: (mission: Mission) => void;
  onError?: (message: string) => void;
  onFork?: (mission: Mission) => void;
}) {
  const [machineOpen, setMachineOpen] = createSignal(false);
  const [forkOpen, setForkOpen] = createSignal(false);
  const used = () => estimateTokens(p.items);
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
  const modelLabel = () => {
    const id = modelId();
    const m = choice()?.models.find((x) => x.value === id);
    if (m) return dockModelLabel(harnessName(), shortModelLabel(m.label));
    return id ? dockModelLabel(harnessName(), shortModelLabel(id)) : "Default";
  };
  const idle = () => isSettingsIdle(p.mission?.status);
  const models = () => choice()?.models ?? [];
  const canChangeModel = () => idle() && models().length > 1 && !saving();
  // The mission's own stored effort, normalized against its harness: a mission
  // created before an effort was offered simply has none.
  const effort = () => normalizeEffort(p.mission?.model_effort, p.mission?.backend);
  const efforts = () => supportedEfforts(p.mission?.backend);
  // Effort can change during a turn: a running Claude session applies it at
  // once, any other mission from its next turn.
  const canChangeEffort = () => !!p.mission && efforts().length > 0 && !saving();
  const pickModel = async (value: string) => {
    const m = p.mission;
    if (!m || value === modelId() || saving()) { setModelOpen(false); return; }
    setSaving(true);
    setModelOpen(false);
    try {
      p.onMission?.(await updateMissionSettings(m.id, { model_override: value }));
    } catch (e) {
      p.onError?.(e instanceof Error && e.message.includes("409") ? "Stop the current turn before switching models." : launchError(e));
    } finally { setSaving(false); }
  };
  /** Next-turn effort. "" is the core's documented clear back to the backend
   * default (`normalize_string_patch` trims it to a null). */
  const pickEffort = async (value: string) => {
    const m = p.mission;
    if (!m || value === (effort() ?? "") || saving()) { setEffortOpen(false); return; }
    setSaving(true);
    setEffortOpen(false);
    try {
      p.onMission?.(await updateMissionSettings(m.id, { model_effort: value }));
    } catch (e) {
      p.onError?.(e instanceof Error && e.message.includes("409") ? "Stop the current turn before switching effort." : launchError(e));
    } finally { setSaving(false); }
  };
  // Warm the machine list once the conversation is idle so the menu opens filled.
  createEffect(on(() => p.mission?.id, id => {
    if (!id) return;
    if (catalogMachine() === "local") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(catalogMachine());
    const timer = setTimeout(() => preloadMachineDestinations(id), 1500);
    onCleanup(() => clearTimeout(timer));
  }));
  return (
    <div class="under">
      <div class="fork-anchor">
        <button class="under-loc fork-trigger" title="Change machine…" aria-label="Change machine" aria-haspopup="menu" aria-expanded={machineOpen()} disabled={!p.mission} onPointerEnter={() => p.mission && preloadMachineDestinations(p.mission.id)} onFocus={() => p.mission && preloadMachineDestinations(p.mission.id)} onClick={() => { setForkOpen(false); setMachineOpen(!machineOpen()); }}>
          <Show when={p.destination !== "Core" && p.destination !== "This computer"} fallback={<Ic.LaptopIcon size={13} />}><Ic.CloudIcon /></Show>
          {p.destination} <Ic.ChevronDown size={10} />
        </button>
        <Show when={machineOpen() && p.mission}>{m => <ChangeMachine mission={m()} choices={harnessChoices()} choicesFor={machine => harnessChoices(machine.kind === "client" ? "local" : machine.kind === "node" ? machine.id : "core")} onDestination={machine => { if (machine.kind === "client") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(machine.kind === "node" ? machine.id : "core"); }} onClose={() => setMachineOpen(false)} onMoved={mission => p.onMission?.(mission)} />}</Show>
      </div>
      <Show when={harnessName()}>
        <span class="under-sep" aria-hidden="true">·</span>
        <div class="fork-anchor"><button class="under-harness fork-trigger" title="Fork with another harness or model" aria-label="Transfer to another agent" onClick={() => setForkOpen(true)}>{harnessName()} <Ic.ChevronDown size={10} /></button>
        <Show when={forkOpen() && p.mission}>{m => <ForkMission mission={m()} choices={harnessChoices(catalogMachine())} onOpen={() => { if (catalogMachine() === "local") void refreshLocalAgents(false); else void refreshNodeAntigravityModels(catalogMachine()); }} destination={p.destination} onClose={() => setForkOpen(false)} onFork={forked => { setForkOpen(false); p.onFork?.(forked); }} />}</Show></div>
        <span class="under-sep" aria-hidden="true">·</span>
        <div class="under-model-wrap">
          <Show
            when={canChangeModel()}
            fallback={
              <span class="under-model" title={idle() ? modelLabel() : "Stop the current turn to switch models"}>
                {modelLabel()}
              </span>
            }
          >
            <button
              class={`under-model ${modelOpen() ? "on" : ""}`}
              title="Model for the next turn"
              onClick={() => setModelOpen(!modelOpen())}
            >
              {modelLabel()} <Ic.ChevronDown size={10} />
            </button>
            <Show when={modelOpen()}>
              <Picker label="Models" searchLabel="Search models" placement="top-start" selected={modelId()}
                items={models().map(m => ({id:m.value,label:shortModelLabel(m.label)}))}
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
          <CodexSpeedPicker model={modelId()} value={missionSpeed(p.mission!)} missionId={p.mission!.id} local={catalogMachine()==="local"} disabled={saving()} onChange={tier=>{
            const mission=p.mission; if(!mission||saving())return;
            setSaving(true);
            void updateMissionSettings(mission.id,{service_tier:tier}).then(updated=>{if(missionSpeed(updated)!==tier)throw new Error('The backend did not save the selected speed. Update it before retrying.');p.onMission?.(updated);}).catch(e=>p.onError?.(launchError(e))).finally(()=>setSaving(false));
          }}/>
        </Show>
        <Show when={p.mission?.backend === "codex"}><MissionCyber mission={p.mission!} onError={p.onError}/></Show>
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

export function MissionView(p: Parameters<typeof NativeMissionView>[0]) {
  const [resolved, setResolved] = createSignal<Mission | null>(p.initial ?? null);
  const [error, setError] = createSignal("");
  createEffect(() => {
    const init = p.initial;
    if (init) setResolved(prev => prev && prev.id === init.id ? { ...prev, ...init } : init);
  });
  onMount(() => {
    if (p.id) void loadTranscript(p.id).catch(swallow("mission.loadTranscript", { mission: p.id }));
    if (!resolved()) void getMission(p.id).then(setResolved).catch(e => setError(String(e)));
  });
  return <Show when={Boolean(resolved())} fallback={<Show when={error()} fallback={<ConversationSkeleton />}><div class="scroll"><div class="col"><p role="alert">{error()}</p></div></div></Show>}><Show when={resolved()?.backend?.startsWith("cloud_")} fallback={<NativeMissionView {...p} initial={resolved() ?? undefined} />}><CloudConversation id={p.id} onMission={p.onMission} onOpenMission={p.onFork} /></Show></Show>;
}

export function NativeMissionView(p: { id: string; launch?:LaunchReceipt; launchError?:string; onRetryLaunch?:()=>void; onPlan?: (id:string,data:PlanProgressData | undefined)=>void; onContext?: (id: string, pct: number | null) => void; initial?: Mission; onMission?: (mission: Mission | null) => void; onFork?: (mission: Mission) => void }) {
  const boundMissionId = p.id;
  const staleMission = () => disposed || Boolean(boundMissionId && p.id !== boundMissionId);
  const receipt = p.launch ?? recalledLaunch(p.id);
  let disposed=false;
  onCleanup(()=>{disposed=true;});
  createEffect(()=>{if(p.id)onCleanup(retainTranscript(p.id));});
  const cached = p.id ? peekReadyTranscript(p.id) : undefined;
  const [mission, setMission] = createSignal<Mission | null>(p.initial ?? null);
  createEffect(()=>{
    const init = p.initial;
    if (init) setMission(prev => prev && prev.id === init.id ? { ...prev, ...init, history: init.history?.length ? init.history : prev.history } : init);
  });
  createEffect(() => p.onMission?.(mission()));
  onCleanup(() => p.onMission?.(null));
  const [items, setItems] = createSignal<StreamItem[]>(cached?.items ?? []);
  const [awaiting, setAwaiting] = createSignal(!cached);
  const [error, setError] = createSignal<string | null>(null);
  const [queueError, setQueueError] = createSignal<string | null>(cached?.queueError ?? null);
  const [sendError, setSendError] = createSignal<string | null>(null);
  const drafts = createOptimisticList<{id:ReturnType<typeof crypto.randomUUID>;text:string; images:DraftImage[];waiting:boolean;failed?:boolean;retry?:()=>void}>();
  const optimisticList = drafts.items;
  const optimistic = drafts.first;
  let sendingIds:ReturnType<typeof crypto.randomUUID>[]=[];
  let sendChain: Promise<void> = Promise.resolve();
  const beginSend = (draft:{text:string;images:DraftImage[];retry?:()=>void}|null) => {
    if(!draft)return;
    const prevErr = sendError();
    const firstOpt = optimistic();
    const nextId = prevErr && firstOpt?.text === draft.text ? firstOpt.id : crypto.randomUUID();
    sendingIds.push(nextId);
    setSendError(null);
    const waiting = busy() || drafts.inFlightOtherThan(nextId);
    drafts.upsert({ ...draft, id: nextId, waiting });
    if (!waiting) {
      nearBottom = true;
      queueMicrotask(scrollIfPinned);
    }
  };
  createEffect(()=>{
    const ids=new Set([
      ...items().filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.messageId??'':''),
      ...queuedLocalMessages(p.id).map(row=>row.id),
      ...acceptedLocalMessages(p.id).map(row=>row.id),
    ]);
    // Remove the projection only after its canonical identity is visible.
    drafts.reconcile(ids);
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
  let scroller: HTMLDivElement | undefined;
  let nearBottom = true;
  createEffect(()=>{if(p.id)cacheRemember(`m:${p.id}`);});

  // First paint of a mission lands at the bottom: hide the column for the few frames the
  // virtual list needs to mount and measure the tail, instead of showing the top then jumping.
  let landedFor = "";
  const landAtBottom = () => {
    if (!scroller || landedFor === p.id || !nearBottom) { landedFor = p.id; return; }
    landedFor = p.id;
    const el = scroller;
    el.classList.add("landing");
    const land = () => { if (nearBottom) el.scrollTo({ top: el.scrollHeight }); };
    // Stop following the moment the reader (or a test) scrolls away during the landing frames.
    land();
    // rAF can be throttled (background window, headless WebKit): never leave the thread hidden.
    let shown = false;
    const show = () => { if (shown) return; shown = true; land(); el.classList.remove("landing"); };
    const fallback = setTimeout(show, 80);
    requestAnimationFrame(() => { land(); requestAnimationFrame(() => { clearTimeout(fallback); show(); }); });
  };
  const scrollIfPinned = () => {
    if (nearBottom && !scroller?.dataset.panelResizing && !scroller?.querySelector(".user.editing")) scroller?.scrollTo({ top: scroller.scrollHeight });
  };
  // Resize notifications run after streaming Markdown has changed layout.
  onMount(() => {
    if (!scroller) return;
    // Near the top, or too short to scroll at all (a page of folded tool rows),
    // keep fetching older pages: a scroll event alone never fires otherwise.
    const older=()=>{
      const el=scroller!;
      const short=el.scrollHeight<=el.clientHeight+800;
      if((el.scrollTop<800||short)&&peekReadyTranscript(p.id)?.hasOlder)void loadOlder().then(()=>requestAnimationFrame(older)).catch(e=>setError(String(e)));
    };
    scroller.addEventListener('scroll',older,{passive:true});onCleanup(()=>scroller?.removeEventListener('scroll',older));
    const observer = new ResizeObserver(() => { if (nearBottom) scrollIfPinned(); older(); });
    const content = scroller.querySelector(".col");
    // Border box: the dock height is bottom padding, which a content-box observer misses.
    if (content) observer.observe(content, { box: "border-box" });
    const dock = scroller.nextElementSibling;
    if (dock) observer.observe(dock);
    onCleanup(() => observer.disconnect());
  });

  const refresh = async () => {
    if(!p.id)return;
    try {
      const next=await getMission(p.id);
      if(disposed)return;
      setMission(next);
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
  const reconcileRemoteQueue=(ids:string[])=>{
    const removed=new Set(remoteQueuedIds().filter(id=>!ids.includes(id)));
    setRemoteQueuedIds(ids);
    if(!removed.size)return;
    setItems(previous=>previous.filter(item=>item.kind!=="user"||!item.queued||!item.messageId||!removed.has(item.messageId)));
    liveEvents=liveEvents.filter(event=>event.type!=="user_message"||!event.data?.queued||!removed.has(String(event.data?.id)));
    void resync(true);
  };
  let replaying = false;
  let refreshAgain = false;
  const [refreshing, setRefreshing] = createSignal(false);
  let held: StreamEvent[] = [];
  let liveEvents:StreamEvent[]=[];
  const applyLive = (ev: StreamEvent) => {
    liveEvents.push(ev);
    setItems((cur) => {
      const next = timed("reduce event", () => applyStreamEvent(cur, ev));
      if (next !== cur) {
        putTranscriptItems(p.id, next);
        queueMicrotask(()=>{if(!disposed){scrollIfPinned();scroller?.dispatchEvent(new Event("orb:transcript-change",{bubbles:true}));}});
      }
      return next;
    });
  };
  const resync = async (fresh = false) => {
    if(disposed||!p.id)return;
    if (replaying) { refreshAgain ||= fresh; return; }
    replaying = true;
    held = [];
    let history: StreamEvent[] = [];
    try {
      const snap = await (fresh ? refreshTranscript(p.id) : loadTranscript(p.id));
      if(disposed)return;
      history = snap.stream;
      liveEvents=heldAfterHistory(history,liveEvents);
      // Absence from a queue snapshot is not proof of delivery: the event
      // logger can lag dequeue. Keep known pending entries until their ID is
      // explicitly delivered, including while a reconnect replay is in flight.
      let next = liveEvents.reduce((state,event)=>applyStreamEvent(state,event),snap.items);
      for (const item of items()) if (item.kind === "user" && item.queued && item.messageId) {
        next = applyStreamEvent(next, { type: "user_message", data: { id: item.messageId, content: item.text, queued: true, receipt: item.receipt, attached: item.attached } });
      }
      setItems(next);
      putTranscript(p.id, { ...snap, items: next });
      setQueueError(snap.queueError ?? null);
      setError(null);
    } catch (e) {
      const local=(await import("../localOrigins").then(m=>m.localOrigins()).catch(()=>[])).find(m=>m.id===p.id);
      if(disposed)return;
      if(local){
        const events:StreamEvent[]=local.history.filter(row=>row.content).map((row,index)=>({type:row.role==="user"?"user_message":"assistant_message",data:{id:`local:${p.id}:${index}`,content:row.content}}));
        setItems(events.reduce((list,event)=>applyStreamEvent(list,event),[] as StreamItem[]));setError(null);
      }else setError(e instanceof Error ? e.message : String(e));
    } finally {
      replaying = false;
      if(disposed)return;
      setAwaiting(false);
      landAtBottom();
      const queued = held;
      held = [];
      for (const ev of heldAfterHistory(history, queued)) applyLive(ev);
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
      let next=heldAfterHistory(snap.stream,liveEvents).reduce((state,event)=>applyStreamEvent(state,event),snap.items);
      for(const item of items())if(item.kind==='user'&&item.queued&&item.messageId)next=applyStreamEvent(next,{type:'user_message',data:{id:item.messageId,content:item.text,queued:true}});
      setItems(next);
    })().finally(()=>olderPending=undefined);
    return olderPending;
  };
  const prepareSearch=async(signal:AbortSignal)=>{
    while(!disposed&&!signal.aborted&&peekReadyTranscript(p.id)?.hasOlder)await loadOlder();
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
    if(!id)return;
    const reload = async () => {
      if (refreshing()) return;
      setRefreshing(true);
      try { await Promise.all([refresh(), resync(true)]); }
      finally { setRefreshing(false); }
    };
    window.addEventListener("orb:refresh", reload);
    onCleanup(() => window.removeEventListener("orb:refresh", reload));
    void refresh();
    // History must load even when the live connection has not opened yet.
    let initialReady = true;
    void resync(true).then(() => { if (nearBottom) scrollIfPinned(); });
    const stopStream = streamMission(
      p.id,
      (ev) => {
        if (ev.type === "mission_status_changed" || ev.type === "status") {
          if (ev.type === "mission_status_changed" && typeof ev.data.status === "string") {
            const status = ev.data.status;
            setMission(old => ({ ...(old ?? {id:p.id,title:null,history:[],created_at:"",updated_at:""}), status,
              status_message: typeof ev.data.summary === "string" ? ev.data.summary : old?.status_message }));
          }
          void refresh();
          return;
        }
        if (replaying) held.push(ev);
        else applyLive(ev);
      },
      () => void resync(true),
      () => {
        if (initialReady) {
          initialReady = false;
          if (nearBottom) scrollIfPinned();
          return;
        }
        void resync(true).then(() => { if (nearBottom) scrollIfPinned(); });
      },
    );
    // Slow status poll — the stream is authoritative for content, but the
    // composer busy state shouldn't depend on it alone.
    const stopPoll = pollWhileVisible(async () => {
      const wasMoving = missionPhase(mission(), activity()).moving;
      await refresh();
      // Reconcile through completion even if the live stream misses output.
      const transcript = items();
      const lastUser = transcript.reduce((last, item, index) => item.kind === "user" && !item.queued ? index : last, -1);
      // Partial text, thinking, and tools are activity, not a final reply.
      const hasFinalReply = transcript.slice(lastUser + 1).some(item =>
        (item.kind === "text" && !item.live && !!item.text.trim()) || item.kind === "error");
      const waitingForReply = ["awaiting_user", "waiting_user", "completed", "done"].includes(mission()?.status ?? "")
        && !hasFinalReply && viewItems().some(item => item.kind === "user" && !item.queued);
      if (wasMoving || missionPhase(mission(), activity()).moving || waitingForReply) await resync(true);
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

  const localMissionId=createMemo(()=>mission()?.tags?.includes("placement:client")?p.id:null);
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
    onCleanup(()=>{stopPoll();window.removeEventListener('orb:queue-wake',refreshLocal);});
  });

  createEffect(() => {
    const transfer = mission()?.machine_transfer;
    if (transfer) void adoptTransferredWorkspace(transfer).catch(e => setSendError(String(e)));
  });
  const clientPlaced = () => !!mission()?.tags?.includes("placement:client");
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
    if (localRunActive(p.id) && localActivities(p.id).length > 0) return true;
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
  const working = () => {
    if(sendError())return false;
    if(!p.id)return !p.launchError;
    if(sendingImmediate())return false;
    if(clientPlaced() && !localRunActive(p.id) && (localFailure(p.id) || queuedLocalMessages(p.id).some(row=>row.interrupted)))return false;
    return busy() || optimisticList().some(item => !item.waiting && !item.failed) || queuedLocalMessages(p.id).some(row=>!row.error && (!row.waiting || row.state==='dispatching' || row.state==='accepted'));
  };
  // A remote job queued for capacity has not started: say so instead of "Working".
  const phaseLabel = () => sendingImmediate() ? "Stopping the current turn…" : mission()?.remote_job?.node_state === "queued" ? "Waiting for a free slot" : mission()?.backend === "claudecode" && !activity() ? "Waiting for Claude Code" : "Working";

  const viewItems = createMemo(() => {
    const canonical = withInitialPrompt(items(), mission(), receipt, awaiting());
    const known = new Set(canonical.filter(i=>i.kind==='user').map(i=>i.kind==='user'?i.messageId:undefined));
    const outbox = [...acceptedLocalMessages(p.id), ...queuedLocalMessages(p.id).filter(row=>!row.error&&(!row.waiting||row.state==='accepted'||row.state==='dispatching'))];
    const drafts=optimisticList();
    const projected:StreamItem[]=[];
    for(const row of outbox){if(!known.has(row.id)){known.add(row.id);projected.push({kind:'user',key:`user:${row.id}`,messageId:row.id,text:row.text});}}
    for(const draft of drafts){if((!draft.waiting||draft.failed||sendError())&&!known.has(draft.id)){known.add(draft.id);projected.push({kind:'user',key:`user:${draft.id}`,messageId:draft.id,text:draft.text,images:draft.images});}}
    const list = [...canonical,...projected];
    const nativeTools = clientPlaced() ? localActivitiesToStreamItems(localActivities(p.id)) : [];
    const lastUserIdx = list.reduce((last, item, idx) => item.kind === "user" && !item.queued ? idx : last, -1);
    const hasCanonicalToolsAfterUser = list.slice(lastUserIdx + 1).some(item => item.kind === "tool");
    const withNativeTools = nativeTools.length && !hasCanonicalToolsAfterUser
      ? (() => {
          const copy = [...list];
          let insertAt = copy.length;
          for (let i = copy.length - 1; i > lastUserIdx; i--) {
            if (copy[i].kind === "text") insertAt = i;
            else break;
          }
          copy.splice(insertAt, 0, ...nativeTools);
          return copy;
        })()
      : list;
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
    return withLive.map((i) => (i.kind === "text" && i.live ? { ...i, live: false } : i));
  });

  const planProgress = createPlanProgress({get mission(){return p.id;},get items(){return viewItems();},get active(){return clientPlaced()?localRunActive(p.id):busy();}});
  createEffect(()=>p.onPlan?.(p.id,planProgress()));
  const titleContext = createMemo(() => awaiting() ? null : contextPct(estimateTokens(viewItems()), contextWindow(mission()?.backend)));
  createEffect(() => p.onContext?.(p.id, titleContext()));

  // Retrying an uncertain network result reuses the original message identity.
  // A different draft/selection, or a definitive rejection, starts a new attempt.
  let retryMessage: { key: string; id: string } | null = null;
  const sendMsgOnce = async (text: string, images: DraftImage[], chips: AttachChip[], attemptId: ReturnType<typeof crypto.randomUUID>, explicitId?: ReturnType<typeof crypto.randomUUID>, replace = false) => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || staleMission()) return false;
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
        // After a project move, the next turn runs in the new project's folder.
        const binding = await followProjectFolder(sendMission, project);
        if (!binding) throw new Error("This session runs on the computer that started it. Your draft is kept.");
        const plan = await materializeMentions(project, text, chips);
        await prepareProjectSkills(project, binding.cwd, binding.harness, binding.bin);
        if (plan.files.length) await writeLocalFiles(binding.cwd, plan.files);
        const imagePaths = await stageLocalImages(binding.cwd, images);
        const sent = imagePrompt(bindWorkspace(plan.prompt, binding.cwd), imagePaths, images);
        if(connectionVersion()!==sendVersion||staleMission()||p.id!==sendMission)throw new Error("Conversation changed. Your draft is kept.");
        if (optEntry && !drafts.has(attemptId)) return true;
        await enqueueLocalMessage({id:sendMission,harness:binding.harness,bin:binding.bin,cwd:binding.cwd,prompt:sent,model:mission()?.model_override ?? binding.model,effort:binding.harness === "antigravity" ? normalizeEffort(mission()?.model_effort,binding.harness) ?? undefined : undefined,service_tier:binding.harness === "codex" ? missionSpeed(mission()??{}) : undefined,imagePaths},imagePrompt(text,imagePaths,images),{id:attemptId,replace,waiting:explicitId ? busy() : optEntry?.waiting??busy()});
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
      const result = await sendMissionMessage(targetMissionId, sent, attachments, explicitId ?? retryMessage.id);
      retryMessage = null;
      if (staleMission()) return true;
      if (result.replacement) {
        const replacement = result.replacement;
        const nodeId = missionNode(replacement) ?? missionNode(mission()) ?? "";
        rememberLaunch(replacement.id, { prompt: sent, nodeId, destination: nodeLabel(nodeId), replacement: true });
        drafts.remove(attemptId);
        if (chips === followAttach()) setFollowAttach([]);
        p.onFork?.(replacement);
        return true;
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
    const attemptId = explicitId ?? sendingIds.shift() ?? crypto.randomUUID();
    const run = sendChain.then(async () => {
      drafts.setFailed(attemptId, false);
      const accepted = await sendMsgOnce(text, images, chips, attemptId, explicitId, replace);
      if (!accepted) drafts.setFailed(attemptId, true);
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
  const sendEditedPrompt = (text: string) => {
    // One pending resend owns its identity even across ambiguous network failures.
    if(resend()?.state==='sending')return true;
    if(resend()?.state==='error'&&!resendKnown())return false;
    setResend({id:crypto.randomUUID(),text,waiting:busy(),state:"accepted"});
    nearBottom=true;
    queueMicrotask(scrollIfPinned);
    void deliverResend();
    return true;
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

  const sendRemoteImmediate = async (
    ordered: { id: string; content: string; attached?: boolean }[],
    liveInjected?: { id: string; content: string; attached?: boolean }[],
  ) => {
    const targetMissionId = boundMissionId || p.id;
    if (!targetMissionId || staleMission()) return;
    if (liveInjected?.length) {
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
        if (replaying) held.push(event);
        else applyLive(event);
      }
    }
    if (!ordered.length) return;
    const wasBusy = busy();
    setSendingImmediate(true);
    setSendError(null);
    // Show the messages as sent right away: stopping a remote turn can take
    // several seconds, and the queue row has already disappeared.
    const projected = ordered.map(row => row.id as ReturnType<typeof crypto.randomUUID>);
    drafts.replaceAll(ordered.map(row => ({ id: row.id as ReturnType<typeof crypto.randomUUID>, text: messagePresentation(row.content).text, images: [], waiting: false })));
    nearBottom = true;
    queueMicrotask(scrollIfPinned);
    try {
      if (wasBusy) {
        await cancelMission(targetMissionId).catch(swallow("mission.sendNow.cancel", { mission: targetMissionId }));
        for (let poll = 0; poll < 75; poll++) {
          if (staleMission() || p.id !== targetMissionId) return;
          try {
            const current = await getMission(targetMissionId);
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
      <div class="mission-tools"><Changes items={viewItems()} githubPr={mission()?.github_pr} /><Chapters items={viewItems()} scroller={() => scroller} /></div>
      <div
        class="scroll"
        ref={scroller}
        onScroll={() => {
          if(scroller?.dataset.panelResizing)return;
          nearBottom = !scroller || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
        }}
      >
        <div class="col" style={peekTranscriptHeight(p.id) && awaiting() ? { "min-height": `${peekTranscriptHeight(p.id)}px` } : undefined}>
          <Show
            when={!awaiting() || !!receipt || viewItems().length > 0}
            fallback={
              <>
                <Show when={receipt}>
                  {(r) => (
                    <>
                      <LaunchStatus destination={missionDestination(mission(), r())} mission={mission()} goal={missionGoal(mission(), r())} />
                      <UserTurn text={r().prompt} images={r().images} pending={working()} onSend={p.id ? sendEditedPrompt : undefined} />
                      <Show when={working()}>
                        <MissionPending destination={missionDestination(mission(), r())} label={phaseLabel()} />
                      </Show>
                    </>
                  )}
                </Show>
                <DelayedTranscriptSkeleton />
              </>
            }
          >

            <Show when={mission() && (!missionPhase(mission(), activity()).moving || ["Checking submission", "Checking remote job"].includes(missionPhase(mission(), activity()).label))}>
              <LaunchStatus destination={missionDestination(mission(), receipt)} mission={mission()} activity={activity()} goal={missionGoal(mission(), receipt)} onResume={() => void actOnRecovery("resume")} onCancelRecovery={() => void actOnRecovery("cancel")} recoveryPending={recoveryPending()} />
            </Show>
            <Transcript sizeKey={p.id ? `m:${p.id}` : undefined} working={working()} workingLabel={`${phaseLabel()} on ${missionDestination(mission(), receipt)}…`} prepareSearch={prepareSearch} items={viewItems().filter(i => i.kind !== "user" || !i.queued)} pending={working() && !activity()} onSend={p.id ? sendEditedPrompt : undefined} onResume={!busy() && !localQueueActive() && (clientPlaced() || (!remoteQueuedIds().length && !items().some(i => i.kind === "user" && i.queued))) && missionPhase(mission(), false).failed && missionPhase(mission(), false).label !== "Cancelled" ? resume : undefined} />
            <TurnRecap mission={mission() ?? undefined} items={viewItems()} busy={busy()} onDraft={text=>setSideRevision({text,append:false})} />
            <Show when={!resendKnown() ? resend() : undefined}>{row=><div class="resend-feedback">
              <UserTurn text={row().text}/>
              <div class="resend-status" role="status">{row().state==='error' ? row().error : row().state==='sending' ? (row().waiting ? "Sending · queued after the current turn…" : "Sending…") : row().waiting ? "Queued after the current turn" : "Sent"}
                <Show when={row().state==='error'}><button onClick={()=>void deliverResend()}>Retry</button></Show>
              </div>
            </div>}</Show>
            <Show when={clientPlaced() && localActivities(p.id).some(a => a.kind === "status" || a.id === "antigravity:status" || a.background || a.id.startsWith("task:"))}>
              <AgentActivity items={localActivities(p.id)} running={localRunActive(p.id)} completed={activityShouldCollapse(mission()?.status, localRunActive(p.id))} />
            </Show>
            <NativeInteraction mission={p.id} active={clientPlaced() ? localRunActive(p.id) : busy()} remote={!clientPlaced()} items={viewItems()} onSend={text => sendMsg(text, [], [])} />
            <Show when={!sendError()}>
              <MissionFailure mission={mission()} active={busy() || localQueueActive() || working() || !!sentOverStop() || (!clientPlaced() && (remoteQueuedIds().length > 0 || items().some(i => i.kind === "user" && i.queued)))} error={clientPlaced() ? localFailure(p.id) : undefined} onResume={resume} failureInTranscript={visibleTranscript(viewItems()).some(item => item.kind === "error")} />
            </Show>
          </Show>

          <NextReminder mission={p.id} busy={busy()} />
          <Show when={refreshing()}><div class="agent-wait-status" role="status">Refreshing conversation…</div></Show>
        </div>
      </div>
      <div class="dock" ref={floatingDock}>
        <div class="col">
          <Show when={p.id}><SideQuestions mission={p.id} items={viewItems()} ref={handle=>sideQuestions=handle} onTransfer={text=>setSideRevision({text,append:true})} onOpenSession={p.onFork?async id=>p.onFork?.(await getMission(id)):undefined}/></Show>
          <RemoteQueue mission={p.id}
            ref={handle => remoteQueue = handle}
            editing={editingQueued()}
            onEdit={row => void queuedEdit.start(row)}
            onSendImmediate={sendRemoteImmediate}
            pending={!clientPlaced() && !sendError() ? optimisticList().filter(item => item.waiting && !item.failed).map(item => ({id:item.id,content:item.text})) : undefined}
            confirmed={clientPlaced() ? [] : items().filter((item): item is Extract<StreamItem,{kind:"user"}> => item.kind === "user" && item.queued === true && !!item.messageId).map(item=>({id:item.messageId!,content:item.text,attached:item.attached}))}
            delivered={items().flatMap(item => item.kind === "user" && !item.queued && item.messageId ? [item.messageId] : [])}
            onRetract={id=>{
              setItems(previous=>previous.filter(item=>item.kind!=="user"||item.queued||item.messageId!==id));
              liveEvents=liveEvents.filter(event=>event.type!=="user_message"||event.data?.queued||event.data?.id!==id);
              held=held.filter(event=>event.type!=="user_message"||event.data?.queued||event.data?.id!==id);
            }}
            onRows={reconcileRemoteQueue} onCancel={id=>{
            setItems(previous=>previous.filter(item=>item.kind!=="user"||!item.queued||item.messageId!==id));
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
            retainFailedMessage
            onSendError={setSendError}
            onSend={async (text,images)=>{
              const id=editingQueued();
              if(!id)return sendMsg(text,images);
              if(queuedEdit.editingRemote()&&remoteQueue){
                const saved=await remoteQueue.replaceEdited(
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
            onAttachments={setFollowAttach}
          />
          <ErrorToast title="Couldn’t send your message" error={p.launchError} action={p.onRetryLaunch ? { label: "Retry", run: p.onRetryLaunch } : undefined} />
          <Show when={mission()?.local_sync_pending}><div class="dim" role="status">{mission()?.local_sync_error || "Saved on this computer · syncing to Core…"}</div></Show>
          <ErrorToast error={sendError()} title="Couldn’t send your message" onDismiss={() => setSendError(null)}
            action={optimistic() ? { label: "Retry", run: () => { const draft = optimistic(); if (draft?.retry) draft.retry(); else if (draft) void sendMsg(draft.text, draft.images, followAttach(), draft.id); } } : undefined} />
          <ErrorToast error={error() || queueError()} title="Couldn’t load the conversation" onDismiss={() => { setError(null); setQueueError(null); }} />
          <MissionDock mission={mission()} items={viewItems()} destination={missionDestination(mission(), receipt)} onMission={setMission} onError={setError} onFork={p.onFork} />
        </div>
      </div>
    </>
  );
}

