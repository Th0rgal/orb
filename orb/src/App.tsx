import { streamMission } from "./stream";
import {
  markUnfocusedMissionsDirty,
  noteMissionPresentationHint,
  recordPresentationActivity,
  refreshPresentationPreview,
  registerTranscriptWarmer,
} from "./missionCache";
import { markUnfocusedBtwDirty, noteBtwPresentationHint } from "./btwAgent";
import { lookupMissionById, resetMissionLookup } from "./missionLookup";
import { movedMission, withMovedMissions } from "./moves";
import { applyServerPlacementEvent, moveMission } from "./missionMove";
import { MissionLookupContext } from "./orchestrationModel";
import { renamedTitle, renameOptimistically, withRenamedTitles } from "./renames";
import { readString, writeString } from "./storage";
import { nodeLabel } from "./machines/nodes";
import { isLive, isWorking, missionActivity, presentedStatus } from "./missionStatus";
import { swallow } from "./log";
import { connectClientLink, reportClientHarnesses, type RemoteStart } from "./clientLink";
import {requireSpeedSupport} from './CodexSpeedPicker';
import { Menu } from "./Menu";
import { missionParent } from "./missionTree";
import { btwParentId, isBtwMission, isPartialList, mergeMission, normalizeMissionFolder, reconcileMissionList, type Misses, type PlacementCommitItem, resetMissionHierarchy, resolvedParent } from "./missionHierarchy";
import { hintSideQuestionOpen, sideQuestionKey } from "./sideQuestionStorage";
import { draftCyber, setDraftCyber, requireCyberSupport } from "./cyberAccess";
import {
  draftClaudePermission,
  draftWorktreeMode,
  setDraftClaudePermission,
  setDraftWorktreeMode,
} from "./ClaudePermissionPicker";
import {trackScrollbarHover} from "./scrollbarHover";
import {WorkingDirectoryPicker} from "./WorkingDirectoryPicker";
import {MentionProjectContext} from "./PromptEditor";
import { startLocalWakeups } from "./localWakeups";
import { startClientDelegations } from "./clientDelegations";
import {
  hasPrimaryModifier,
  isFindShortcut,
  isSearchShortcut,
  navigationShortcut,
  searchShortcutLabel,
  shortcutLabel,
  sidebarShortcutLabel,
} from "./keyboardShortcuts";
import {preferSparkAdministration} from "./machineDestinations";
import { LazyCloudAgentPage as CloudAgentPage } from "./cloudAgentsLoader";
import { orbComposerDefaultStep } from "./orbKernel";
import { monitorSoftware } from "./softwareInventory";
import {startLocalQueueWorker} from "./localMessageQueue";
const BtwSettings = lazy(() => import("./btwSettings").then(module => ({ default: module.BtwSettings })));
import { screenName, startUsageTelemetry, usageTelemetry } from "./usageTelemetry";
import {type PlanProgressData} from "./PlanProgress";
import { startLocalOrigin, localAgentForLaunch, localRunActive } from "./localAgents";
import { MachineLoadBadge, byLeastLoaded, firstAvailableNodeId, recordFleet, recordMissions } from "./machineLoad";
import { imagePrompt, stageLocalImages, stageRemoteImages, type DraftImage } from "./imageAttachments";
import { FilePanelProvider, FilePanelButton } from "./FilePanel";
import { ErrorToast, SlotActiveContext, notify } from "./toast";
import { copyText } from "./clipboard";
import { applyArchiveState, archiveStateTargets } from "./archiveState";
import type { ApprovalConfirmationPrompt } from "./tree/moves";
const ApprovalTransferDialog = lazy(() => import("./ApprovalTransferDialog"));
import { rememberLaunch, recalledLaunch, missionDestination, launchRefusal, isAdministrationNode, remoteLaunchPreflight, remoteHarnessSupport, remoteLaunchUnconfirmed, missionGoal, type LaunchReceipt, type LaunchRefusal, type RemoteSupport } from "./missionLaunch";
import { goalDraft, goalPrompt, planObjective, missionTitle, displayTitle, EMPTY_GOAL_ERROR } from "./goal";
import { chipToAttachment, type AttachChip } from "./attach";
import { DEFAULT_PROJECT, ensureDefaultProject, projectChoices } from "./defaultProject";
import { ProjectPicker, ProjectCreation } from "./ProjectPicker";
import { hasInteractiveOverlay, hasOverlay, overlayTrigger } from "./overlayLayer";
import { For, Show, Switch, Match, Suspense, lazy, createMemo, createSignal, createEffect, on, onCleanup, onMount, batch, type JSX } from "solid-js";
import { Portal } from "solid-js/web";
import { requestSearchTarget } from "./searchTarget";
import * as Ic from "./icons";
const SearchDialog = lazy(() => import("./SearchDialog"));
const Settings=lazy(()=>import("./Settings").then(module=>({default:module.Settings})));
const LocalAgentsSettings=lazy(()=>import("./Settings").then(module=>({default:module.LocalAgentsSettings})));
const SecuritySettings=lazy(()=>import("./SettingsShell").then(module=>({default:module.SecuritySettings})));
const SettingsShell=lazy(()=>import("./SettingsShell").then(module=>({default:module.SettingsShell})));
const UsersSettings=lazy(()=>import("./UsersSettings").then(module=>({default:module.UsersSettings})));
const ShareMissionDialog=lazy(()=>import("./ShareMissionDialog").then(module=>({default:module.ShareMissionDialog})));
import { SETTINGS_PAGE_IDS, SETTINGS_SECTIONS, settingsAttention, settingsPageId, settingsSectionFor, skillPageName } from "./settingsNav";
const SkillPage = lazy(() => import("./SkillPage").then(module => ({ default: module.SkillPage })));
import { ProviderLogo } from "./ProviderLogo";
import { SessionPreview, type SessionPreviewData } from "./SessionPreview";
let routingConfirmLeave: ((onDiscard?: () => void) => boolean) | null = null;
const confirmLeaveRouting = (onDiscard: () => void = () => {}) =>
  routingConfirmLeave ? routingConfirmLeave(onDiscard) : true;
const RoutingSettings = lazy(() =>
  import("./RoutingSettings").then((module) => {
    routingConfirmLeave = module.confirmLeaveRouting;
    return { default: module.RoutingSettings };
  }),
);
const Machines = lazy(() => import("./Machines").then(module => ({ default: module.Machines })));
import {
  MACHINES,
  isAdminOnlyNode,
  isAgentSpawnedManagedNode,
  isAutoManagedTarget,
  isManagedNode,
  isUserManagedNode,
  nodeSize,
  parseAutoManagedTarget,
} from "./machines/nodes";
import type { ActiveProviderSubmenu, Pending24hLeasePrompt } from "./MachineCloudMenu";
const NewAgentCloudVmSection = lazy(() => import("./MachineCloudMenu").then(module => ({ default: module.NewAgentCloudVmSection })));
const AgentSpawnedVmsToggle = lazy(() => import("./MachineCloudMenu").then(module => ({ default: module.AgentSpawnedVmsToggle })));
const Lazy24hConfirmDialog = lazy(() => import("./MachineCloudMenu").then(module => ({ default: module.Lazy24hConfirmDialog })));
const loadProvidersModule = () => import("./Providers");
const Providers = lazy(() => loadProvidersModule().then((module) => ({ default: module.Providers })));
import { ProvidersPageSkeleton } from "./ProvidersSkeleton";
const Resources = lazy(() => import("./Resources"));
import { PopupMenu, type MenuEntry } from "./Menu";
import { mdSource, toggleMdSource, warmTranscriptMarkdown } from "./Markdown";
import { createMissionKeepAlivePool } from "./missionKeepAlive";
import { projectColor } from "./projectAppearance";
import { applyPendingMoves } from "./missionMove";
import { cachePrefetch, cachePut, cacheRecents } from "./pageCache";
import { effortLabel, normalizeEffort } from "./effort";
import { loadTranscript, noteLiveMissionIds, peekReadyTranscript, prefetchTranscript, selectLivePrefetchIds, transcriptVersion } from "./missionCache";
import { loadPersistedSidebar, savePersistedSidebar } from "./persistentCache";
import { historyScope } from "./resourceCache";
import { mergeById, pollWhileVisible } from "./poll";
import { LiveProjectsSection, ProjectFileView, isMissionDeleting, missionCopyId } from "./ProjectFiles";
const ProjectSettings=lazy(()=>import("./ProjectSettings").then(module=>({default:module.ProjectSettings})));
const MissionSettings=lazy(()=>import("./MissionSettings").then(module=>({default:module.MissionSettings})));
import {
  bindWorkspace,
  desktopInvoke,
  installedIds,
  localBinding,
  localAgentsScanning,
  localSkillsStatus,
  localSkillsSync,
  localWorkspace,
  localDirectory,
  materializeMentions,
  refreshLocalAgents,
  writeLocalFiles,
} from "./localAgents";
const ControllerView = lazy(() => import("./Controller").then(module => ({ default: module.ControllerView })));
import {
  createMission,
  getMission,
  getRemoteNodes,
  isAdminUser,
  isClientPlacement,
  isConnected,
  isMissionParticipant,
  listArchivedMissions,
  ApprovalTransferConfirmationRequiredError,
  type ApprovalTransferPolicy,
  listCompletedMissions,
  listMissions,
  renameMission,
  listProjectMissions,
  listProjects,
  listProviders,
  peekCachedProjects,
  readMissionSyncCursor,
  refreshCurrentUser,
  shortModelLabel,
  createProject,
  bumpProjects,
  projectsVersion,
  connectionVersion,
  getApiUrl,
  type Mission,
  type ProjectSummary,
  type RemoteNodeView,
  type RemoteLaunchCapability,
  type RemoteNodesResponse,
} from "./api";
const UsageSettings = lazy(() => import("./UsageSettings").then(module => ({ default: module.UsageSettings })));
const HermesSettings = lazy(() => import("./HermesSettings").then(module => ({ default: module.HermesSettings })));
const SkillsSettings = lazy(() => import("./SkillsSettings").then(module => ({ default: module.SkillsSettings })));
const UsageTelemetrySettings = lazy(() => import("./UsageTelemetrySettings").then(module => ({ default: module.UsageTelemetrySettings })));
const BitwardenSettings = lazy(() => import("./BitwardenSettings").then(module => ({ default: module.BitwardenSettings })));
const InboxPage = lazy(() => import("./Inbox").then(module => ({ default: module.InboxPage })));
import { requestInboxDigest } from "./inboxDigest";
import { countUnreadInboxMissions, listUnreadInboxCandidates } from "./inboxUnread";
import { inboxConfig } from "./inboxSettings";
const InboxSettings = lazy(() => import("./InboxSettingsPanels").then(module => ({ default: module.InboxSettings })));
const InboxSummariesSettings = lazy(() => import("./InboxSettingsPanels").then(module => ({ default: module.InboxSummariesSettings })));
import { shouldRequestInboxDigest } from "./inboxPolicy";
import { pendingMissionInteraction } from "./missionAttention";
import { markMissionRead, unreadVersion } from "./missionUnread";

import { harnessChoices, harnessPick, effectivePick, refreshHarnessChoices, refreshNodeAntigravityModels, type HarnessPick } from "./harnessPick";
import { Composer } from "./composer/Composer";
import { MissionView, NativeMissionView } from "./mission/MissionView";
import {
  createNativeChromeSyncer,
  installNativeChromeWindowHandlers,
  type NativeMissionAction,
  withLiveExecution,
  isNativeChromeEnabled,
  notifyNativeChromeShell,
} from "./nativeChromeBridge";


const SETTINGS_ICONS: Record<string, () => JSX.Element> = {
  account: () => <Ic.GearIcon />, models: () => <Ic.CubeIcon />, agents: () => <Ic.SkillsIcon />, security: () => <Ic.KeyIcon />, notifications: () => <Ic.BellIcon />,
};
const PAGES = new Set(["inbox", "cloud-agent", "machines", "providers", "resources", ...SETTINGS_PAGE_IDS]);

export default function App() {
  const [secretRequests, setSecretRequests] = createSignal(0);
  const [accessRequests, setAccessRequests] = createSignal(0);
  const [privilegeRequests, setPrivilegeRequests] = createSignal(0);
  const [bunkerActive, setBunkerActive] = createSignal(false);
  const [deviceUnenrolled, setDeviceUnenrolled] = createSignal(false);
  const [searchOpen, setSearchOpen] = createSignal(false);
  const [searchQuery, setSearchQuery] = createSignal("");
  const [searchReturnFocus, setSearchReturnFocus] = createSignal<HTMLElement | null>(null);
  let searchInputEl: HTMLInputElement | undefined;
  const nativeChromeActive = isNativeChromeEnabled();
  const openSearch = () => {
    if (nativeChromeActive) {
      notifyNativeChromeShell("open_native_palette");
      return;
    }
    if (searchOpen()) {
      searchInputEl?.focus({ preventScroll: true });
      return;
    }
    const trigger = overlayTrigger() ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    setSearchReturnFocus(trigger);
    setSearchOpen(true);
  };
  onMount(() => {
    const warm = setTimeout(() => { void import("./SearchDialog"); }, 400);
    onCleanup(() => clearTimeout(warm));
  });
  const settingsDots = createMemo(() => settingsAttention({ bunkerActive: bunkerActive(), deviceEnrolled: !deviceUnenrolled() }));
  onMount(() => onCleanup(trackScrollbarHover()));
  onMount(() => { const stop = monitorSoftware(); onCleanup(stop); });
  createEffect(()=>{connectionVersion();const stop=startLocalQueueWorker();onCleanup(stop);const stopDelegations=startClientDelegations(missions);onCleanup(stopDelegations);onCleanup(startLocalWakeups());});
  const [selected, setSelected] = createSignal<string | null>((() => { const saved = readString("orb.selectedConversation"); return saved && (PAGES.has(saved) || /^(m|pf|c|pc|ps|sk|rm):/.test(saved)) ? settingsPageId(saved) : null; })());
  createEffect(() => {
    const next = selected() ?? "";
    if (readString("orb.selectedConversation") !== next) {
      writeString("orb.selectedConversation", next);
    }
  });
  onMount(() => {
    const syncWindowFocus = () => {
      const focused = document.visibilityState !== "hidden" && document.hasFocus();
      document.documentElement.dataset.windowFocused = focused ? "true" : "false";
    };
    if (!document.documentElement.dataset.windowFocused) syncWindowFocus();
    const onFocus = () => { document.documentElement.dataset.windowFocused = "true"; };
    const onBlur = () => { document.documentElement.dataset.windowFocused = "false"; };
    const onVis = () => { if (document.visibilityState === "hidden") onBlur(); else syncWindowFocus(); };
    window.addEventListener("focus", onFocus);
    window.addEventListener("blur", onBlur);
    document.addEventListener("visibilitychange", onVis);
    onCleanup(() => {
      window.removeEventListener("focus", onFocus);
      window.removeEventListener("blur", onBlur);
      document.removeEventListener("visibilitychange", onVis);
    });
  });
  onMount(() => onCleanup(startUsageTelemetry()));
  // One page view per selected page; the previous page is the entry point.
  createEffect(on(() => screenName(selected()), (screen, previous) => {
    const close = usageTelemetry.page(screen, "screen", previous ?? "launch");
    onCleanup(close);
  }));
  onMount(() => {
    registerTranscriptWarmer(warmTranscriptMarkdown);
    onCleanup(() => registerTranscriptWarmer(null));
  });
  const [sidebar, setSidebar] = createSignal(!window.matchMedia("(max-width: 720px)").matches);
  const setSidebarWithNative = (next: boolean) => {
    setSidebar(next);
    if (nativeChromeActive) notifyNativeChromeShell("set_native_sidebar", { open: next });
  };
  const [sbWidth, setSbWidth] = createSignal(220);
  const keepAlivePool = createMissionKeepAlivePool();
  const [deleteMissionRequest, setDeleteMissionRequest] = createSignal<string[] | null>(null);
  const [newFolder, setNewFolder] = createSignal<{ project: string; path: string } | null>(null);
  const newFolderPath = (project: string | null | undefined) =>
    newFolder()?.project === project && newFolder()?.path ? normalizeMissionFolder(newFolder()!.path) : "";
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
  const [rawLiveProjects, setLiveProjects] = createSignal<ProjectSummary[]>(
    isConnected() ? (peekCachedProjects() ?? []) : [],
  );
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
  // Title a cloud launch from its prompt while Core creates the mission.
  const [cloudLaunchTitle,setCloudLaunchTitle]=createSignal<string|null>(null);
  const prepareLaunch=(draft:{text:string;images:DraftImage[];retry?:()=>void}|null)=>{
    if(!draft){setLaunchPreview(null);return;}
    retryLaunch=draft.retry;setCreateError(null);
    if(!launchPreview())setLaunchViewKey(crypto.randomUUID());
    setLaunchPreview({messageKey:`initial:${launchViewKey()}`,prompt:draft.text,images:draft.images,nodeId:newMachine(),destination:nodeLabel(newMachine())});
  };
  let launchAttempt: { signature: string; key: string } | undefined;
  const MACHINE_KEY = "orb.machine";
  const [explicitMachine, setExplicitMachine] = createSignal(false);
  const initialStoredMachine = readString(MACHINE_KEY);
  const [newMachine, setNewMachine] = createSignal(
    (initialStoredMachine === "dgx-spark-admin" || isAutoManagedTarget(initialStoredMachine) ? "core" : initialStoredMachine) || "core",
  );
  const [titleShareMission, setTitleShareMission] = createSignal<Mission | null>(null);
  const [providerSubmenu, setProviderSubmenu] = createSignal<ActiveProviderSubmenu | undefined>();
  const [agentVmsOpen, setAgentVmsOpen] = createSignal(false);
  const [pending24hPick, setPending24hPick] = createSignal<Pending24hLeasePrompt | null>(null);
  const [confirmed24hTarget, setConfirmed24hTarget] = createSignal<string | null>(null);
  const [managedAntigravityAllowed, setManagedAntigravityAllowed] = createSignal(true);
  const warmManagedCatalog = (force = false) => {
    void import("./MachineCloudMenu");
    void import("./managedMachineModel").then(async m => {
      await m.refreshManagedCatalog(force);
      setManagedAntigravityAllowed(m.managedCatalog().settings?.antigravity_on_managed !== false);
    });
  };
  const chooseMachine = (id: string) => {
    const safeId = !isAdminUser() && (id === "core" || id === "dgx-spark-admin") ? "local" : id;
    setExplicitMachine(true);
    setNewMachine(safeId);
    writeString(
      MACHINE_KEY,
      safeId === "dgx-spark-admin" || isAutoManagedTarget(safeId)
        ? (isAdminUser() ? "core" : "local")
        : safeId,
    );
    if (safeId === "local") void refreshLocalAgents(false);
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
  const [palomaAvailable, setPalomaAvailable] = createSignal(false);
  createEffect(
    on([isConnected, connectionVersion], ([connected]) => {
      if (connected) void refreshCurrentUser(true);
    }),
  );
  createEffect(() => {
    connectionVersion();
    if (!isConnected()) {
      setPalomaAvailable(false);
      return;
    }
    import("./cloudAgentApi")
      .then((m) => m.cloudAccounts())
      .then((rows) => {
        if (!Array.isArray(rows)) {
          setPalomaAvailable(false);
          return;
        }
        cachePut("settings:cloud-accounts", rows);
        setPalomaAvailable(rows.some((row) => row.provider === "hermes" && row.available));
      })
      .catch(() => setPalomaAvailable(false));
  });
  const showAskPaloma = createMemo(
    () =>
      isConnected() &&
      orbComposerDefaultStep({
        hasExplicitChoice: Boolean(harnessPick()),
        hasPinnedContext: Boolean(newFolder() || workingDirectory().trim() || explicitMachine()),
        hermesAvailable: palomaAvailable(),
        hasNativeHarness: harnessChoices(newMachine()).length > 0,
      }) === "default_paloma_hermes",
  );
  const [envOpen, setEnvOpen] = createSignal<"machine" | "project" | null>(null);
  const [history, setHistory] = createSignal<(string | null)[]>([selected()]);
  const [hIdx, setHIdx] = createSignal(0);

  const [attachChips, setAttachChips] = createSignal<AttachChip[]>([]);
  const [ctx, setCtx] = createSignal<{ x: number; y: number; items: MenuEntry[] } | null>(null);
  /** A structured launch refusal, when the core gave one we can act on. */
  const [createRefusal, setCreateRefusal] = createSignal<{ refusal: LaunchRefusal; project: string | null } | null>(null);
  // Shared with ProjectFileView so ⌘/ reaches core-hosted reference files too.
  const mdSrc = mdSource;

  const [rawMissions, setMissions] = createSignal<Mission[]>([]);
  // Pending moves show every mission in its new project before Core confirms.
  const missions = createMemo(() => withMovedMissions(rawMissions()));
  const [missionsLoading, setMissionsLoading] = createSignal(true);
  const [previewContext, setPreviewContext] = createSignal<{id: string; pct: number | null} | null>(null);
  const [previewPlan, setPreviewPlan] = createSignal<{id:string; data:PlanProgressData | undefined}>();
  const [openMission, setOpenMission] = createSignal<Mission | null>(null, {
    equals: (a, b) =>
      a === b ||
      (!!a &&
        !!b &&
        a.id === b.id &&
        a.status === b.status &&
        a.updated_at === b.updated_at &&
        a.title === b.title &&
        a.project === b.project &&
        a.folder === b.folder &&
        a.backend === b.backend &&
        a.model_override === b.model_override &&
        a.model_effort === b.model_effort &&
        a.working_directory === b.working_directory &&
        a.remote_job === b.remote_job &&
        a.queue_wait === b.queue_wait &&
        a.execution === b.execution),
  });
  const syncOpenMission = (next: Mission | null, authoritative = false) => {
    if (!next) {
      if (!currentMissionId()) setOpenMission(null);
      return;
    }
    if (next.id === currentMissionId()) setOpenMission(next);
    const syncRow = (row: Mission) => {
      if (row.id !== next.id) return row;
      const prevTs = Date.parse(row.updated_at || "");
      const nextTs = Date.parse(next.updated_at || "");
      const statusNewer = authoritative || Number.isNaN(prevTs) || Number.isNaN(nextTs) || nextTs >= prevTs;
      const nextUpdatedAt = authoritative ? (next.updated_at ?? row.updated_at) : (statusNewer ? (next.updated_at || row.updated_at) : row.updated_at);
      const nextStatus = statusNewer ? next.status : row.status;
      const nextRemoteJob = statusNewer && next.remote_job !== undefined ? next.remote_job : row.remote_job;
      const nextQueueWait = statusNewer && next.queue_wait !== undefined ? next.queue_wait : row.queue_wait;
      const nextExecution = statusNewer && next.execution !== undefined ? next.execution : row.execution;
      if (
        row.status === nextStatus &&
        row.remote_job === nextRemoteJob &&
        row.queue_wait === nextQueueWait &&
        row.execution === nextExecution &&
        row.backend === next.backend &&
        row.agent === next.agent &&
        row.model_override === next.model_override &&
        row.model_effort === next.model_effort &&
        row.fast_mode === next.fast_mode &&
        row.service_tier === next.service_tier &&
        row.config_profile === next.config_profile &&
        row.updated_at === nextUpdatedAt
      ) {
        return row;
      }
      return {
        ...row,
        status: nextStatus,
        ...(nextRemoteJob !== undefined ? { remote_job: nextRemoteJob } : {}),
        ...(nextQueueWait !== undefined ? { queue_wait: nextQueueWait } : {}),
        ...(nextExecution !== undefined ? { execution: nextExecution } : {}),
        backend: next.backend,
        agent: next.agent,
        model_override: next.model_override,
        model_effort: next.model_effort,
        fast_mode: next.fast_mode,
        service_tier: next.service_tier,
        config_profile: next.config_profile,
        updated_at: nextUpdatedAt,
      };
    };
    setMissions(rows => {
      if (rows.some(r => r.id === next.id)) return rows.map(syncRow);
      if (isWorking(next.status) && !isBtwMission(next) && !isMissionDeleting(next.id)) return [next, ...rows];
      return rows;
    });
  };
  /** Only missions still doing something: the sidebar is a place to act,
   * not a history. Everything else lives under its project. */
  const [fleetNodes, setFleetNodes] = createSignal<RemoteNodeView[]>([]);
  /** Typed remote launch support as last advertised by the server. "loading"
   * until the first answer; "error" keeps the last capability but says so. */
  const [remoteLaunch, setRemoteLaunch] = createSignal<{ state: "loading" | "ready" | "error"; capability: RemoteLaunchCapability | null }>({ state: "loading", capability: null });
  const acceptFleet = (fleet: RemoteNodesResponse) => {
    setFleetNodes(fleet.nodes);
    if (Array.isArray(fleet.nodes)) cachePut("machines:nodes", fleet.nodes);
    recordFleet(fleet.nodes);
    setRemoteLaunch({ state: "ready", capability: fleet.remote_launch ?? null });
  };
  const harnessName = (id: string) => harnessChoices().find((c) => c.backend.id === id)?.backend.name ?? id;
  /** What the harness menu shows next to each harness for the selected machine. */
  const remoteSupport = (backend: string): { state: RemoteSupport; note: string } => {
    const machine = newMachine();
    if (!isConnected() || machine === "core" || machine === "local") return { state: "unknown", note: "" };
    if (isAutoManagedTarget(machine)) {
      if (backend === "grok" || backend === "vibe") return { state: "unsupported", note: "not on Cloud VMs" };
      if (backend === "antigravity" && !managedAntigravityAllowed()) {
        return { state: "unsupported", note: "disabled on Cloud VMs" };
      }
    }
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
  let sidebarPersistTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingSidebarPersist: {
    scope: string;
    missions: Mission[];
    completedMissions: Mission[];
    projects: ProjectSummary[];
  } | null = null;
  const stripSidebarHistory = (rows: Mission[]) =>
    rows.some(m => m.history?.length) ? rows.map(m => (m.history?.length ? { ...m, history: undefined } : m)) : rows;
  const flushSavePersistedSidebar = () => {
    if (sidebarPersistTimer !== undefined) {
      clearTimeout(sidebarPersistTimer);
      sidebarPersistTimer = undefined;
    }
    if (!pendingSidebarPersist) return;
    const snap = pendingSidebarPersist;
    pendingSidebarPersist = null;
    void savePersistedSidebar(snap.scope, {
      missions: stripSidebarHistory(snap.missions),
      completedMissions: stripSidebarHistory(snap.completedMissions),
      projects: snap.projects,
    });
  };
  const scheduleSavePersistedSidebar = (
    scope: string,
    payload: { missions: Mission[]; completedMissions: Mission[]; projects: ProjectSummary[] },
  ) => {
    pendingSidebarPersist = { scope, ...payload };
    if (sidebarPersistTimer !== undefined) return;
    sidebarPersistTimer = setTimeout(flushSavePersistedSidebar, 2_500);
  };
  onMount(() => {
    const onVis = () => { if (document.visibilityState === "hidden") flushSavePersistedSidebar(); };
    window.addEventListener("pagehide", flushSavePersistedSidebar);
    document.addEventListener("visibilitychange", onVis);
    onCleanup(() => {
      window.removeEventListener("pagehide", flushSavePersistedSidebar);
      document.removeEventListener("visibilitychange", onVis);
      flushSavePersistedSidebar();
    });
  });
  const listMisses: Misses = new Map();
  let missionRefreshRevision = 0, missionAppliedRevision = 0;
  let initialFullMissionSyncDone = false;
  createEffect(on(connectionVersion, () => { initialFullMissionSyncDone = false; }, { defer: true }));
  const refreshMissions = async (forceFull = false) => {
    const revision = ++missionRefreshRevision, connection = connectionVersion();
    try {
      const prev = missions().filter(m => !isMissionDeleting(m.id));
      const syncCursor = !forceFull && initialFullMissionSyncDone ? readMissionSyncCursor() : null;
      const useDelta = Boolean(syncCursor && syncCursor.polls < 20 && Date.now() - syncCursor.syncedAt < 10 * 60_000);
      const [rawFresh, rawCompleted] = await Promise.all([
        listMissions(200, useDelta ? { updatedSince: syncCursor!.cursor } : undefined),
        useDelta ? Promise.resolve(null) : listCompletedMissions(100),
      ]);
      if (revision < missionAppliedRevision || connection !== connectionVersion()) return;
      missionAppliedRevision = revision;
      if (!useDelta) initialFullMissionSyncDone = true;
      const partial = isPartialList(rawFresh);
      const fresh = rawFresh.filter(m => !isMissionDeleting(m.id));
      // No answer keeps the completed list on screen; it never empties it.
      if (rawCompleted) { const completed = rawCompleted.filter(m => !isMissionDeleting(m.id)); setCompletedMissions(current => mergeById(current, completed)); }
      const freshIds = new Set(fresh.map(m => m.id));
      const vanished = partial ? [] : prev.filter(m => !freshIds.has(m.id));
      // Reconcile, never replace: a short answer during a restart keeps what is on screen.
      const nextMissions = applyPendingMoves(mergeById(missions(), reconcileMissionList(missions().filter(m => !isMissionDeleting(m.id)), fresh, listMisses, partial)));
      setMissions(nextMissions);
      const liveIds = selectLivePrefetchIds(nextMissions, isLive);
      noteLiveMissionIds(liveIds);
      for (const id of liveIds) prefetchTranscript(id);
      scheduleSavePersistedSidebar(historyScope(), {
        missions: nextMissions,
        completedMissions: completedMissions(),
        projects: rawLiveProjects(),
      });
      recordMissions(fresh);
      if (vanished.length) {
        const slugs = [...new Set(vanished.map(m => m.project?.trim()).filter((s): s is string => !!s))];
        for (const slug of slugs) {
          void listProjectMissions(slug, { background: true })
            .then(rows => {
              const clean = rows.filter(m => !isMissionDeleting(m.id));
              setProjectMissions(cur => ({ ...cur, [slug]: clean }));
            })
            .catch(swallow("app.refreshProjectMissions", { slug }));
        }
        for (const m of vanished) {
          if (!m.project?.trim()) {
            void getMission(m.id, { includeHistory: false })
              .then(updated => {
                if (isMissionDeleting(updated.id) || isBtwMission(updated)) return;
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
      for (const key of cacheRecents()) {
        if (key.startsWith("m:") && !isMissionDeleting(key.slice(2))) prefetchTranscript(key.slice(2));
      }
      // Pre-warm top unread Inbox transcripts & AI digests in the background so opening Inbox is instant
      const cfg = inboxConfig();
      if (cfg.inboxEnabled) {
        const topUnread = listUnreadInboxCandidates(
          inboxMissions(),
          liveProjects(),
          (id) => peekReadyTranscript(id)?.items,
          pendingMissionInteraction,
          currentMissionId(),
          cfg,
        ).slice(0, 10);
        topUnread.forEach((item, idx) => {
          const readyTx = peekReadyTranscript(item.id);
          if (readyTx) {
            if (!item.hasInteraction && shouldRequestInboxDigest(cfg, "background", isLive(item.mission.status), item.updatedMs)) {
              requestInboxDigest(item.mission, readyTx.items, item.updatedMs, 10 + idx, "background");
            }
          } else {
            prefetchTranscript(item.id);
          }
        });
      }
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
  const [projectFolders, setProjectFolders] = createSignal<Record<string, string[]>>({});
  const [projectFiles, setProjectFiles] = createSignal<Record<string, string[]>>({});
  createEffect(on(connectionVersion, () => {
    setProjectMissions({});
    setProjectFolders({});
    setProjectFiles({});
    setCompletedMissions([]);
    resetMissionHierarchy();
    resetMissionLookup();
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
    return withMovedMissions(withRenamedTitles("mission", prevInboxMissions, m => m.id));
  });
  const currentMissionId = createMemo(() => {
    const id = selected();
    return id && id.startsWith("m:") ? id.slice(2) : null;
  });
  const findKnownMission = (id: string | null | undefined): Mission | undefined => {
    if (!id) return undefined;
    return (
      (openMission()?.id === id ? openMission() ?? undefined : undefined) ??
      missions().find(m => m.id === id) ??
      inboxMissions().find(m => m.id === id) ??
      resolvedParent<Mission>(id) ??
      lookupMissionById(id)
    );
  };
  /** The open mission for files and side questions. While the view reloads
   * it (openMission briefly null, mission not in the loaded list) keep the
   * last known record for the same id instead of dropping the scope. */
  const fileScopeMission = createMemo<Mission | null>(previous => {
    const id = currentMissionId();
    if (!id) return null;
    const found = findKnownMission(id);
    return found ?? (previous?.id === id ? previous : null);
  }, null);
  const inboxCount = createMemo(() => {
    transcriptVersion();
    unreadVersion();
    const cfg = inboxConfig();
    if (!cfg.inboxEnabled || !isConnected()) return 0;
    return countUnreadInboxMissions(
      inboxMissions(),
      liveProjects(),
      (id) => peekReadyTranscript(id)?.items,
      pendingMissionInteraction,
      currentMissionId(),
      cfg,
    );
  });
  createEffect(() => {
    if (!inboxConfig().inboxEnabled && selected() === "inbox") open(null);
  });
  createEffect(() => {
    const m = openMission();
    const parent = btwParentId(m);
    if (m && parent && selected() === `m:${m.id}`) {
      keepAlivePool.evictMission(m.id);
      hintSideQuestionOpen(sideQuestionKey(parent));
      setOpenMission(null);
      open(`m:${parent}`, false);
    }
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
  // Per-mission Resources / Fast-DAG view: `rm:<missionId>`.
  const currentResourcesMissionId = createMemo(() => {
    const id = selected();
    return id?.startsWith("rm:") ? id.slice(3) : null;
  });
  // Per-mission Settings page: `ms:<missionId>`.
  const currentMissionSettingsId = createMemo(() => {
    const id = selected();
    return id?.startsWith("ms:") ? id.slice(3) : null;
  });
  const resolveMissionTitle = (id: string): string | undefined => {
    const found =
      (openMission()?.id === id ? openMission() : undefined) ??
      missions().find(m => m.id === id) ??
      completedMissions().find(m => m.id === id) ??
      Object.values(projectMissions()).flat().find(m => m.id === id) ??
      lookupMissionById(id);
    return displayTitle(renamedTitle("mission", id, found?.title)) || undefined;
  };
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
    const visible = fleetNodes().filter(node => isAdminUser() || !isAdminOnlyNode(node));
    const nodes = preferSparkAdministration(visible, node => node.id);
    return [...byLeastLoaded(nodes.filter(usableNode), node => node.id), ...nodes.filter(node => !usableNode(node))];
  });
  const currentAutoBackend = () => harnessPick()?.backend ?? harnessChoices()[0]?.backend.id;
  const canAutoSelectRemote = () => {
    const rl = remoteLaunch();
    if (rl.state !== "ready" || !rl.capability?.typed) return false;
    const backend = currentAutoBackend();
    return !backend || remoteHarnessSupport(rl.capability, backend) === "supported";
  };
  const firstNodeId = createMemo(() => (canAutoSelectRemote() ? firstAvailableNodeId(sortedNodes(), currentAutoBackend()) : null));
  createEffect(() => {
    if (!isConnected() || creating() || launchPreview()) return;
    if (!isAdminUser()) {
      const cur = newMachine();
      const forbiddenNode = fleetNodes().find(n => n.id === cur && isAdminOnlyNode(n));
      if (cur === "core" || cur === "dgx-spark-admin" || Boolean(forbiddenNode)) {
        const first = firstNodeId();
        setNewMachine(first ?? "local");
        return;
      }
    }
    if (explicitMachine()) return;
    const first = firstNodeId();
    if (first) {
      if (newMachine() !== first) setNewMachine(first);
    } else if (remoteLaunch().state === "ready" && newMachine() !== "core" && newMachine() !== "local") {
      setNewMachine(isAdminUser() ? "core" : "local");
    }
  });
  const machineLabel = () => {
    if (isConnected()) {
      if (newMachine() === "core") return "Core (agent-core)";
      return nodeLabel(newMachine());
    }
    return MACHINES.find((m) => m.id === newMachine())?.name ?? nodeLabel(newMachine());
  };

  // Harnesses without models are hidden, so connecting or removing a provider
  // account can add or drop a whole harness, not just models.
  const onProvidersChanged = () => { if (isConnected()) void refreshHarnessChoices(); };
  window.addEventListener("orb:providers-refresh", onProvidersChanged);
  onCleanup(() => window.removeEventListener("orb:providers-refresh", onProvidersChanged));

  // Keyed on the connection only: the body reads selected()/newMachine()/
  // fleetNodes(), and tracking those made every fleet poll re-run the
  // effect, which re-polled the fleet — an endless fetch loop.
  createEffect(on(isConnected, (connected) => {
    if (connected) {
      const syncCachedProjects = peekCachedProjects();
      if (rawLiveProjects().length === 0 && syncCachedProjects && syncCachedProjects.length > 0) {
        setLiveProjects(syncCachedProjects);
      }
      const ver = connectionVersion();
      void loadPersistedSidebar<Mission, ProjectSummary>(historyScope()).then((cachedSidebar) => {
        if (!cachedSidebar || ver !== connectionVersion()) return;
        batch(() => {
          if (rawMissions().length === 0 && cachedSidebar.missions.length > 0) {
            setMissions(cachedSidebar.missions.filter((m) => !isMissionDeleting(m.id)));
            setMissionsLoading(false);
          }
          if (completedMissions().length === 0 && cachedSidebar.completedMissions.length > 0) {
            setCompletedMissions(cachedSidebar.completedMissions.filter((m) => !isMissionDeleting(m.id)));
          }
          if (rawLiveProjects().length === 0 && cachedSidebar.projects.length > 0) {
            setLiveProjects(cachedSidebar.projects);
          }
        });
      });
      void refreshMissions();
      void refreshFleet();
      warmManagedCatalog();
      void refreshHarnessChoices();
      cachePrefetch("providers:list", async () => {
        const providers = await listProviders();
        cachePut("providers:list", providers);
        return providers;
      });
      listProjects()
        .then((projects) => {
          setLiveProjects(projects);
          scheduleSavePersistedSidebar(historyScope(), {
            missions: rawMissions(),
            completedMissions: completedMissions(),
            projects,
          });
        })
        .catch(() => {
          if (rawLiveProjects().length === 0) setLiveProjects([]);
        });
      // Seed agent ids only exist offline — don't land on a demo transcript.
      const sel = selected();
      if (sel && !sel.includes(":") && !PAGES.has(sel)) open(null);
      if (newMachine() === "local") void refreshLocalAgents(false);
      if (desktopInvoke()) {
        const repairTimer = setTimeout(() => {
          void localSkillsStatus()
            .then((rep) => {
              if (rep?.mcp?.ready && rep.mcp.missing_harnesses.length > 0) {
                return localSkillsSync({ pruneRemoved: false, skipMcpMint: true });
              }
            })
            .catch(swallow("app.localMcpRepair"));
        }, 1500);
        onCleanup(() => clearTimeout(repairTimer));
      }
    } else {
      // Backend views (missions, hosted files) can't render offline — e.g.
      // after a 401 cleared the token mid-session.
      const sel = selected();
      if (sel && (sel.startsWith("m:") || sel.startsWith("ms:") || sel.startsWith("pf:") || sel.startsWith("c:") || sel.startsWith("pc:") || sel.startsWith("ps:") || sel.startsWith("rm:") || sel === "execution")) open(null);
      // Keep an explicit machine selection across reconnects.
    }
  }));
  const sessionPreview = createMemo<SessionPreviewData>(() => {
    const id = currentMissionId() ?? "";
    const found = findKnownMission(id);
    const mission = found ? movedMission(found) : found;
    if (mission?.backend?.startsWith("cloud_")) return { id, title: displayTitle(renamedTitle("mission", id, mission.title)) || "Cloud agent", local: false, destination: ({cloud_grok_bot:"Grok Bot",cloud_cursor:"Cursor Cloud",cloud_hermes:"Paloma"} as Record<string,string>)[mission.backend], project: mission.project, context: null };
    const binding = localBinding(id);
    const local = !!binding || isClientPlacement(mission);
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

  const onSettings = () => !!settingsSectionFor(selected());
  const pendingLaunchSlotKey = createMemo(() =>
    selected() === null && launchPreview() ? launchViewKey() : "",
  );
  let prevPoolConnEpoch = connectionVersion();
  createEffect(() => {
    const epoch = connectionVersion();
    if (epoch !== prevPoolConnEpoch) {
      prevPoolConnEpoch = epoch;
      launchedViewKeys.clear();
      keepAlivePool.clear();
    }
    const mid = currentMissionId();
    const pendingKey = pendingLaunchSlotKey();
    keepAlivePool.reconcile({
      activeMissionId: mid,
      pendingLaunchKey: pendingKey,
      launchedSlotKey: mid ? launchedViewKeys.get(mid) : undefined,
      isDeleting: isMissionDeleting,
    });
  });
  const openSettings = () => {
    open("settings");
  };
  const leaveSettings = () => {
    const h = history();
    const inboxOn = inboxConfig().inboxEnabled;
    for (let i = hIdx() - 1; i >= 0; i--) {
      if (!settingsSectionFor(h[i]) && (inboxOn || h[i] !== "inbox")) {
        if (selected() === "routing" && !confirmLeaveRouting(() => { if (open(h[i], false)) setHIdx(i); })) return;
        if (open(h[i], false)) setHIdx(i);
        return;
      }
    }
    open(null);
  };


  let sbScrollEl: HTMLElement | undefined;
  let savedSidebarScrollTop = 0;
  let navigationVersion = 0;
  const open = (id: string | null, push = true) => {
    if (id?.startsWith("m:") && isMissionDeleting(id.slice(2))) return false;
    if (id === "inbox" && !inboxConfig().inboxEnabled) id = null;
    if(id===null){
      setLaunchPreview(null);setLaunchViewKey('');
      setExplicitMachine(false);
      const first = firstNodeId();
      if (first) setNewMachine(first);
    }
    if (id) id = settingsPageId(id);
    if (selected() === "routing" && id !== "routing" && !confirmLeaveRouting(() => open(id, push))) return false;
    const wasOnSettings = onSettings();
    const nextOnSettings = Boolean(settingsSectionFor(id));
    if (!wasOnSettings && nextOnSettings && sbScrollEl) {
      savedSidebarScrollTop = sbScrollEl.scrollTop;
    }
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
    if (!wasOnSettings && nextOnSettings && sbScrollEl) {
      sbScrollEl.scrollTop = 0;
    } else if (wasOnSettings && !nextOnSettings && sbScrollEl) {
      const restore = savedSidebarScrollTop;
      sbScrollEl.scrollTop = restore;
      queueMicrotask(() => {
        if (sbScrollEl && !onSettings()) sbScrollEl.scrollTop = restore;
      });
    }
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

  const nativeChromeSyncer = nativeChromeActive ? createNativeChromeSyncer() : null;
  // The HTML sidebar (and its archive pager) is not mounted under native chrome, so the
  // native Archived section is fed from here.
  const [nativeArchived, setNativeArchived] = createSignal<Mission[]>([]);
  const [nativeApprovalPrompt, setNativeApprovalPrompt] = createSignal<ApprovalConfirmationPrompt | null>(null);
  const loadNativeArchived = () => {
    const version = connectionVersion();
    void listArchivedMissions()
      .then(rows => { if (version === connectionVersion()) setNativeArchived(rows.filter(m => !isMissionDeleting(m.id))); })
      .catch(swallow("app.nativeArchived"));
  };
  if (nativeChromeActive) {
    createEffect(on(connectionVersion, () => { setNativeArchived([]); if (isConnected()) loadNativeArchived(); }));
    onMount(() => {
      const reload = () => loadNativeArchived();
      window.addEventListener("orb:mission-archived", reload);
      onCleanup(() => window.removeEventListener("orb:mission-archived", reload));
    });
  }
  /** Native sidebar context-menu actions, sharing the HTML sidebar's API calls. */
  const nativeMissionAction = (action: NativeMissionAction, id: string, arg: string): boolean => {
    const mission = findKnownMission(id) ?? nativeArchived().find(m => m.id === id);
    if (!mission) return false;
    const fail = (title: string) => (error: unknown) => notify({ kind: "error", key: `native-action:${id}`, title, message: error instanceof Error ? error.message : String(error) });
    const settle = () => { void refreshMissions(); loadNativeArchived(); };
    switch (action) {
      case "rename":
        if (!arg || arg === mission.title) return false;
        void renameOptimistically("mission", id, arg, mission.title ?? null, () => renameMission(id, arg)).then(settle, swallow("app.nativeRename", { mission: id }));
        return true;
      case "move": {
        if (!arg || arg === (mission.project ?? "")) return false;
        // Same confirmation as the HTML sidebar (`tree/moves.ts`): a conversation holding secret
        // grants or requests asks whether to revoke or keep them before it changes project.
        const move = (policy: ApprovalTransferPolicy) => moveMission(id, arg, "", mission.project ?? null, false, policy).then(settle, error => {
          if (error instanceof ApprovalTransferConfirmationRequiredError) {
            setNativeApprovalPrompt({ error, confirm: chosen => void move(chosen), cancel: () => {} });
          } else fail("Couldn’t move the conversation")(error);
        });
        void move("check");
        return true;
      }
      case "archive":
      case "restore": {
        // Same subtree targeting as the HTML sidebar (`changeArchiveState`).
        const restore = action === "restore";
        if (restore !== (mission.status === "acknowledged")) return false; // bulk: skip rows already in that state
        const known = [...missions(), ...completedMissions(), ...Object.values(projectMissions()).flat(), ...nativeArchived()];
        void Promise.resolve()
          .then(() => applyArchiveState(mission, archiveStateTargets(mission, known, restore), restore))
          .then(settle, fail(restore ? "Couldn’t restore the conversation" : "Couldn’t archive the conversation"));
        return true;
      }
      case "copy-id":
        void copyText(missionCopyId(mission)).catch(fail("Couldn’t copy the mission ID"));
        return true;
      case "settings":
        return open(`ms:${id}`);
      case "delete": {
        // One confirmation for the whole selection, through the headless sidebar's delete flow
        // (running workers, descendants). `arg` lists the selected ids; "current" is the open one.
        const ids = arg === "current" ? [currentMissionId()].filter((x): x is string => !!x) : arg.split(/\s+/).filter(Boolean);
        if (!ids.length) return false;
        setDeleteMissionRequest(ids);
        return true;
      }
    }
  };
  onMount(() => {
    const disposeHandlers = installNativeChromeWindowHandlers({
      open: (target) => open(target),
      leaveSettings,
      navHistory: (delta) => nav(delta),
      getSidebarOpen: () => sidebar(),
      setSidebarOpen: setSidebarWithNative,
      selectProject: (slug) => {
        setNewFolder(null);
        setNewProject(slug);
      },
      getScope: historyScope,
      missionAction: nativeMissionAction,
    });
    onCleanup(() => {
      disposeHandlers();
      nativeChromeSyncer?.dispose();
    });
  });
  if (nativeChromeSyncer) {
    createEffect(() => {
      const canBack = hIdx() > 0;
      const canForward = hIdx() < history().length - 1;
      notifyNativeChromeShell("set_native_history", { can_back: canBack, can_forward: canForward });
    });
    createEffect(() => {
      const scope = historyScope();
      const sel = selected();
      const inSet = onSettings();
      const admin = isAdminUser();
      const inboxOn = inboxConfig().inboxEnabled;
      const unread = inboxCount();
      const badge = secretRequests() + accessRequests() + privilegeRequests();
      const dots = Array.from(settingsDots());
      const projs = liveProjects();
      const projColors: Record<string, string | undefined> = {};
      for (const proj of projs) {
        const c = projectColor(proj.slug);
        if (c) projColors[proj.slug] = c;
      }
      // Present the same effective status as the HTML sidebar row (`rowEffectiveStatus` in
      // ProjectFiles.tsx): a just-sent turn, a "send now" handoff or a local run reads as working
      // even before Core's mission list catches up, so switching away never shows a stale glyph.
      // The live list is the single owner of execution state: `syncOpenMission` patches only it
      // (an optimistic send keeps `updated_at`), so per-project and completed copies take their
      // status from it instead of overriding it on a timestamp tie in `orb-locald`'s merge.
      const live = new Map(missions().map(m => [m.id, m]));
      const shown = (rows: readonly Mission[]) => withLiveExecution(withRenamedTitles("mission", [...rows], m => m.id), live).map(m => {
        const status = presentedStatus(m, missionActivity(m, [], { localRun: localRunActive(m.id) }));
        return status === m.status ? m : { ...m, status };
      });
      const liveMissions = shown(missions());
      const archived = shown(nativeArchived());
      const compMissions = shown(completedMissions());
      const projMissions = Object.fromEntries(Object.entries(projectMissions()).map(([slug, rows]) => [slug, shown(rows)]));
      const projFolders = projectFolders();
      const projFiles = projectFiles();
      nativeChromeSyncer.schedule({
        scope,
        selected: sel,
        onSettings: inSet,
        isAdmin: admin,
        inboxEnabled: inboxOn,
        inboxUnread: unread,
        settingsBadge: badge,
        settingsDots: dots,
        projects: projs,
        projectColors: projColors,
        projectFolders: projFolders,
        projectFiles: projFiles,
        missions: liveMissions,
        completedMissions: compMissions,
        archivedMissions: archived,
        projectMissions: projMissions,
      });
    });
  }

  /** `remote`: a start requested from another device over the client link.
   * It never reads or clears this window's draft and never navigates. */
  const launchLocal = async (typed: string, prompt: string, title: string, projectSlug: string | undefined, pick: HarnessPick, images: DraftImage[], launchNavigation: number, remote?: { key: string; cwd?: string | null }) => {
    const selectedCyber = remote ? "automatic" : draftCyber();
    if (pick.backend === "codex") await requireCyberSupport({model:pick.model,mode:selectedCyber,remote:false,goal:goalDraft(prompt).kind === "goal"});
    if (!projectSlug) throw new Error("Choose a project before starting on this computer. Your draft is kept.");
    const [, row, plan] = await Promise.all([
      pick.backend === "codex" ? requireSpeedSupport(pick.model,pick.service_tier??"standard",undefined,true) : Promise.resolve(),
      localAgentForLaunch(pick.backend),
      materializeMentions(projectSlug, prompt, remote ? [] : attachChips()),
    ]);
    if (!row?.path) throw new Error("That CLI is not installed on this computer. Set its path in Settings → Agents → Local agents. Your draft is kept.");
    const chosenDirectory = remote ? (remote.cwd ?? "") : workingDirectory();
    const root = chosenDirectory.trim() ? await localDirectory(chosenDirectory) : await localWorkspace(projectSlug);
    const [, imagePaths] = await Promise.all([
      plan.files.length ? writeLocalFiles(root, plan.files) : Promise.resolve(),
      stageLocalImages(root, images),
    ]);
    const sent = imagePrompt(bindWorkspace(plan.prompt, root), imagePaths, images);
    const effort = normalizeEffort(pick.effort, pick.backend);
    const folder = newFolderPath(projectSlug);
    const body = { title, prompt: imagePrompt(typed, imagePaths, images), project: projectSlug, ...(folder ? { folder } : {}), tags: [] as string[], backend: pick.backend, model_override: pick.model, placement: "client" as const, working_directory: root, ...(effort ? { model_effort: effort } : {}) };
    const signature = JSON.stringify({...body, cyber_access:selectedCyber});
    if (remote) {
      // The request id makes a retried remote start idempotent.
      const m=await startLocalOrigin({harness:pick.backend,bin:row.path,cwd:root,prompt:sent,model:pick.model,effort:effort ?? undefined,cyber_access:pick.backend === "codex" ? selectedCyber : undefined,service_tier:pick.backend === "codex" ? pick.service_tier??"standard" : undefined,imagePaths}, {key:remote.key,title,project:projectSlug,...(folder ? {folder} : {}),prompt:body.prompt,tags:body.tags});
      setMissions(prev=>[m,...prev.filter(old=>old.id!==m.id)]);
      void refreshMissions();
      return m.id;
    }
    if (launchAttempt?.signature !== signature) launchAttempt = { signature, key: crypto.randomUUID() };
    const m=await startLocalOrigin({harness:pick.backend,bin:row.path,cwd:root,prompt:sent,model:pick.model,effort:effort ?? undefined,cyber_access:pick.backend === "codex" ? selectedCyber : undefined,service_tier:pick.backend === "codex" ? pick.service_tier??"standard" : undefined,permissionMode:pick.backend === "claudecode" ? draftClaudePermission() : undefined,worktreeMode:draftWorktreeMode(),imagePaths}, {key:launchAttempt.key,title,project:projectSlug,...(folder ? {folder} : {}),prompt:body.prompt,tags:body.tags});
    launchAttempt = undefined;
    setDraftCyber("automatic");
    setDraftClaudePermission("supervised");
    setDraftWorktreeMode("auto");
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
        if(pick.backend === "codex") { await Promise.all([requireCyberSupport({model:pick.model,mode:selectedCyber,remote:machine !== "core",goal:goal.kind === "goal"}), requireSpeedSupport(pick.model,pick.service_tier??"standard")]); }
        const effort = normalizeEffort(pick.effort, pick.backend);
        const attachments = attachChips().map(chipToAttachment);
        const sentPrompt = imagePrompt(prompt, await stageRemoteImages(images, undefined, machine), images);
        const folder = newFolderPath(projectSlug);
        const autoTarget = parseAutoManagedTarget(machine);
        const allow24h = autoTarget
          ? confirmed24hTarget() === machine ||
            await import("./managedMachineModel").then(m => m.is24hCommitmentSize(m.findManagedSize(autoTarget.provider, autoTarget.size)))
          : false;
        const body = {...(pick.backend === "codex" ? {cyber_access:selectedCyber,service_tier:pick.service_tier??"standard"} : {}),...(pick.backend === "claudecode" && draftClaudePermission() !== "supervised" ? {permission_mode:draftClaudePermission()} : {}),...(draftWorktreeMode() !== "auto" && !autoTarget && workingDirectory().trim() ? {worktree_mode:draftWorktreeMode()} : {}),...(pick.backend === "vibe" && planObjective(prompt) !== null ? {agent:"plan"} : {}),title,prompt:sentPrompt,working_directory:autoTarget ? undefined : (workingDirectory().trim() || undefined),project:projectSlug,...(folder ? {folder} : {}),backend:pick.backend,model_override:pick.model,...(effort ? {model_effort:effort} : {}),...(machine === "core" ? {} : {remote_node_id:machine}),...(allow24h ? {managed_allow_24h_commitment:true} : {}),...(attachments.length ? {attachments} : {})};
        const signature = JSON.stringify(body);
        if (launchAttempt?.signature !== signature) launchAttempt = {signature,key:crypto.randomUUID()};
        const m = await createMission({...body,idempotency_key:launchAttempt.key});
        launchAttempt = undefined;
        setDraftCyber("automatic");
        setDraftClaudePermission("supervised");
        setDraftWorktreeMode("auto");
        setAttachChips([]);
        if (autoTarget) warmManagedCatalog(true);
        const resolvedNode = m.remote_node_id ?? machine;
        rememberLaunch(m.id, {...receipt,nodeId:resolvedNode,destination:nodeLabel(resolvedNode === machine ? machine : resolvedNode),prompt:sentPrompt});
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
    const sidebarFocused =
      isFindShortcut(e) &&
      !!document.getElementById("orb-sidebar")?.contains(document.activeElement);
    if (isSearchShortcut(e) || sidebarFocused) {
      if (searchOpen()) {
        e.preventDefault();
        searchInputEl?.focus({ preventScroll: true });
        return;
      }
      if (!hasInteractiveOverlay()) {
        e.preventDefault();
        openSearch();
      }
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "r" && !e.altKey) {
      e.preventDefault();
      if (e.shiftKey) {
        window.location.reload();
        return;
      }
      window.dispatchEvent(new Event("orb:refresh"));
      void refreshMissions();
      return;
    }
    if (hasOverlay()) return;
    const destination = navigationShortcut(e);
    if (destination) {
      if (destination.id === "inbox" && !inboxConfig().inboxEnabled) return;
      e.preventDefault();
      if (destination.id === 'projects') {
        if (onSettings()) leaveSettings();
        setSidebarWithNative(true);
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
    if (hasPrimaryModifier(e) && !e.altKey && !e.shiftKey && e.key === "/") {
      // Core-hosted reference files render through ProjectFileView.
      if (currentProjectFile()) {
        e.preventDefault();
        toggleMdSource();
      }
      return;
    }
    if (!hasPrimaryModifier(e) || e.altKey || e.shiftKey) return;
    const key = e.key.toLowerCase();
    if (key === "n") (e.preventDefault(), open(null));
    else if (key === "b") (e.preventDefault(), setSidebarWithNative(!sidebar()));
    else if (e.key === ",") (e.preventDefault(), onSettings() ? leaveSettings() : openSettings());
    else if (e.key === "[") (e.preventDefault(), nav(-1));
    else if (e.key === "]") (e.preventDefault(), nav(1));
  };
  onMount(() => {
    window.addEventListener("keydown", onKey);
    // When the user selects non-editable DOM text while an input/textarea retains focus with no
    // text selected inside it (e.g. auto-focused Composer), blur the input so WebKit/WebKitGTK
    // routes Cmd/Ctrl+C to the document range selection.
    const onSelectionChange = () => {
      const active = document.activeElement;
      if (!(active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement)) return;
      if ((active.selectionStart ?? 0) !== (active.selectionEnd ?? 0)) return;
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed || !sel.anchorNode || active.contains(sel.anchorNode)) return;
      active.blur();
    };
    document.addEventListener("selectionchange", onSelectionChange);
    onCleanup(() => document.removeEventListener("selectionchange", onSelectionChange));
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
    const onPlacementChanged = (e: Event) => {
      const { moves } = (e as CustomEvent<{ moves?: PlacementCommitItem[] }>).detail ?? {};
      if (!moves?.length) return;
      const byId = new Map(moves.map(item => [item.mission_id, item]));
      setMissions(prev => {
        let changed = false;
        const out = prev.map(m => {
          const item = byId.get(m.id);
          if (!item) return m;
          changed = true;
          return mergeMission(m, {
            id: m.id,
            project: item.project,
            folder: item.folder,
            placement_revision: item.placement_revision,
          }, "partial");
        });
        return changed ? out : prev;
      });
    };
    window.addEventListener("orb:mission-placement-changed", onPlacementChanged);
    onCleanup(() => window.removeEventListener("orb:mission-placement-changed", onPlacementChanged));
    // A harness transfer archives the original: hide it at once, restore it if Core refuses.
    const archivedBefore = new Map<string, Mission>();
    const onArchived = (e: Event) => {
      const { id } = (e as CustomEvent<{ id: string }>).detail;
      if (id !== currentMissionId()) keepAlivePool.evictMission(id);
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
    // One foreground compact stream. Hints invalidate authoritative reads;
    // they never overwrite mission status or transcript revisions directly.
    let stopPresentation: (() => void) | undefined;
    let presentationTimer: ReturnType<typeof setTimeout> | undefined;
    let presentationConnected = false;
    let missionPollTick = 0;
    const changed = new Set<string>();
    let needsList = false;
    const flushPresentation = () => {
      presentationTimer = undefined;
      const ids = [...changed].slice(0, 12); changed.clear();
      for (const id of ids) void refreshPresentationPreview(id).catch(swallow("presentation.refresh"));
      if (needsList) { needsList = false; void refreshMissions(); }
    };
    const connectPresentation = () => {
      stopPresentation?.(); stopPresentation = undefined;
      presentationConnected = false;
      changed.clear(); needsList = false; clearTimeout(presentationTimer); presentationTimer = undefined;
      if (document.hidden || !isConnected()) return;
      stopPresentation = streamMission(
        null,
        event => {
          if (event.type === "mission_placement_changed") {
            const moves = Array.isArray(event.data.moves)
              ? (event.data.moves as import("./api").MissionPlacementItem[])
              : [];
            const clientOpId = typeof event.data.client_op_id === "number" ? event.data.client_op_id : null;
            const clientId = typeof event.data.client_id === "string" ? event.data.client_id : null;
            applyServerPlacementEvent(moves, clientOpId, clientId);
            return;
          }
          if (event.type !== "mission_presentation") return;
          const id = event.data.mission_id;
          const btwParent = event.data.btw_parent_id;
          if (typeof btwParent === "string") {
            noteBtwPresentationHint(btwParent, typeof id === "string" ? id : undefined);
          }
          if (typeof id === "string") {
            noteMissionPresentationHint(id, event.data.kind);
          }
          if (event.data.kind === "mission_activity") {
            if (typeof id === "string") recordPresentationActivity(id, event.data.label);
            return;
          }
          if (typeof id === "string" && changed.size < 12) changed.add(id);
          if (event.data.kind !== "mission_activity") needsList = true;
          presentationTimer ??= setTimeout(flushPresentation, needsList ? 150 : 1000);
        },
        () => { markUnfocusedMissionsDirty(); markUnfocusedBtwDirty(); void refreshMissions(); },
        () => { presentationConnected = true; },
        "presentation",
        undefined,
        () => { presentationConnected = false; markUnfocusedMissionsDirty(); markUnfocusedBtwDirty(); },
      );
    };
    createEffect(() => { connectionVersion(); connectPresentation(); });
    document.addEventListener("visibilitychange", connectPresentation);
    onCleanup(() => {
      presentationConnected = false;
      stopPresentation?.(); clearTimeout(presentationTimer);
      document.removeEventListener("visibilitychange", connectPresentation);
    });
    const stopMissions = pollWhileVisible(() => {
      if (!isConnected()) return undefined;
      if (presentationConnected && ++missionPollTick % 6 !== 0) return undefined;
      return refreshMissions();
    }, 5000, "app.missions");
    const stopFleet = pollWhileVisible(() => (isConnected() ? refreshFleet() : undefined), 15000, "app.fleet");
    // Learn this Mac's approval device id so notifications sign approvals too.
    // An unenrolled device that could approve puts a dot on Security.
    const loadEnrollment = () => {
      if (!isConnected() || !isAdminUser()) {
        setDeviceUnenrolled(false);
        return;
      }
      void import("./deviceApproval")
        .then((da) =>
          Promise.all([da.listApprovalDevices().then((d) => da.thisDeviceEnrollment(d.devices)), da.localApprovalKey()]),
        )
        .then(([mine, key]) => setDeviceUnenrolled(key.available && !mine))
        .catch(swallow("app.approvalDevices"));
    };
    loadEnrollment();
    window.addEventListener("orb:approval-devices-changed", loadEnrollment);
    onCleanup(() => window.removeEventListener("orb:approval-devices-changed", loadEnrollment));
    const loadApprovals = () => {
      if (!isConnected() || !isAdminUser()) {
        setSecretRequests(0);
        setAccessRequests(0);
        setPrivilegeRequests(0);
        return undefined;
      }
      return Promise.all([import("./approvalQueue"), import("./approvalQueueNotices")])
        .then(([aq, notices]) =>
          aq.getApprovalQueue().then(({ items }) => {
            // One queue for every kind: the card shows them all, the badges count each.
            setSecretRequests(items.filter((i) => i.kind === "secret").length);
            setAccessRequests(items.filter((i) => i.kind === "mission_access").length);
            setPrivilegeRequests(items.filter((i) => i.kind === "privilege").length);
            notices.syncApprovalQueue(items, () => open("bitwarden-settings"));
          }),
        )
        .catch(swallow("app.approvalQueue"));
    };
    const stopApprovals = pollWhileVisible(loadApprovals, 10000, "app.approvalQueue");
    const loadBunkerState = () => {
      if (!isConnected() || !isAdminUser()) {
        setBunkerActive(false);
        return undefined;
      }
      return Promise.all([import("./privilegeAccessApi"), import("./approvalQueueNotices")])
        .then(([pa, notices]) =>
          pa.getPrivilegeAccess().then((snap) => {
            setBunkerActive(snap.bunker_state > 0);
            notices.syncBunkerNotice(snap.bunker_state, () => open("security-settings"));
          }),
        )
        .catch(swallow("app.bunkerState"));
    };
    const stopBunkerState = pollWhileVisible(loadBunkerState, 10000, "app.bunkerState");
    void loadBunkerState();
    onCleanup(stopBunkerState);
    // Answering anywhere (card, notification, Secrets page) refreshes the queue at once.
    const answeredEvents = ["orb:secret-request-answered", "orb:mission-access-answered", "orb:privilege-access-answered", "focus"];
    let reloadQueued = false;
    const onApprovalsChanged = () => {
      // A batch answers several requests at once: reload once.
      if (reloadQueued) return;
      reloadQueued = true;
      queueMicrotask(() => { reloadQueued = false; void loadApprovals(); void loadBunkerState(); });
    };
    for (const e of answeredEvents) window.addEventListener(e, onApprovalsChanged);
    onCleanup(() => { for (const e of answeredEvents) window.removeEventListener(e, onApprovalsChanged); });
    onCleanup(() => {
      stopMissions();
      stopFleet();
      stopApprovals();
    });
  });
  onCleanup(() => {
    window.removeEventListener("keydown", onKey);
  });

  const commitFork = (m: Mission, navigate = true) => {
    if (isBtwMission(m)) {
      const parent = btwParentId(m);
      if (parent && navigate) {
        hintSideQuestionOpen(sideQuestionKey(parent));
        open(`m:${parent}`, false);
      }
      return;
    }
    batch(() => {
      setMissions(ms => [m, ...ms.filter(x => x.id !== m.id)]);
      if (navigate) setOpenMission(m);
      window.dispatchEvent(new CustomEvent("orb:mission-forked", { detail: { mission: m } }));
      bumpProjects();
      if (navigate) open(`m:${m.id}`);
    });
  };

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

  const renderLiveProjectsSection = (headless: boolean) => (
    <LiveProjectsSection
      headless={headless}
      active={() => !onSettings()}
      deleteRequest={deleteMissionRequest()}
      onDeleteRequestHandled={() => setDeleteMissionRequest(null)}
      activityMissions={missions()}
      currentMission={(() => { const m = findKnownMission(currentMissionId()); return m ? movedMission(m) : undefined; })()}
      harnessChoices={harnessChoices()}
      forkChoices={mission => harnessChoices(mission.remote_node_id ?? "core")}
      onForkOpen={mission => void refreshNodeAntigravityModels(mission.remote_node_id ?? "core")}
      onFork={commitFork}
      selected={selected}
      onDeleted={ids => {
        const idSet = new Set(ids);
        const removed = new Set(ids.flatMap(id => [`m:${id}`, `ms:${id}`, `rm:${id}`]));
        batch(() => {
          for (const id of ids) keepAlivePool.evictMission(id);
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
      onProjectEntries={(slug, folders, files) => {
        setProjectFolders(prev => ({ ...prev, [slug]: folders }));
        setProjectFiles(prev => ({ ...prev, [slug]: files }));
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
  );

  return (
    <div class={`app ${onSettings() ? "settings-view" : ""} ${(nativeChromeActive || !sidebar()) ? "sb-hidden" : ""}`} data-native-chrome={nativeChromeActive ? "true" : undefined} data-native-sb-open={nativeChromeActive ? (sidebar() ? "true" : "false") : undefined} data-pane={currentMissionId() ? "mission" : (currentController() || currentProjectFile() || currentProjectSettings()) ? "project" : "page"} style={{ "--sb-w": `${onSettings() ? 220 : sbWidth()}px` }}>
      <MentionProjectContext.Provider value={()=>openMission()?.project??currentController()?.slug??effectiveNewProject()}>
      <FilePanelProvider missionOpen={currentMissionId()} scope={{ mission: fileScopeMission() ?? undefined, project: currentController()?.slug, controller: currentController()?.id }} sidebar={sidebar} onSetSidebar={setSidebarWithNative}>
      <Show when={!nativeChromeActive}>
      <button class="sidebar-backdrop" aria-label="Close sidebar" onClick={() => setSidebar(false)} tabIndex={-1} />
      <aside id="orb-sidebar" class="sidebar">
        <div class="sb-top" data-orb-drag-region />
        <nav ref={sbScrollEl} class="sb-scroll" onContextMenu={(e) => e.preventDefault()}>
          <div class="sb-main-nav" hidden={onSettings()}>
            <button class={`row ${selected() === null ? "active" : ""}`} onClick={() => open(null)}>
              <span class="row-ico"><Ic.NewAgentIcon /></span>
              <span class="row-label">New Agent</span>
              <kbd>⌘N</kbd>
            </button>
            <Show when={inboxConfig().inboxEnabled}>
              <button class={`row ${selected() === "inbox" ? "active" : ""}`} title={selected() === "inbox" ? "Space to return to the Inbox list" : undefined} onClick={() => open("inbox")}>
                <span class="row-ico"><Ic.InboxIcon /></span>
                <span class="row-label">Inbox</span>
                <Show when={inboxCount() > 0}><span class="inbox-sb-badge" aria-label={`${inboxCount()} need attention`}>{inboxCount()}</span></Show>
                <kbd aria-hidden="true">{shortcutLabel("inbox")}</kbd>
              </button>
            </Show>
            <button class={`row ${selected() === "cloud-agent" ? "active" : ""}`} onClick={() => open("cloud-agent")}>
              <span class="row-ico"><Ic.CloudIcon /></span><span class="row-label">Cloud agent</span><kbd aria-hidden="true">{shortcutLabel("cloud-agent")}</kbd>
            </button>
            <button class={`row ${selected() === "machines" ? "active" : ""}`} onClick={() => open("machines")}>
              <span class="row-ico"><Ic.MachinesIcon /></span>
              <span class="row-label">Machines</span><kbd aria-hidden="true">{shortcutLabel("machines")}</kbd>
            </button>
            <button
              class={`row ${selected() === "providers" ? "active" : ""}`}
              onPointerEnter={() => void loadProvidersModule()}
              onFocus={() => void loadProvidersModule()}
              onClick={() => open("providers")}
            >
              <span class="row-ico"><Ic.CubeIcon /></span>
              <span class="row-label">Inference</span><kbd aria-hidden="true">{shortcutLabel("providers")}</kbd>
            </button>
            <button class={`row ${selected() === "resources" || Boolean(currentResourcesMissionId()) ? "active" : ""}`} data-testid="sb-resources" onClick={() => open("resources")}>
              <span class="row-ico"><Ic.ResourcesIcon /></span>
              <span class="row-label">Resources</span><kbd aria-hidden="true">{shortcutLabel("resources")}</kbd>
            </button>

            <Show
              when={isConnected() ? connectionVersion() + 1 : 0}
              keyed
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
              {(_ver) => (
                <div data-project-navigation tabindex="-1" aria-label="Projects" aria-keyshortcuts="Meta+5" onKeyDown={event => {
                  if (event.defaultPrevented || !['ArrowDown','ArrowUp','Home','End'].includes(event.key) || (event.target as HTMLElement).matches('input,textarea,[contenteditable]')) return;
                  const rows = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('button.row-main, button.row.agent:not(:disabled)')).filter(row => row.getClientRects().length > 0);
                  if (!rows.length) return;
                  event.preventDefault();
                  const current = rows.indexOf(document.activeElement as HTMLButtonElement);
                  const next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : (current + (event.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
                  rows[next].focus();
                }}>
                  {renderLiveProjectsSection(false)}
                </div>
              )}
            </Show>
          </div>
          <Show when={onSettings()}>
            <button class="row settings-back" onClick={leaveSettings}>
              <span class="row-ico"><Ic.ArrowLeft /></span>
              <span class="row-label">Back</span>
            </button>
            <div class="settings-nav-gap" />
            <For each={SETTINGS_SECTIONS.filter((sec) => sec.id !== "security" || isAdminUser())}>{(sec) => {
              const count = () => sec.id === "security" ? secretRequests() + accessRequests() + privilegeRequests() : 0;
              return <button class={`row ${settingsSectionFor(selected())?.id === sec.id ? "active" : ""}`} data-settings-section={sec.id}
                aria-current={settingsSectionFor(selected())?.id === sec.id ? "page" : undefined} onClick={() => open(sec.tabs[0].id)}>
                <span class="row-ico">{SETTINGS_ICONS[sec.id]()}</span><span class="row-label">{sec.label}</span>
                <Show when={count() > 0}><span class="row-badge">{count()}</span></Show>
                <Show when={settingsDots().has(sec.id)}><span class="row-dot" role="img" aria-label="Needs attention" title="Needs attention" /></Show>
              </button>;
            }}</For>
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
            <Show when={secretRequests() + accessRequests() + privilegeRequests() > 0}>
              <span class="gear-count" title={`${secretRequests() + accessRequests() + privilegeRequests()} request(s) waiting`}>{secretRequests() + accessRequests() + privilegeRequests()}</span>
            </Show>
          </button>
        </div>
        <div class="sb-resize" onPointerDown={startResize} />
      </aside>
      </Show>
      <Show when={nativeChromeActive && isConnected() ? connectionVersion() + 1 : 0} keyed>
        {(_ver) => renderLiveProjectsSection(true)}
      </Show>
      <Show when={nativeApprovalPrompt()}>
        {(prompt) => <Suspense><ApprovalTransferDialog prompt={prompt()} onDismiss={() => setNativeApprovalPrompt(null)} /></Suspense>}
      </Show>

      <header class="titlebar" data-orb-drag-region>
        <div class="tb-left">
          <button class="icon-btn" aria-label="Toggle sidebar" aria-expanded={sidebar()} aria-controls="orb-sidebar" title={`Toggle sidebar (${sidebarShortcutLabel()})`} onClick={() => setSidebarWithNative(!sidebar())}>
            <Ic.SidebarIcon />
          </button>
          <button class="icon-btn" aria-label="Search conversations" title={`Search (${searchShortcutLabel()})`} onClick={openSearch}>
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
        <div class="tb-title" data-orb-drag-region>
          <Switch>
            <Match when={skillPageName(selected())}>{(sk) => <span>Skills · {sk().name}</span>}</Match>
            <Match when={settingsSectionFor(selected())}>{(sec) => <span>Settings · {sec().label}</span>}</Match>
            <Match when={selected() === "machines"}>
              <span>Machines</span>
            </Match>
            <Match when={selected() === "providers"}>
              <span>Inference</span>
            </Match>
            <Match when={selected() === "resources"}>
              <span>Resources</span>
            </Match>
            <Match when={currentResourcesMissionId()}>
              {(mid) => (
                <span>
                  Resources · {missions().find((m) => m.id === mid())?.title || mid().slice(0, 8)}
                </span>
              )}
            </Match>
            <Match when={selected() === "inbox"}><span>Inbox</span></Match>
            <Match when={selected() === "cloud-agent" && cloudLaunchTitle()}>{(title) => <span>{title().replace(/\s+/g, " ").slice(0, 80)}</span>}</Match>
            <Match when={selected() === "cloud-agent"}><span>Cloud agent</span></Match>
            <Match when={currentProjectSettings()}>
              {(slug) => <span>{liveProjects().find((x) => x.slug === slug())?.title ?? slug()} · Settings</span>}
            </Match>
            <Match when={currentMissionSettingsId()}>
              {(mid) => <span>{resolveMissionTitle(mid()) ?? `Agent ${mid().slice(0, 8)}`} · Settings</span>}
            </Match>
            <Match when={currentMissionId()}>
              {(id) => {
                const activeM = () => (openMission()?.id === id() ? openMission() : missions().find((m) => m.id === id()));
                const canShareTitle = () =>
                  isConnected() &&
                  Boolean(activeM()) &&
                  !isMissionParticipant(activeM()) &&
                  !isClientPlacement(activeM());
                return (
                  <>
                    <Show when={sessionPreview().destination === "Paloma"}><ProviderLogo type="hermes" /></Show>
                    <SessionPreview
                      data={sessionPreview()}
                      plan={previewPlan()?.id === id() ? previewPlan()?.data : undefined}
                      goal={!!missionGoal(activeM())}
                      participant={isMissionParticipant(activeM())}
                      ownerUsername={activeM()?.owner_username}
                      onOpenSettings={isConnected() ? () => open(`ms:${id()}`) : undefined}
                      onShare={canShareTitle() ? () => setTitleShareMission(activeM()!) : undefined}
                    />
                  </>
                );
              }}
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
        {/* A mission view portals its Chapters navigation here, beside the title-bar icons. */}
        <div class="tb-tools" id="tb-tools" />
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
                        onMachine={() => {
                          setProviderSubmenu(undefined);
                          setAgentVmsOpen(sortedNodes().filter(isAgentSpawnedManagedNode).some(n => n.id === newMachine()));
                          warmManagedCatalog();
                          setEnvOpen("machine");
                        }} />
                    </Show>
                  </div>

                  <div class="na-drop" onPointerDown={(e) => e.stopPropagation()}>
                    <button
                      class="na-drop-btn"
                      onClick={() => {
                        if (envOpen() === "machine") {
                          setProviderSubmenu(undefined);
                          setEnvOpen(null);
                        } else {
                          setProviderSubmenu(undefined);
                          setAgentVmsOpen(sortedNodes().filter(isAgentSpawnedManagedNode).some(n => n.id === newMachine()));
                          warmManagedCatalog();
                          setEnvOpen("machine");
                        }
                      }}
                    >
                      <Show when={newMachine() !== "local"} fallback={<Ic.LaptopIcon size={14} />}>
                        <Show
                          when={newMachine() === "core"}
                          fallback={
                            <Show when={isAutoManagedTarget(newMachine())} fallback={<Ic.ComputeNodeIcon size={14} />}>
                              <Ic.CloudIcon size={14} />
                            </Show>
                          }
                        >
                          <Ic.CoreServerIcon size={14} />
                        </Show>
                      </Show>
                      {machineLabel()}
                      <Ic.ChevronDown size={12} />
                    </button>
                    <Show when={envOpen() === "machine"}>
                      <Menu
                        class="na-menu machine-menu"
                        label="Choose machine"
                        width={340}
                        onClose={() => {
                          setProviderSubmenu(undefined);
                          setEnvOpen(null);
                        }}
                      >
                        <div
                          class="na-menu-list"
                          onMouseOver={(e) => {
                            if (!providerSubmenu()) return;
                            const t = e.target instanceof Element ? e.target : null;
                            if (t && !t.closest(".machine-submenu") && !t.closest(".machine-provider-trigger") && t.closest(".menu-item")) {
                              setProviderSubmenu(undefined);
                            }
                          }}
                        >
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
                              <For each={MACHINES.filter((m) => m.id !== "local" && (isAdminUser() || (!isAdminOnlyNode(m) && m.id !== "core")))}>
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
                          <Show when={isAdminUser()}>
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
                          </Show>
                          <Show when={sortedNodes().some(n => !isManagedNode(n))}>
                            <div class="menu-sep" />
                            <div class="machine-section-label machine-nodes-label">Compute nodes</div>
                            <For each={sortedNodes().filter(n => !isManagedNode(n))}>
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
                                    <span class="menu-title" title={n.display_name ? n.id : undefined}>{isAdministrationNode(n) ? "DGX Spark · Admin" : n.display_name || n.id}</span>
                                  </span>
                                  <MachineLoadBadge machine={n.id} />
                                  <span class="machine-node-state"><span class={`machine-state-dot ${n.status === "online" && (!n.cordoned || isAdministrationNode(n)) ? "online" : ""}`} />{isAdministrationNode(n) && n.status === "online" ? "Manual" : n.cordoned ? "Cordoned" : n.status}</span>
                                </button>
                              )}
                            </For>
                          </Show>
                          <NewAgentCloudVmSection
                            selectedTarget={newMachine()}
                            activeSubmenu={providerSubmenu()}
                            confirmed24hTarget={confirmed24hTarget()}
                            onSubmenuChange={setProviderSubmenu}
                            onPickTarget={(target) => {
                              setEnvOpen(null);
                              chooseMachine(target);
                            }}
                            onRequire24hConfirm={(prompt) => {
                              setEnvOpen(null);
                              setPending24hPick(prompt);
                            }}
                          />
                          <Show when={sortedNodes().some(isUserManagedNode)}>
                            <div class="menu-sep" />
                            <div class="machine-section-label machine-managed-label">Your VMs</div>
                            <For each={sortedNodes().filter(isUserManagedNode)}>
                              {(n) => (
                                <button
                                  class={`menu-item machine-node-option ${n.id === newMachine() ? "on" : ""}`}
                                      aria-pressed={n.id === newMachine()}
                                  title={nodeLaunchNote()}
                                  onClick={() => {
                                    chooseMachine(n.id);
                                    setEnvOpen(null);
                                  }}
                                >
                                  <span class="menu-ico">
                                    <Ic.ComputeNodeIcon />
                                  </span>
                                  <span class="menu-col">
                                    <span class="menu-title" title={n.display_name ? n.id : undefined}>{n.display_name || n.id}</span><Show when={nodeSize(n)}><span class="machine-inline-note">{nodeSize(n)}</span></Show>
                                  </span>
                                  <MachineLoadBadge machine={n.id} />
                                  <span class="machine-node-state"><span class={`machine-state-dot ${n.status === "online" && !n.cordoned ? "online" : ""}`} />{n.cordoned ? "Cordoned" : n.status}</span>
                                </button>
                              )}
                            </For>
                          </Show>
                          <Show when={sortedNodes().some(isAgentSpawnedManagedNode)}>
                            <div class="menu-sep" />
                            <AgentSpawnedVmsToggle
                              count={sortedNodes().filter(isAgentSpawnedManagedNode).length}
                              expanded={agentVmsOpen()}
                              hasSelected={sortedNodes().filter(isAgentSpawnedManagedNode).some(n => n.id === newMachine())}
                              onToggle={() => setAgentVmsOpen(v => !v)}
                            />
                            <Show when={agentVmsOpen()}>
                              <For each={sortedNodes().filter(isAgentSpawnedManagedNode)}>
                                {(n) => (
                                  <button
                                    class={`menu-item machine-node-option machine-agent-vm-row ${n.id === newMachine() ? "on" : ""}`}
                                        aria-pressed={n.id === newMachine()}
                                    title={nodeLaunchNote()}
                                    onClick={() => {
                                      chooseMachine(n.id);
                                      setEnvOpen(null);
                                    }}
                                  >
                                    <span class="menu-ico">
                                      <Ic.ComputeNodeIcon />
                                    </span>
                                    <span class="menu-col">
                                      <span class="menu-title" title={n.display_name ? n.id : undefined}>{n.display_name || n.id}</span><Show when={nodeSize(n)}><span class="machine-inline-note">{nodeSize(n)}</span></Show>
                                    </span>
                                    <MachineLoadBadge machine={n.id} />
                                    <span class="machine-node-state"><span class={`machine-state-dot ${n.status === "online" && !n.cordoned ? "online" : ""}`} />{n.cordoned ? "Cordoned" : n.status}</span>
                                  </button>
                                )}
                              </For>
                            </Show>
                          </Show>
                        </Show>
                        </div>
                        <div class="na-menu-foot" onMouseEnter={() => setProviderSubmenu(undefined)}>
                          <div class="menu-sep" />
                          <button
                            class="menu-item"
                            onClick={() => {
                              setProviderSubmenu(undefined);
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
                    <Show when={pending24hPick()}>
                      {(pick) => (
                        <Lazy24hConfirmDialog
                          prompt={pick()}
                          onConfirm={() => {
                            const target = pick().target;
                            setConfirmed24hTarget(target);
                            chooseMachine(target);
                            setPending24hPick(null);
                          }}
                          onClose={() => setPending24hPick(null)}
                        />
                      )}
                    </Show>
                  </div><WorkingDirectoryPicker machine={newMachine()} machineName={machineLabel()} missions={missions()} value={workingDirectory()} disabled={creating()} onChange={chooseDirectory}/>
                  <Show when={showAskPaloma()}>
                    <button
                      type="button"
                      class="na-drop-btn"
                      aria-label="Ask Paloma"
                      title="Switch to Paloma for instant memory and fleet answers"
                      onClick={() => {
                        writeString("orb.cloud.provider", "hermes");
                        open("cloud-agent");
                      }}
                    >
                      <ProviderLogo type="hermes" />
                      <span>Ask Paloma</span>
                    </button>
                  </Show>
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
                  localCwd={newMachine() === "local" ? workingDirectory() : undefined}
                  onAttachments={setAttachChips}
                />
                <Show when={newMachine() === "local" && localAgentsScanning()}><div class="local-scan-status" role="status"><Ic.Spinner size={12} /> Checking local agents…</div></Show>
                <ErrorToast error={createError()} title="Couldn’t start the mission" onDismiss={() => setCreateError(null)}
                  action={/GiB required.*GiB is free/.test(createError() ?? "") ? { label: "Choose machine", run: () => { setCreateError(null); setEnvOpen("machine"); } }
                    : createRefusal()?.project ? { label: "Open project settings", run: () => { const project = createRefusal()!.project; setCreateError(null); open(`ps:${project}`); } } : undefined} />
                </div>
              </div>
            </div>
        </div></Show>
        <For each={keepAlivePool.slots()}>{slot => {
          const isActive = createMemo(() => {
            const mid = currentMissionId();
            if (mid) return slot.missionId() === mid;
            const pendingKey = pendingLaunchSlotKey();
            return Boolean(pendingKey && slot.slotKey === pendingKey);
          });
          return (
            <div class="mission-slot" data-slot-key={slot.slotKey} hidden={!isActive()}>
              <SlotActiveContext.Provider value={isActive}>
                <Show
                  when={slot.kind === "launch"}
                  fallback={
                    <MissionLookupContext.Provider value={id => findKnownMission(id)}>
                      <MissionView
                        id={slot.missionId()}
                        active={isActive()}
                        initial={findKnownMission(slot.missionId())}
                        onMission={syncOpenMission}
                        onPlan={(id, data) => setPreviewPlan({ id, data })}
                        onContext={(id, pct) => setPreviewContext({ id, pct })}
                        onFork={m => {
                          const active = isActive();
                          if (!active && slot.missionId() && m.id !== slot.missionId()) {
                            keepAlivePool.evictMission(slot.missionId());
                          }
                          commitFork(m, active);
                        }}
                      />
                    </MissionLookupContext.Provider>
                  }
                >
                  <NativeMissionView
                    id={slot.missionId()}
                    active={isActive()}
                    initial={findKnownMission(slot.missionId())}
                    launch={slot.missionId() ? undefined : (launchPreview() ?? undefined)}
                    launchError={slot.missionId() ? undefined : (createError() ?? undefined)}
                    onRetryLaunch={() => retryLaunch?.()}
                    onMission={syncOpenMission}
                    onContext={(id, pct) => setPreviewContext({ id, pct })}
                    onPlan={(id, data) => setPreviewPlan({ id, data })}
                    onFork={m => {
                      const active = isActive();
                      if (!active && slot.missionId() && m.id !== slot.missionId()) {
                        keepAlivePool.evictMission(slot.missionId());
                      }
                      commitFork(m, active);
                    }}
                  />
                </Show>
              </SlotActiveContext.Provider>
            </div>
          );
        }}</For>
        <Switch>
            <Match when={selected() === "inbox"}>
              <Suspense>
                <InboxPage
                  onFocusContent={() => { if (window.matchMedia("(max-width: 720px)").matches) setSidebar(false); }}
                  onDeleteMission={setDeleteMissionRequest}
                  missions={inboxMissions()}
                  projects={liveProjects()}
                  loading={missionsLoading()}
                  onOpenMission={(id) => { usageTelemetry.action("inbox_open", "inbox"); open(`m:${id}`); }}
                  onOpenSettings={openSettings}
                  onOpenInboxSettings={() => open("inbox-summaries")}
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
              </Suspense>
            </Match>
            <Match when={selected() === "cloud-agent"}>
            <Suspense>
              <CloudAgentPage project={effectiveNewProject() ?? ""} path={newFolder()?.project === effectiveNewProject() ? newFolder()?.path : undefined}
                projects={projectChoices(liveProjects())} onProject={id => { setNewProject(id); setNewFolder(null); }}
                onCreateProject={isConnected() ? () => { setProjectCreationAnchor(undefined); setNewProjectDraft(true); } : undefined}
                onPending={seed => setCloudLaunchTitle(seed?.prompt.trim() || null)}
                onCreated={m => { setCloudLaunchTitle(null); setMissions(ms => [m, ...ms.filter(x => x.id !== m.id)]); bumpProjects(); open(`m:${m.id}`); }} />
            </Suspense>
          </Match>
          <Match when={skillPageName(selected())}>
            {(sk) => <Show when={sk().name} keyed>{(name) => <SkillPage name={name} initialView={sk().history ? "history" : "edit"} onBack={() => open("skills-settings")} onOpenPage={open} />}</Show>}
          </Match>
          <Match when={settingsSectionFor(selected())}>
            <Suspense>
              <SettingsShell page={selected()!} onOpen={open}>
                <Switch>
                  <Match when={selected() === "settings"}><Settings onOpenPage={open} /></Match>
                  <Match when={selected() === "users-settings"}>{isAdminUser() ? <UsersSettings /> : <Settings onOpenPage={open} />}</Match>
                  <Match when={selected() === "usage-telemetry"}><UsageTelemetrySettings /></Match>
                  <Match when={selected() === "routing" || selected() === "routing-providers" || selected() === "routing-keys"}>
                    <RoutingSettings onOpenClient={() => open("settings")} tab={selected() === "routing-providers" ? "health" : selected() === "routing-keys" ? "keys" : "chains"} />
                  </Match>
                  <Match when={selected() === "usage-settings"}><UsageSettings /></Match>
                  <Match when={selected() === "skills-settings"}><SkillsSettings onOpenPage={open} /></Match>
                  <Match when={selected() === "hermes-settings"}><HermesSettings /></Match>
                  <Match when={selected() === "btw-settings"}><BtwSettings/></Match>
                  <Match when={selected() === "inbox-summaries"}><InboxSummariesSettings /></Match>
                  <Match when={selected() === "local-agents"}><LocalAgentsSettings /></Match>
                  <Match when={selected() === "security-settings"}>{isAdminUser() ? <SecuritySettings /> : <Settings onOpenPage={open} />}</Match>
                  <Match when={selected() === "bitwarden-settings"}>{isAdminUser() ? <BitwardenSettings /> : <Settings onOpenPage={open} />}</Match>
                  <Match when={selected() === "inbox-settings"}><InboxSettings onOpenPage={open} /></Match>
                </Switch>
              </SettingsShell>
            </Suspense>
          </Match>
          <Match when={selected() === "machines"}>
            <Suspense>
              <Machines />
            </Suspense>
          </Match>
          <Match when={selected() === "providers"}>
            <Suspense fallback={<ProvidersPageSkeleton />}>
              <Providers />
            </Suspense>
          </Match>
          <Match when={selected() === "resources" || Boolean(currentResourcesMissionId())}>
            <Suspense>
              <Resources missionId={currentResourcesMissionId()} onOpen={open} />
            </Suspense>
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
          <Match when={currentMissionSettingsId()}>
            {(mid) => (
              <Suspense>
                <Show when={mid()} keyed>
                  {(id) => (
                    <MissionSettings
                      missionId={id}
                      title={resolveMissionTitle(id) ?? `Agent ${id.slice(0, 8)}`}
                      titleOf={resolveMissionTitle}
                      onOpen={open}
                      readOnly={isMissionParticipant(
                        missions().find((m) => m.id === id) ?? (openMission()?.id === id ? openMission() : null),
                      )}
                    />
                  )}
                </Show>
              </Suspense>
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
      <Show when={titleShareMission()}>
        {m => (
          <Suspense>
            <ShareMissionDialog mission={m()} onClose={() => setTitleShareMission(null)} />
          </Suspense>
        )}
      </Show>
      <Show when={searchOpen()}>
        <Suspense
          fallback={
            <Portal>
              <div
                style={{
                  position: "fixed",
                  inset: 0,
                  display: "flex",
                  "align-items": "flex-start",
                  "justify-content": "center",
                  padding: "clamp(28px, 8vh, 76px) 16px 24px",
                  "box-sizing": "border-box",
                  background: "color-mix(in srgb, var(--overlay) 78%, transparent)",
                  "z-index": 1300,
                }}
                onPointerDown={e => {
                  if (e.target === e.currentTarget) {
                    setSearchOpen(false);
                    searchReturnFocus()?.focus({ preventScroll: true });
                  }
                }}
              >
                <div
                  role="dialog"
                  aria-modal="true"
                  aria-label="Search conversations"
                  data-testid="conversation-search-dialog"
                  onKeyDown={e => {
                    if (!e.isComposing && e.key === "Escape") {
                      e.preventDefault();
                      e.stopPropagation();
                      setSearchOpen(false);
                      searchReturnFocus()?.focus({ preventScroll: true });
                    }
                  }}
                  style={{
                    width: "min(880px, calc(100vw - 32px))",
                    height: "min(580px, calc(100dvh - 64px))",
                    background: "var(--bg-elev)",
                    border: "1px solid var(--stroke)",
                    "border-radius": "var(--radius-xl)",
                    "box-shadow": "var(--shadow-dlg)",
                    padding: "12px 14px",
                    "box-sizing": "border-box",
                  }}
                >
                  <input
                    ref={el => {
                      searchInputEl = el;
                      queueMicrotask(() => el.focus({ preventScroll: true }));
                    }}
                    type="text"
                    autocapitalize="off"
                    autocorrect="off"
                    spellcheck={false}
                    aria-label="Search conversations and messages"
                    value={searchQuery()}
                    onInput={e => setSearchQuery(e.currentTarget.value)}
                    placeholder="Search conversations, code, identifiers, and messages…"
                    style={{
                      width: "100%",
                      border: "none",
                      background: "transparent",
                      color: "var(--fg-strong)",
                      "font-size": "16px",
                      outline: "none",
                    }}
                  />
                </div>
              </div>
            </Portal>
          }
        >
          <SearchDialog
            query={searchQuery()}
            onQueryChange={setSearchQuery}
            projects={liveProjects()}
            recentMissions={inboxMissions()}
            returnFocus={searchReturnFocus()}
            onInputRef={el => {
              searchInputEl = el;
            }}
            onClose={() => setSearchOpen(false)}
            onOpenMission={missionId => {
              setSearchOpen(false);
              open(`m:${missionId}`);
            }}
            onOpenHit={(hit, query) => {
              requestSearchTarget({
                missionId: hit.mission_id,
                locator: hit.locator,
                role: hit.role,
                sequence: hit.sequence,
                eventId: hit.event_id,
                query,
              });
              setSearchOpen(false);
              open(`m:${hit.mission_id}`);
            }}
          />
        </Suspense>
      </Show>

      </FilePanelProvider>
      </MentionProjectContext.Provider>
    </div>
  );
}
