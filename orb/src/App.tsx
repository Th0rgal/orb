import { renamedTitle, withRenamedTitles } from "./renames";
import { jsonSignal, readString, writeString } from "./storage";
import { missionAssignedNode, missionNode, nodeLabel } from "./machines/nodes";
import { isFailedStatus, isLive, isRunning, isSettingsIdle } from "./missionStatus";
import { errorText, log, swallow } from "./log";
import { flushClientLink, connectClientLink, reportClientHarnesses, type RemoteStart } from "./clientLink";
import {CodexSpeedPicker, missionSpeed, requireSpeedSupport} from './CodexSpeedPicker';
import type {CodexServiceTier} from './api';
import { Picker } from "./Picker";
import { Menu } from "./Menu";
import { Popover } from "./Popover";
import { missionParent } from "./missionTree";
import { destinationHarnessChoices } from "./harness-models";
import { RemoteQueue, type RemoteQueueHandle } from "./RemoteQueue";
import { CyberPicker, MissionCyber, draftCyber, setDraftCyber, requireCyberSupport } from "./cyberAccess";
import {trackScrollbarHover} from "./scrollbarHover";
import {NextReminder} from "./AutomaticReminder";
import {WorkingDirectoryPicker} from "./WorkingDirectoryPicker";
import { MessageCircle } from "./sidebarIcons";
import {MentionPicker} from "./MentionPicker";
import {MentionProjectContext} from "./PromptEditor";
import { startLocalWakeups } from "./localWakeups";
import { startClientDelegations } from "./clientDelegations";
import { navigationShortcut, shortcutLabel } from "./keyboardShortcuts";
import {preferSparkAdministration} from "./machineDestinations";
import { CloudAgentPage, CloudConversation } from "./CloudAgents";
import { monitorSoftware } from "./softwareInventory";
import {QueuedMessages} from "./QueuedMessages";
import {enqueueLocalMessage,startLocalQueueWorker,queuedLocalMessages,acceptedLocalMessages,forgetAcceptedLocalMessages,sendQueuedNow,resumePrompt} from "./localMessageQueue";
import {createQueuedEdit} from "./queuedEdit";
import {messagePresentation} from "./messagePresentation";
import {BtwSettings} from "./btwSettings";
import {createPlanProgress, type PlanProgressData} from "./PlanProgress";
import { nativeComposerDrop } from "./composerDrop";
import { SideQuestions, type SideQuestionsHandle } from "./SideQuestionPanel";
import { AgentActivity, activityShouldCollapse } from "./AgentActivity";
import { startLocalOrigin, localRunKnown, localAgentForLaunch } from "./localAgents";
import { ChangeMachine, preloadMachineDestinations } from "./ChangeMachine";
import { MachineLoadBadge, byLeastLoaded, firstAvailableNodeId, recordFleet, recordMissions } from "./machineLoad";
import { adoptTransferredWorkspace } from "./machineTransfer";
import { NativeInteraction } from "./NativeInteraction";
import { backgroundUploads, cancelBackgroundUpload, encoded, formatFileSize, HARD_MAX_BYTES, hasNativePicker, pauseBackgroundUpload, pickNativeFiles, prepareUploads, resumeBackgroundUpload, softLimitForDestination, startBackgroundUpload, statUploadSource, transferFile, uploadToken, type UploadedFile, type UploadSource } from "./uploads";
import { readComposerDraft, saveComposerDraft } from "./composerDrafts";
import { readImagePaste, imagePrompt, stageLocalImages, stageRemoteImages, IMAGE_COUNT, type DraftImage } from "./imageAttachments";
import { FilePanelProvider, FilePanelButton } from "./FilePanel";
import { ErrorToast } from "./toast";
import { MissionFailure, LaunchStatus, MissionPending, missionPhase, rememberLaunch, recalledLaunch, missionDestination, withInitialPrompt, launchError, launchRefusal, isAdministrationNode, remoteLaunchPreflight, remoteHarnessSupport, remoteLaunchUnconfirmed, missionGoal, dockModelLabel, type LaunchReceipt, type LaunchRefusal, type RemoteSupport } from "./missionLaunch";
import { goalDraft, goalPrompt, planObjective, missionTitle, displayTitle, EMPTY_GOAL_ERROR, absorbGoalPrefix, composerModes, filterSlash, slashQuery, modePrompt, ModeChip, type ComposerMode } from "./goal";
import { atQuery, browseAttachItems, chipToAttachment, filterAttach, folderPrefixFromQuery, insertMention, loadAttachItems, mentionedChips, type AttachChip, type AttachItem } from "./attach";
import { DEFAULT_PROJECT, ensureDefaultProject, projectChoices } from "./defaultProject";
import { ProjectPicker, ProjectCreation } from "./ProjectPicker";
import { hasOverlay } from "./overlayLayer";
import { Lightbox } from "./Lightbox";
import { For, Show, Switch, Match, lazy, createMemo, createSignal, createEffect, on, onCleanup, onMount, batch } from "solid-js";
import type { JSX } from "solid-js";
import * as Ic from "./icons";
import { ForkMission } from "./ForkMission";
const Settings=lazy(()=>import("./Settings").then(module=>({default:module.Settings})));
import { ProviderLogo } from "./ProviderLogo";
import { SessionPreview, type SessionPreviewData } from "./SessionPreview";
import { RoutingSettings, confirmLeaveRouting } from "./RoutingSettings";
import { MACHINES, Machines } from "./Machines";
const Providers=lazy(()=>import("./Providers").then(module=>({default:module.Providers})));
import { PopupMenu, type MenuEntry } from "./Menu";
import { mdSource, toggleMdSource } from "./Markdown";
import { streamMission, heldAfterHistory, type StreamEvent } from "./stream";
import { localActivitiesToStreamItems } from "./workModel";
import { applyPendingMoves } from "./missionMove";
import { Chapters } from "./Chapters";
import { Changes } from "./Changes";
import { TurnRecap } from "./TurnRecap";
import { Transcript, UserTurn, applyStreamEvent, type StreamItem } from "./Transcript";
import { cacheRemember, cacheRecents } from "./pageCache";
import { antigravityBaseModel, defaultEffortLabel, effortLabel, harnessSupportsEffort, normalizeEffort, supportedEfforts } from "./effort";
import { retainTranscript, loadOlderTranscript, refreshTranscript, loadTranscript, peekReadyTranscript, peekTranscriptHeight, prefetchTranscript, putTranscript, putTranscriptHeight, putTranscriptItems, transcriptVersion } from "./missionCache";
import { ConversationSkeleton, DelayedTranscriptSkeleton } from "./Skeleton";
import { visibleTranscript } from "./transcriptModel";
import { mergeById, pollWhileVisible } from "./poll";
import { getSecretBroker } from "./bitwardenApi";
import { syncSecretRequestNotices } from "./secretRequestNotices";
import { listApprovalDevices, thisDeviceEnrollment } from "./deviceApproval";
import { LiveProjectsSection, ProjectFileView, isMissionDeleting } from "./ProjectFiles";
const ProjectSettings=lazy(()=>import("./ProjectSettings").then(module=>({default:module.ProjectSettings})));
import { VoiceButton, ensureVoiceProbe, voiceAvailable } from "./VoiceButton";
import { insertAtCaret } from "./voice";
import { contextPct, contextWindow, estimateTokens, formatTokens } from "./missionContext";
import {
  bindWorkspace,
  installedIds,
  localBinding,
  localInstalled,
  localAgentsScanning,
  localLiveText,
  localActivities,
  localFailure,
  recordLocalFailure,
  localRunActive,
  reconcileLocalRun,
  localWorkspace,
  localDirectory,
  materializeMentions,
  prepareProjectSkills,
  refreshLocalAgents,
  stopLocal,
  writeLocalFiles,
} from "./localAgents";
import { ControllerView } from "./Controller";
import { timed } from "./diagnostics";
import {
  createMission,
  getMission,
  getRemoteNodes,
  isConnected,
  listCompletedMissions,
  listMissions,
  listProjectMissions,
  listProjects,
  listHarnessChoices,
  shortModelLabel,
  createProject,
  bumpProjects,
  projectsVersion,
  type HarnessChoice,
  cancelMission,
  setClientMissionStatus,
  sendMissionMessage,
  ApiError,
  MessageRejectedError,
  connectionVersion,
  getApiUrl,
  updateMissionSettings,
  type Mission,
  type ProjectSummary,
  type RemoteNodeView,
  type RemoteLaunchCapability,
  type RemoteNodesResponse,
  listNodeAntigravityModels,
} from "./api";
const HermesSettings = lazy(() => import("./HermesSettings").then(module => ({ default: module.HermesSettings })));
const SkillsSettings = lazy(() => import("./SkillsSettings").then(module => ({ default: module.SkillsSettings })));
const BitwardenSettings = lazy(() => import("./BitwardenSettings").then(module => ({ default: module.BitwardenSettings })));
import { InboxPage } from "./Inbox";
import { requestInboxDigest } from "./inboxDigest";
import { countUnreadInboxMissions, listUnreadInboxCandidates } from "./inboxModel";
import { InboxSettings, inboxConfig } from "./inboxSettings";
import { pendingMissionInteraction } from "./missionAttention";
import { markMissionRead, unreadVersion } from "./missionUnread";

const PAGES = new Set(["inbox", "cloud-agent", "settings", "inbox-settings", "btw-settings", "hermes-settings", "skills-settings", "bitwarden-settings", "routing", "machines", "providers", "execution"]);

const MODELS = ["Orb Lorem 4.6 High Fast", "Ipsum 5 Max", "Dolor 4.5 Sonnet", "Auto"];

/** Harness + model chosen for new agents; persisted per user. `effort` is
 * absent for "let the backend decide", and is dropped whenever the selected
 * harness does not accept that level (see `effort.ts`). */
export type HarnessPick = { backend: string; model: string; effort?: string; service_tier?: CodexServiceTier };
const PICK_KEY = "orb.harnessPick";
const [remoteHarnessChoices, setRemoteHarnessChoices] = createSignal<HarnessChoice[]>([]);
const [nodeAntigravityModels, setNodeAntigravityModels] = createSignal<Record<string, [string,string][]>>({});
const nodeModelRequests = new Set<string>();
async function refreshNodeAntigravityModels(machine: string) {
  if (machine === "local") return;
  const version = connectionVersion(), key = `${version}:${machine}`;
  if (nodeModelRequests.has(key)) return;
  nodeModelRequests.add(key);
  try {
    const models = await listNodeAntigravityModels(machine);
    if (version === connectionVersion()) setNodeAntigravityModels(old => ({...old, [key]:models}));
  } catch {
    // A slow or failed lookup must not hide Antigravity on this machine for the whole
    // session: keep whatever was known and retry shortly instead of caching [].
    if (version === connectionVersion()) setTimeout(() => void refreshNodeAntigravityModels(machine), 15_000);
  }
  finally { nodeModelRequests.delete(key); }
}
const harnessChoices = (machine = "core"): HarnessChoice[] => {
  const models = machine === "local" ? (localInstalled().find(row => row.id === "antigravity")?.models ?? []) : (nodeAntigravityModels()[`${connectionVersion()}:${machine}`] ?? []);
  return destinationHarnessChoices(remoteHarnessChoices(), machine, models, localInstalled().some(row => row.id === "vibe" && row.installed));
};
const [harnessPick, setHarnessPick] = jsonSignal<HarnessPick | null>(PICK_KEY, null);
/** Preserve an explicit selection; launch validation reports unavailable models.
 * A stored effort is normalized against the stored harness on every read, so a
 * level that harness never accepted can't survive into a create payload. */
const effectivePick = (machine = "core"): HarnessPick | null => {
  const choices = harnessChoices(machine);
  if (!choices.length) return null;
  const stored = harnessPick();
  if (stored) {
    const effort = normalizeEffort(stored.effort, stored.backend);
    return { ...stored, effort: effort ?? undefined };
  }
  const first = choices.find((c) => c.backend.id === "claudecode") ?? choices[0];
  return { backend: first.backend.id, model: first.models[0].value };
};
async function refreshHarnessChoices() {
  try {
    setRemoteHarnessChoices(await listHarnessChoices());
  } catch {
    /* keep last */
  }
}

export const draftLightbox = (images: DraftImage[]) => images.map((image, index) => ({ src: image.dataUrl, label: image.reference ? `Image #${image.reference}` : `Image ${index + 1}` }));

function OptimisticMessage(p: {draft:{text:string; images:DraftImage[]}}) {
  const [viewing,setViewing]=createSignal<number|null>(null);
  return <div class="optimistic-message" aria-label="Pending message"><div class="user"><Show when={p.draft.images.length}><div class="message-images"><For each={p.draft.images}>{(image,index)=><button type="button" class="message-image" aria-label={`Open image #${image.reference ?? index()+1}`} onClick={()=>setViewing(index())}><img src={image.dataUrl} alt={`Image #${image.reference ?? index()+1}`}/><span>#{image.reference ?? index()+1}</span></button>}</For></div></Show><Show when={viewing()!==null}><Lightbox items={draftLightbox(p.draft.images)} index={viewing()!} onClose={()=>setViewing(null)}/></Show><span>{p.draft.text}</span></div><span class="composer-pending-status" role="status">Waiting for confirmation…</span></div>;
}

export function Composer(p: {
  revision?: { text: string; append?: boolean };
  onBtw?: (question: string, images?: DraftImage[], files?: UploadedFile[]) => boolean | Promise<boolean>;
  sideQuestion?: boolean;
  onOpenBtw?: () => void;
  placeholder: string;
  busy: boolean;
  onSend: (t: string, images: DraftImage[], files?: UploadedFile[]) => void | boolean | Promise<void | boolean>;
  onStop?: () => void;
  textOnly?: boolean;
  imagesOnly?: boolean;
  directFileUpload?: boolean;
  controls?: JSX.Element;
  disabled?: boolean;
  autofocus?: boolean;
  tall?: boolean;
  /** Show the harness + model picker (new agents only). */
  picker?: boolean;
  /** Conversation identity; dictation results for another scope are dropped. */
  scope?: string;
  /** Server-confirmed remote support for a harness on the selected machine (new agents only). */
  remoteSupport?: (backend: string) => { state: RemoteSupport; note: string };
  /** When set, the harness menu only lists these ids (This computer). */
  harnessIds?: string[];
  /** Follow-up: the mission's harness. New agent uses the picker. */
  backend?: string;
  onDraft?: (text: string) => void;
  onPending?: (draft: {text:string; images:DraftImage[]; retry?:()=>void} | null) => void;
  onSendError?: (error:string)=>void;
  retainFailedMessage?:boolean;
  projectSlug?: string;
  /** Reports what the draft currently mentions; the draft text is the source. */
  onAttachments?: (next: AttachChip[]) => void;
  uploadTarget?: string;
  /** Editing a queued follow-up in place: shows the chip, × cancels. */
  editingQueued?: { onCancel: () => void };
  /** Enter on an empty draft (e.g. send the queued follow-ups now). */
  onEmptySubmit?: () => void;
  /** Right arrow on an empty draft edits the first queued message. */
  onEditFirstQueued?: () => void;
  /** Allow typing and stacking follow-up messages while an earlier send is in flight. */
  allowConcurrentSend?: boolean;
}) {
  const [text, setText] = createSignal("");
  const [uploading, setUploading] = createSignal(false);
  const [uploadError, setUploadError] = createSignal<string | null>(null);
  const [pendingLargeUploads, setPendingLargeUploads] = createSignal<Array<{ source: UploadSource; size: number; destination: string }>>([]);
  let uploaded: UploadedFile[] = [];
  let disposed = false;
  onCleanup(() => { disposed = true; });
  let fileInput!: HTMLInputElement;
  const uploadTarget = () => p.uploadTarget ?? "core";
  const attachmentTarget = () => ["local", "side"].includes(uploadTarget()) ? uploadTarget() : p.projectSlug ? `context:${p.projectSlug}` : uploadTarget();
  const insertUploadedFile = (file: UploadedFile) => {
    uploaded.push(file);
    const current = ta ? (ta.selectionStart ?? text().length) : text().length;
    const token = uploadToken(file.path) + " ";
    const next = insertAtCaret(text(), current, ta ? (ta.selectionEnd ?? current) : current, token);
    write(next.value); setCaret(next.caret); ta?.setSelectionRange(next.caret, next.caret);
  };
  const confirmLargeUploads = () => {
    const items = pendingLargeUploads();
    setPendingLargeUploads([]);
    const scopeKey = p.scope ?? "new";
    for (const item of items) {
      startBackgroundUpload({
        source: item.source,
        destination: item.destination,
        totalBytes: item.size,
        confirmedLarge: true,
        scope: scopeKey,
        onComplete: (file) => {
          if (!disposed) insertUploadedFile(file);
        },
      });
    }
  };
  const scopedBgUploads = createMemo(() => {
    const scopeKey = p.scope ?? "new";
    return backgroundUploads().filter((item) => item.scope === scopeKey && (item.state === "uploading" || item.state === "paused" || item.state === "failed"));
  });
  const attachSources = async (sources: UploadSource[]) => {
    if (p.textOnly || p.imagesOnly) return;
    const scope = p.scope;
    const destination = attachmentTarget();
    const softLimit = softLimitForDestination(destination);
    setUploading(true); setUploadError(null); setCtx(false);
    try {
      const largeQueue: Array<{ source: UploadSource; size: number; destination: string }> = [];
      for (const source of sources) {
        if (disposed || scope !== p.scope || destination !== attachmentTarget()) return;
        const stat = await statUploadSource(source);
        if (stat.size > HARD_MAX_BYTES) {
          throw new Error(`${source.name} (${formatFileSize(stat.size)}) exceeds the 2 GiB maximum.`);
        }
        if (stat.size > softLimit) {
          largeQueue.push({ source, size: stat.size, destination });
          continue;
        }
        const file = await transferFile(source, destination);
        if (disposed || scope !== p.scope || destination !== attachmentTarget()) return;
        insertUploadedFile(file);
      }
      if (largeQueue.length) {
        setPendingLargeUploads((prev) => [...prev, ...largeQueue]);
      }
    } catch (error) { const message=error instanceof Error ? error.message : String(error);setUploadError(message);p.onSendError?.(message); }
    finally { setUploading(false); }
  };
  let composerElement:HTMLDivElement|undefined;
  nativeComposerDrop(()=>composerElement, async sources=>{
    if(sendingLocked()||uploading()||readingImages()) { setUploadError("Please wait for the current attachment or message to finish, then drop your files again."); return; }
    if (p.imagesOnly || p.directFileUpload) await attachMixed(sources);
    else await attachSources(sources);
  });
  const attachMixed = async (sources: UploadSource[]) => {
    if (p.textOnly) return;
    try {
    const scope=p.scope;
    sources=await Promise.all(sources.map(async source=>{
      const mime:Record<string,string>={png:"image/png",jpg:"image/jpeg",jpeg:"image/jpeg",webp:"image/webp",gif:"image/gif"};
      const type=mime[source.name.split('.').at(-1)?.toLowerCase()??''];
      if(!source.file&&source.localPath&&type){
        const bytes=Uint8Array.from(atob(await encoded(source)),c=>c.charCodeAt(0));
        return {...source,file:new File([bytes],source.name,{type})};
      }
      return source;
    }));
    if(disposed||scope!==p.scope)return;
    const pictures = sources.filter(source => source.file?.type.startsWith("image/"));
    if (pictures.length) {
      const clipboard = { files: pictures.map(source=>source.file!), getData:()=>"" };
      await pasteImages({clipboardData:clipboard,preventDefault(){}} as unknown as ClipboardEvent);
    }
    const files = sources.filter(source => !pictures.includes(source));
    if (files.length && !p.imagesOnly) await attachSources(files);
    else if (files.length && p.imagesOnly) setImageError("Use a PNG, JPEG, WebP or GIF image.");
    } catch(error){setUploadError(error instanceof Error?error.message:String(error));}
  };
  const chooseFiles = async () => {
    setCtx(false); setUploadError(null);
    if (p.imagesOnly || p.directFileUpload || !hasNativePicker()) { fileInput.click(); return; }
    const scope = p.scope;
    const selection = uploadTarget();
    try { const files = await pickNativeFiles(); if (!disposed && scope === p.scope && selection === uploadTarget()) await attachMixed(files); }
    catch (error) { setUploadError(error instanceof Error ? error.message : String(error)); }
  };
  const [images, setImages] = createSignal<DraftImage[]>([]);
  const [viewing, setViewing] = createSignal<number | null>(null);
  const [sendingCount, setSendingCount] = createSignal(0);
  const sending = () => sendingCount() > 0;
  const sendingLocked = () => sending() && (!p.allowConcurrentSend || !!p.editingQueued);
  const [pendingSend, setPendingSend] = createSignal<{text:string; images:DraftImage[]} | null>(null);
  const [mode, setMode] = createSignal<ComposerMode | null>(null);
  const [draftReady, setDraftReady] = createSignal(false);
  createEffect(on(() => p.scope, (scope, previous) => {
    if (previous !== undefined && previous !== scope) { setText(""); setImages([]); setMode(null); uploaded = []; }
    setDraftReady(false);
    if (!scope) { setDraftReady(true); return; }
    let current=true;
    onCleanup(() => {
      current=false;
      // A fast close can happen before hydration enables the persistence
      // effect. Flush typed content without clearing an untouched disk draft.
      if (draftReady() || text() || images().length || mode()) {
        void saveComposerDraft(scope,{text:pendingSend()?.text ?? text(),images:pendingSend()?.images ?? images(),mode:mode(),uploads:uploaded.map(file => ({...file, source:file.source}))}).catch(swallow("composer.saveDraft", { scope, phase: "close" }));
      }
    });
    void readComposerDraft(scope).then(draft => {
      if (current && draft && !text() && !images().length) {
        uploaded = (draft.uploads ?? []).map(file => ({...file, connection: file.endpoint === getApiUrl() ? connectionVersion() : -1}));
        setText(draft.text);setImages(draft.images);
        if(draft.mode) setMode(draft.mode);
        queueMicrotask(() => { if (ta?.isConnected) { ta.value=draft.text; resize(); } });
      }
    }).catch(swallow("composer.readDraft", { scope })).finally(() => { if (current) setDraftReady(true); });
  }));
  let draftTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingDraftSave: { scope: string; draft: Parameters<typeof saveComposerDraft>[1] } | null = null;
  const flushDraftSave = () => {
    if (draftTimer !== undefined) {
      clearTimeout(draftTimer);
      draftTimer = undefined;
    }
    if (pendingDraftSave) {
      const { scope, draft } = pendingDraftSave;
      pendingDraftSave = null;
      void saveComposerDraft(scope, draft).catch(swallow("composer.saveDraft", { scope }));
    }
  };
  onCleanup(flushDraftSave);
  createEffect(() => {
    const scope = p.scope;
    const ready = draftReady();
    const curText = pendingSend()?.text ?? text();
    const curImages = pendingSend()?.images ?? images();
    const curMode = mode();
    if (!ready || !scope) return;
    const draft = {
      text: curText,
      images: curImages,
      mode: curMode,
      uploads: uploaded.map((file) => ({ ...file, source: file.source })),
    };
    if (!curText && !curImages.length && !curMode) {
      pendingDraftSave = { scope, draft };
      flushDraftSave();
      return;
    }
    pendingDraftSave = { scope, draft };
    if (draftTimer !== undefined) clearTimeout(draftTimer);
    draftTimer = setTimeout(flushDraftSave, 180);
  });
  const [imageError, setImageError] = createSignal<string | null>(null);
  const [readingImages, setReadingImages] = createSignal(false);
  const pasteImages = async (event: ClipboardEvent) => {
    if (p.textOnly) return;
    const clipboard = event.clipboardData;
    if (!clipboard) return;
    const files = Array.from(clipboard.files).filter(file => file.type.startsWith("image/"));
    const html = clipboard.getData("text/html");
    const plain = clipboard.getData("text/plain");
    if (!files.length && !/<img\b|data-proton-embedded\s*=/i.test(html)) return;
    event.preventDefault();
    if (readingImages() || sendingLocked()) return;
    setImageError(null);
    const scope = p.scope;
    const original = text(), start = ta.selectionStart, end = ta.selectionEnd;
    setReadingImages(true);
    try {
      const first = Math.max(0, ...images().map(image => image.reference ?? 0)) + 1;
      const next = await readImagePaste(html, plain, files, first);
      if (disposed || scope !== p.scope) return;
      if (images().length + next.images.length > IMAGE_COUNT) throw new Error(`Attach up to ${IMAGE_COUNT} images at a time.`);
      // Do not overwrite edits made while an embedded image was loading.
      if (text() !== original) throw new Error("The draft changed while images loaded. Paste again to insert them at the cursor.");
      const value = original.slice(0, start) + next.text + original.slice(end);
      setImages(previous => [...previous, ...next.images]);
      setText(value); ta.value = value;
      ta.setSelectionRange(start + next.text.length, start + next.text.length);
      resize();
    } catch (e) { if (scope === p.scope) setImageError(e instanceof Error ? e.message : String(e)); }
    finally { setReadingImages(false); }
  };
  createEffect(on(() => p.scope, () => { setImages([]); setImageError(null); }, {defer:true}));
  // Local voice input (macOS): dictated text lands at the caret, never sends.
  const [voiceActive, setVoiceActive] = createSignal(false);
  ensureVoiceProbe();

  const [slashHi, setSlashHi] = createSignal(0);
  const [model, setModel] = createSignal(MODELS[0]);
  const live = () => isConnected() && harnessChoices(p.uploadTarget).length > 0;
  const [menu, setMenu] = createSignal(false);
  const [ctx, setCtx] = createSignal(false);
  const [which, setWhich] = createSignal<"harness" | "model" | "effort" | null>(null);
  const [slashOff, setSlashOff] = createSignal(false);
  const [atOff, setAtOff] = createSignal(false);
  const [atHi, setAtHi] = createSignal(0);
  const [atItems, setAtItems] = createSignal<AttachItem[]>([]);
  const [caret, setCaret] = createSignal(0);
  let ta!: HTMLTextAreaElement;
  const pick = () => effectivePick(p.uploadTarget);
  const backend = () => p.backend ?? pick()?.backend ?? null;
  // Restored local conversations can open before New Agent or Settings has
  // scanned installed harnesses. Load capabilities for their composer too.
  createEffect(() => {
    if (p.uploadTarget === "local") void refreshLocalAgents(false);
    else if (p.uploadTarget) void refreshNodeAntigravityModels(p.uploadTarget);
  });
  const modes = createMemo(() => p.textOnly || p.imagesOnly || p.sideQuestion ? [] : [...composerModes(backend(), p.uploadTarget === "local" ? !!localInstalled().find(h=>h.id===backend())?.plan_supported : !!p.uploadTarget && !!harnessChoices(p.uploadTarget).find(h=>h.backend.id===backend())?.backend.native_plan), ...(p.onBtw ? [{id:"btw" as const, section:"Modes" as const,label:"Side question",title:"Ask without interrupting the agent"}] : [])]);
  const slash = createMemo(() => {
    if (mode() || voiceActive() || slashOff()) return null;
    const q = slashQuery(text());
    if (!q.open) return null;
    const items = filterSlash(modes(), q.query);
    return items.length ? { query: q.query, items } : null;
  });
  const [ctxFolder, setCtxFolder] = createSignal("");
  const atSource = createMemo<AttachItem[]>(() => {
    return [...(p.sideQuestion || mode() === "btw" ? [{ id: "btw:conversation", kind: "context" as const, section: "Context" as const, path: "conversation", label: "conversation · Latest agent conversation" }] : []), ...(isConnected() ? atItems() : [])];
  });
  const at = createMemo(() => {
    if (p.textOnly || p.imagesOnly || voiceActive() || atOff() || slash()) return null;
    const q = atQuery(text(), caret());
    if (!q.open) return null;
    const source = atSource();
    const items = filterAttach(source, q.query);
    const folder = folderPrefixFromQuery(source, q.query) ?? "";
    return items.length ? { query: q.query, items, folder } : null;
  });
  const setAtFolder = (folder: string) => {
    const q = atQuery(text(), caret());
    if (!q.open || q.start < 0) return;
    const token = folder ? `@${folder.replace(/\/+$/, "")}/` : "@";
    const next = `${text().slice(0, q.start)}${token}${text().slice(caret())}`;
    const nextCaret = q.start + token.length;
    write(next);
    setAtOff(false);
    ta.focus();
    ta.setSelectionRange(nextCaret, nextCaret);
    setCaret(nextCaret);
  };
  createEffect(() => {
    slash();
    setSlashHi(0);
  });
  createEffect(() => {
    at();
    setAtHi(0);
  });
  let attachmentLoad: Promise<void> = Promise.resolve();
  createEffect(() => {
    const slug = p.projectSlug;
    if (!slug || !isConnected()) {
      setAtItems([]);
      return;
    }
    let current = true;
    setAtItems([]);
    onCleanup(() => { current = false; });
    const reloadAttachments=()=>{attachmentLoad = loadAttachItems(slug).then(items => { if (current) setAtItems(items); }).catch(() => { if (current) setAtItems([]); });};
    const imported=(event:Event)=>{if((event as CustomEvent).detail?.slug===slug)reloadAttachments();};
    reloadAttachments();window.addEventListener('orb:context-imported',imported);onCleanup(()=>window.removeEventListener('orb:context-imported',imported));
  });
  /** What the current draft refers to, resolved against this project's files. */
  const mentioned = createMemo(() => mentionedChips(text(), atItems()));
  createEffect(() => p.onAttachments?.(mentioned()));
  const [multiline, setMultiline] = createSignal(false);
  // Measuring scrollHeight forces a synchronous layout of the whole window on
  // every keystroke; with a long transcript that made typing lag per letter.
  // Single-line drafts are decided with canvas text metrics instead.
  let measureCtx: CanvasRenderingContext2D | null | undefined;
  let compactWidth = 0;
  const fitsOneLine = (value: string) => {
    if (!compactWidth) return false;
    measureCtx ??= document.createElement("canvas").getContext("2d");
    if (!measureCtx) return false;
    measureCtx.font = getComputedStyle(ta).font;
    return measureCtx.measureText(value).width < compactWidth - 24;
  };
  onMount(() => {
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => { if (!multiline()) compactWidth = entry.contentRect.width; });
    observer.observe(ta);
    onCleanup(() => observer.disconnect());
  });
  const resize = () => {
    const composer = ta.closest<HTMLElement>(".composer");
    if (!composer) return;
    // Canvas metrics decide most single-line drafts without touching layout.
    const value = text();
    if (!multiline() && !p.tall && !images().length && !value.includes("\n") && fitsOneLine(value)) {
      ta.style.height = "";
      return;
    }
    const val = ta.value;
    // Fast path for empty or short single-line compact inputs that cannot wrap:
    // skip collapsing and re-measuring the DOM box on every keystroke.
    const style = getComputedStyle(ta);
    const singleLineHeight = parseFloat(style.lineHeight) + parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    if (!multiline() && !val.includes("\n") && val.length <= 32 && ta.scrollHeight <= singleLineHeight + 1) {
      composer.classList.toggle("tall", Boolean(p.tall || images().length));
      ta.style.height = "";
      return;
    }
    // Measuring collapses the textarea: hold the composer's box so the
    // transcript above is not resized (and its scroll clamped), and keep the
    // caret line in view afterwards.
    const follow = document.activeElement === ta && ta.selectionEnd === val.length;
    const top = ta.scrollTop;
    composer.style.minHeight = `${composer.offsetHeight}px`;
    // Always decide from the compact width. Measuring the current layout makes
    // wrapped text alternate between narrow/compact and wide/tall on each key.
    composer.classList.remove("tall");
    ta.style.height = "0px";
    ta.style.minHeight = "0";
    const wrapped = val.includes("\n") || ta.scrollHeight > singleLineHeight + 1;
    setMultiline(wrapped);
    composer.classList.toggle("tall", Boolean(p.tall || images().length || wrapped));
    // Compact drafts return to their intrinsic single-line height, including
    // after a soft wrap; retaining a measured height leaves the controls below the text.
    ta.style.height = wrapped ? Math.min(ta.scrollHeight, 220) + "px" : "";
    ta.style.minHeight = "";
    composer.style.minHeight = "";
    ta.scrollTop = follow ? ta.scrollHeight : top;
  };

  createEffect(() => { const revision = p.revision; if (revision) { setMode(null); setText(current => { const next = revision.append && current ? `${current}\n\n${revision.text}` : revision.text; ta.value = next; return next; }); queueMicrotask(() => { resize(); ta?.focus(); }); } });
  const draftOf = (visible: string, m = mode()) => modePrompt(m, visible);
  // Report every change, including restored drafts and revisions, not only typing.
  createEffect(on([text, mode], ([visible, m]) => p.onDraft?.(draftOf(visible, m))));
  const write = (visible: string) => {
    ta.value = visible;
    setText(visible);
    resize();
  };
  const enterMode = (next: ComposerMode, visible: string) => {
    setMode(next);
    write(visible);
    ta.focus();
  };
  const clearMode = () => {
    setMode(null);
    ta.focus();
  };
  const pickSlash = (item: { id: ComposerMode }) => enterMode(item.id, "");
  /**
   * Write the chosen attachment into the sentence at the point `@` was typed.
   *
   * The mention is the reference: there is no separate list to keep in step, so
   * editing the text is editing the attachments, and the agent reads the same
   * words the user wrote.
   */
  const pickAttach = (item: AttachItem) => {
    const next = insertMention(text(), caret(), item);
    write(next.text);
    setAtOff(true);
    setCtx(false);
    setCtxFolder("");
    ta.focus();
    ta.setSelectionRange(next.caret, next.caret);
    setCaret(next.caret);
  };
  const send = async () => {
    const original = text();
    let payload = draftOf(original);
    if (!payload && !images().length && p.onEmptySubmit && !p.disabled && !sending()) { p.onEmptySubmit(); return; }
    if (p.disabled || (!payload && !images().length) || sendingLocked() || uploading() || readingImages()) return;
    if (!p.textOnly && !p.imagesOnly && (mode() === "plan" || /^\/plan(?:\s|$)/.test(payload)) && !modes().some(m => m.id === "plan")) {
      setUploadError("Plan mode is not supported by this harness on this machine. Your draft is kept.");
      return;
    }
    const sideMode = !p.textOnly && !p.imagesOnly && (mode() === "btw" || /^\/btw(?:\s|$)/.test(payload));
    if (sideMode && !p.onBtw) { setUploadError("Side questions require an existing conversation."); return; }
    if (sideMode && !payload.replace(/^\/btw\s*/, "").trim() && !images().length && !uploaded.length) { setMode(null); p.onOpenBtw?.(); return; }
    const sentImages = images();
    const originalMode = mode();
    const originalUploads = uploaded;
    const draftScope = p.scope;
    const project = p.projectSlug;
    const destination = attachmentTarget();
    setPendingSend({text:original,images:sentImages});
    if(!sideMode)p.onPending?.({text:payload,images:sentImages,retry:()=>{uploaded=originalUploads;setText(original);setImages(sentImages);setMode(originalMode);void send();}});
    setSendingCount(c => c + 1);
    setText(""); setImages([]); ta.value=""; resize();
    let accepted = false;
    try {
      await attachmentLoad;
      if (project !== p.projectSlug || draftScope !== p.scope || destination !== attachmentTarget()) return;
      const resolved = (p.textOnly || p.imagesOnly) ? {text: original, files: []} : await prepareUploads(original, originalUploads, destination);
      if (project !== p.projectSlug || draftScope !== p.scope || destination !== attachmentTarget()) return;
      uploaded = resolved.files;
      payload = draftOf(resolved.text);
      p.onAttachments?.(mentionedChips(resolved.text,[...atItems(), ...resolved.files.filter(file => file.destination.startsWith("context:")).map(file => ({id:`upload:${file.path}`,kind:"context" as const,label:file.source.name,path:file.path,project:file.destination.slice("context:".length),section:"Files" as const}))]));
      accepted = sideMode
        ? await p.onBtw!(payload.replace(/^\/btw\s*/, "").trim() || "Please look at the attachments.", sentImages, resolved.files)
        : await (p.sideQuestion ? p.onSend(payload || "Please look at the attached images.", sentImages, resolved.files) : p.onSend(payload || "Please look at the attached images.", sentImages)) !== false;
      if (accepted) {
        if (sideMode) p.onAttachments?.([]);
        if (uploaded === resolved.files) uploaded = [];
        setUploadError(null);
        if (draftTimer !== undefined) {
          clearTimeout(draftTimer);
          draftTimer = undefined;
        }
        pendingDraftSave = null;
        if (sendingCount() <= 1) setPendingSend(null);
        if (draftScope && !text() && !images().length) await saveComposerDraft(draftScope, {text:"",images:[]}).catch(swallow("composer.clearDraft", { scope: draftScope }));
        if (!text()) setMode(null);
      }
    } catch (error) { const message=error instanceof Error ? error.message : String(error);setUploadError(message);p.onSendError?.(message); }
    finally {
      setSendingCount(c => Math.max(0, c - 1));
      if (!accepted && !p.retainFailedMessage && draftScope === p.scope && !text() && !images().length) {
        uploaded = originalUploads;
        setMode(originalMode);setText(original);setImages(sentImages);
        ta.value=original;resize();
      }
      if (sendingCount() === 0) setPendingSend(null);
      if (!accepted && !sideMode) p.onPending?.(null);
      // The launch preview hides the composer. Restore visibility before focus.
      if (!accepted && draftScope === p.scope && ta.isConnected) ta.focus();
    }
  };
  const insertDictation = (t: string) => {
    const cur = ta.value;
    const { value, caret } = insertAtCaret(cur, ta.selectionStart ?? cur.length, ta.selectionEnd ?? cur.length, t);
    write(value);
    ta.setSelectionRange(caret, caret);
    ta.focus();
  };
  onMount(() => p.autofocus && ta.focus());
  const close = () => {
    setMenu(false);
    setCtx(false);
    setCtxFolder("");
    setWhich(null);
    if (slash()) setSlashOff(true);
    if (atQuery(text(), caret()).open) setAtOff(true);
  };
  const onEsc = (e: KeyboardEvent) => {
    if (e.defaultPrevented || e.isComposing || hasOverlay()) return;
    // Dismiss a pending mention query too: its file catalog can arrive
    // after Escape and must not reopen the picker over the next Enter.
    if (e.key === "Escape" && (menu() || ctx() || which() || slash() || atQuery(text(), caret()).open)) {
      e.stopPropagation();
      close();
      return;
    }
    if (e.key === "Escape" && p.editingQueued) {
      e.preventDefault();
      e.stopPropagation();
      p.editingQueued.onCancel();
    }
  };
  onMount(() => {
    window.addEventListener("keydown", onEsc, true);
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onEsc, true);
  });
  const plusItems = createMemo(() => {
    const raw: AttachItem[] = isConnected() ? atItems() : [];
    return browseAttachItems(raw, ctxFolder());
  });
  const plus = (
    <div class="plus-wrap" onPointerDown={(e) => e.stopPropagation()}>
      <input ref={fileInput} type="file" accept={p.imagesOnly ? "image/png,image/jpeg,image/webp,image/gif" : undefined} multiple hidden aria-label={p.imagesOnly || p.directFileUpload ? "Choose images" : "Choose files or images"} onChange={(event) => { const files = Array.from(event.currentTarget.files ?? []); event.currentTarget.value = ""; void attachMixed(files.map(file => ({ name: file.name, file }))); }} />
      <button class="plus" title={p.imagesOnly ? "Attach image" : p.directFileUpload ? "Attach file or image" : "Add context"} aria-label={p.imagesOnly ? "Attach image" : p.directFileUpload ? "Attach file or image" : undefined} disabled={uploading() || sendingLocked()} onClick={() => { if (p.imagesOnly || p.directFileUpload) void chooseFiles(); else { const next = !ctx(); setCtx(next); if (!next) setCtxFolder(""); } }}>
        <Ic.PlusIcon size={14} />
      </button>
      <Show when={ctx() && !p.imagesOnly && !p.directFileUpload}>
        <Menu label="Add context" class="plus-menu slash-menu" width={340} onClose={() => setCtx(false)}>
          <Show when={ctxFolder()} fallback={<button class="menu-item" onClick={chooseFiles}><span class="menu-ico"><Ic.FileIcon size={14} /></span><span class="slash-item-label">Upload file or image…</span></button>}>
            <div class="slash-folder-bar">
              <button type="button" class="menu-item slash-back" onClick={() => { const cur = ctxFolder(); const slashIdx = cur.lastIndexOf("/"); setCtxFolder(slashIdx >= 0 ? cur.slice(0, slashIdx) : ""); }}>
                <span class="menu-ico"><Ic.ArrowLeft size={14} /></span>
                <span class="slash-item-label">{ctxFolder()}/</span>
              </button>
              <button type="button" class="slash-attach-folder" title={`Attach @${ctxFolder()}/`} onClick={() => {
                const f = ctxFolder();
                const existing = atItems().find((it) => it.section === "Folders" && (it.path ?? "").replace(/\/$/, "").toLowerCase() === f.toLowerCase());
                pickAttach(existing ?? { id: `folder:${f}`, kind: "folder", section: "Folders", path: f, label: `${f}/` });
              }}>Attach</button>
            </div>
          </Show>
          <Show when={plusItems().some((i) => i.section === "Folders")}>
            <div class="slash-head">Folders</div>
            <For each={plusItems().filter((i) => i.section === "Folders")}>
              {(it) => {
                const display = () => ctxFolder() && it.label.toLowerCase().startsWith(`${ctxFolder().toLowerCase()}/`) ? it.label.slice(ctxFolder().length + 1) : it.label;
                return (
                  <button class={`menu-item ${mentioned().some((c) => c.id === it.id) ? "on" : ""}`} title={it.path ?? it.label} onClick={() => setCtxFolder((it.path ?? it.label).replace(/\/$/, ""))}>
                    <span class="menu-ico"><Ic.FolderIcon size={14} /></span>
                    <span class="slash-item-label">{display()}</span>
                    <span class="menu-attachment-mark" aria-hidden="true">{mentioned().some((c) => c.id === it.id) ? "✓" : ""}</span>
                    <span class="slash-chevron"><Ic.ChevronRight size={12} /></span>
                  </button>
                );
              }}
            </For>
          </Show>
          <Show when={plusItems().some((i) => i.section === "Files")}>
            <div class="slash-head">Files</div>
            <For each={plusItems().filter((i) => i.section === "Files")}>
              {(item) => {
                const display = () => ctxFolder() && item.label.toLowerCase().startsWith(`${ctxFolder().toLowerCase()}/`) ? item.label.slice(ctxFolder().length + 1) : item.label;
                return (
                  <button
                    class={`menu-item ${mentioned().some((c) => c.id === item.id) ? "on" : ""}`}
                    title={item.path ?? item.label}
                    onClick={() => { if (p.onAttachments) pickAttach(item); }}
                  >
                    <span class="menu-ico"><Ic.FileIcon size={14} /></span>
                    <span class="slash-item-label">{display()}</span>
                    <span class="menu-attachment-mark" aria-hidden="true">{mentioned().some((c) => c.id === item.id) ? "✓" : ""}</span>
                  </button>
                );
              }}
            </For>
          </Show>
        </Menu>
      </Show>
    </div>
  );
  // Two pickers, Cursor-style: harness first (Claude Code, Codex, …), then
  // the model that harness can run. Changing the harness resets the model.
  const choice = () => harnessChoices(p.uploadTarget).find((c) => c.backend.id === pick()?.backend);
  const modelLabel = () => {
    const m = choice()?.models.find((x) => x.value === pick()?.model);
    return m ? shortModelLabel(m.label) : (pick()?.model ?? "Model");
  };
  const modelBtn = (
    <Show when={p.picker !== false}>
      <div class="picks" onPointerDown={(e) => e.stopPropagation()}>
        <Show
          when={live()}
          fallback={
            <div class="model-wrap">
              <button class="model" onClick={() => setMenu(!menu())}>
                {model()} <Ic.ChevronDown size={12} />
              </button>
              <Show when={menu()}>
                <Picker label="Models" searchable={false} selected={model()} items={MODELS.map(m => ({id:m,label:m}))}
                  onClose={() => setMenu(false)} onSelect={m => {setModel(m);setMenu(false);}}/>
              </Show>
            </div>
          }
        >
          <div class="model-wrap">
            <button class={`model ${which() === "harness" ? "on" : ""}`} title="Harness" onClick={() => {
              const opening = which() !== "harness";
              setWhich(opening ? "harness" : null);
              // Discover newly installed CLIs without recreating the composer.
              if (opening && p.harnessIds) void refreshLocalAgents(false);
              if (opening && p.uploadTarget) void refreshNodeAntigravityModels(p.uploadTarget);
            }}>
              {choice()?.backend.name ?? "Harness"} <Ic.ChevronDown size={12} />
            </button>
            <Show when={which() === "harness"}>
              <Picker label="Harness" searchable={false} selected={pick()?.backend}
                items={harnessChoices(p.uploadTarget).filter(c => !p.harnessIds || p.harnessIds.includes(c.backend.id)).map(c => ({id:c.backend.id,label:c.backend.name,description:p.remoteSupport?.(c.backend.id).note || `${c.models.length} model${c.models.length === 1 ? "" : "s"}`}))}
                onClose={() => setWhich(null)} onSelect={id => {
                  const c = harnessChoices(p.uploadTarget).find(c => c.backend.id === id);
                  if (c && id !== pick()?.backend) {
                    const effort = normalizeEffort(pick()?.effort, id);
                    setHarnessPick({backend:id,model:c.models[0].value,...(effort ? {effort} : {})});
                  }
                  setWhich(null);
                }}/>

            </Show>
          </div>
          <span class="picks-sep">·</span>
          <div class="model-wrap">
            <button class={`model ${which() === "model" ? "on" : ""}`} title="Model" onClick={() => setWhich(which() === "model" ? null : "model")}>
              {modelLabel()} <Ic.ChevronDown size={12} />
            </button>
            <Show when={which() === "model"}>
              <Picker label="Models" searchLabel="Search models" selected={pick()?.model}
                items={(choice()?.models ?? []).map(m => ({id:m.value,label:shortModelLabel(m.label)}))}
                onClose={() => setWhich(null)} onSelect={value => {
                  const backend = choice()!.backend.id;
                  const effort = normalizeEffort(pick()?.effort, backend);
                  setHarnessPick({...pick()!,backend,model:value,...(effort ? {effort} : {})});setWhich(null);
                }}/>

            </Show>
          </div>
          {/* Effort, after harness and model. Only rendered for a harness the
              core actually accepts an effort for — everything else has
              model_effort forced to null server-side. */}
          <Show when={harnessSupportsEffort(pick()?.backend)}>
            <span class="picks-sep">·</span>
            <div class="model-wrap">
              <button
                class={`model ${which() === "effort" ? "on" : ""}`}
                title="Reasoning effort"
                aria-label={`Reasoning effort: ${effortLabel(pick()?.effort,pick()?.backend,pick()?.model)}`}
                onClick={() => setWhich(which() === "effort" ? null : "effort")}
              >
                {effortLabel(pick()?.effort,pick()?.backend,pick()?.model)} <Ic.ChevronDown size={12} />
              </button>
              <Show when={which() === "effort"}>
                <Picker label="Reasoning effort" searchable={false} selected={pick()?.effort ?? ""}
                  items={[{id:"",label:defaultEffortLabel(pick()?.backend,pick()?.model)},...supportedEfforts(pick()?.backend).map(e => ({id:e,label:effortLabel(e)}))]}
                  onClose={() => setWhich(null)} onSelect={value => {
                    const cur = pick()!; const effort = normalizeEffort(value, cur.backend);
                    setHarnessPick({...cur,backend:cur.backend,model:cur.model,...(effort ? {effort} : {})});setWhich(null);
                  }}/>

              </Show>
            </div>
          </Show>
          <Show when={pick()?.backend === "codex"}>
            <span class="picks-sep">·</span><CodexSpeedPicker model={pick()?.model??""} value={pick()?.service_tier??"standard"} local={p.uploadTarget==="local"} onChange={tier=>setHarnessPick({...pick()!,service_tier:tier})}/>
            <span class="picks-sep">·</span><CyberPicker value={draftCyber()} model={pick()?.model??""} remote={!!p.uploadTarget&&p.uploadTarget!=="core"&&p.uploadTarget!=="local"} onChange={setDraftCyber}/>
          </Show>
        </Show>
      </div>
    </Show>
  );
  // Cursor keeps the microphone mounted while a turn is streaming; Stop sits
  // beside it. A draft still sends — the backend queues it for the next turn.
  const sendBtn = (
    <div class="send-slot">
      <Show when={(text().trim() || images().length) && !slash() && !voiceActive()}>
        <button class="send" disabled={p.disabled || uploading() || sendingLocked() || readingImages()} onClick={send} title={mode()==="btw" ? "Ask side question" : p.busy ? "Queue for next turn" : "Send"}>
          <Ic.ArrowUpIcon size={14} />
        </button>
      </Show>
      <Show when={p.busy && p.onStop}>
        <button class="send stop" disabled={p.disabled} onClick={p.onStop} title="Stop">
          <Ic.StopIcon size={14} />
        </button>
      </Show>
    </div>
  );
  const voice = (
    <Show when={voiceAvailable()}>
      <div class="voice-slot" onPointerDown={(e) => e.stopPropagation()}>
        <VoiceButton scope={p.scope} onText={insertDictation} onActive={setVoiceActive} />
      </div>
    </Show>
  );
  const atMenu=<Show when={at()}>{s=><MentionPicker anchor={ta} onClose={() => setAtOff(true)} items={s().items} index={atHi()} highlight={setAtHi} pick={pickAttach} folder={s().folder || undefined} onBack={()=>{const cur=s().folder;const idx=cur.lastIndexOf("/");setAtFolder(idx>=0?cur.slice(0,idx):"");}} onOpenFolder={setAtFolder}/>}</Show>;
  const slashMenu = (
    <Show when={slash()}>
      {(s) => (
        <Popover role="listbox" label="Commands" class="slash-menu" anchor={ta} placement="top-start" width={340} trap={false} onClose={() => setSlashOff(true)}>
          <div class="slash-head">Modes</div>
          <For each={s().items}>
            {(it, i) => (
              <button
                type="button"
                role="option"
                aria-selected={slashHi() === i()}
                class={`menu-item ${slashHi() === i() ? "on" : ""}`}
                title={it.title}
                onMouseEnter={() => setSlashHi(i())}
                onClick={() => pickSlash(it)}
              >
                <span class="menu-ico"><Ic.TargetIcon size={14} /></span>
                {it.label}
              </button>
            )}
          </For>
        </Popover>
      )}
    </Show>
  );
  return (<>
    <Show when={!p.onPending && pendingSend()}>{pending=><OptimisticMessage draft={pending()} />}</Show>
    <div ref={composerElement} class={`composer ${p.tall || images().length || multiline() ? "tall" : ""} ${voiceActive() ? "voice-on" : ""} ${mode() || p.editingQueued ? "has-mode" : ""}`} data-mode={mode() ?? ""}
      onDragOver={e=>{if(Array.from(e.dataTransfer?.types??[]).includes("Files")){e.preventDefault();e.stopPropagation();if(e.dataTransfer)e.dataTransfer.dropEffect="copy";e.currentTarget.classList.add("drop-active");}}}
      onDragLeave={e=>{if(!e.currentTarget.contains(e.relatedTarget as Node))e.currentTarget.classList.remove("drop-active");}}
      onDrop={e=>{e.preventDefault();e.stopPropagation();e.currentTarget.classList.remove("drop-active");if(sendingLocked()||uploading()||readingImages())return;void attachMixed(Array.from(e.dataTransfer?.files??[]).map(file=>({name:file.name,file})));}}
      onClick={() => !voiceActive() && ta.focus()}>
      <Show when={!p.textOnly}>{plus}</Show>
      {slashMenu}
      {atMenu}
      <Show when={uploading()}><div class="composer-upload-status" role="status">Attaching file…</div></Show>
      <Show when={pendingLargeUploads().length > 0}>
        <div class="composer-large-confirm" role="alertdialog" aria-label="Confirm large file upload" onClick={(e) => e.stopPropagation()}>
          <div class="composer-large-confirm-text">
            <strong>Large file{pendingLargeUploads().length > 1 ? "s" : ""}</strong>
            <span>
              {pendingLargeUploads().map((item) => `${item.source.name} (${formatFileSize(item.size)})`).join(", ")} exceed{pendingLargeUploads().length === 1 ? "s" : ""} the standard limit ({formatFileSize(softLimitForDestination(attachmentTarget()))}). Upload in the background with resumable chunks?
            </span>
          </div>
          <div class="composer-large-confirm-actions">
            <button type="button" class="s-btn" onClick={() => setPendingLargeUploads([])}>Cancel</button>
            <button type="button" class="s-btn primary" onClick={confirmLargeUploads}>Upload in background</button>
          </div>
        </div>
      </Show>
      <Show when={scopedBgUploads().length > 0}>
        <div class="composer-bg-uploads" role="status" aria-live="polite" onClick={(e) => e.stopPropagation()}>
          <For each={scopedBgUploads()}>{(item) => {
            const pct = () => item.totalBytes > 0 ? Math.min(100, Math.round((item.uploadedBytes / item.totalBytes) * 100)) : 0;
            return (
              <div class={`composer-bg-upload-row ${item.state === "failed" ? "error" : item.state}`}>
                <span class="composer-bg-upload-name" title={item.name}>{item.name}</span>
                <span class="composer-bg-upload-meta">
                  {item.state === "paused"
                    ? `Paused · ${pct()}%`
                    : item.state === "failed"
                      ? `Interrupted (${pct()}%)${item.error ? ` — ${item.error}` : ""}`
                      : `${pct()}% · ${formatFileSize(item.uploadedBytes)} / ${formatFileSize(item.totalBytes)}${item.speedBps > 0 ? ` · ${formatFileSize(item.speedBps)}/s` : ""}`}
                </span>
                <div class="composer-bg-upload-actions">
                  <Show when={item.state === "uploading"}>
                    <button type="button" class="bg-upload-btn" onClick={() => pauseBackgroundUpload(item.id)}>Pause</button>
                  </Show>
                  <Show when={item.state === "paused" || item.state === "failed"}>
                    <button type="button" class="bg-upload-btn" onClick={() => resumeBackgroundUpload(item.id)}>Resume</button>
                  </Show>
                  <button type="button" class="bg-upload-btn" aria-label={`Cancel upload of ${item.name}`} onClick={() => cancelBackgroundUpload(item.id)}>×</button>
                </div>
                <span class="bg-upload-bar"><i style={{ width: `${pct()}%` }} /></span>
              </div>
            );
          }}</For>
        </div>
      </Show>
      <ErrorToast error={uploadError()} title="Couldn’t upload the file" onDismiss={() => setUploadError(null)} />
      <Show when={mode()}>{m => <ModeChip mode={m()} onClear={clearMode} />}</Show>
      <Show when={!mode() && p.editingQueued}>{editing => <span class="mode-chip edit-queued" role="status" aria-label="Editing a queued message">
        <Ic.PencilIcon size={12} /><span class="mode-chip-label">Edit Queued</span>
        <button type="button" class="mode-chip-x" tabIndex={-1} title="Stop editing" aria-label="Stop editing the queued message" onClick={e => { e.preventDefault(); e.stopPropagation(); editing().onCancel(); }}><Ic.CloseIcon size={10} /></button>
      </span>}</Show>
      <div class="composer-field">
        <Show when={images().length}><div class="composer-images"><For each={images()}>{image => <div class="composer-image"><img src={image.dataUrl} alt={image.reference ? `Image #${image.reference}` : "Attached image"} title="Open preview" onClick={e => { e.stopPropagation(); setViewing(images().indexOf(image)); }} /><Show when={image.reference}><span class="composer-image-reference">#{image.reference}</span></Show><button class="icon-btn" aria-label="Remove image" title="Remove image" onClick={e => { e.stopPropagation(); setImages(current => current.filter(item => item.id !== image.id)); if (image.reference) { const value = text().replaceAll(`[Image #${image.reference}]`, ""); setText(value); ta.value = value; resize(); } }}><Ic.CloseIcon size={12}/></button></div>}</For></div></Show><Show when={viewing() !== null && images().length}><Lightbox items={draftLightbox(images())} index={viewing()!} onClose={() => setViewing(null)} /></Show>
        <ErrorToast error={imageError()} title="Couldn’t add the image" onDismiss={() => setImageError(null)} />
        <textarea readOnly={sendingLocked()}
          ref={ta}
          onPaste={event => void pasteImages(event)}
          rows={1}
          // Keep the placeholder clear of the native caret without shifting typed text.
          placeholder={"\u2009" + (mode() === "btw" ? "Ask without interrupting…" : mode() === "goal" ? "Describe the objective" : mode() === "plan" ? "Plan before making changes…" : p.placeholder)}
          onInput={(e) => {
            const next = e.currentTarget.value;
            setSlashOff(false);
            setAtOff(false);
            setCaret(e.currentTarget.selectionStart ?? next.length);
            if (!mode() && /^\/btw(?:\s|$)/.test(next) && p.onBtw) { enterMode('btw', next.replace(/^\/btw\s*/,'')); return; }
            if (!mode() && /^\/plan(?:\s|$)/.test(next) && modes().some(m=>m.id==='plan')) {
              enterMode('plan', next.replace(/^\/plan\s*/,'')); return;
            }
            if (!mode() || mode() === "goal") {
              const absorbed = absorbGoalPrefix(next);
              if (absorbed !== null && modes().some((it) => it.id === "goal")) {
                enterMode("goal", absorbed);
                return;
              }
            }
            write(next);
          }}
          onClick={() => setCaret(ta.selectionStart ?? text().length)}
          onKeyUp={() => setCaret(ta.selectionStart ?? text().length)}
          onKeyDown={(e) => {
            const atItemsOpen = at()?.items;
            if (atItemsOpen && atItemsOpen.length) {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                const n = atItemsOpen.length;
                setAtHi((i) => (e.key === "ArrowDown" ? (i + 1) % n : (i - 1 + n) % n));
                return;
              }
              if ((e.key === "Enter" || e.key === "Tab") && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                pickAttach(atItemsOpen[Math.min(atHi(), atItemsOpen.length - 1)]);
                return;
              }
            }
            const items = slash()?.items;
            if (items) {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                const n = items.length;
                setSlashHi((i) => (e.key === "ArrowDown" ? (i + 1) % n : (i - 1 + n) % n));
                return;
              }
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                pickSlash(items[Math.min(slashHi(), items.length - 1)]);
                return;
              }
              if (e.key === "Tab") {
                e.preventDefault();
                pickSlash(items[Math.min(slashHi(), items.length - 1)]);
                return;
              }
            }
            if (e.key === "Backspace" && mode() && !text() && ta.selectionStart === 0 && ta.selectionEnd === 0) {
              e.preventDefault();
              clearMode();
              return;
            }
            if (e.key === "ArrowRight" && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && !e.isComposing && !text() && !images().length && !mode() && !p.editingQueued && p.onEditFirstQueued) {
              e.preventDefault();
              p.onEditFirstQueued();
              return;
            }
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault();
              send();
            }
          }}
        />
      </div>
      {p.controls ?? modelBtn}
      {voice}
      {sendBtn}
    </div>
  </>);
}

// Keep the last message reachable while the transparent dock floats over the transcript.
export function floatingDock(el: HTMLDivElement) {
  let parent: HTMLElement | null = null;
  const update = () => {
    const bounds = el.getBoundingClientRect();
    parent?.style.setProperty("--dock-height", `${bounds.height}px`);
    const composer = el.querySelector<HTMLElement>(".composer");
    if (composer) el.closest<HTMLElement>(".app")?.style.setProperty(
      "--composer-bottom-space", `${bounds.bottom - composer.getBoundingClientRect().bottom}px`,
    );
  };
  const observer = new ResizeObserver(update);
  queueMicrotask(() => { parent = el.parentElement; update(); observer.observe(el); });
  onCleanup(() => { observer.disconnect(); parent?.style.removeProperty("--dock-height"); el.closest<HTMLElement>(".app")?.style.removeProperty("--composer-bottom-space"); });
}

export default function App() {
  const [secretRequests, setSecretRequests] = createSignal(0);
  onMount(() => onCleanup(trackScrollbarHover()));
  onMount(() => { const stop = monitorSoftware(); onCleanup(stop); });
  createEffect(()=>{connectionVersion();const stop=startLocalQueueWorker();onCleanup(stop);const stopDelegations=startClientDelegations(missions);onCleanup(stopDelegations);onCleanup(startLocalWakeups());});
  const [selected, setSelected] = createSignal<string | null>((() => { const saved = readString("orb.selectedConversation"); return saved && (PAGES.has(saved) || /^(m|pf|c|pc|ps):/.test(saved)) ? saved : null; })());
  createEffect(() => { writeString("orb.selectedConversation", selected() ?? ""); });
  const [sidebar, setSidebar] = createSignal(!window.matchMedia("(max-width: 720px)").matches);
  const [sbWidth, setSbWidth] = createSignal(220);
  const [deleteMissionRequest, setDeleteMissionRequest] = createSignal<string | null>(null);
  const [newFolder, setNewFolder] = createSignal<{ project: string; path: string } | null>(null);
  const folderTags = (project: string | null | undefined) => newFolder()?.project === project && newFolder()?.path ? [`orb-folder:${newFolder()!.path}`] : [];
  const [newProject, setNewProject] = createSignal(DEFAULT_PROJECT.slug);
  // "New project…" inside the project picker (Cursor puts creation at the
  // bottom of the picker it belongs to, never in the sidebar chrome).
  const [projectCreationAnchor, setProjectCreationAnchor] = createSignal<HTMLElement>();
  const [newProjectDraft, setNewProjectDraft] = createSignal(false);
  createEffect(on(projectsVersion, () => {
    if (isConnected()) listProjects(true).then(setLiveProjects).catch(swallow("app.listProjects"));
  }, { defer: true }));
  const submitNewProject = async (title: string, slug: string) => {
    const created = await createProject({ slug, title });
    setLiveProjects((current) => [
      ...current.filter((p) => p.slug !== created.slug),
      created,
    ]);
    bumpProjects();
    setNewProject(created.slug);
    setNewProjectDraft(false);
    window.dispatchEvent(new CustomEvent("orb:project-created", { detail: created }));
  };
  const [rawLiveProjects, setLiveProjects] = createSignal<ProjectSummary[]>([]);
  // Pending renames show in every view before the next project list arrives.
  const liveProjects = createMemo(() => withRenamedTitles("project", rawLiveProjects(), project => project.slug));
  const effectiveNewProject = createMemo(() => isConnected()
    ? (liveProjects().find(p => p.slug === newProject())?.slug ?? DEFAULT_PROJECT.slug)
    : newProject());
  const [createError, setCreateError] = createSignal<string | null>(null);
  const [creating, setCreating] = createSignal(false);
  const [newAgentRevision, setNewAgentRevision] = createSignal<{ text: string; append?: boolean } | undefined>();
  const [launchPreview, setLaunchPreview] = createSignal<LaunchReceipt | null>(null);
  const [launchViewKey,setLaunchViewKey]=createSignal<string>(crypto.randomUUID());
  let retryLaunch:(()=>void)|undefined;
  const launchedViewKeys=new Map<string,string>();
  const prepareLaunch=(draft:{text:string;images:DraftImage[];retry?:()=>void}|null)=>{
    if(!draft){setLaunchPreview(null);return;}
    retryLaunch=draft.retry;setCreateError(null);
    if(!launchPreview())setLaunchViewKey(crypto.randomUUID());
    setLaunchPreview({messageKey:`initial:${launchViewKey()}`,prompt:draft.text,images:draft.images,nodeId:newMachine(),destination:nodeLabel(newMachine())});
  };
  let launchAttempt: { signature: string; key: string } | undefined;
  const MACHINE_KEY = "orb.machine";
  const [explicitMachine, setExplicitMachine] = createSignal(false);
  const [newMachine, setNewMachine] = createSignal((readString(MACHINE_KEY) === "dgx-spark-admin" ? "core" : readString(MACHINE_KEY)) || "core");
  const chooseMachine = (id: string) => {
    setExplicitMachine(true);
    setNewMachine(id);
    writeString(MACHINE_KEY, id === "dgx-spark-admin" ? "core" : id);
    if (id === "local") void refreshLocalAgents(false);
  };
  const [workingDirectory, setWorkingDirectory] = createSignal("");
  const directoryKey = () => `orb.directory:${getApiUrl()}:${effectiveNewProject()}:${newMachine()}`;
  createEffect(() => {
    const key = directoryKey();
    setWorkingDirectory(readString(key) ?? "");
  });
  const chooseDirectory = (value: string) => {
    setWorkingDirectory(value);
    writeString(directoryKey(), value); // Kept in memory when storage refuses it.
  };
  const [envOpen, setEnvOpen] = createSignal<"machine" | "project" | null>(null);
  const [history, setHistory] = createSignal<(string | null)[]>([selected()]);
  const [hIdx, setHIdx] = createSignal(0);

  const [attachChips, setAttachChips] = createSignal<AttachChip[]>([]);
  const [ctx, setCtx] = createSignal<{ x: number; y: number; items: MenuEntry[] } | null>(null);
  /** A structured launch refusal, when the core gave one we can act on. */
  const [createRefusal, setCreateRefusal] = createSignal<{ refusal: LaunchRefusal; project: string | null } | null>(null);
  // Shared with ProjectFileView so ⌘/ reaches core-hosted reference files too.
  const mdSrc = mdSource;

  const [missions, setMissions] = createSignal<Mission[]>([]);
  const [missionsLoading, setMissionsLoading] = createSignal(true);
  const [previewContext, setPreviewContext] = createSignal<{id: string; pct: number | null} | null>(null);
  const [previewPlan, setPreviewPlan] = createSignal<{id:string; data:PlanProgressData | undefined}>();
  const [openMission, setOpenMission] = createSignal<Mission | null>(null);
  /** Only missions still doing something: the sidebar is a place to act,
   * not a history. Everything else lives under its project. */
  const [fleetNodes, setFleetNodes] = createSignal<RemoteNodeView[]>([]);
  /** Typed remote launch support as last advertised by the server. "loading"
   * until the first answer; "error" keeps the last capability but says so. */
  const [remoteLaunch, setRemoteLaunch] = createSignal<{ state: "loading" | "ready" | "error"; capability: RemoteLaunchCapability | null }>({ state: "loading", capability: null });
  const acceptFleet = (fleet: RemoteNodesResponse) => {
    setFleetNodes(fleet.nodes);
    recordFleet(fleet.nodes);
    setRemoteLaunch({ state: "ready", capability: fleet.remote_launch ?? null });
  };
  const harnessName = (id: string) => harnessChoices().find((c) => c.backend.id === id)?.backend.name ?? id;
  /** What the harness menu shows next to each harness for the selected machine. */
  const remoteSupport = (backend: string): { state: RemoteSupport; note: string } => {
    const machine = newMachine();
    if (!isConnected() || machine === "core" || machine === "local") return { state: "unknown", note: "" };
    const rl = remoteLaunch();
    if (rl.state === "loading") return { state: "unknown", note: `checking ${nodeLabel(machine)}…` };
    const support = remoteHarnessSupport(rl.capability, backend);
    if (support === "supported") return { state: "supported", note: "" };
    if (support === "unsupported") return { state: "unsupported", note: `not on ${nodeLabel(machine)}` };
    return { state: "unknown", note: rl.state === "error" ? "remote support unknown" : "no typed remote launch" };
  };
  /** One-line remote launch summary for a node row in the machine menu. */
  const nodeLaunchNote = () => {
    const rl = remoteLaunch();
    if (rl.state === "loading") return "checking launch support…";
    const cap = rl.capability;
    if (!cap || cap.typed !== true) return rl.state === "error" ? "launch support unknown" : "no typed remote launch";
    const names = (cap.harnesses ?? []).map(harnessName);
    const summary = names.length ? names.join(", ") : "no harness enabled";
    return rl.state === "error" ? `${summary} (last known)` : summary;
  };
  const [completedMissions, setCompletedMissions] = createSignal<Mission[]>([]);
  const refreshMissions = async () => {
    try {
      const prev = missions().filter(m => !isMissionDeleting(m.id));
      const [rawFresh, rawCompleted] = await Promise.all([
        listMissions(200),
        listCompletedMissions(100),
      ]);
      const fresh = rawFresh.filter(m => !isMissionDeleting(m.id));
      const completed = rawCompleted.filter(m => !isMissionDeleting(m.id));
      setCompletedMissions(completed);
      const freshIds = new Set(fresh.map(m => m.id));
      const vanished = prev.filter(m => !freshIds.has(m.id));
      setMissions((current) => applyPendingMoves(mergeById(current.filter(m => !isMissionDeleting(m.id)), fresh)));
      recordMissions(fresh);
      if (vanished.length) {
        const slugs = [...new Set(vanished.map(m => m.project?.trim()).filter((s): s is string => !!s))];
        for (const slug of slugs) {
          void listProjectMissions(slug)
            .then(rows => {
              const clean = rows.filter(m => !isMissionDeleting(m.id));
              setProjectMissions(cur => ({ ...cur, [slug]: clean }));
            })
            .catch(swallow("app.refreshProjectMissions", { slug }));
        }
        for (const m of vanished) {
          if (!m.project?.trim()) {
            void getMission(m.id)
              .then(updated => {
                if (isMissionDeleting(updated.id)) return;
                const slug = updated.project?.trim() || DEFAULT_PROJECT.slug;
                setProjectMissions(cur => {
                  const existing = cur[slug] ?? [];
                  return { ...cur, [slug]: [updated, ...existing.filter(x => x.id !== updated.id)] };
                });
              })
              .catch(swallow("app.refreshVanishedMission", { mission: m.id }));
          }
        }
      }
      for (const m of fresh) if (isLive(m.status)) prefetchTranscript(m.id);
      for (const key of cacheRecents()) {
        if (key.startsWith("m:") && !isMissionDeleting(key.slice(2))) prefetchTranscript(key.slice(2));
      }
      // Pre-warm top unread Inbox transcripts & AI digests in the background so opening Inbox is instant
      const topUnread = listUnreadInboxCandidates(
        inboxMissions(),
        liveProjects(),
        (id) => peekReadyTranscript(id)?.items,
        pendingMissionInteraction,
        currentMissionId(),
        inboxConfig(),
      ).slice(0, 10);
      const cfg = inboxConfig();
      topUnread.forEach((item, idx) => {
        const readyTx = peekReadyTranscript(item.id);
        if (readyTx) {
          if (cfg.aiSummary && !item.hasInteraction) {
            requestInboxDigest(item.mission, readyTx.items, item.updatedMs, 10 + idx);
          }
        } else {
          prefetchTranscript(item.id);
        }
      });
    } catch {
      /* keep last good list */
    } finally {
      setMissionsLoading(false);
    }
  };
  const refreshFleet = async () => {
    try {
      acceptFleet(await getRemoteNodes());
    } catch {
      /* keep last good list, but stop claiming the capability is current */
      setRemoteLaunch((prev) => ({ ...prev, state: "error" }));
    }
  };
  const [projectMissions, setProjectMissions] = createSignal<Record<string, Mission[]>>({});
  createEffect(on(connectionVersion, () => {
    setProjectMissions({});
    setCompletedMissions([]);
  }, { defer: true }));
  let prevInboxMissions: Mission[] = [];
  const inboxMissions = createMemo(() => {
    const byId = new Map<string, Mission>();
    const put = (m: Mission) => {
      if (!m?.id || isMissionDeleting(m.id)) return;
      const prev = byId.get(m.id);
      if (!prev) {
        byId.set(m.id, m);
        return;
      }
      const prevTs = Date.parse(prev.updated_at || prev.created_at || "") || 0;
      const nextTs = Date.parse(m.updated_at || m.created_at || "") || 0;
      if (nextTs >= prevTs) {
        if (!prev.history?.length || m.history?.length) {
          byId.set(m.id, m);
        } else {
          byId.set(m.id, { ...prev, ...m, history: prev.history });
        }
      } else {
        if (!m.history?.length || prev.history?.length) {
          byId.set(m.id, prev);
        } else {
          byId.set(m.id, { ...m, ...prev, history: m.history });
        }
      }
    };
    for (const rows of Object.values(projectMissions())) {
      for (const m of rows) put(m);
    }
    for (const m of completedMissions()) put(m);
    for (const m of missions()) put(m);
    prevInboxMissions = mergeById(prevInboxMissions, Array.from(byId.values()));
    return withRenamedTitles("mission", prevInboxMissions, m => m.id);
  });
  const currentMissionId = createMemo(() => {
    const id = selected();
    return id && id.startsWith("m:") ? id.slice(2) : null;
  });
  /** The open mission for files and side questions. While the view reloads
   * it (openMission briefly null, mission not in the loaded list) keep the
   * last known record for the same id instead of dropping the scope. */
  const fileScopeMission = createMemo<Mission | null>(previous => {
    const id = currentMissionId();
    if (!id) return null;
    const found = openMission()?.id === id ? openMission() : missions().find(m => m.id === id);
    return found ?? (previous?.id === id ? previous : null);
  }, null);
  const inboxCount = createMemo(() => {
    transcriptVersion();
    unreadVersion();
    return isConnected()
      ? countUnreadInboxMissions(
          inboxMissions(),
          liveProjects(),
          (id) => peekReadyTranscript(id)?.items,
          pendingMissionInteraction,
          currentMissionId(),
          inboxConfig(),
        )
      : 0;
  });
  createEffect(() => {
    const mid = currentMissionId();
    if (!mid) return;
    const m = openMission()?.id === mid ? openMission()! : inboxMissions().find((row) => row.id === mid);
    if (m) markMissionRead(m, true, Boolean(pendingMissionInteraction(mid)));
  });
  // Project controller (Hermes cron): `c:<slug>`.
  const currentController = createMemo(() => {
    const id = selected();
    if (id?.startsWith("c:")) return { slug: id.slice(2) };
    if (id?.startsWith("pc:")) {
      const [, slug, cronId] = id.split(":");
      return slug && cronId ? { slug, id: cronId } : null;
    }
    return null;
  });
  // Project settings page: `ps:<slug>`.
  const currentProjectSettings = createMemo(() => {
    const id = selected();
    return id?.startsWith("ps:") ? id.slice(3) : null;
  });
  // Hosted project file: `pf:<slug>:<path>` (path may itself contain slashes).
  const currentProjectFile = createMemo(() => {
    const id = selected();
    if (!id || !id.startsWith("pf:")) return null;
    const rest = id.slice(3);
    const sep = rest.indexOf(":");
    if (sep < 0) return null;
    return { slug: rest.slice(0, sep), path: rest.slice(sep + 1) };
  });
  // Usable machines first; among them the least busy, then the one with most free memory.
  const usableNode = (node: RemoteNodeView) => node.status === "online" && (!node.cordoned || isAdministrationNode(node));
  const sortedNodes = createMemo(() => {
    const nodes = preferSparkAdministration([...fleetNodes()], node => node.id);
    return [...byLeastLoaded(nodes.filter(usableNode), node => node.id), ...nodes.filter(node => !usableNode(node))];
  });
  const canAutoSelectRemote = () => {
    const rl = remoteLaunch();
    if (rl.state !== "ready" || !rl.capability?.typed) return false;
    const backend = harnessPick()?.backend ?? harnessChoices()[0]?.backend.id;
    return !backend || remoteHarnessSupport(rl.capability, backend) === "supported";
  };
  const firstNodeId = createMemo(() => (canAutoSelectRemote() ? firstAvailableNodeId(sortedNodes()) : null));
  createEffect(() => {
    if (!isConnected() || explicitMachine() || creating() || launchPreview()) return;
    const first = firstNodeId();
    if (first && newMachine() !== first) setNewMachine(first);
  });
  const machineLabel = () => {
    if (isConnected()) {
      if (newMachine() === "core") return "Core (agent-core)";
      return nodeLabel(newMachine());
    }
    return MACHINES.find((m) => m.id === newMachine())?.name ?? nodeLabel(newMachine());
  };

  // Keyed on the connection only: the body reads selected()/newMachine()/
  // fleetNodes(), and tracking those made every fleet poll re-run the
  // effect, which re-polled the fleet — an endless fetch loop.
  createEffect(on(isConnected, (connected) => {
    if (connected) {
      void refreshMissions();
      void refreshFleet();
      void refreshHarnessChoices();
      listProjects()
        .then(setLiveProjects)
        .catch(() => setLiveProjects([]));
      // Seed agent ids only exist offline — don't land on a demo transcript.
      const sel = selected();
      if (sel && !sel.includes(":") && !PAGES.has(sel)) open(null);
      if (newMachine() === "local") void refreshLocalAgents(false);
    } else {
      // Backend views (missions, hosted files) can't render offline — e.g.
      // after a 401 cleared the token mid-session.
      const sel = selected();
      if (sel && (sel.startsWith("m:") || sel.startsWith("pf:") || sel.startsWith("c:") || sel.startsWith("pc:") || sel.startsWith("ps:") || sel === "execution")) open(null);
      // Keep an explicit machine selection across reconnects.
    }
  }));
  const sessionPreview = createMemo<SessionPreviewData>(() => {
    const id = currentMissionId() ?? "";
    const mission = openMission()?.id === id ? openMission() : missions().find(m => m.id === id);
    if (mission?.backend?.startsWith("cloud_")) return { id, title: displayTitle(renamedTitle("mission", id, mission.title)) || "Cloud agent", local: false, destination: ({cloud_chatgpt:"ChatGPT",cloud_grok_bot:"Grok Bot",cloud_cursor:"Cursor Cloud",cloud_hermes:"Paloma"} as Record<string,string>)[mission.backend], project: mission.project, context: null };
    const binding = localBinding(id);
    const local = !!binding || !!mission?.tags?.includes("placement:client");
    const backend = mission?.backend || binding?.harness;
    const choice = harnessChoices(local ? "local" : "core").find(c => c.backend.id === backend);
    const model = mission?.model_override || binding?.model;
    const modelLabel = choice?.models.find(m => m.value === model)?.label;
    const effort = normalizeEffort(mission?.model_effort, backend);
    return { id, title: displayTitle(renamedTitle("mission", id, mission?.title)) || "Mission", local,
      destination: local ? "This computer" : missionDestination(mission ?? null, recalledLaunch(id)),
      directory: binding?.cwd || mission?.working_directory,
      parent: mission && missionParent(mission) ? missions().find(m => m.id === missionParent(mission))?.title || missionParent(mission) : undefined,
      children: missions().filter(m => missionParent(m) === id).length,
      project: liveProjects().find(p => p.slug === mission?.project)?.title || mission?.project,
      harness: choice?.backend.name || backend,
      model: modelLabel ? shortModelLabel(modelLabel) : model || undefined,
      effort: effort ? effortLabel(effort) : undefined,
      context: previewContext()?.id === id ? previewContext()?.pct : null };
  });

  const onSettings = () => selected() === "settings" || selected() === "execution" || selected() === "routing" || selected() === "inbox-settings" || selected() === "btw-settings" || selected() === "hermes-settings" || selected() === "skills-settings" || selected() === "bitwarden-settings";
  const openSettings = () => {
    open("settings");
  };
  const leaveSettings = () => {
    const h = history();
    for (let i = hIdx() - 1; i >= 0; i--) {
      if (h[i] !== "settings" && h[i] !== "routing" && h[i] !== "inbox-settings" && h[i] !== "btw-settings" && h[i] !== "hermes-settings" && h[i] !== "skills-settings" && h[i] !== "bitwarden-settings") {
        if (selected() === "routing" && !confirmLeaveRouting(() => { if (open(h[i], false)) setHIdx(i); })) return;
        if (open(h[i], false)) setHIdx(i);
        return;
      }
    }
    open(null);
  };


  let navigationVersion = 0;
  const open = (id: string | null, push = true) => {
    if (id?.startsWith("m:") && isMissionDeleting(id.slice(2))) return false;
    if(id===null){
      setLaunchPreview(null);setLaunchViewKey('');
      setExplicitMachine(false);
      const first = firstNodeId();
      if (first) setNewMachine(first);
    }
    if (id === "execution") id = "settings";
    if (selected() === "routing" && id !== "routing" && !confirmLeaveRouting(() => open(id, push))) return false;
    navigationVersion++;
    if (window.matchMedia("(max-width: 720px)").matches) setSidebar(false);
    batch(() => {
      setSelected(id);
      if (push) {
        const h = history().slice(0, hIdx() + 1);
        h.push(id);
        setHistory(h);
        setHIdx(h.length - 1);
      }
    });
    if (id?.startsWith("m:")) {
      const mid = id.slice(2);
      const known = inboxMissions().find((m) => m.id === mid) ?? missions().find((m) => m.id === mid);
      if (known) markMissionRead(known, true, Boolean(pendingMissionInteraction(mid)));
      void loadTranscript(mid).catch(swallow("app.loadTranscript", { mission: mid }));
    }
    return true;
  };
  const nav = (d: number) => {
    const i = hIdx() + d;
    if (i < 0 || i >= history().length) return;
    if (selected() === "routing" && history()[i] !== "routing" && !confirmLeaveRouting(() => { if (open(history()[i], false)) setHIdx(i); })) return;
    if (open(history()[i], false)) setHIdx(i);
  };

  /** `remote`: a start requested from another device over the client link.
   * It never reads or clears this window's draft and never navigates. */
  const launchLocal = async (typed: string, prompt: string, title: string, projectSlug: string | undefined, pick: HarnessPick, images: DraftImage[], launchNavigation: number, remote?: { key: string; cwd?: string | null }) => {
    const selectedCyber = remote ? "standard" : draftCyber();
    if (!projectSlug) throw new Error("Choose a project before starting on this computer. Your draft is kept.");
    if (pick.backend === "codex") await requireSpeedSupport(pick.model,pick.service_tier??"standard",undefined,true);
    const row = await localAgentForLaunch(pick.backend);
    if (!row?.path) throw new Error("That CLI is not installed on this computer. Set its path in Settings → Local agents. Your draft is kept.");
    const plan = await materializeMentions(projectSlug, prompt, remote ? [] : attachChips());
    const chosenDirectory = remote ? (remote.cwd ?? "") : workingDirectory();
    const root = chosenDirectory.trim() ? await localDirectory(chosenDirectory) : await localWorkspace(projectSlug);
    if (plan.files.length) await writeLocalFiles(root, plan.files);
    const imagePaths = await stageLocalImages(root, images);
    const sent = imagePrompt(bindWorkspace(plan.prompt, root), imagePaths, images);
    const effort = normalizeEffort(pick.effort, pick.backend);
    const body = { title, prompt: imagePrompt(typed, imagePaths, images), project: projectSlug, tags: folderTags(projectSlug), backend: pick.backend, model_override: pick.model, placement: "client" as const, working_directory: root, ...(effort ? { model_effort: effort } : {}) };
    const signature = JSON.stringify({...body, cyber_access:selectedCyber});
    if (remote) {
      // The request id makes a retried remote start idempotent.
      const m=await startLocalOrigin({harness:pick.backend,bin:row.path,cwd:root,prompt:sent,model:pick.model,effort:pick.backend === "antigravity" ? effort ?? undefined : undefined,cyber_access:pick.backend === "codex" ? selectedCyber : undefined,service_tier:pick.backend === "codex" ? pick.service_tier??"standard" : undefined,imagePaths}, {key:remote.key,title,project:projectSlug,prompt:body.prompt,tags:body.tags});
      setMissions(prev=>[m,...prev.filter(old=>old.id!==m.id)]);
      void refreshMissions();
      return m.id;
    }
    if (launchAttempt?.signature !== signature) launchAttempt = { signature, key: crypto.randomUUID() };
    const m=await startLocalOrigin({harness:pick.backend,bin:row.path,cwd:root,prompt:sent,model:pick.model,effort:pick.backend === "antigravity" ? effort ?? undefined : undefined,cyber_access:pick.backend === "codex" ? selectedCyber : undefined,service_tier:pick.backend === "codex" ? pick.service_tier??"standard" : undefined,imagePaths}, {key:launchAttempt.key,title,project:projectSlug,prompt:body.prompt,tags:body.tags});
    launchAttempt = undefined;
    setDraftCyber("standard");
    setAttachChips([]);
    rememberLaunch(m.id, {messageKey:launchPreview()?.messageKey,prompt:imagePrompt(typed,imagePaths,images),images,nodeId:"local",destination:"This computer"});
    launchedViewKeys.set(m.id, launchViewKey());
    setMissions(prev=>[m,...prev.filter(old=>old.id!==m.id)]);
    if (selected() === null && navigationVersion === launchNavigation) open(`m:${m.id}`);
    void refreshMissions();
    return m.id;
  };

  // Remote start: another device asked this computer, over the client link,
  // to begin a mission. It runs exactly like a local start.
  const startFromRemote = async (f: RemoteStart) => {
    const choice = harnessChoices("local").find(c => c.backend.id === f.backend);
    if (!choice) throw new Error(`${f.backend} is not available on this computer.`);
    const model = f.model_override && choice.models.some(m => m.value === f.model_override) ? f.model_override : choice.models[0]?.value;
    if (!model) throw new Error(`No model is available for ${f.backend} on this computer.`);
    let projectSlug = f.project || DEFAULT_PROJECT.slug;
    if (projectSlug === DEFAULT_PROJECT.slug && !liveProjects().some(project => project.slug === projectSlug)) {
      const project = await ensureDefaultProject();
      setLiveProjects(current => [...current.filter(item => item.slug !== projectSlug), { ...DEFAULT_PROJECT, ...project } as ProjectSummary]);
      bumpProjects();
      projectSlug = DEFAULT_PROJECT.slug;
    }
    const goal = goalDraft(f.prompt);
    if (goal.kind === "empty") throw new Error(EMPTY_GOAL_ERROR);
    const prompt = goal.kind === "goal" ? goalPrompt(goal.objective) : f.prompt;
    const pick: HarnessPick = { backend: f.backend, model, ...(f.model_effort ? { effort: f.model_effort } : {}), ...(f.backend === "codex" ? { service_tier: "standard" as const } : {}) };
    return launchLocal(f.prompt, prompt, f.title?.trim() || missionTitle(f.prompt), projectSlug, pick, [], navigationVersion, { key: f.request_id, cwd: f.working_directory });
  };
  createEffect(on(isConnected, connected => {
    if (connected) void connectClientLink((f) => startFromRemote(f));
  }));
  createEffect(() => {
    if (!isConnected()) return;
    void reportClientHarnesses(harnessChoices("local").map(c => ({ backend: c.backend.id, name: c.backend.name, models: c.models.map(m => ({ value: m.value, label: m.label })) })));
  });

  const create = async (text: string, images: DraftImage[] = []) => {
    if (isConnected()) {
      if (creating()) return false;
      const goal = goalDraft(text);
      if (goal.kind === "empty") { setCreateError(EMPTY_GOAL_ERROR); return false; }
      // Goal mode rides on the prompt (server contract): the canonical
      // `/goal <objective>` enters goal mode; the title is the objective.
      const prompt = goal.kind === "goal" ? goalPrompt(goal.objective) : text;
      const title = missionTitle(text);
      const launchNavigation = navigationVersion;
      const machine = newMachine();
      if (!launchPreview() || !launchViewKey()) setLaunchViewKey(crypto.randomUUID());
      const activeViewKey = launchViewKey();
      const receipt = {messageKey:launchPreview()?.messageKey ?? `initial:${activeViewKey}`,prompt,images,nodeId:machine,destination:nodeLabel(machine)};
      const projectSlug = effectiveNewProject();
      const pick = effectivePick(machine);
      const selectedCyber = draftCyber();
      setCreating(true); setCreateError(null); setCreateRefusal(null); setLaunchPreview(receipt);
      try {
        if (!pick || !harnessChoices(machine).some(c => c.backend.id === pick.backend && c.models.some(m => m.value === pick.model))) throw new Error("Choose an available harness and model before starting. Your draft is kept.");
        if (projectSlug === DEFAULT_PROJECT.slug && !liveProjects().some(project => project.slug === projectSlug)) {
          const version = connectionVersion();
          const project = await ensureDefaultProject();
          if (connectionVersion() !== version) throw new Error("The backend changed. Try again; your draft is kept.");
          setLiveProjects(current => [...current.filter(item => item.slug !== projectSlug), { ...DEFAULT_PROJECT, ...project } as ProjectSummary]);
          bumpProjects();
        }
        if (machine === "local") {
          await launchLocal(text, prompt, title, projectSlug, pick, images, launchNavigation);
          return true;
        }
        if (machine !== "core") {
          // Fresh capability read every time: the server decides which
          // harnesses a node can run. A read failure refuses rather than guesses.
          let fleet: RemoteNodesResponse;
          try { fleet = await getRemoteNodes(); }
          catch (e) { setRemoteLaunch(prev => ({ ...prev, state: "error" })); throw new Error(remoteLaunchUnconfirmed(machine, e)); }
          acceptFleet(fleet);
          const refusal = remoteLaunchPreflight(fleet, machine, pick, harnessName);
          if (refusal) throw new Error(refusal);
        }
        // `effectivePick` already dropped an effort this harness can't take, so
        // an omitted field means "backend default" rather than a stale level.
        if(pick.backend === "codex") { await requireCyberSupport({model:pick.model,mode:selectedCyber,remote:machine !== "core"}); await requireSpeedSupport(pick.model,pick.service_tier??"standard"); }
        const effort = normalizeEffort(pick.effort, pick.backend);
        const attachments = attachChips().map(chipToAttachment);
        const sentPrompt = imagePrompt(prompt, await stageRemoteImages(images, undefined, machine), images);
        const body = {...(pick.backend === "codex" ? {cyber_access:selectedCyber,service_tier:pick.service_tier??"standard"} : {}),...(pick.backend === "vibe" && planObjective(prompt) !== null ? {agent:"plan"} : {}),title,prompt:sentPrompt,working_directory:workingDirectory().trim() || undefined,project:projectSlug,tags:folderTags(projectSlug),backend:pick.backend,model_override:pick.model,...(effort ? {model_effort:effort} : {}),...(machine === "core" ? {} : {remote_node_id:machine}),...(attachments.length ? {attachments} : {})};
        const signature = JSON.stringify(body);
        if (launchAttempt?.signature !== signature) launchAttempt = {signature,key:crypto.randomUUID()};
        const m = await createMission({...body,idempotency_key:launchAttempt.key});
        launchAttempt = undefined;
        setDraftCyber("standard");
        setAttachChips([]);
        rememberLaunch(m.id, {...receipt,prompt:sentPrompt});
        if (machine === "dgx-spark-admin") chooseMachine("core");
        launchedViewKeys.set(m.id, activeViewKey);
        setMissions(prev => [m, ...prev.filter(old => old.id !== m.id)]);
        if (selected() === null && navigationVersion === launchNavigation) open(`m:${m.id}`);
        void refreshMissions();
        return true;
      } catch (e) {
        // The idempotency key is deliberately *not* cleared here: a retry of
        // the same draft reuses it, so a request the server actually accepted
        // before failing the response cannot become a second mission.
        const refusal = launchRefusal(e, projectSlug ?? null);
        setCreateError(refusal.message);
        setCreateRefusal(refusal.kind === "other" ? null : { refusal, project: projectSlug ?? null });
        // Returning false keeps the composer text exactly as typed.
        return false;
      } finally { setCreating(false); }
    }
    setCreateError("Connect to a backend before starting a mission. Your draft is kept.");
    return false;
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.defaultPrevented || e.isComposing) return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "r" && !e.altKey) {
      e.preventDefault();
      window.dispatchEvent(new Event("orb:refresh"));
      void refreshMissions();
      return;
    }
    if (hasOverlay()) return;
    const destination = navigationShortcut(e);
    if (destination) {
      e.preventDefault();
      if (destination.id === 'projects') {
        if (onSettings()) leaveSettings();
        setSidebar(true);
        requestAnimationFrame(() => {
          const region = document.querySelector<HTMLElement>('[data-project-navigation]');
          (region?.querySelector<HTMLElement>('button.row-main, button.row.agent:not(:disabled)') ?? region)?.focus();
        });
      } else open(destination.id === 'new-agent' ? null : destination.id);
      return;
    }
    if (e.key === "Escape" && sidebar() && window.matchMedia("(max-width: 720px)").matches) {
      e.preventDefault(); setSidebar(false); return;
    }
    if (ctx() && e.key === "Escape") {
      e.preventDefault();
      setCtx(null);
      return;
    }
    if (e.key === "Escape") {
      if (onSettings()) {
        e.preventDefault();
        leaveSettings();
      }
      return;
    }
    if (e.metaKey && e.key === "/") {
      // Core-hosted reference files render through ProjectFileView.
      if (currentProjectFile()) {
        e.preventDefault();
        toggleMdSource();
      }
      return;
    }
    if (!e.metaKey) return;
    if (e.key === "n") (e.preventDefault(), open(null));
    else if (e.key === "b") (e.preventDefault(), setSidebar(!sidebar()));
    else if (e.key === ",") (e.preventDefault(), onSettings() ? leaveSettings() : openSettings());
    else if (e.key === "[") (e.preventDefault(), nav(-1));
    else if (e.key === "]") (e.preventDefault(), nav(1));
  };
  onMount(() => {
    window.addEventListener("keydown", onKey);
    const onOpenPage = (ev: Event) => {
      const target = (ev as CustomEvent<string>).detail;
      if (target) open(target);
    };
    const onDebugCron = (ev: Event) => {
      const detail = (ev as CustomEvent<{ slug?: string; prompt?: string }>).detail;
      if (!detail?.prompt) return;
      setNewFolder(null);
      if (detail.slug) setNewProject(detail.slug);
      open(null);
      setNewAgentRevision({ text: detail.prompt });
    };
    window.addEventListener("orb:open-page", onOpenPage);
    const onMoved = (e: Event) => {
      const { id, project, tags } = (e as CustomEvent<{ id: string; project: string | null; tags: string[] }>).detail;
      setMissions(prev => prev.map(m => m.id === id ? { ...m, project, tags } : m));
    };
    window.addEventListener("orb:mission-moved", onMoved);
    onCleanup(() => window.removeEventListener("orb:mission-moved", onMoved));
    // A harness transfer archives the original: hide it at once, restore it if Core refuses.
    const archivedBefore = new Map<string, Mission>();
    const onArchived = (e: Event) => {
      const { id } = (e as CustomEvent<{ id: string }>).detail;
      setMissions(prev => { const m = prev.find(x => x.id === id); if (m) archivedBefore.set(id, m); return prev.filter(x => x.id !== id); });
    };
    const onArchiveFailed = (e: Event) => {
      const { id } = (e as CustomEvent<{ id: string }>).detail;
      const m = archivedBefore.get(id); archivedBefore.delete(id);
      if (m) setMissions(prev => prev.some(x => x.id === id) ? prev : [...prev, m]);
    };
    window.addEventListener("orb:mission-archived", onArchived);
    window.addEventListener("orb:mission-archive-failed", onArchiveFailed);
    onCleanup(() => { window.removeEventListener("orb:mission-archived", onArchived); window.removeEventListener("orb:mission-archive-failed", onArchiveFailed); });
    window.addEventListener("orb:debug-cron", onDebugCron);
    onCleanup(() => {
      window.removeEventListener("orb:open-page", onOpenPage);
      window.removeEventListener("orb:debug-cron", onDebugCron);
    });
    const stopMissions = pollWhileVisible(() => (isConnected() ? refreshMissions() : undefined), 5000, "app.missions");
    const stopFleet = pollWhileVisible(() => (isConnected() ? refreshFleet() : undefined), 15000, "app.fleet");
    // Learn this Mac's approval device id so notifications sign approvals too.
    if (isConnected()) void listApprovalDevices().then((d) => thisDeviceEnrollment(d.devices)).catch(swallow("app.approvalDevices"));
    const loadSecretRequests = () =>
        isConnected()
          ? getSecretBroker()
              .then((b) => {
                const pending = b.requests.filter((r) => r.status === "pending");
                setSecretRequests(pending.length);
                syncSecretRequestNotices(pending, () => open("bitwarden-settings"));
              })
              .catch(swallow("app.secretRequests"))
          : undefined;
    const stopSecretRequests = pollWhileVisible(loadSecretRequests, 10000, "app.secretRequests");
    // Answering from a notification or the Secrets page updates the badge at once, then confirms.
    const onSecretAnswered = () => { setSecretRequests((n) => Math.max(0, n - 1)); void loadSecretRequests(); };
    const onFocus = () => void loadSecretRequests();
    window.addEventListener("orb:secret-request-answered", onSecretAnswered);
    window.addEventListener("focus", onFocus);
    onCleanup(() => { window.removeEventListener("orb:secret-request-answered", onSecretAnswered); window.removeEventListener("focus", onFocus); });
    onCleanup(() => {
      stopMissions();
      stopFleet();
      stopSecretRequests();
    });
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onKey);
  });

  const startResize = (e: PointerEvent) => {
    e.preventDefault();
    document.body.classList.add("resizing");
    const move = (ev: PointerEvent) => setSbWidth(Math.min(420, Math.max(180, ev.clientX)));
    const up = () => {
      document.body.classList.remove("resizing");
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  return (
    <div class={`app ${onSettings() ? "settings-view" : ""} ${sidebar() ? "" : "sb-hidden"}`} style={{ "--sb-w": `${onSettings() ? 220 : sbWidth()}px` }}>
      <MentionProjectContext.Provider value={()=>openMission()?.project??currentController()?.slug??effectiveNewProject()}>
      <FilePanelProvider scope={{ mission: fileScopeMission() ?? undefined, project: currentController()?.slug, controller: currentController()?.id }}>
      <button class="sidebar-backdrop" aria-label="Close sidebar" onClick={() => setSidebar(false)} tabIndex={-1} />
      <aside id="orb-sidebar" class="sidebar">
        <div class="sb-top" data-tauri-drag-region />
        <nav class="sb-scroll" onContextMenu={(e) => e.preventDefault()}>
          <Show
            when={onSettings()}
            fallback={
              <>
                <button class={`row ${selected() === null ? "active" : ""}`} onClick={() => open(null)}>
                  <span class="row-ico"><Ic.NewAgentIcon /></span>
                  <span class="row-label">New Agent</span>
                  <kbd>⌘N</kbd>
                </button>
                <button class={`row ${selected() === "inbox" ? "active" : ""}`} title={selected() === "inbox" ? "Space to return to the Inbox list" : undefined} onClick={() => open("inbox")}>
                  <span class="row-ico"><Ic.InboxIcon /></span>
                  <span class="row-label">Inbox</span>
                  <Show when={inboxCount() > 0}><span class="inbox-sb-badge" aria-label={`${inboxCount()} need attention`}>{inboxCount()}</span></Show>
                  <kbd aria-hidden="true">{shortcutLabel("inbox")}</kbd>
                </button>
                <button class={`row ${selected() === "cloud-agent" ? "active" : ""}`} onClick={() => open("cloud-agent")}>
                  <span class="row-ico"><Ic.CloudIcon /></span><span class="row-label">Cloud agent</span><kbd aria-hidden="true">{shortcutLabel("cloud-agent")}</kbd>
                </button>
                <button class={`row ${selected() === "machines" ? "active" : ""}`} onClick={() => open("machines")}>
                  <span class="row-ico"><Ic.MachinesIcon /></span>
                  <span class="row-label">Machines</span><kbd aria-hidden="true">{shortcutLabel("machines")}</kbd>
                </button>
                <button class={`row ${selected() === "providers" ? "active" : ""}`} onClick={() => open("providers")}>
                  <span class="row-ico"><Ic.ProvidersIcon /></span>
                  <span class="row-label">Providers</span><kbd aria-hidden="true">{shortcutLabel("providers")}</kbd>
                </button>

                <Show
                  when={isConnected()}
                  fallback={
                    <>
                      <div class="section">Projects</div>
                      <div class="sb-empty">
                        No backend connected.
                        <button class="sb-link" onClick={() => openSettings()}>
                          Connect
                        </button>
                      </div>
                    </>
                  }
                >
                  <div data-project-navigation tabindex="-1" aria-label="Projects" title={`Projects (${shortcutLabel('projects')})`} onKeyDown={event => {
                    if (event.defaultPrevented || !['ArrowDown','ArrowUp','Home','End'].includes(event.key) || (event.target as HTMLElement).matches('input,textarea,[contenteditable]')) return;
                    const rows = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('button.row-main, button.row.agent:not(:disabled)')).filter(row => row.getClientRects().length > 0);
                    if (!rows.length) return;
                    event.preventDefault();
                    const current = rows.indexOf(document.activeElement as HTMLButtonElement);
                    const next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : (current + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
                    rows[next].focus();
                  }}>
                  <LiveProjectsSection
                    deleteRequest={deleteMissionRequest()}
                    onDeleteRequestHandled={() => setDeleteMissionRequest(null)}
                    activityMissions={missions()}
                    currentMission={openMission()?.id === currentMissionId() ? openMission() ?? undefined : undefined}
                    harnessChoices={harnessChoices()}
                    forkChoices={mission => harnessChoices(mission.remote_node_id ?? "core")}
                    onForkOpen={mission => void refreshNodeAntigravityModels(mission.remote_node_id ?? "core")}
                    onFork={m => { setMissions(ms => [m, ...ms.filter(x => x.id !== m.id)]); bumpProjects(); open(`m:${m.id}`); }}
                    selected={selected}
                    onDeleted={ids => {
                      const idSet = new Set(ids);
                      const removed = new Set(ids.map(id => `m:${id}`));
                      batch(() => {
                        setMissions(rows => rows.filter(m => !idSet.has(m.id)));
                        setCompletedMissions(rows => rows.filter(m => !idSet.has(m.id)));
                        setProjectMissions(prev => {
                          const next: Record<string, Mission[]> = {};
                          for (const [k, rows] of Object.entries(prev)) {
                            next[k] = rows.filter(m => !idSet.has(m.id));
                          }
                          return next;
                        });
                        if (removed.has(selected() ?? "")) setSelected(null);
                        // Back/forward must not reopen conversations that no longer exist.
                        setHistory(entries => entries.map(id => id && removed.has(id) ? null : id));
                      });
                    }}
                    onProjectMissions={(slug, rows) => {
                      const clean = rows.filter(m => !isMissionDeleting(m.id));
                      setProjectMissions(prev => ({ ...prev, [slug]: clean }));
                    }}
                    open={open}
                    onNewCloudAgent={(project, path) => { setNewProject(project); setNewFolder(path ? {project, path} : null); open("cloud-agent"); }}
                    onNewAgent={(slug, path) => {
                      setNewFolder(path ? { project: slug, path } : null);
                      setNewProject(slug);
                      open(null);
                    }}
                    onNewProject={anchor => {
                      setProjectCreationAnchor(anchor);
                      setNewProjectDraft(true);
                    }}
                  />
                  </div>
                </Show>

              </>
            }
          >
            <button class="row settings-back" onClick={leaveSettings}>
              <span class="row-ico"><Ic.ArrowLeft /></span>
              <span class="row-label">Back</span>
            </button>
            <div class="settings-nav-gap" />
            <button class={`row ${selected() === "settings" ? "active" : ""}`} onClick={() => open("settings")}><span class="row-ico"><Ic.GearIcon /></span><span class="row-label">General</span></button>
            <div class="settings-nav-group-gap" />
            <button class={`row ${selected() === "routing" ? "active" : ""}`} onClick={() => open("routing")}><span class="row-ico"><Ic.CubeIcon /></span><span class="row-label">Models &amp; Routing</span></button>
            <button class={`row ${selected() === "hermes-settings" ? "active" : ""}`} onClick={() => open("hermes-settings")}><span class="row-ico"><Ic.TargetIcon /></span><span class="row-label">Coordinator</span></button>
            <button class={`row ${selected() === "btw-settings" ? "active" : ""}`} onClick={() => open("btw-settings")}><span class="row-ico"><MessageCircle size={16} /></span><span class="row-label">Side Questions</span></button>
            <div class="settings-nav-group-gap" />
            <button class={`row ${selected() === "skills-settings" ? "active" : ""}`} onClick={() => open("skills-settings")}><span class="row-ico"><Ic.SkillsIcon /></span><span class="row-label">Skills</span></button>
            <button class={`row ${selected() === "bitwarden-settings" ? "active" : ""}`} onClick={() => open("bitwarden-settings")}><span class="row-ico"><Ic.KeyIcon /></span><span class="row-label">Secrets</span><Show when={secretRequests() > 0}><span class="row-badge">{secretRequests()}</span></Show></button>
            <div class="settings-nav-group-gap" />
            <button class={`row ${selected() === "inbox-settings" ? "active" : ""}`} onClick={() => open("inbox-settings")}><span class="row-ico"><Ic.BellIcon /></span><span class="row-label">Notifications</span></button>
          </Show>
        </nav>
        <div class="sb-foot">
          <button
            class={`gear-btn ${onSettings() ? "on" : ""}`}
            title="Settings (⌘,)"
            aria-label="Settings"
            onClick={() => (onSettings() ? undefined : openSettings())}
          >
            <Ic.GearIcon />
            <span>Settings</span>
            <Show when={secretRequests() > 0}>
              <span class="gear-count" title={`${secretRequests()} secret request(s) waiting`}>{secretRequests()}</span>
            </Show>
          </button>
        </div>
        <div class="sb-resize" onPointerDown={startResize} />
      </aside>

      <header class="titlebar" data-tauri-drag-region>
        <div class="tb-left">
          <button class="icon-btn" aria-label="Toggle sidebar" aria-expanded={sidebar()} aria-controls="orb-sidebar" title="Toggle sidebar (⌘B)" onClick={() => setSidebar(!sidebar())}>
            <Ic.SidebarIcon />
          </button>
          <button class="icon-btn" title="Search">
            <Ic.SearchIcon />
          </button>
          <span class="tb-gap" />
          <button class="icon-btn" disabled={hIdx() === 0} onClick={() => nav(-1)}>
            <Ic.ArrowLeft />
          </button>
          <button class="icon-btn" disabled={hIdx() >= history().length - 1} onClick={() => nav(1)}>
            <Ic.ArrowRight />
          </button>
        </div>
        <div class="tb-title" data-tauri-drag-region>
          <Switch>
            <Match when={selected() === "settings" || selected() === "execution"}>
              <span>Settings · General</span>
            </Match>
            <Match when={selected() === "skills-settings"}><span>Settings · Skills</span></Match>
            <Match when={selected() === "bitwarden-settings"}><span>Settings · Secrets</span></Match>
            <Match when={selected() === "inbox-settings"}><span>Settings · Notifications</span></Match>
            <Match when={selected() === "hermes-settings"}><span>Settings · Coordinator</span></Match>
            <Match when={selected() === "btw-settings"}><span>Settings · Side Questions</span></Match>
            <Match when={selected() === "routing"}><span>Settings · Models &amp; Routing</span></Match>
            <Match when={selected() === "machines"}>
              <span>Machines</span>
            </Match>
            <Match when={selected() === "providers"}>
              <span>Providers</span>
            </Match>
            <Match when={selected() === "inbox"}><span>Inbox</span></Match>
            <Match when={selected() === "cloud-agent"}><span>Cloud agent</span></Match>
            <Match when={currentProjectSettings()}>
              {(slug) => <span>{liveProjects().find((x) => x.slug === slug())?.title ?? slug()} · Settings</span>}
            </Match>
            <Match when={currentMissionId()}>
              {(id) => (
                <>
                  <Show when={sessionPreview().destination === "Paloma"}><ProviderLogo type="hermes" /></Show><SessionPreview data={sessionPreview()} plan={previewPlan()?.id === id() ? previewPlan()?.data : undefined} goal={!!missionGoal(openMission()?.id === id() ? openMission() : missions().find((m) => m.id === id()))} />
                </>
              )}
            </Match>
            <Match when={currentProjectFile()}>
              {(pf) => (
                <>
                  <span>{pf().path.split("/").pop()}</span>
                  <Ic.CloudIcon class="dim" />
                  <kbd class="tb-kbd">{mdSrc() ? "Preview" : "Source"} ⌘/</kbd>
                </>
              )}
            </Match>
            {/* Right after sending, title the view from the prompt instead of "New Agent"
                for the seconds Core takes to create and title the mission. */}
            <Match when={launchPreview()?.prompt?.trim()}>
              {(prompt) => <span>{prompt().replace(/\s+/g, " ").slice(0, 80)}</span>}
            </Match>
            <Match when={true}>
              <span>New Agent</span>
            </Match>
          </Switch>
        </div>
        <FilePanelButton />
      </header>

      <main class="main">
        <Show when={selected()===null || creating()}><div style={{display:launchPreview()?"none":"contents"}}>
            <div class={`new-agent ${creating() ? "launching" : ""}`}>
              <div class="new-inner">
                <div class="na-meta">
                  <div class="na-drop" onPointerDown={(e) => e.stopPropagation()}>
                    <button class="na-drop-btn" aria-label="Choose project" aria-haspopup="dialog" aria-expanded={envOpen() === "project"} onClick={(event) => { event.currentTarget.focus(); setEnvOpen(envOpen() === "project" ? null : "project"); }}>
                      {isConnected()
                        ? (liveProjects().find((p) => p.slug === effectiveNewProject())?.title ?? (effectiveNewProject() === DEFAULT_PROJECT.slug ? DEFAULT_PROJECT.title : effectiveNewProject()) ?? "No project")
                        : undefined}
                      <Show when={newFolder()?.project === effectiveNewProject()}><span class="new-agent-folder">/ {newFolder()?.path}</span></Show>
                      <Ic.ChevronDown size={12} />
                    </button>
                    <Show when={envOpen() === "project"}>
                      <ProjectPicker projects={isConnected() ? projectChoices(liveProjects()) : []}
                        selected={effectiveNewProject() ?? ""} canCreate={isConnected()}
                        onSelect={(id) => { setNewFolder(null); setNewProject(id); setEnvOpen(null); }}
                        onClose={() => setEnvOpen(null)}
                        onCreate={() => { setProjectCreationAnchor(undefined); setEnvOpen(null); setNewProjectDraft(true); }}
                        onMachine={() => setEnvOpen("machine")} />
                    </Show>
                  </div>

                  <div class="na-drop" onPointerDown={(e) => e.stopPropagation()}>
                    <button class="na-drop-btn" onClick={() => setEnvOpen(envOpen() === "machine" ? null : "machine")}>
                      <Show when={newMachine() !== "local"} fallback={<Ic.LaptopIcon size={14} />}>
                        <Show when={newMachine() === "core"} fallback={<Ic.ComputeNodeIcon size={14} />}><Ic.CoreServerIcon size={14} /></Show>
                      </Show>
                      {machineLabel()}
                      <Ic.ChevronDown size={12} />
                    </button>
                    <Show when={envOpen() === "machine"}>
                      <Menu class="na-menu machine-menu" label="Choose machine" width={340} onClose={() => setEnvOpen(null)}>
                        <div class="na-menu-list">
                        <Show
                          when={isConnected()}
                          fallback={
                            <>
                              <For each={MACHINES.filter((m) => m.id === "local")}>
                                {(m) => (
                                  <button
                                    class={`menu-item ${m.id === newMachine() ? "on" : ""}`}
                                    aria-pressed={m.id === newMachine()}
                                    onClick={() => {
                                      chooseMachine(m.id);
                                      setEnvOpen(null);
                                    }}
                                  >
                                    <span class="menu-ico">
                                      <Ic.LaptopIcon />
                                    </span>
                                    {m.name}
                                  </button>
                                )}
                              </For>
                              <div class="menu-sep" />
                              <For each={MACHINES.filter((m) => m.id !== "local")}>
                                {(m) => (
                                  <button
                                    class={`menu-item ${m.id === newMachine() ? "on" : ""}`}
                                    aria-pressed={m.id === newMachine()}
                                    onClick={() => {
                                      chooseMachine(m.id);
                                      setEnvOpen(null);
                                    }}
                                  >
                                    <span class="menu-ico">
                                      <Ic.ComputeNodeIcon />
                                    </span>
                                    <span class="menu-col">
                                      <span class="menu-title">{m.name}</span>
                                      <span class="menu-sub">{m.user}@{m.host}</span>
                                    </span>
                                  </button>
                                )}
                              </For>
                            </>
                          }
                        >

                          <button
                            class={`menu-item ${newMachine() === "local" ? "on" : ""}`}
                                    aria-pressed={newMachine() === "local"}
                            onClick={() => {
                              chooseMachine("local");
                              setEnvOpen(null);
                            }}
                          >
                            <span class="menu-ico">
                              <Ic.LaptopIcon />
                            </span>
                            <span class="menu-col">
                              <span class="menu-title">This computer</span>

                            </span>
                            <MachineLoadBadge machine="client" />
                          </button>
                          <div class="menu-sep" />
                          <div class="machine-section-label">Remote</div>
                          <button
                            class={`menu-item ${newMachine() === "core" ? "on" : ""}`}
                                    aria-pressed={newMachine() === "core"}
                            onClick={() => {
                              chooseMachine("core");
                              setEnvOpen(null);
                            }}
                          >
                            <span class="menu-ico">
                              <Ic.CoreServerIcon />
                            </span>
                            <span class="menu-col">
                              <span class="menu-title">Core</span><span class="machine-inline-note">agent-core</span>
                            </span>
                            <MachineLoadBadge machine="core" />
                          </button>
                          <div class="menu-sep" />
                          <div class="machine-section-label machine-nodes-label">Compute nodes</div>
                          <For each={sortedNodes()}>
                            {(n) => (
                              <button
                                class={`menu-item machine-node-option ${n.id === newMachine() ? "on" : ""}`}
                                    aria-pressed={n.id === newMachine()}
                                title={isAdministrationNode(n) ? `Administration · Full sudo · Manual selection only. ${nodeLaunchNote() ?? ""}` : nodeLaunchNote()}
                                onClick={() => {
                                  chooseMachine(n.id);
                                  setEnvOpen(null);
                                }}
                              >
                                <span class="menu-ico">
                                  <Ic.ComputeNodeIcon />
                                </span>
                                <span class="menu-col">
                                  <span class="menu-title">{isAdministrationNode(n) ? "DGX Spark · Admin" : n.id}</span>
                                </span>
                                <MachineLoadBadge machine={n.id} />
                                <span class="machine-node-state"><span class={`machine-state-dot ${n.status === "online" && (!n.cordoned || isAdministrationNode(n)) ? "online" : ""}`} />{isAdministrationNode(n) && n.status === "online" ? "Manual" : n.cordoned ? "Cordoned" : n.status}</span>
                              </button>
                            )}
                          </For>
                        </Show>
                        </div>
                        <div class="na-menu-foot">
                          <div class="menu-sep" />
                          <button
                            class="menu-item"
                            onClick={() => {
                              setEnvOpen(null);
                              open("machines");
                            }}
                          >
                            <span class="menu-ico">
                              <Ic.GearIcon />
                            </span>
                            Manage machines
                          </button>
                        </div>
                      </Menu>
                    </Show>
                  </div><WorkingDirectoryPicker machine={newMachine()} machineName={machineLabel()} missions={missions()} value={workingDirectory()} disabled={creating()} onChange={chooseDirectory}/>
                </div>

                {/* NativeMissionView owns the preview through acceptance; failures restore this composer. */}
                <div hidden={!!launchPreview()}>
                <Composer
                  revision={newAgentRevision()}
                  placeholder="Describe a task, / for commands, @ for context"
                  busy={creating()}
                  onSend={create}
                  onPending={prepareLaunch}
                  onSendError={setCreateError}
                  onDraft={(text) => { if (createError() === EMPTY_GOAL_ERROR && goalDraft(text).kind !== "empty") setCreateError(null); }}
                  autofocus
                  tall
                  scope="new-agent"
                  uploadTarget={newMachine()}
                  remoteSupport={remoteSupport}
                  harnessIds={newMachine() === "local" ? installedIds() : undefined}
                  projectSlug={liveProjects().some(project => project.slug === effectiveNewProject()) ? effectiveNewProject() : undefined}
                  onAttachments={setAttachChips}
                />
                <Show when={newMachine() === "local" && localAgentsScanning()}><div class="local-scan-status" role="status"><Ic.Spinner size={12} /> Checking local agents…</div></Show>
                <ErrorToast error={createError()} title="Couldn’t start the mission" onDismiss={() => setCreateError(null)}
                  action={/GiB required.*GiB is free/.test(createError() ?? "") ? { label: "Choose machine", run: () => setEnvOpen("machine") }
                    : createRefusal()?.project ? { label: "Open project settings", run: () => open(`ps:${createRefusal()!.project}`) } : undefined} />
                </div>
              </div>
            </div>
        </div></Show>
        <Switch>
            <Match when={selected() === "inbox"}>
              <InboxPage
                onFocusContent={() => { if (window.matchMedia("(max-width: 720px)").matches) setSidebar(false); }}
                onDeleteMission={setDeleteMissionRequest}
                missions={inboxMissions()}
                projects={liveProjects()}
                loading={missionsLoading()}
                onOpenMission={(id) => open(`m:${id}`)}
                onOpenSettings={openSettings}
                onOpenInboxSettings={() => open("inbox-settings")}
                onNewAgent={() => open(null)}
                onRefresh={refreshMissions}
                onMissionUpdated={(m) => {
                  setMissions((ms) => [m, ...ms.filter((x) => x.id !== m.id)]);
                  setProjectMissions((prev) => {
                    const next: Record<string, Mission[]> = {};
                    for (const [k, rows] of Object.entries(prev)) {
                      next[k] = rows.map((x) => (x.id === m.id ? m : x));
                    }
                    return next;
                  });
                  bumpProjects();
                }}
              />
            </Match>
            <Match when={selected() === "cloud-agent"}>
            <CloudAgentPage project={effectiveNewProject() ?? ""} path={newFolder()?.project === effectiveNewProject() ? newFolder()?.path : undefined}
              projects={projectChoices(liveProjects())} onProject={id => { setNewProject(id); setNewFolder(null); }}
              onCreateProject={isConnected() ? () => { setProjectCreationAnchor(undefined); setNewProjectDraft(true); } : undefined}
              onCreated={m => { setMissions(ms => [m, ...ms.filter(x => x.id !== m.id)]); bumpProjects(); open(`m:${m.id}`); }} />
          </Match>
          <Match when={selected() === "skills-settings"}><SkillsSettings onOpenPage={open} /></Match>
          <Match when={selected() === "bitwarden-settings"}><BitwardenSettings /></Match>
          <Match when={selected() === "inbox-settings"}><InboxSettings /></Match>
          <Match when={selected() === "hermes-settings"}><HermesSettings /></Match>
          <Match when={selected() === "btw-settings"}><BtwSettings/></Match>
          <Match when={selected() === "settings" || selected() === "execution"}>
            <Settings onOpenPage={open} />
          </Match>
          <Match when={selected() === "routing"}>
            <RoutingSettings onOpenClient={() => open("settings")} />
          </Match>
          <Match when={selected() === "machines"}>
            <Machines />
          </Match>
          <Match when={selected() === "providers"}>
            <Providers />
          </Match>
          <Match when={currentMissionId() || (selected()===null && launchPreview())}>
            <Show when={currentMissionId() ? launchedViewKeys.get(currentMissionId()!) || currentMissionId() : launchViewKey()} keyed>{viewKey =>
              <Show when={viewKey===launchViewKey()} fallback={<MissionView id={currentMissionId()!} initial={missions().find(m=>m.id===currentMissionId())} onMission={setOpenMission} onPlan={(id,data)=>setPreviewPlan({id,data})} onContext={(id,pct)=>setPreviewContext({id,pct})} onFork={m=>{setMissions(ms=>[m,...ms.filter(x=>x.id!==m.id)]);bumpProjects();open(`m:${m.id}`);}}/>}>
                <NativeMissionView id={currentMissionId() || ''} initial={missions().find(m=>m.id===currentMissionId())} launch={launchPreview()??undefined} launchError={createError()??undefined} onRetryLaunch={()=>retryLaunch?.()} onMission={setOpenMission} onContext={(id,pct)=>setPreviewContext({id,pct})} onPlan={(id,data)=>setPreviewPlan({id,data})} onFork={m=>{setMissions(ms=>[m,...ms.filter(x=>x.id!==m.id)]);bumpProjects();open(`m:${m.id}`);}}/>
              </Show>
            }</Show>
          </Match>
          <Match when={currentController()}>
            {(slug) => (
              <Show when={slug()} keyed>
                {(s) => <ControllerView slug={s.slug} id={s.id} />}
              </Show>
            )}
          </Match>
          <Match when={currentProjectSettings()}>
            {(slug) => (
              <Show when={slug()} keyed>
                {(s) => <ProjectSettings slug={s} onOpenPage={open} onOpenMission={(id) => open(`m:${id}`)} />}
              </Show>
            )}
          </Match>
          <Match when={currentProjectFile()}>
            {(pf) => (
              <Show when={pf()} keyed>
                {(f) => <ProjectFileView slug={f.slug} path={f.path} />}
              </Show>
            )}
          </Match>
        </Switch>
      </main>
      <Show when={ctx()}>
        {(c) => <PopupMenu x={c().x} y={c().y} items={c().items} onClose={() => setCtx(null)} />}
      </Show>
      <Show when={newProjectDraft()}><ProjectCreation anchor={projectCreationAnchor()} existingIds={projectChoices(liveProjects()).map(p => p.id)} onCreate={submitNewProject} onClose={() => setNewProjectDraft(false)} /></Show>

      </FilePanelProvider>
      </MentionProjectContext.Provider>
    </div>
  );
}

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

function MissionView(p: Parameters<typeof NativeMissionView>[0]) {
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
  const [optimisticList, setOptimisticList] = createSignal<{id:ReturnType<typeof crypto.randomUUID>;text:string; images:DraftImage[];waiting:boolean;failed?:boolean;retry?:()=>void}[]>([]);
  const optimistic = () => optimisticList()[0] ?? null;
  let sendingIds:ReturnType<typeof crypto.randomUUID>[]=[];
  let sendChain: Promise<void> = Promise.resolve();
  const beginSend = (draft:{text:string;images:DraftImage[];retry?:()=>void}|null) => {
    if(!draft)return;
    const prevErr = sendError();
    const firstOpt = optimistic();
    const nextId = prevErr && firstOpt?.text === draft.text ? firstOpt.id : crypto.randomUUID();
    sendingIds.push(nextId);
    setSendError(null);
    let addedWaiting = true;
    setOptimisticList(prev => {
      const hasEarlierInFlight = prev.some(item => item.id !== nextId && !item.failed);
      const waiting = busy() || hasEarlierInFlight;
      addedWaiting = waiting;
      if (prev.some(item => item.id === nextId)) {
        return prev.map(item => item.id === nextId ? { ...draft, id: nextId, waiting } : item);
      }
      return [...prev, { ...draft, id: nextId, waiting }];
    });
    if (!addedWaiting) {
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
    if(optimisticList().some(item=>ids.has(item.id)))setOptimisticList(prev=>prev.filter(item=>!ids.has(item.id)));
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
    const older=()=>{if(scroller!.scrollTop<800&&peekReadyTranscript(p.id)?.hasOlder)void loadOlder().catch(e=>setError(String(e)));};
    scroller.addEventListener('scroll',older,{passive:true});onCleanup(()=>scroller?.removeEventListener('scroll',older));
    const observer = new ResizeObserver(() => { if (nearBottom) scrollIfPinned(); });
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
      const local=(await import("./localOrigins").then(m=>m.localOrigins()).catch(()=>[])).find(m=>m.id===p.id);
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
      await import("./localAgents").then(m => m.refreshLocalBindings());
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
  const localQueueActive = () => clientPlaced() && queuedLocalMessages(p.id).some(row => !row.error && !row.interrupted && (row.state === "queued" || row.state === "dispatching" || row.state === "accepted"));
  const busy = () => {
    if(!p.id)return !p.launchError;
    if (sendingImmediate()) return true;
    if (localRunActive(p.id)) return true;
    if(clientPlaced()&&localRunKnown(p.id))return queuedLocalMessages(p.id).some(row=>row.state==='dispatching');
    const s = mission()?.status;
    return isLive(s);
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
  const pending = () => {
    if(sendError())return false;
    if(!p.id)return !p.launchError;
    if(clientPlaced() && !localRunActive(p.id) && (localFailure(p.id) || queuedLocalMessages(p.id).some(row=>row.interrupted)))return false;
    const phase = missionPhase(mission(), activity());
    return (optimisticList().some(item => !item.waiting && !item.failed) || queuedLocalMessages(p.id).some(row=>!row.error && (!row.waiting || row.state==='dispatching' || row.state==='accepted')) || localRunActive(p.id) || phase.moving) && !activity();
  };
  // A remote job queued for capacity has not started: say so instead of "Working".
  const phaseLabel = () => sendingImmediate() ? "Stopping the current turn…" : mission()?.remote_job?.node_state === "queued" ? "Waiting for a free slot" : mission()?.backend === "claudecode" ? "Waiting for Claude Code" : "Working";

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
    const optEntry = optimisticList().find(item => item.id === attemptId);
    setSendError(null);
    if(explicitId&&optimisticList().length&&!optimisticList().some(item=>item.id===explicitId))setOptimisticList([]);
    if (clientPlaced()) {
      const sendVersion=connectionVersion(),sendMission=targetMissionId;
      try {
        await import("./localAgents").then(m => m.refreshLocalBindings());
      } catch (error) {
        if (!localBinding(sendMission)) {
          setSendError(`Couldn’t restore this computer’s session: ${error instanceof Error ? error.message : String(error)}. Your draft is kept.`);
          return false;
        }
      }
      const binding = localBinding(sendMission);
      if (!binding) {
        setSendError("This session runs on the computer that started it. Your draft is kept.");
        return false;
      }
      const project = mission()?.project;
      if (!project) {
        setSendError("This mission has no project, so its files cannot be copied. Your draft is kept.");
        return false;
      }
      try {
        const plan = await materializeMentions(project, text, chips);
        await prepareProjectSkills(project, binding.cwd, binding.harness, binding.bin);
        if (plan.files.length) await writeLocalFiles(binding.cwd, plan.files);
        const imagePaths = await stageLocalImages(binding.cwd, images);
        const sent = imagePrompt(bindWorkspace(plan.prompt, binding.cwd), imagePaths, images);
        if(connectionVersion()!==sendVersion||staleMission()||p.id!==sendMission)throw new Error("Conversation changed. Your draft is kept.");
        if (optEntry && !optimisticList().some(item => item.id === attemptId)) return true;
        await enqueueLocalMessage({id:sendMission,harness:binding.harness,bin:binding.bin,cwd:binding.cwd,prompt:sent,model:mission()?.model_override ?? binding.model,effort:binding.harness === "antigravity" ? normalizeEffort(mission()?.model_effort,binding.harness) ?? undefined : undefined,service_tier:binding.harness === "codex" ? missionSpeed(mission()??{}) : undefined,imagePaths},imagePrompt(text,imagePaths,images),{id:attemptId,replace,waiting:explicitId ? busy() : optEntry?.waiting??busy()});
        setOptimisticList(prev => prev.filter(item => item.id !== attemptId));
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
        setOptimisticList(prev => prev.filter(item => item.id !== attemptId));
        if (chips === followAttach()) setFollowAttach([]);
        p.onFork?.(replacement);
        return true;
      }
      const event: StreamEvent = { type: "user_message", eventId: result.id, data: { id: result.id, content: sent, queued: result.queued, receipt: true, attached: chips.length > 0 } };
      if (replaying) held.push(event);
      else applyLive(event);
      setOptimisticList(prev => prev.filter(item => item.id !== attemptId));
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
      setOptimisticList(prev => prev.map(item => item.id === attemptId ? { ...item, failed: false } : item));
      const accepted = await sendMsgOnce(text, images, chips, attemptId, explicitId, replace);
      if (!accepted) setOptimisticList(prev => prev.map(item => item.id === attemptId ? { ...item, failed: true } : item));
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
    setOptimisticList(prev => [...prev.filter(item => !projected.includes(item.id)), ...ordered.map(row => ({ id: row.id as ReturnType<typeof crypto.randomUUID>, text: messagePresentation(row.content).text, images: [], waiting: false }))]);
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
      const maxAttempts = wasBusy ? 30 : 1;
      for (let i = 0; i < ordered.length; i++) {
        if (staleMission() || p.id !== targetMissionId) return;
        const row = ordered[i];
        const presented = messagePresentation(row.content);
        const cleanText = presented.text;
        const attachments = (project ? mentionedChips(cleanText, attachItems) : []).map(chipToAttachment);
        let sent = false;
        // One id per message for every retry: Core ignores a repeated id, so a
        // retry after a lost response can never deliver the message twice.
        const freshId = crypto.randomUUID();
        for (let attempt = 0; attempt < maxAttempts; attempt++) {
          if (staleMission() || p.id !== targetMissionId) return;
          try {
            const result = await sendMissionMessage(targetMissionId, cleanText, attachments, freshId);
            if (staleMission() || p.id !== targetMissionId) return;
            if (result.replacement) {
              const replacement = result.replacement;
              const nodeId = missionNode(replacement) ?? missionNode(mission()) ?? "";
              rememberLaunch(replacement.id, { prompt: cleanText, nodeId, destination: nodeLabel(nodeId), replacement: true });
              for (const rest of ordered.slice(i + 1)) {
                const restText = messagePresentation(rest.content).text;
                const restAttach = (project ? mentionedChips(restText, attachItems) : []).map(chipToAttachment);
                await sendMissionMessage(replacement.id, restText, restAttach, crypto.randomUUID()).catch(swallow("mission.forwardToReplacement", { replacement: replacement.id }));
              }
              p.onFork?.(replacement);
              return;
            }
            // Queued behind a turn that is still stopping is accepted delivery:
            // Core sends it next. Deleting and resending would risk losing it.
            setOptimisticList(prev => prev.filter(item => item.id !== row.id));
            const event: StreamEvent = { type: "user_message", eventId: result.id, data: { id: result.id, content: cleanText, queued: result.queued, receipt: true, attached: Boolean(row.attached || presented.attached || attachments.length > 0) } };
            if (replaying) held.push(event);
            else applyLive(event);
            sent = true;
            break;
          } catch (e) {
            const msg = e instanceof Error ? e.message : String(e);
            if (attempt < maxAttempts - 1 && /still has a remote job|stopping|409/i.test(msg)) {
              await new Promise(r => setTimeout(r, 250));
              continue;
            }
            throw e;
          }
        }
        if (!sent) break;
      }
      if (!staleMission()) await refresh();
    } catch (e) {
      if (!staleMission()) setSendError(launchError(e));
      // Keep what was not delivered visible as failed rather than losing it.
      setOptimisticList(prev => prev.map(item => projected.includes(item.id) ? { ...item, failed: true } : item));
      throw e;
    } finally {
      setSendingImmediate(false);
      setOptimisticList(prev => prev.filter(item => !projected.includes(item.id) || item.failed));
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
                      <UserTurn text={r().prompt} images={r().images} pending={pending()} onSend={p.id ? sendEditedPrompt : undefined} />
                      <Show when={pending()}>
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
            <Transcript sizeKey={p.id ? `m:${p.id}` : undefined} working={busy() && activity() && !sendingImmediate()} prepareSearch={prepareSearch} items={viewItems().filter(i => i.kind !== "user" || !i.queued)} pending={pending()} onSend={p.id ? sendEditedPrompt : undefined} onResume={!busy() && !localQueueActive() && (clientPlaced() || (!remoteQueuedIds().length && !items().some(i => i.kind === "user" && i.queued))) && missionPhase(mission(), false).failed && missionPhase(mission(), false).label !== "Cancelled" ? resume : undefined} />
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
              <MissionFailure mission={mission()} active={busy() || localQueueActive() || pending() || !!sentOverStop() || (!clientPlaced() && (remoteQueuedIds().length > 0 || items().some(i => i.kind === "user" && i.queued)))} error={clientPlaced() ? localFailure(p.id) : undefined} onResume={resume} failureInTranscript={visibleTranscript(viewItems()).some(item => item.kind === "error")} />
            </Show>
            <Show when={pending()}>
              <MissionPending destination={missionDestination(mission(), receipt)} label={phaseLabel()} />
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
          <QueuedMessages mission={p.id} editing={editingQueued()} pending={clientPlaced() && !sendError() && !editingQueued() ? optimisticList().filter(item => item.waiting && !item.failed).map(item => ({id:item.id,text:item.text})) : undefined} onCancelPending={id => setOptimisticList(prev => prev.filter(item => item.id !== id))} onEdit={row=>void queuedEdit.start(row)}/>
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
