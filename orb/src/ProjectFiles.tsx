import { deleteFileOptimistically, fileMoveKey, filesMovedAway, filesMovedInto, isFilePathPending, mergeArrivingMissions, missionMoveKey, previewMove, movedMission, missionsMovedInto, moveOptimistically, movingOutOf, pendingMoves as pendingPlaceMoves, settleMove, upsertMissionPreservingOrder, waitForFilePathSettled, withMovedMissions } from "./moves";
import { renameOptimistically } from "./renames";
import { isArchivable, isReopenable, isRunning, isLive, isWorking, missionActivity, presentedStatus } from "./missionStatus";
import { localRunActive } from "./localAgents";
import { swallow } from "./log";
import { useTooltip } from "./Tooltip";
import { ErrorToast } from "./toast";
import {nativeComposerDrop} from "./composerDrop";
import {importProjectFiles} from "./projectFileImport";
import {backgroundUploads,cancelBackgroundUpload,formatFileSize,pauseBackgroundUpload,resumeBackgroundUpload,type UploadSource} from "./uploads";
import {subscribeProjectContext} from "./projectContext";
import { assertFolderHasNoWork, didServerCascadeFolderTransfer, folderWorkError, moveFolderWork, makeFileReference, readFileReference, makeCronReference, readCronReference, makeItemsReference, readItemsReference, type ClipboardItem, fileDestination, fileParent, fileName as fileBaseName, transferProjectFile } from "./fileActions";
import { FolderActivityIcon, folderActivity } from "./FolderActivity";
import { createSidebarRequests } from "./sidebarRequests";
import { folderLabel, setFolderLabel } from "./folderLabels";
import { projectColor } from "./projectAppearance";
import { ProviderLogo } from "./ProviderLogo";
import { ContextBadge } from "./ContextBadge";
const ContextHistory = lazy(() => import("./ContextHistory").then(module => ({ default: module.ContextHistory })));
import { readProjectFileVersion } from "./projectContext";
import { makeCutMission, moveMissions, planMissionMoves, readCutMission } from "./missionMove";
import { RunningWorkers, deleteDescendants, descendantsSentence, pausedMissionIds, requiresDescendantOptIn, runningWorkerIds } from "./deleteRunning";
const ForkMission = lazy(() => import("./ForkMission").then(module => ({ default: module.ForkMission })));
import { For, Show, Suspense, createMemo, createSelector, createSignal, onCleanup, onMount, createEffect, on, batch, lazy } from "solid-js";
import { mergeById, pollWhileVisible } from "./poll";
import { createStore, reconcile } from "solid-js/store";
import * as Ic from "./icons";
import * as SidebarIcon from "./sidebarIcons";
import { pendingMissionInteraction } from "./missionAttention";
import { MissionGlyph, missionStatusPresentation } from "./MissionGlyph";
import { isMissionUnread } from "./missionUnread";
import { MdSource, MdView, mdSource, setMdSource } from "./Markdown";
import { missionDestination } from "./missionLaunch";
import {
  api,
  currentUser,
  getApiUrl,
  isClientPlacement,
  isConnected,
  isMissionParticipant,
  ApiError,
  cancelMission,
  connectionVersion,
  listProjectFiles,
  listProjectMissions,
  listProjects,
  peekCachedProjects,
  updateProject,
  renameMission,
  archiveMission,
  reopenMission,
  archiveProject,
  bumpProjects,
  createProjectCron,
  deleteProjectController,
  deleteProjectCron,
  updateProjectCron,
  listProjectCrons,
  getProjectCronDefaults,
  mkdirProjectFile,
  deleteProjectFile,
  readProjectFile,
  writeProjectFile,
  type Mission,
  type HarnessChoice,
  type ProjectFileEntry,
  type ProjectSummary,
  projectsVersion,
  getProjectController,
  controllerAction,
  ApprovalTransferConfirmationRequiredError,
  type ApprovalTransferPolicy,
  type ControllerView as ControllerData,
} from "./api";
import { CronGlyph, untilLabel } from "./cronGlyph";
import { ConfirmDialog, Dialog, DialogButton, NameDialog } from "./Dialog";
import { PopupMenu, type MenuEntry } from "./Menu";
import { Picker, type PickerItem } from "./Picker";
import { Portal } from "solid-js/web";
import { createSidebarRowDrag, isGroupMoveAdmitted, type DragSourceItem } from "./tree/rowDrag";
import {
  copyText,
  isClipboardReferenceRetired,
  isUnsyncedClipboard,
  retireActiveClipboardReference,
  retireClipboardReference,
  writeClipboardReference,
} from "./clipboard";
const CronForm = lazy(() => import("./ControllerSettings").then(module => ({ default: module.CronForm })));
import { getProjectCronFromJob } from "./cronSchema";
import { loadTranscript, prefetchTranscript, selectLivePrefetchIds } from "./missionCache";
import { cacheCanPrefetch, cachePeek, cachePrefetch, cachePut, cacheRemember } from "./pageCache";
import { currentLinkBudget, onLinkBudgetChange } from "./networkHealth";
import { SidebarTree } from "./Tree";
import { type TreeRow } from "./treeModel";
const ShareMissionDialog = lazy(() => import("./ShareMissionDialog").then(module => ({ default: module.ShareMissionDialog })));
import { deletingIds, setDeletingIds, createTreeSelection } from "./tree/selection";
import { createArchivePager } from "./tree/archivePager";
import { createMissionMoves, type ApprovalConfirmationPrompt } from "./tree/moves";
const ApprovalTransferDialog = lazy(() => import("./ApprovalTransferDialog"));
import { createProjectTree, missionFolder, missionIdFromTreeId, type Node, type RowData } from "./tree/TreeView";
import { MachineBadge, missionMachine, missionCopyId, rowDetail, ROW_TIP_ID, launchedToggle as launchedToggleView, type RowTipContent } from "./tree/missionRow";
import { FileSkeleton } from "./Skeleton";
import { excludeBtwMissions, isBtwMission, isPartialList, mergeMission, type Misses, type PlacementCommitItem, reconcileMissionList, resolvedParents, withHierarchy } from "./missionHierarchy";
import { forkLeaders, missionParent, missionSubtree, missionTreeRows, archiveOnlyRows, isSupersededInTree, ARCHIVE_DAY_MS, ARCHIVE_WEEK_MS, filterArchivedMissionsByAge, expandMissionDescendants } from "./missionTree";

export { isMissionDeleting } from "./tree/selection";
export { missionMachine, rowDetail, missionCopyId, type RowTipContent } from "./tree/missionRow";

/** Default extension for a new reference file: these are Markdown notes. */
export const REFERENCE_FILE_EXT = ".md";

/**
 * Validate a new file name typed into the sidebar and return the path relative
 * to `dir`. Traversal, absolute paths and Windows separators are refused here
 * as well as by the core's `safe_join`, so the user sees why instead of a 400.
 * A name with no extension gets `.md`, matching the Markdown view/editor these
 * reference files are read in.
 */
export function newFilePath(dir: string, raw: string): { path: string; name: string } | { error: string } {
  const name = raw.trim();
  if (!name) return { error: "Enter a file name." };
  if (name.includes("\\")) return { error: "Use forward slashes, not backslashes." };
  if (name.startsWith("/")) return { error: "Use a path relative to this folder." };
  const parts = name.split("/");
  if (parts.some((part) => part.trim() === "")) return { error: "Remove the empty path segment." };
  if (parts.some((part) => part.trim() === "." || part.trim() === "..")) {
    return { error: "Paths cannot contain '.' or '..' segments." };
  }
  const cleaned = parts.map((part) => part.trim());
  const last = cleaned[cleaned.length - 1];
  // A dotfile ("`.gitignore`") is already named; only an extensionless name
  // gets the Markdown default.
  cleaned[cleaned.length - 1] = last.includes(".") ? last : `${last}${REFERENCE_FILE_EXT}`;
  return { path: dir ? `${dir}/${cleaned.join("/")}` : cleaned.join("/"), name: cleaned[cleaned.length - 1] };
}




export function LiveProjectsSection(p: {
  /** Reuse the same confirmation and deletion pipeline from other views. */
  deleteRequest?: string | null;
  onDeleteRequestHandled?: () => void;
  activityMissions?: Mission[];
  /** Details from the open conversation, including restored/local sessions. */
  currentMission?: Mission;
  harnessChoices: HarnessChoice[];
  forkChoices?: (mission: Mission) => HarnessChoice[];
  onForkOpen?: (mission: Mission) => void;
  onFork: (mission: Mission) => void;
  selected: () => string | null;
  open: (id: string | null) => void;
  /** "+" on a project row: start a new agent in that project. */
  onNewAgent: (slug: string, path?: string) => void;
  onNewCloudAgent?: (slug: string, path?: string) => void;
  onDeleted?: (ids: string[]) => void;
  onProjectMissions?: (slug: string, rows: Mission[]) => void;
  /** "+" on the section header: create a project (opens the picker flow). */
  onNewProject: (anchor: HTMLButtonElement) => void;
  /** False while Settings hides the main sidebar so background sweeps pause without unmounting state. */
  active?: () => boolean;
}) {
  const isSidebarActive = () => (p.active ? p.active() : true);
  const rowEffectiveStatus = (m: Mission) =>
    presentedStatus(m, missionActivity(m, [], { localRun: localRunActive(m.id) }));
  const initialCachedProjects = isConnected() ? peekCachedProjects() : null;
  const [projects, setProjects] = createSignal<ProjectSummary[]>(initialCachedProjects ?? []);
  const [projectsLoading, setProjectsLoading] = createSignal<boolean>(isConnected() && initialCachedProjects === null);
  const [error, setError] = createSignal<string | null>(null);
  const [expanded, setExpanded] = createStore<Record<string, boolean>>({});
  const [archiveMenu, setArchiveMenu] = createSignal<{ x: number; y: number; slug?: string } | null>(null);
  const [shareDialogMission, setShareDialogMission] = createSignal<Mission | null>(null);
  const isArchived = (mission: Mission) => mission.status === "acknowledged";
  const LIVE = new Set(["active", "pending", "queued", "awaiting_user", "resuming", "running", "starting", "blocked", "paused", "waiting_background"]);
  const sharedWithMeMissions = createMemo(() =>
    (p.activityMissions ?? []).filter(
      m =>
        isMissionParticipant(m) &&
        !isArchived(m) &&
        !deletingIds().has(m.id) &&
        !m.parent_mission_id &&
        !m.tags?.some(t => t.startsWith("btw:")),
    ),
  );
  const isSelectedRow = createSelector(() => p.selected());
  const isSelectedMissionId = createSelector(() => {
    const sel = p.selected();
    return sel?.startsWith("m:") ? sel.slice(2) : sel?.startsWith("ms:") ? sel.slice(3) : null;
  });
  const visibleMissions = (slug: string) => {
    // Pending moves: rows leave their old project and appear in the new one at once.
    // The per-project fetch pages history and walks parents. Until it lands,
    // the conversations already on the activity list are the list.
    const stored = missions[slug] ?? (p.activityMissions ?? []).filter(m => !isMissionParticipant(m) && (m.project ?? "") === slug);
    const own = stored.filter(m => !isMissionParticipant(m) && !movingOutOf(m.id, slug) && (!m.project || m.project === slug));
    const arriving = pendingPlaceMoves().size ? missionsMovedInto(slug, [...Object.values(missions).flat(), ...(p.activityMissions ?? [])]).filter(m => !isMissionParticipant(m) && !own.some(o => o.id === m.id)) : [];
    const rows = withMovedMissions(mergeArrivingMissions(own, arriving)).map(withHierarchy);
    const current = isOpenLiveProject(slug) ? currentMission() : undefined;
    // A paginated project list may not contain an older open conversation, and
    // the open conversation's live status updates ahead of the project poll.
    const withCurrent = current
      ? (rows.some(m => m.id === current.id)
        ? rows.map(m => m.id === current.id ? { ...mergeMission(m, current, "partial"), status: archiving.get(m.id) ?? current.status } : m)
        : [withHierarchy(current), ...rows])
      : rows;
    const shown = new Set(withCurrent.map(r => r.id));
    const listedIds = new Set(Object.values(missions).flat().map(m => m.id));
    const extraArchived = withMovedMissions(archivedMissions()).filter(m => (m.project ?? "") === slug && !shown.has(m.id) && !listedIds.has(m.id));
    // Parents the resolver fetched by id (paged out of this project's list) are listed as context.
    for (const m of [...withCurrent, ...extraArchived]) shown.add(m.id);
    const fetchedParents = withMovedMissions(resolvedParents<Mission>()).filter(m => (m.project ?? "") === slug && !shown.has(m.id) && !listedIds.has(m.id));
    const allRows = excludeBtwMissions([...withCurrent, ...extraArchived, ...fetchedParents]);
    const byId = new Map(allRows.map(m => [m.id, m]));
    return missionTreeRows(allRows, m => !isArchived(m) && (!isSupersededInTree(m, byId) || isSelectedMissionId(m.id)));
  };
  const allKnownMissions = (): Mission[] => {
    const byId = new Map<string, Mission>();
    for (const m of p.activityMissions ?? []) byId.set(m.id, m);
    for (const m of archivedMissions()) byId.set(m.id, m);
    for (const m of resolvedParents<Mission>()) byId.set(m.id, m);
    for (const m of Object.values(missions).flat()) byId.set(m.id, m);
    const current = currentMission();
    if (current && !byId.has(current.id)) byId.set(current.id, current);
    return [...byId.values()];
  };
  // Missions per project slug; file listings per `${slug}:${dirPath}`.
  const [missions, setMissions] = createStore<Record<string, Mission[]>>({});
  const [dirErrors, setDirErrors] = createStore<Record<string, string | null>>({});
  const [dirs, setDirs] = createStore<Record<string, ProjectFileEntry[]>>({});
  // The project's controller (Hermes cron), shown as the folder's first row.
  const [controllers, setControllers] = createStore<Record<string, ControllerData>>({});
  const [cronErrors, setCronErrors] = createStore<Record<string, string | null>>({});
  const [cronRetryable, setCronRetryable] = createStore<Record<string, boolean>>({});
  const [cronUnsupported, setCronUnsupported] = createSignal(false);
  const [cronInfo, setCronInfo] = createSignal<string | null>(null);
  const [cronChecking, setCronChecking] = createSignal(false);
  const [cronDefaults, setCronDefaults] = createSignal<import("./api").ProjectCronDefaults | null>(null);
  const [defaultsError, setDefaultsError] = createSignal<string | null>(null);
  const [crons, setCrons] = createStore<Record<string, import("./api").ControllerJob[]>>({});
  const [controllerMenu, setControllerMenu] = createSignal<{x:number;y:number;slug:string;id?:string;name:string;folder?:string;controller:boolean;archived:boolean} | null>(null);
  const [deleteCronTarget, setDeleteCronTarget] = createSignal<{slug:string;id?:string;name:string;controller:boolean;items?:Array<{slug:string;id:string;name:string}>} | null>(null);
  const [deletingCron, setDeletingCron] = createSignal(false);
  const [deleteCronError, setDeleteCronError] = createSignal<string | null>(null);
  const [movingCron, setMovingCron] = createSignal(false);
  const [cutCron, setCutCron] = createSignal<{slug:string;id:string;name:string} | null>(null);
  const [actionMenu, setActionMenu] = createSignal<{ x: number; y: number; slug: string; path: string } | null>(null);
  const [newFolder, setNewFolder] = createSignal<{ slug: string; path: string } | null>(null);
  const [folderName, setFolderName] = createSignal("");
  const [folderError, setFolderError] = createSignal<string | null>(null);
  const [makingFolder, setMakingFolder] = createSignal(false);
  const [newFile, setNewFile] = createSignal<{ slug: string; path: string } | null>(null);
  const [fileName, setFileName] = createSignal("");
  const [fileError, setFileError] = createSignal<string | null>(null);
  const [makingFile, setMakingFile] = createSignal(false);
  /** The context menu targets the selected group without opening its conversation. */
  const [missionMenu, setMissionMenu] = createSignal<{ x: number; y: number; mission: Mission; treeId: string; slug: string; folder: string } | null>(null);
  const [fileMenu, setFileMenu] = createSignal<{ slug: string; path: string; x: number; y: number } | null>(null);
  const [multiSelectMenu, setMultiSelectMenu] = createSignal<{ x: number; y: number; treeIds: string[] } | null>(null);
  const [movePicker, setMovePicker] = createSignal<{ sources: DragSourceItem[]; anchor: HTMLElement; treeId: string } | null>(null);
  const [deleteTargets, setDeleteTargets] = createSignal<string[]>([]);
  const [deleteConfirmBusy, setDeleteConfirmBusy] = createSignal(false);
  const [batchBusy, setBatchBusy] = createSignal(false);
  const deletedInSession = new Set<string>();
  /** Archived elsewhere (superseded by a replacement, or transferred): hidden at
   * once, and kept out of any list read that started before Core archived it. */
  const archivedInSession = new Set<string>();
  const deleteQueue: string[] = [];
  const queuedDeletes = new Set<string>();
  const deletingDescendants = new Map<string, string[]>();
  const deleteFailures: string[] = [];
  /** Deletes held back only by running workers: root id -> running worker ids. */
  const runningBlocks = new Map<string, string[]>();
  /** The user confirmed "Stop and delete" for these roots. */
  const stopApproved = new Set<string>();
  /** Roots whose delete the user confirmed with their descendants listed. */
  const descendantsConfirmed = new Set<string>();
  const deleteList = (ids: readonly string[]) => deleteDescendants(ids, allKnownMissions());
  const [stopPrompt, setStopPrompt] = createSignal<{ roots: string[]; workers: number } | null>(null);
  const [approvalTransferPrompt, setApprovalTransferPrompt] = createSignal<ApprovalConfirmationPrompt | null>(null);
  const listMisses = new Map<string, Misses>();
  let activeDeleteWorkers = 0;
  let pendingRemoved = new Set<string>();
  let pendingUnmark = new Set<string>();
  let flushTimer: ReturnType<typeof setTimeout> | undefined;
  let missionRevision = 0;
  const archiving = new Map<string, string>();
  const { archivesOpen, setArchivesOpen, archiveExpanded, setArchiveExpanded, archivedMissions, setArchivedMissions, archivesLoading, archivesError, archivesMore, archivesLoaded, archivesRequest, loadArchives, removeArchived, reset: resetArchives } =
    createArchivePager({ revision: () => missionRevision, archiving, deleted: deletedInSession, currentConnection: version => currentConnection(version) });
  const currentMission = createMemo(() => {
    const selected = p.selected();
    if (!selected?.startsWith("m:")) return undefined;
    const id = selected.slice(2);
    const listed = Object.values(missions).flat().find(m => m.id === id);
    const current = (p.currentMission?.id === id ? p.currentMission : undefined)
      ?? p.activityMissions?.find(m => m.id === id)
      ?? listed ?? archivedMissions().find(m => m.id === id);
    if (!current) return undefined;
    // Project listings own placement; the open detail owns live status/content.
    // Its older project/folder must not reinsert a conversation we just moved.
    return movedMission(listed ? {
      ...current,
      project: listed.project,
      folder: listed.folder,
      placement_revision: listed.placement_revision,
    } : current);
  });
  const isCurrentMissionId = createSelector(() => currentMission()?.id ?? null);
  const isCurrentProject = createSelector(() => currentMission()?.project ?? null);
  const isOpenLiveProject = createSelector(() => {
    const c = currentMission();
    return c && !isMissionParticipant(c) && !isArchived(c) && !isBtwMission(c) ? (c.project ?? "") : null;
  });
  const contextTreeId = () => {
    const mm = missionMenu();
    if (mm) return mm.treeId;
    const fm = fileMenu();
    if (fm) return `pf:${fm.slug}:${fm.path}`;
    const cm = controllerMenu();
    if (cm) return cm.controller ? `c:${cm.slug}` : cm.id ? `pc:${cm.slug}:${cm.id}` : null;
    const mp = movePicker();
    if (mp) return mp.treeId;
    return null;
  };
  const { setSelectedTreeIds, setSelectedAgents, selectionActive, setSelectionActive, selectedTreeSet, selectedRowIds, isRowActive, selectionAnchor, setSelectionAnchor, syncToCommitted, clickSelectableRow, contextSelectRow, selectedFor, selectedTreeFor } =
    createTreeSelection({ visibleNodes: () => [...tree(), ...(archivesOpen() ? archiveNodes() : [])], selected: () => p.selected(), contextTreeId });
  const { cutId, setCutId, pendingMoves, setPendingMoves, beginMove, moveDirect, pasteMission, isMoving, hasCutClipboard, hasUnsyncedCutClipboard } = createMissionMoves({
    allKnownMissions: () => allKnownMissions(),
    leaveProjects: (id, keep) => leaveProjects(id, keep),
    revealDestination: (slug, path) => { setExpanded(slug, true); if (path) setExpanded(`${slug}:${path}`, true); },
    loadMissions: slug => loadMissions(slug),
    setActionError: error => setActionError(error),
    onApprovalConfirmationRequired: prompt => setApprovalTransferPrompt(prompt),
  });
  const { tree, archiveNodes, controllerRow, controllerLaunched } = createProjectTree({
    projects, expanded, missions, dirs, dirErrors, crons, controllers, cronUnsupported, cronErrors, archiveExpanded,
    visibleMissions: slug => visibleMissions(slug), archivedMissionRows: () => archivedMissionRows(), selected: () => p.selected(),
  });
  setDeletingIds(new Set<string>());
  onCleanup(() => {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = undefined; }
  });
  const clickAgent = (e: MouseEvent, id: string, treeId = `m:${id}`) => clickSelectableRow(e, treeId, () => p.open(`m:${id}`));
  const removeRows = (ids: readonly string[]) => {
    const removed = new Set(ids);
    if (!removed.size) return;
    missionRevision++;
    for (const id of removed) deletedInSession.add(id);
    batch(() => {
      for (const slug of Object.keys(missions)) {
        if (missions[slug]?.some(m => removed.has(m.id))) {
          setMissions(slug, rows => rows.filter(m => !removed.has(m.id)));
        }
      }
      removeArchived(removed);
      setSelectedTreeIds(current => current.some(x => { const mid = missionIdFromTreeId(x); return !!mid && removed.has(mid); }) ? current.filter(x => { const mid = missionIdFromTreeId(x); return !mid || !removed.has(mid); }) : current);
    });
  };
  const removeRow = (id: string) => removeRows([id]);
  /** A moved mission leaves its old listings. Unlike `removeRows` it is not
   * remembered as deleted, so the destination still lists it. */
  const leaveProjects = (id: string, keep: string) => batch(() => {
    for (const slug of Object.keys(missions)) {
      if (slug !== keep) {
        listMisses.get(slug)?.delete(id);
        if (missions[slug]?.some(m => m.id === id)) setMissions(slug, rows => rows.filter(m => m.id !== id));
      }
    }
  });
  const forgetDeleted = (ids: string[]) => {
    const removed = new Set(ids);
    if (!removed.size) return;
    removeRows(ids);
    setDeleteTargets(current => current.some(id => removed.has(id)) ? current.filter(id => !removed.has(id)) : current);
    setPendingMoves(current => current.some(id => removed.has(id)) ? current.filter(id => !removed.has(id)) : current);
    if (cutId() && removed.has(cutId()!)) setCutId(null);
    { const anchor = selectionAnchor(), mid = anchor ? missionIdFromTreeId(anchor) : null; if (mid && removed.has(mid)) setSelectionAnchor(null); }
    if (p.onDeleted) p.onDeleted(ids);
    else if (ids.some(id => p.selected() === `m:${id}` || p.selected() === `ms:${id}`)) p.open(null);
  };
  const flushDeleteBatch = (version: number, final = false) => {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = undefined; }
    if (version !== connectionVersion()) return;
    const removed = pendingRemoved;
    const unmark = pendingUnmark;
    pendingRemoved = new Set();
    pendingUnmark = new Set();
    batch(() => {
      if (removed.size) forgetDeleted([...removed]);
      if (unmark.size) {
        setDeletingIds(prev => {
          const next = new Set(prev);
          for (const id of unmark) next.delete(id);
          return next;
        });
      }
      if (final) {
        for (const id of stopApproved) if (!runningBlocks.has(id)) stopApproved.delete(id);
        if (runningBlocks.size) {
          const roots = [...runningBlocks.keys()], workers = new Set([...runningBlocks.values()].flat()).size;
          runningBlocks.clear();
          setStopPrompt({ roots, workers });
        }
        if (deleteFailures.length) {
          const failures = deleteFailures.splice(0, deleteFailures.length);
          setActionError(`Couldn’t delete ${failures.length} agent(s). ${failures.join("; ")}`);
        }
        setDeleteConfirmBusy(false);
        if (!deleteFailures.length && !actionError() || stopPrompt()) setDeleteTargets([]);
        bumpProjects();
      }
    });
  };
  const scheduleDeleteFlush = (version: number) => {
    if (deleteQueue.length <= 8) flushDeleteBatch(version, false);
    else if (!flushTimer) flushTimer = setTimeout(() => flushDeleteBatch(version, false), 32);
  };
  const stopWorkers = async (ids: readonly string[]) => {
    await Promise.all(ids.map(wid => cancelMission(wid)));
  };
  const acknowledgeMissions = async (ids: readonly string[], version: number) => {
    await Promise.all(ids.map(pausedId => api(`/api/control/missions/${encodeURIComponent(pausedId)}/status`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "acknowledged" }),
    })));
    return version === connectionVersion();
  };
  /** DELETE `id`; with `stop`, a 409 naming a running worker cancels it and retries. */
  const deleteMissionStopping = async (id: string, stop: boolean, version: number) => {
    for (let attempt = 0; ; attempt++) {
      try {
        // Core refuses to delete descendants unless asked: only a delete whose
        // confirmation listed them opts in.
        const cascade = descendantsConfirmed.has(id) ? "?include_descendants=true" : "";
        return await api<{deleted_ids?: string[]}>(`/api/control/missions/${id}${cascade}`, {method: "DELETE"});
      } catch (error) {
        if (error instanceof ApiError && error.status === 409) {
          if (requiresDescendantOptIn(error.detail)) {
            descendantsConfirmed.add(id);
            throw error;
          }
          const paused = pausedMissionIds(error.detail);
          if (paused.length && attempt < 3) {
            if (!await acknowledgeMissions(paused, version)) return undefined;
            continue;
          }
          const blocking = runningWorkerIds(error.detail);
          if (blocking.length && attempt < 3) {
            if (!stop) throw new RunningWorkers(blocking);
            await stopWorkers(blocking);
            continue;
          }
        }
        throw error;
      }
    }
  };
  const confirmStopAndDelete = () => {
    const prompt = stopPrompt();
    if (!prompt) return;
    setStopPrompt(null);
    for (const id of prompt.roots) { stopApproved.add(id); if (deleteList([id]).length) descendantsConfirmed.add(id); }
    setDeleteTargets(prompt.roots);
    deleteSelected();
  };
  const runDeleteWorker = async (version: number) => {
    activeDeleteWorkers++;
    try {
      while (version === connectionVersion() && deleteQueue.length > 0) {
        const id = deleteQueue.shift()!;
        queuedDeletes.delete(id);
        const covered = deletingDescendants.get(id) ?? [id];
        deletingDescendants.delete(id);
        if (deletedInSession.has(id)) {
          for (const cid of covered) {
            pendingRemoved.add(cid);
            pendingUnmark.add(cid);
          }
          scheduleDeleteFlush(version);
          continue;
        }
        try {
          const known = allKnownMissions();
          const knownById = new Map(known.map(m => [m.id, m]));
          const subtree = missionSubtree(known, [id]);
          const mission = knownById.get(id);
          // Preserve live running agents. DELETE also checks the root and all
          // descendants against Core's authoritative execution ownership snapshot.
          const live = (status: string) => ["active", "waiting_background"].includes(status);
          if (mission && live(mission.status)) throw new Error("Stop or finish this agent before deleting it.");
          const runningChildren = subtree.filter(m => m.id !== id && live(m.status)).map(m => m.id);
          if (runningChildren.length && !stopApproved.has(id)) throw new RunningWorkers(runningChildren);
          if (runningChildren.length) await stopWorkers(runningChildren);
          if (version !== connectionVersion()) break;
          const pausedIds = [
            ...(mission?.status === "paused" ? [id] : []),
            ...subtree.filter(m => m.id !== id && m.status === "paused").map(m => m.id),
          ];
          if (pausedIds.length && !await acknowledgeMissions(pausedIds, version)) break;
          if (version !== connectionVersion()) break;
          let result: {deleted_ids?: string[]} | undefined;
          try {
            result = await deleteMissionStopping(id, stopApproved.has(id), version);
          } catch (error) {
            // If `id` was still running on the server despite a stale sidebar row,
            // match the root guard message instead of offering "Stop and delete" for `id` itself.
            if (error instanceof RunningWorkers && error.ids.length === 1 && error.ids[0] === id) {
              throw new Error("Stop or finish this agent before deleting it.");
            }
            throw error;
          }
          if (version !== connectionVersion()) break;
          const serverDeleted = new Set(result?.deleted_ids ?? []);
          await Promise.all(subtree.map(async m => {
            const extraId = m.id;
            if (extraId !== id && !serverDeleted.has(extraId)) {
              const child = knownById.get(extraId);
              if (child && !child.parent_mission_id && child.callback_parent_mission_id) {
                if (child.status === "paused") {
                  await api(`/api/control/missions/${encodeURIComponent(extraId)}/status`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ status: "acknowledged" }),
                  }).catch(swallow("projectFiles.acknowledgeChild", { mission: extraId }));
                }
                await api(`/api/control/missions/${extraId}`, {method: "DELETE"}).catch(swallow("projectFiles.deleteChild", { mission: extraId }));
              }
            }
          }));
          const removed = [...new Set([id, ...covered, ...serverDeleted, ...subtree.map(m => m.id)])];
          void import("./localOrigins").then(m => m.confirmDeletedLocalOrigins(removed));
          for (const rid of removed) {
            deletedInSession.add(rid);
            pendingRemoved.add(rid);
            pendingUnmark.add(rid);
          }
        } catch (error) {
          if (version !== connectionVersion()) break;
          // An already-removed mission is the desired result, including a race
          // between the GET and DELETE or a child removed with its parent.
          if (error instanceof ApiError && error.status === 404) {
            void import("./localOrigins").then(m => m.confirmDeletedLocalOrigins(covered));
            for (const rid of covered) {
              deletedInSession.add(rid);
              pendingRemoved.add(rid);
              pendingUnmark.add(rid);
            }
          } else if (error instanceof RunningWorkers) {
            // Not a failure: ask once whether to stop them (see stopPrompt).
            runningBlocks.set(id, error.ids);
            for (const cid of covered) {
              if (!queuedDeletes.has(cid)) pendingUnmark.add(cid);
            }
          } else {
            deleteFailures.push(`${id.slice(0, 8)}: ${String(error)}`);
            for (const cid of covered) {
              if (!queuedDeletes.has(cid)) pendingUnmark.add(cid);
            }
          }
        }
        scheduleDeleteFlush(version);
      }
    } finally {
      activeDeleteWorkers--;
      if (activeDeleteWorkers === 0 && version === connectionVersion()) {
        flushDeleteBatch(version, true);
      }
    }
  };
  const deleteSelected = () => {
    const version = connectionVersion();
    const currentlyDeleting = deletingIds();
    const targets = deleteTargets().filter(id => !currentlyDeleting.has(id) && !deletedInSession.has(id));
    if (deleteConfirmBusy()) return;
    if (!targets.length) {setDeleteTargets([]); return;}
    setDeleteConfirmBusy(true);
    setActionError(null);
    for (const id of targets) if (deleteList([id]).length) descendantsConfirmed.add(id);
    const allLoaded = allKnownMissions();
    for (const id of targets) {
      deletingDescendants.set(id, expandMissionDescendants([id], allLoaded));
    }
    const allDeleting = expandMissionDescendants(targets, allLoaded);
    const targetSet = new Set(allDeleting);
    batch(() => {
      setDeletingIds(prev => {
        const next = new Set(prev);
        for (const id of allDeleting) next.add(id);
        return next;
      });
      setSelectedAgents(ids => {
        const next = ids.filter(id => !targetSet.has(id));
        if (!next.length) setSelectionActive(false);
        return next;
      });
      { const anchor = selectionAnchor(), mid = anchor ? missionIdFromTreeId(anchor) : null; if (mid && targetSet.has(mid)) setSelectionAnchor(null); }
      setPendingMoves(current => current.some(id => targetSet.has(id)) ? current.filter(id => !targetSet.has(id)) : current);
      if (cutId() && targetSet.has(cutId()!)) setCutId(null);
      if (missionMenu() && targetSet.has(missionMenu()!.mission.id)) {
        setMissionMenu(null);
        setForkTarget(null);
      }
      if (forkTarget() && targetSet.has(forkTarget()!.mission.id)) setForkTarget(null);
      const currentRename = rename();
      if (currentRename && "missionId" in currentRename && targetSet.has(currentRename.missionId)) {
        setRename(null);
      }
      if (p.onDeleted) p.onDeleted(allDeleting);
      else if (allDeleting.some(id => p.selected() === `m:${id}` || p.selected() === `ms:${id}`)) p.open(null);
    });
    const freshTargets = targets.filter(id => !queuedDeletes.has(id) && !deletedInSession.has(id));
    for (const id of freshTargets) queuedDeletes.add(id);
    deleteQueue.unshift(...freshTargets);
    const desiredWorkers = deleteQueue.length + activeDeleteWorkers > 4 ? 6 : 1;
    while (activeDeleteWorkers < desiredWorkers && deleteQueue.length > 0) {
      void runDeleteWorker(version);
    }
  };
  const startMoveSelection = (id: string, clipboardData?: DataTransfer | null) => {
    setFileClipboard("");
    setCutCron(null);
    const ids = [...selectedFor(id)];
    if (!ids.length) return;
    if (ids.length === 1) { setPendingMoves([]); beginMove(id, clipboardData); }
    else {
      retireActiveClipboardReference();
      if (clipboardData) clipboardData.setData("text/plain", makeCutMission(ids[0]));
      setPendingMoves(ids); setCutId(ids[0]); setActionError(null);
    }
  };
  const [forkTarget, setForkTarget] = createSignal<{ anchor?: HTMLButtonElement; mission: Mission } | null>(null);
  const [makingCron, setMakingCron] = createSignal(false);
  const [cronWarning, setCronWarning] = createSignal<string | null>(null);
  const [cronFolder, setCronFolder] = createSignal("");
  const [newCron, setNewCron] = createSignal<string | null>(null);
  const [actionFocus, setActionFocus] = createSignal(true);
  const [fileAction, setFileAction] = createSignal<{ slug: string; path: string; kind: "rename" | "move" | "delete"; directory?: boolean } | null>(null);
  const [fileActionValue, setFileActionValue] = createSignal("");
  const [fileActionError, setFileActionError] = createSignal<string | null>(null);
  const [fileBusy, setFileBusy] = createSignal(false);
  const [fileClipboard, setFileClipboard] = createSignal("");
  let consumedFileClipboard = "";
  const cutFile = createMemo(() => { const item = readFileReference(fileClipboard()); return item && !item.copy ? item : null; });
  const cutItems = createMemo(() => { const bundle = readItemsReference(fileClipboard()); return bundle && !bundle.copy ? bundle.items : []; });
  const isItemCut = (treeId: string) => {
    for (const item of cutItems()) {
      if (item.kind === "file" && `pf:${item.slug}:${item.path}` === treeId) return true;
      if (item.kind === "cron" && `pc:${item.slug}:${item.id}` === treeId) return true;
      if (item.kind === "mission" && missionIdFromTreeId(treeId) === item.id) return true;
    }
    return false;
  };
  const beginFileAction = (slug: string, path: string, kind: "rename" | "move" | "delete", directory = false) => {
    setFileMenu(null); setActionMenu(null); setMultiSelectMenu(null);
    if (isFilePathPending(slug, path)) return;
    // A folder renamed on this device before paths could change keeps that name as the suggestion.
    setFileActionValue(kind === "rename" ? (directory ? folderLabel(slug, path) : fileBaseName(path)) : fileParent(path));
    setFileActionError(null);
    setFileAction({ slug, path, kind, directory });
  };
  const refreshFileParents = async (slug: string, path: string, destination?: string) => {
    await Promise.all([
      loadDir(slug, fileParent(path), true),
      ...(destination && fileParent(destination) !== fileParent(path) ? [loadDir(slug, fileParent(destination), true)] : []),
    ]);
  };
  const applyOptimisticFolderMove = (slug: string, path: string, destination: string, project = slug) => {
    batch(() => {
      const oldPrefix = `${slug}:${path}`, newPrefix = `${project}:${destination}`;
      for (const key of Object.keys(expanded)) {
        if (key === oldPrefix || key.startsWith(`${oldPrefix}/`)) {
          setExpanded(newPrefix + key.slice(oldPrefix.length), expanded[key]);
        }
      }
      for (const key of Object.keys(dirs)) {
        if (key === oldPrefix || key.startsWith(`${oldPrefix}/`)) {
          setDirs(newPrefix + key.slice(oldPrefix.length), reconcile([...dirs[key]]));
        }
      }
    });
  };
  const openMovedSelection = (slug: string, path: string, destination: string, directory: boolean, project = slug) => {
    const selected = p.selected(), prefix = `pf:${slug}:${path}`;
    if (selected === prefix || (directory && selected?.startsWith(`${prefix}/`))) {
      p.open(`pf:${project}:${destination}${selected.slice(prefix.length)}`);
    }
  };
  const folderMoved = async (slug: string, path: string, destination: string, project = slug, alreadyProjected = false, serverCascaded = false) => {
    setFolderLabel(slug, path, fileBaseName(path));
    if (!alreadyProjected) applyOptimisticFolderMove(slug, path, destination, project);
    openMovedSelection(slug, path, destination, true, project);
    try { if (!serverCascaded) await moveFolderWork(slug, path, destination, project); }
    finally {
      await Promise.all([
        loadMissions(slug),
        loadCrons(slug, true),
        ...(project !== slug ? [loadMissions(project), loadCrons(project, true)] : []),
      ]);
    }
  };
  const clearDeletedFileUi = (slug: string, path: string, directory: boolean) => {
    const treePrefix = `pf:${slug}:${path}`;
    const matchesTree = (id: string) => id === treePrefix || (directory && id.startsWith(`${treePrefix}/`));
    const matchesPath = (candidate: string) => candidate === path || (directory && candidate.startsWith(`${path}/`));
    batch(() => {
      const selected = p.selected();
      if (selected && matchesTree(selected)) p.open(null);
      setSelectedTreeIds(ids => {
        if (!ids.some(matchesTree)) return ids;
        const next = ids.filter(id => !matchesTree(id));
        if (!next.length) setSelectionActive(false);
        return next;
      });
      const anchor = selectionAnchor();
      if (anchor && matchesTree(anchor)) setSelectionAnchor(null);
      const singleClip = readFileReference(fileClipboard());
      if (singleClip?.slug === slug && matchesPath(singleClip.path)) setFileClipboard("");
      if (cutItems().some(item => item.kind === "file" && item.slug === slug && matchesPath(item.path))) setFileClipboard("");
    });
  };
  const saveFileAction = async () => {
    const target = fileAction(), version = connectionVersion();
    if (!target || isFilePathPending(target.slug, target.path)) return;
    const moveKey = fileMoveKey(target.slug, target.path);
    setFileActionError(null);
    if (target.kind === "delete") {
      if (target.directory) {
        const immediateBlock = folderWorkError(target.slug, target.path, allKnownMissions(), crons[target.slug] ?? []);
        if (immediateBlock) {
          setFileActionError(immediateBlock);
          return;
        }
      }
      setFileAction(null);
      const label = target.directory ? folderLabel(target.slug, target.path) : fileBaseName(target.path);
      try {
        await deleteFileOptimistically(target.slug, target.path, !!target.directory, async () => {
          if (target.directory) await assertFolderHasNoWork(target.slug, target.path);
          await deleteProjectFile(target.slug, target.path);
        }, label);
        if (version !== connectionVersion()) return;
        clearDeletedFileUi(target.slug, target.path, !!target.directory);
        try {
          await refreshFileParents(target.slug, target.path);
        } finally {
          settleMove(moveKey);
        }
      } catch {
        // `deleteFileOptimistically` restores the row and surfaces an error toast.
      }
      return;
    }
    let destination: string;
    try {
      destination = fileDestination(target.path, fileActionValue(), target.kind === "rename");
    } catch (e) {
      setFileActionError(e instanceof Error ? e.message : String(e));
      return;
    }
    if (target.directory && destination.startsWith(`${target.path}/`)) {
      setFileActionError("A folder cannot be moved into itself.");
      return;
    }
    const destParentKey = `${target.slug}:${fileParent(destination)}`;
    if ((dirs[destParentKey] ?? []).some(entry => entry.name.toLowerCase() === fileBaseName(destination).toLowerCase())) {
      setFileActionError(`"${fileBaseName(destination)}" already exists at the destination.`);
      return;
    }
    if (isFilePathPending(target.slug, destination)) return;
    const label = target.directory ? folderLabel(target.slug, target.path) : fileBaseName(target.path);
    setFileAction(null);
    if (target.directory) {
      applyOptimisticFolderMove(target.slug, target.path, destination);
    }
    let serverCascaded = false;
    try {
      await moveOptimistically(
        moveKey,
        { kind: "file", fromProject: target.slug, toProject: target.slug, path: destination, fromPath: target.path, directory: !!target.directory },
        async () => {
          const res = await transferProjectFile(target.slug, target.path, destination);
          serverCascaded = didServerCascadeFolderTransfer(res);
        },
        label,
      );
    } catch {
      if (version === connectionVersion() && target.directory) {
        const newPrefix = `${target.slug}:${destination}`;
        batch(() => {
          for (const key of Object.keys(expanded)) if (key === newPrefix || key.startsWith(`${newPrefix}/`)) setExpanded(key, false);
        });
      }
      return;
    }
    if (version !== connectionVersion()) return;
    try {
      if (target.directory) {
        try { await folderMoved(target.slug, target.path, destination, target.slug, true, serverCascaded); }
        finally {
          await refreshFileParents(target.slug, target.path, destination);
          settleMove(moveKey);
        }
        return;
      }
      openMovedSelection(target.slug, target.path, destination, false);
      try {
        await refreshFileParents(target.slug, target.path, destination);
      } finally {
        settleMove(moveKey);
      }
    } catch (e) {
      if (version === connectionVersion()) setActionError(e instanceof Error ? e.message : String(e));
    }
  };
  const copyFile = async (slug: string, path: string, copy: boolean, directory = false, clipboardData?: DataTransfer | null) => {
    setFileMenu(null); setActionMenu(null); setMultiSelectMenu(null);
    const text = makeFileReference(slug, path, copy, directory);
    setCutId(null); setPendingMoves([]); setCutCron(null); setFileClipboard(text); setActionError(null);
    await writeClipboardReference(text, clipboardData);
  };
  const pasteFile = async (slug: string, path: string, text: string) => {
    const item = readFileReference(text), version = connectionVersion();
    if (!item || fileBusy() || text === consumedFileClipboard || isClipboardReferenceRetired(text)) return;
    setFileBusy(true); setActionMenu(null); setActionError(null);
    try {
      const other = item.slug !== slug;
      const destination = other ? [path, fileBaseName(item.path)].filter(Boolean).join("/") : fileDestination(item.path, path, false);
      if (isFilePathPending(item.slug, item.path) || isFilePathPending(slug, path) || (!item.copy && isFilePathPending(slug, destination))) {
        await Promise.all([waitForFilePathSettled(item.slug, item.path), waitForFilePathSettled(slug, path), ...(!item.copy ? [waitForFilePathSettled(slug, destination)] : [])]);
        const parent = dirs[`${item.slug}:${fileParent(item.path)}`];
        if (version !== connectionVersion() || text === consumedFileClipboard || isClipboardReferenceRetired(text) || (parent && !parent.some(e => e.name === fileBaseName(item.path) && e.kind === (item.directory ? "dir" : "file")))) return;
      }
      let serverCascaded = false;
      const transfer = async () => {
        const res = await transferProjectFile(item.slug, item.path, destination, item.copy, slug);
        serverCascaded = didServerCascadeFolderTransfer(res);
      };
      const moveKey = fileMoveKey(item.slug, item.path);
      // A move shows at its destination at once; a copy waits for the server.
      if (item.copy) await transfer();
      else await moveOptimistically(moveKey, { kind: "file", fromProject: item.slug, toProject: slug, path: destination, fromPath: item.path, directory: item.directory }, transfer, fileBaseName(item.path));
      if (version !== connectionVersion()) return;
      if (!item.copy) { consumedFileClipboard = text; retireClipboardReference(text); setFileClipboard(""); }
      try {
        await Promise.all([loadDir(item.slug, fileParent(item.path), true), loadDir(slug, path, true)]);
        setExpanded(path ? `${slug}:${path}` : slug, true);
        if (item.copy) return;
        if (item.directory) await folderMoved(item.slug, item.path, destination, slug, false, serverCascaded);
        else if (p.selected() === `pf:${item.slug}:${item.path}`) p.open(`pf:${slug}:${destination}`);
      } finally {
        if (!item.copy) settleMove(moveKey);
      }
    } catch (e) { if (version === connectionVersion()) setActionError(String(e)); }
    finally { setFileBusy(false); }
  };
  const [rename, setRename] = createSignal<({ slug: string; title: string; path?: string } | { missionId: string; title: string }) | null>(null);
  const [renameValue, setRenameValue] = createSignal("");
  const [renameError, setRenameError] = createSignal<string | null>(null);
  const [actionError, setActionError] = createSignal<string | null>(null);
  createEffect(on(() => p.deleteRequest, id => {
    if (!id) return;
    setActionError(null);
    setDeleteTargets([id]);
    p.onDeleteRequestHandled?.();
  }));
  const rowTip = useTooltip<RowTipContent>(ROW_TIP_ID, tip => <><div class="row-tip-title">{tip.title}</div><For each={tip.meta}>{line => <div class="row-tip-meta">{line}</div>}</For></>);
  const currentConnection = (version: number) => isConnected() && connectionVersion() === version;
  const requests = createSidebarRequests();
  const warmed = new Set<string>();
  const warmupQueue: string[] = [];
  let warmupActive = 0;
  const loadController = (slug: string, force = true, background = false) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    return requests.read(`controller:${version}:${slug}`, () => getProjectController(slug, 3, background ? "p2" : undefined), force)
      .then((view) => { if (currentConnection(version)) setControllers(slug, reconcile(view)); })
      .catch(swallow("projectFiles.loadController", { slug }));
  };
  const missingCronApi = (error: unknown) => error instanceof ApiError && [404, 405].includes(error.status) && !/project not found/i.test(error.detail);
  const cronFailure = (slug: string, error: unknown) => {
    if (missingCronApi(error)) setCronUnsupported(true);
    else { setCronRetryable(slug, !(error instanceof ApiError) || error.status >= 500 || [408, 429].includes(error.status)); setCronErrors(slug, error instanceof Error ? error.message : String(error)); }
  };
  const cronLoads = new Map<string, Promise<void>>();
  const loadCrons = (slug: string, force = false, background = false): Promise<void> => {
    if (!isConnected() || (cronUnsupported() && !force)) return Promise.resolve();
    const version = connectionVersion();
    const key = `${version}:${slug}`;
    const pending = cronLoads.get(key);
    if (pending) return pending;
    const request = (async () => {
      try {
        const jobs = await requests.read(`crons:${version}:${slug}`, () => listProjectCrons(slug, background ? "p2" : undefined), force);
        if (!currentConnection(version)) return;
        setCrons(slug, reconcile(jobs, {key: "id"})); setCronErrors(slug, null); setCronUnsupported(false);
      } catch (error) { if (currentConnection(version)) cronFailure(slug, error); }
      finally { cronLoads.delete(key); }
    })();
    cronLoads.set(key, request);
    return request;
  };
  createEffect(on(connectionVersion, () => {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = undefined; }
    deletedInSession.clear(); deleteQueue.length = 0; queuedDeletes.clear(); deletingDescendants.clear(); deleteFailures.length = 0; pendingRemoved = new Set(); pendingUnmark = new Set();
    setDeletingIds(new Set<string>());
    setRename(null); setActionMenu(null); setFileMenu(null); setFileAction(null); setFileClipboard(""); setArchiveMenu(null); setControllerMenu(null); setDeleteCronTarget(null); setDeletingCron(false); setDeleteCronError(null);
    setMovingCron(false); setCutCron(null); setMultiSelectMenu(null);
    setSelectionActive(false); setSelectedAgents([]); setSelectionAnchor(null); setPendingMoves([]); setDeleteTargets([]); setMissionMenu(null);
    resetArchives();
    setCronUnsupported(false);
    setCronChecking(false);
    setCronInfo(null);
    requests.clear();
    cancelIntent(); setError(null);
    const cachedOnSwitch = isConnected() ? peekCachedProjects() : null;
    setProjects(cachedOnSwitch ?? []);
    setProjectsLoading(isConnected() && cachedOnSwitch === null);
    setMissions(reconcile({})); setDirs(reconcile({}));
    setControllers(reconcile({})); setCrons(reconcile({}));
    setDirErrors(reconcile({})); setCronErrors(reconcile({}));
    warmed.clear();
    warmupQueue.length = 0;
    if (!isConnected()) return;
    refresh();
    for (const slug of Object.keys(expanded)) if (expanded[slug] && !slug.includes(":")) void loadCrons(slug);
  }, { defer: true }));
  const beginCron = async (slug: string, path = "") => {
    setCronFolder(path);
    setActionMenu(null);
    if (!isConnected()) return;
    const version = connectionVersion();
    if (cronUnsupported()) { setCronInfo(slug); return; }
    setCronChecking(true);
    try {
      const defaults = await getProjectCronDefaults(slug);
      if (!currentConnection(version)) return;
      if (path && !defaults.folders_supported) {
        setActionError("This backend needs the project-folder update before it can create a cron inside a folder. No cron was created.");
        return;
      }
      setCronDefaults(defaults); setDefaultsError(null); setNewCron(slug);
    } catch (error) { if (currentConnection(version)) { cronFailure(slug, error); setCronInfo(slug); } }
    finally { if (currentConnection(version)) setCronChecking(false); }
  };

  let refreshGeneration = 0;
  const refresh = (force = false) => {
    if (!isConnected()) {
      setProjectsLoading(false);
      return;
    }
    const version = connectionVersion();
    const gen = ++refreshGeneration;
    if (projects().length === 0) setProjectsLoading(true);
    listProjects(force)
      .then((list) => {
        if (!currentConnection(version) || gen !== refreshGeneration) return;
        batch(() => {
          setProjects(list);
          setProjectsLoading(false);
          setError(null);
        });
        warmupProjects(list);
      })
      .catch((e) => {
        if (!currentConnection(version) || gen !== refreshGeneration) return;
        const msg = e instanceof Error ? e.message : String(e);
        batch(() => {
          setProjectsLoading(false);
          setError(
            /^(404|405)\b/.test(msg)
              ? "This backend build doesn't expose projects yet — update the core."
              : msg,
          );
        });
      });
  };
  createEffect(on(projectsVersion, () => {
    refresh(true);
    for (const slug of Object.keys(expanded)) {
      if (expanded[slug] && !slug.includes(":")) {
        void loadController(slug, true);
        void loadCrons(slug, true);
      }
    }
  }, { defer: true }));
  onMount(() => {
    refresh();
    const onProjectCreated = (event: Event) => {
      const detail = (event as CustomEvent<ProjectSummary>).detail;
      if (!detail?.slug) return;
      setProjects((current) => current.some((p) => p.slug === detail.slug)
        ? current.map((p) => p.slug === detail.slug ? { ...p, ...detail } : p)
        : [...current, detail]);
      setError(null);
      setExpanded(detail.slug, true);
      void loadMissions(detail.slug);
      void loadDir(detail.slug, "");
    };
    window.addEventListener("orb:project-created", onProjectCreated);
    const onPlacementChanged = (event: Event) => {
      const { moves } = (event as CustomEvent<{ moves?: PlacementCommitItem[] }>).detail ?? {};
      if (!moves?.length) return;
      const knownById = new Map(allKnownMissions().map(m => [m.id, m]));
      missionRevision++;
      batch(() => {
        for (const item of moves) {
          const targetSlug = item.project || "default";
          leaveProjects(item.mission_id, targetSlug);
          const prior = knownById.get(item.mission_id);
          if (prior && !isBtwMission(prior)) {
            const updated = mergeMission(prior, {
              id: item.mission_id,
              project: item.project,
              folder: item.folder,
              placement_revision: item.placement_revision,
            }, "partial");
            if (!isArchived(updated) || (missions[targetSlug] ?? []).some(m => m.id === item.mission_id)) {
              setMissions(targetSlug, rows => upsertMissionPreservingOrder(rows ?? [], updated));
            }
          } else if ((missions[targetSlug] ?? []).some(m => m.id === item.mission_id)) {
            setMissions(targetSlug, rows => (rows ?? []).map(m => m.id === item.mission_id
              ? mergeMission(m, { id: item.mission_id, project: item.project, folder: item.folder, placement_revision: item.placement_revision }, "partial")
              : m));
          }
        }
        const moveById = new Map(moves.map(item => [item.mission_id, item]));
        setArchivedMissions(prev => {
          if (!prev.some(m => moveById.has(m.id))) return prev;
          return prev.map(m => {
            const item = moveById.get(m.id);
            if (!item) return m;
            return mergeMission(m, {
              id: m.id,
              project: item.project,
              folder: item.folder,
              placement_revision: item.placement_revision,
            }, "partial");
          });
        });
      });
    };
    window.addEventListener("orb:mission-placement-changed", onPlacementChanged);
    onCleanup(() => window.removeEventListener("orb:mission-placement-changed", onPlacementChanged));
    const onMissionForked = (event: Event) => {
      const { mission } = (event as CustomEvent<{ mission: Mission }>).detail ?? {};
      const slug = mission?.project?.trim();
      if (!mission?.id || !slug || isBtwMission(mission)) return;
      missionRevision++;
      const clean = withHierarchy(mission);
      batch(() => {
        setMissions(slug, rows => [clean, ...(rows ?? []).filter(m => m.id !== clean.id)]);
      });
    };
    window.addEventListener("orb:mission-forked", onMissionForked);
    onCleanup(() => window.removeEventListener("orb:mission-forked", onMissionForked));
    const onArchived = (event: Event) => {
      const { id } = (event as CustomEvent<{ id: string }>).detail;
      archivedInSession.add(id);
      leaveProjects(id, "");
    };
    const onArchiveFailed = (event: Event) => {
      const { id } = (event as CustomEvent<{ id: string }>).detail;
      archivedInSession.delete(id);
      for (const project of projects()) if (expanded[project.slug]) void loadMissions(project.slug);
    };
    window.addEventListener("orb:mission-archived", onArchived);
    window.addEventListener("orb:mission-archive-failed", onArchiveFailed);
    onCleanup(() => { window.removeEventListener("orb:mission-archived", onArchived); window.removeEventListener("orb:mission-archive-failed", onArchiveFailed); });
    const onCronChanged = (event: Event) => {
      const detail = (event as CustomEvent<{ slug: string; id?: string; deleted?: boolean; targetSlug?: string; folder?: string }>).detail;
      if (!detail?.slug) return;
      if (detail.deleted) {
        if (detail.id) {
          setCrons(detail.slug, (list) => (list ?? []).filter((j) => j.id !== detail.id));
          if (p.selected() === `pc:${detail.slug}:${detail.id}`) p.open(null);
        } else {
          setControllers(detail.slug, reconcile({ slug: detail.slug, job: null, runs: [] }));
          if (p.selected() === `c:${detail.slug}`) p.open(null);
        }
      } else {
        if (detail.targetSlug && detail.targetSlug !== detail.slug && detail.id) {
          const movedJob = (crons[detail.slug] ?? []).find(j => j.id === detail.id);
          setCrons(detail.slug, list => (list ?? []).filter(j => j.id !== detail.id));
          if (movedJob) {
            const updated = { ...movedJob, folder: detail.folder ?? movedJob.folder };
            setCrons(detail.targetSlug, list => [...(list ?? []).filter(j => j.id !== detail.id), updated]);
          }
          if (p.selected() === `pc:${detail.slug}:${detail.id}`) p.open(`pc:${detail.targetSlug}:${detail.id}`);
        }
        void loadCrons(detail.slug, true);
        if (detail.targetSlug && detail.targetSlug !== detail.slug) void loadCrons(detail.targetSlug, true);
      }
    };
    window.addEventListener("orb:cron-changed", onCronChanged);
    const onVisible = () => {
      if (document.visibilityState === "visible" && isSidebarActive()) pumpWarmup();
    };
    document.addEventListener("visibilitychange", onVisible);
    createEffect(on(isSidebarActive, (active) => {
      if (active) pumpWarmup();
    }, { defer: true }));
    // Mission statuses under expanded projects already react immediately to
    // `activityMissions` (SSE + global poll); keep a calm, concurrency-bounded
    // fallback sweep so 7+ expanded projects never fire 35+ simultaneous HTTP/2
    // requests on a single tick.
    let projectSweepBusy = false;
    const stop = pollWhileVisible(async () => {
      if (!isConnected() || !isSidebarActive() || projectSweepBusy) return;
      projectSweepBusy = true;
      try {
        if (error()) refresh();
        const slugs = projects().map(proj => proj.slug).filter(slug => expanded[slug]);
        for (let i = 0; i < slugs.length; i += 2) {
          if (!isConnected()) break;
          await Promise.all(slugs.slice(i, i + 2).map(async (slug) => {
            if (!expanded[slug]) return;
            const subdirs = Object.keys(expanded)
              .filter(key => expanded[key] && key.startsWith(`${slug}:`))
              .map(key => key.slice(slug.length + 1));
            await Promise.all([
              loadMissions(slug),
              loadController(slug),
              loadCrons(slug),
              loadDir(slug, "", true),
              ...subdirs.map(sub => loadDir(slug, sub, true)),
            ]);
          }));
        }
      } finally {
        projectSweepBusy = false;
      }
    }, 10000);
    onCleanup(() => {
      stop();
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("orb:cron-changed", onCronChanged);
      window.removeEventListener("orb:project-created", onProjectCreated);
    });
  });

  const newerThan = (a: Mission, b: Mission) => (Date.parse(a.updated_at || "") || 0) > (Date.parse(b.updated_at || "") || 0);
  const loadMissions = (slug: string, opts?: { transcripts?: boolean; cached?: boolean; background?: boolean }) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    const revision = missionRevision;
    return requests.read(`missions:${version}:${revision}:${slug}`, () => listProjectMissions(slug, opts?.background ? { background: true } : undefined), !opts?.cached)
      .then((list) => {
        if (!currentConnection(version)) return;
        if (revision !== missionRevision) return;
        const partial = isPartialList(list);
        const visibleList = list.filter(m => !deletedInSession.has(m.id) && !archivedInSession.has(m.id));
        // Reconcile, never replace: a short answer during a Core/Hermes restart keeps what is on screen.
        const misses = listMisses.get(slug) ?? new Map() as Misses; listMisses.set(slug, misses);
        const reconciled = reconcileMissionList((missions[slug] ?? []).filter(m => !deletedInSession.has(m.id) && !archivedInSession.has(m.id)), visibleList.map(m => archiving.has(m.id) ? {...m, status: archiving.get(m.id)!} : m), misses, partial);
        const merged = mergeById(missions[slug] ?? [], reconciled);
        batch(() => {
          if (merged !== missions[slug]) setMissions(slug, merged);
          // A mission lives in one project. One moved here (from another window,
          // an agent, a rename-and-move) leaves the copy that the other project's
          // reconciled listing still holds, unless that copy is newer.
          const listed = new Map(visibleList.filter(m => !m.project || m.project === slug).map(m => [m.id, m]));
          for (const other of Object.keys(missions)) if (other !== slug && missions[other]?.some(m => listed.has(m.id) && !newerThan(m, listed.get(m.id)!)))
            setMissions(other, rows => rows.filter(m => !listed.has(m.id) || newerThan(m, listed.get(m.id)!)));
        });
        p.onProjectMissions?.(slug, merged);
        if (opts?.transcripts === false) return;
        const deleting = deletingIds();
        for (const id of selectLivePrefetchIds(merged.filter(m => !deleting.has(m.id)), isLive)) prefetchTranscript(id);
      })
      .catch(() => {
        if (currentConnection(version) && !missions[slug]) setMissions(slug, []);
      });
  };

  let prevActivityByProject = new Map<string, string>();
  createEffect(on(() => p.activityMissions, (list) => {
    if (!isConnected()) {
      prevActivityByProject = new Map();
      return;
    }
    const incomingByProject = new Map<string, Mission[]>();
    const nextByProject = new Map<string, string[]>();
    for (const m of list ?? []) {
      if (isMissionParticipant(m)) continue;
      const slug = m.project?.trim();
      if (!slug) continue;
      let rows = incomingByProject.get(slug);
      if (!rows) incomingByProject.set(slug, rows = []);
      rows.push(m);
      let entries = nextByProject.get(slug);
      if (!entries) nextByProject.set(slug, entries = []);
      entries.push(`${m.id}:${m.status}:${m.remote_job?.job_id ?? ""}:${m.remote_job?.node_state ?? ""}`);
    }
    const nextSignatures = new Map<string, string>();
    for (const [slug, entries] of nextByProject) {
      nextSignatures.set(slug, entries.sort().join("|"));
    }
    if (prevActivityByProject.size > 0) {
      const slugs = new Set([...prevActivityByProject.keys(), ...nextSignatures.keys()]);
      batch(() => {
        for (const slug of slugs) {
          if (prevActivityByProject.get(slug) === nextSignatures.get(slug)) continue;
          const existing = missions[slug];
          const incoming = incomingByProject.get(slug);
          if (existing && incoming?.length) {
            const byId = new Map(incoming.map(item => [item.id, item]));
            let changed = false;
            const patched = existing.map(row => {
              const inc = byId.get(row.id);
              if (!inc || deletedInSession.has(row.id) || archivedInSession.has(row.id)) return row;
              const merged = mergeMission(row, inc, "partial");
              const withArch = archiving.has(row.id) ? { ...merged, status: archiving.get(row.id)! } : merged;
              if (withArch !== row) changed = true;
              return withArch;
            });
            if (changed) setMissions(slug, patched);
          }
          if (warmed.has(slug)) {
            void loadMissions(slug);
          }
        }
      });
    }
    prevActivityByProject = nextSignatures;
  }));

  const dirGenerations = new Map<string, number>();
  const loadDir = (slug: string, path: string, force = false, background = false) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    const key = `${slug}:${path}`;
    const gen = (dirGenerations.get(key) ?? 0) + (force ? 1 : 0);
    if (force) dirGenerations.set(key, gen);
    setDirErrors(key, null);
    return requests.read(`files:${version}:${key}`, () => listProjectFiles(slug, path, { background }), force)
      .then((entries) => { if (currentConnection(version) && (dirGenerations.get(key) ?? 0) === gen) setDirs(key, reconcile(Array.isArray(entries) ? entries : [], {key: "name"})); })
      .catch((e) => { if (currentConnection(version) && (dirGenerations.get(key) ?? 0) === gen) setDirErrors(key, e instanceof Error ? e.message : String(e)); });
  };

  const warmupOne = async (slug: string) => {
    const isOpen = !!expanded[slug];
    await Promise.all([
      loadMissions(slug, { transcripts: false, cached: true, background: !isOpen }),
      loadDir(slug, "", false, !isOpen),
      loadController(slug, false, !isOpen),
      loadCrons(slug, false, !isOpen),
    ]);
  };
  const pumpWarmup = () => {
    if (!cacheCanPrefetch()) return;
    const cap = Math.min(2, currentLinkBudget().p2Cap);
    if (cap <= 0) return;
    while (warmupActive < cap && warmupQueue.length) {
      const slug = warmupQueue.shift()!;
      warmupActive++;
      void warmupOne(slug).finally(() => {
        warmupActive--;
        pumpWarmup();
      });
    }
  };
  onCleanup(onLinkBudgetChange(pumpWarmup));
  const warmupProjects = (list: ProjectSummary[]) => {
    const limit = list.length;
    if (!limit) return;
    const active = new Set((p.activityMissions ?? []).filter(m => isRunning(m.status)).map(m => m.project));
    const prioritized = [...list].sort((a, b) => Number(!!expanded[b.slug] || active.has(b.slug)) - Number(!!expanded[a.slug] || active.has(a.slug)));
    for (const proj of prioritized.slice(0, limit)) {
      if (warmed.has(proj.slug)) continue;
      warmed.add(proj.slug);
      warmupQueue.push(proj.slug);
    }
    pumpWarmup();
  };

  const beginFolder = (slug: string, path: string) => {
    setActionMenu(null);
    setFolderName("");
    setFolderError(null);
    setNewFolder({ slug, path });
  };
  const createFolder = async () => {
    const target = newFolder();
    const name = folderName().trim();
    if (!target || makingFolder()) return;
    if (!name || name === "." || name === ".." || /[\\/]/.test(name)) {
      setFolderError("Use a folder name without slashes.");
      return;
    }
    // Optimistic: the folder shows at once and the dialog closes; a failure
    // removes it again and reopens the dialog with the error.
    const key = `${target.slug}:${target.path}`;
    const path = target.path ? `${target.path}/${name}` : name;
    const existed = (dirs[key] ?? []).some(e => e.name === name);
    if (!existed) setDirs(key, rows => [...(rows ?? []), { name, kind: "dir" } as ProjectFileEntry].sort((a, b) => a.kind === b.kind ? a.name.localeCompare(b.name) : a.kind === "dir" ? -1 : 1));
    setExpanded(target.path ? key : target.slug, true);
    setNewFolder(null);
    setFolderError(null);
    try {
      await mkdirProjectFile(target.slug, path);
      void loadDir(target.slug, target.path, true);
    } catch (e) {
      if (!existed) setDirs(key, rows => (rows ?? []).filter(r => !(r.name === name && r.kind === "dir")));
      setFolderName(name); setNewFolder(target);
      setFolderError(e instanceof Error ? e.message : String(e));
    }
  };
  const beginFile = (slug: string, path: string) => {
    if (!path) return;
    setActionMenu(null);
    setFileName("");
    setFileError(null);
    setNewFile({ slug, path });
  };
  /**
   * Create an empty reference file through the core's project-file API
   * (`PUT /api/projects/:slug/file`), which stores it under the backend's own
   * `.sandboxed-sh/project-files/<slug>` tree. No mission, workspace or
   * execution machine is involved, and no cron API is touched.
   */
  const createFile = async () => {
    const target = newFile();
    if (!target || makingFile()) return;
    const resolved = newFilePath(target.path, fileName());
    if ("error" in resolved) { setFileError(resolved.error); return; }
    setMakingFile(true);
    setFileError(null);
    try {
      // Re-list the parent rather than trusting the cached rows: another client
      // (or a mission) may have added the file since this listing was loaded,
      // and `writeProjectFile` would overwrite it without asking.
      const parent = resolved.path.slice(0, Math.max(0, resolved.path.lastIndexOf("/")));
      const siblings = await listProjectFiles(target.slug, parent);
      if (siblings.some((entry) => entry.name === resolved.name)) {
        setFileError(`"${resolved.name}" already exists here. Choose another name.`);
        return;
      }
      await writeProjectFile(target.slug, resolved.path, "");
      // Reveal it: refresh the parent listing, unfold every folder on the way
      // down, then open the file in the Markdown view.
      await loadDir(target.slug, parent, true);
      setExpanded(target.slug, true);
      const segments = parent ? parent.split("/") : [];
      for (let i = 1; i <= segments.length; i++) setExpanded(`${target.slug}:${segments.slice(0, i).join("/")}`, true);
      setNewFile(null);
      p.open(`pf:${target.slug}:${resolved.path}`);
    } catch (e) {
      setFileError(e instanceof Error ? e.message : String(e));
    } finally {
      setMakingFile(false);
    }
  };
  const copyMissionId = async (mission: Mission) => {
    setMissionMenu(null);
    setActionError(null);
    const id = missionCopyId(mission);
    try {
      await copyText(id);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };
  const beginRename = (slug: string) => {
    const project = projects().find((x) => x.slug === slug);
    const title = (project?.title || slug).trim();
    // NameDialog captures its clean value when mounted. Publish the target last.
    setRenameValue(title);
    setRenameError(null);
    setRename({ slug, title });
  };
  const beginMissionRename = (mission: Mission) => {
    setMissionMenu(null);
    setForkTarget(null);
    setRenameValue(mission.title ?? "");
    setRenameError(null);
    setRename({ missionId: mission.id, title: mission.title ?? "" });
  };
  const saveRename = async () => {
    const target = rename();
    const title = renameValue().trim();
    if (!target) return;
    if (!title) { setRenameError("Enter a name."); return; }
    // Optimistic: every view shows the new name now; a failure restores the
    // old one and reports it in a toast (see renames.ts).
    setRename(null);
    setRenameError(null);
    if ("missionId" in target) {
      void renameOptimistically("mission", target.missionId, title, target.title, () => renameMission(target.missionId, title)).then(() => {
        for (const slug of Object.keys(missions)) setMissions(slug, m => m.id === target.missionId, "title", title);
      }, swallow("projectFiles.renameMission", { mission: target.missionId }));
    } else {
      void renameOptimistically("project", target.slug, title, target.title, () => updateProject({ slug: target.slug, title })).then(() => {
        setProjects(list => list.map(project => project.slug === target.slug ? {...project, title} : project));
        bumpProjects();
      }, swallow("projectFiles.renameProject", { slug: target.slug }));
    }
  };
  const archive = async (slug: string) => {
    setActionError(null);
    try {
      await archiveProject(slug);
      setProjects((list) => list.filter((x) => x.slug !== slug));
      bumpProjects();
      const sel = p.selected();
      if (sel === `c:${slug}` || sel?.startsWith(`pc:${slug}:`) || sel?.startsWith(`pf:${slug}:`)) p.open(null);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };
  const performMoveCron = async (fromSlug: string, id: string, toSlug: string, folder: string) => {
    const version = connectionVersion();
    const trimmedFolder = folder.trim().replace(/^\/+|\/+$/g, "");
    const view = await updateProjectCron(fromSlug, id, {
      ...(toSlug !== fromSlug ? { project: toSlug } : {}),
      folder: trimmedFolder,
    });
    if (version !== connectionVersion()) return;
    if (toSlug !== fromSlug) {
      cachePut(`c:${fromSlug}:${id}`, { slug: fromSlug, job: null, runs: [] });
      setCrons(fromSlug, (list) => (list ?? []).filter((j) => j.id !== id));
    }
    cachePut(`c:${toSlug}:${id}`, view);
    setExpanded(toSlug, true);
    const segments = trimmedFolder ? trimmedFolder.split("/").filter(Boolean) : [];
    for (let i = 1; i <= segments.length; i++) {
      const path = segments.slice(0, i).join("/");
      setExpanded(`${toSlug}:${path}`, true);
      void loadDir(toSlug, path, true);
    }
    await Promise.all([
      loadCrons(toSlug, true),
      ...(toSlug !== fromSlug ? [loadCrons(fromSlug, true)] : []),
      loadDir(toSlug, "", true),
    ]);
    if (p.selected() === `pc:${fromSlug}:${id}`) p.open(`pc:${toSlug}:${id}`);
    window.dispatchEvent(new CustomEvent("orb:cron-changed", { detail: { slug: fromSlug, id, targetSlug: toSlug, folder: trimmedFolder } }));
    bumpProjects();
  };
  const startCutCron = async (slug: string, id: string, name: string, folder = "", clipboardData?: DataTransfer | null) => {
    setControllerMenu(null); setActionMenu(null); setMultiSelectMenu(null);
    const text = makeCronReference(slug, id, name, folder);
    setCutId(null); setPendingMoves([]); setCutCron({ slug, id, name }); setFileClipboard(text); setActionError(null);
    await writeClipboardReference(text, clipboardData);
  };
  const pasteCron = async (toSlug: string, folder: string, fromText?: string) => {
    const ref = fromText && !isClipboardReferenceRetired(fromText) ? readCronReference(fromText) : null;
    const item = ref ?? cutCron();
    if (!item || movingCron() || (fromText && (fromText === consumedFileClipboard || isClipboardReferenceRetired(fromText)))) return;
    setActionMenu(null);
    setMovingCron(true);
    setActionError(null);
    try {
      await performMoveCron(item.slug, item.id, toSlug, folder);
      if (fromText) { consumedFileClipboard = fromText; retireClipboardReference(fromText); }
      const currentClip = fileClipboard();
      if (readCronReference(currentClip)?.id === item.id) {
        consumedFileClipboard = currentClip;
        retireClipboardReference(currentClip);
        setFileClipboard("");
      }
      setCutCron(null);
    } catch (e) {
      setActionError(`Couldn’t move cron: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setMovingCron(false);
    }
  };
  const findNodeById = (id: string, nodes: Node[] = [...tree(), ...(archivesOpen() ? archiveNodes() : [])]): RowData | undefined => {
    for (const node of nodes) {
      if (node.id === id) return node.data;
      const child = node.children && findNodeById(id, node.children);
      if (child) return child;
    }
  };
  /** Resolve any live project-tree row to its enclosing `(project, folder)` destination. */
  const resolveTreeDestination = (treeId: string, nodes: Node[] = tree(), enclosingFolder = ""): { slug: string; path: string } | null => {
    for (const node of nodes) {
      const d = node.data;
      if (node.id === treeId) {
        if (d.kind === "project") return { slug: d.slug, path: "" };
        if (d.kind === "folder") return { slug: d.slug, path: d.path ?? "" };
        if (d.kind === "note") return { slug: d.slug, path: d.path ?? enclosingFolder };
        if (d.kind === "file") return { slug: d.slug, path: fileParent(d.path ?? "") };
        if (d.kind === "cron" || d.kind === "mission") return { slug: d.slug, path: enclosingFolder };
        return null;
      }
      if (node.children?.length) {
        const found = resolveTreeDestination(treeId, node.children, d.kind === "folder" ? (d.path ?? "") : enclosingFolder);
        if (found) return found;
      }
    }
    return null;
  };
  const treeIdToClipboardItem = (treeId: string): ClipboardItem | null => {
    const row = findNodeById(treeId);
    if (row) {
      if (row.kind === "file" || row.kind === "folder") return { kind: "file", slug: row.slug, path: row.path!, ...(row.kind === "folder" ? { directory: true } : {}) };
      if (row.kind === "cron" && !row.controller && row.job?.id) return { kind: "cron", slug: row.slug, id: row.job.id, name: row.label, ...(row.job.folder ? { folder: row.job.folder } : {}) };
      if (row.kind === "mission" && row.mission) return { kind: "mission", id: row.mission.id };
    }
    const mid = missionIdFromTreeId(treeId);
    if (mid) return { kind: "mission", id: mid };
    if (treeId.startsWith("pc:")) {
      const rest = treeId.slice(3), sep = rest.indexOf(":");
      if (sep > 0) {
        const slug = rest.slice(0, sep), id = rest.slice(sep + 1);
        const job = (crons[slug] ?? []).find(j => j.id === id);
        return { kind: "cron", slug, id, name: job?.name || id, ...(job?.folder ? { folder: job.folder } : {}) };
      }
    }
    if (treeId.startsWith("pf:")) {
      const rest = treeId.slice(3), sep = rest.indexOf(":");
      if (sep > 0) {
        const slug = rest.slice(0, sep), path = rest.slice(sep + 1);
        const parent = fileParent(path), base = fileBaseName(path);
        const directory = (dirs[`${slug}:${parent}`] ?? []).some(e => e.name === base && e.kind === "dir");
        return { kind: "file", slug, path, ...(directory ? { directory: true } : {}) };
      }
    }
    return null;
  };
  const copySelectedItems = async (treeIds: string[], copy: boolean, clipboardData?: DataTransfer | null) => {
    const items = treeIds.map(treeIdToClipboardItem).filter((x): x is ClipboardItem => !!x);
    if (!items.length) return;
    if (copy && items.some(i => i.kind !== "file")) return;
    // If all items are missions and !copy, preserve the existing pendingMoves path so Move N agents works identically.
    if (!copy && items.every(i => i.kind === "mission")) {
      const ids = [...new Set(items.map(i => (i as { kind: "mission"; id: string }).id))];
      setMultiSelectMenu(null); setActionMenu(null); setFileMenu(null); setControllerMenu(null);
      setFileClipboard(""); setCutCron(null);
      if (ids.length === 1) { setPendingMoves([]); beginMove(ids[0], clipboardData); }
      else {
        retireActiveClipboardReference();
        if (clipboardData) clipboardData.setData("text/plain", makeCutMission(ids[0]));
        setPendingMoves(ids); setCutId(ids[0]); setActionError(null);
      }
      return;
    }
    if (items.length === 1) {
      const single = items[0];
      if (single.kind === "file") { await copyFile(single.slug, single.path, copy, !!single.directory, clipboardData); return; }
      if (single.kind === "cron" && !copy) { await startCutCron(single.slug, single.id, single.name, single.folder, clipboardData); return; }
    }
    setMultiSelectMenu(null); setActionMenu(null); setFileMenu(null); setControllerMenu(null); setMissionMenu(null);
    const text = makeItemsReference(items, copy);
    setCutId(null); setPendingMoves([]); setCutCron(null); setFileClipboard(text); setActionError(null);
    await writeClipboardReference(text, clipboardData);
  };
  const pasteItems = async (targetSlug: string, targetPath: string, text: string, approvalPolicy: ApprovalTransferPolicy = "check") => {
    const bundle = readItemsReference(text), version = connectionVersion();
    if (!bundle || fileBusy() || movingCron() || isMoving() || text === consumedFileClipboard || isClipboardReferenceRetired(text)) return;
    setFileBusy(true); setActionMenu(null); setActionError(null);
    // Show every moved item at its destination at once; each is settled or
    // reverted as its own request finishes (see moves.ts).
    const previewed: string[] = [];
    if (!bundle.copy) for (const item of bundle.items) {
      if (item.kind === "file") {
        const destination = item.slug !== targetSlug ? [targetPath, fileBaseName(item.path)].filter(Boolean).join("/") : fileDestination(item.path, targetPath, false);
        const key = fileMoveKey(item.slug, item.path);
        previewMove(key, { kind: "file", fromProject: item.slug, toProject: targetSlug, path: destination, fromPath: item.path, directory: !!item.directory });
        previewed.push(key);
      } else if (item.kind === "mission") {
        const known = allKnownMissions().find(m => m.id === item.id);
        const key = missionMoveKey(item.id);
        previewMove(key, { kind: "mission", fromProject: known?.project ?? null, toProject: targetSlug, path: targetPath });
        previewed.push(key);
      }
    }
    const moveFile = (item: { slug: string; path: string; directory?: boolean }, destination: string, run: () => Promise<unknown>) => bundle.copy ? run()
      : moveOptimistically(fileMoveKey(item.slug, item.path), { kind: "file", fromProject: item.slug, toProject: targetSlug, path: destination, fromPath: item.path, directory: !!item.directory }, run, fileBaseName(item.path));
    try {
      const movedFolders = new Map<string, { destSlug: string; destPath: string }>();
      const folderItems = bundle.items.filter((i): i is Extract<ClipboardItem, { kind: "file" }> => i.kind === "file" && !!i.directory)
        .sort((a, b) => a.path.length - b.path.length);
      const fileItems = bundle.items.filter((i): i is Extract<ClipboardItem, { kind: "file" }> => i.kind === "file" && !i.directory);
      const cronItems = bundle.items.filter((i): i is Extract<ClipboardItem, { kind: "cron" }> => i.kind === "cron");
      const missionItems = bundle.items.filter((i): i is Extract<ClipboardItem, { kind: "mission" }> => i.kind === "mission");
      const underMovedFolder = (slug: string, folderPath: string) => {
        for (const [key, dest] of movedFolders) {
          const [fSlug, fPath] = [key.slice(0, key.indexOf(":")), key.slice(key.indexOf(":") + 1)];
          if (fSlug === slug && (folderPath === fPath || folderPath.startsWith(`${fPath}/`))) {
            return { destSlug: dest.destSlug, destPath: dest.destPath + folderPath.slice(fPath.length) };
          }
        }
        return null;
      };
      const failures: string[] = [];
      for (const item of folderItems) {
        if (version !== connectionVersion()) break;
        if (underMovedFolder(item.slug, item.path)) continue;
        try {
          const other = item.slug !== targetSlug;
          const destination = other ? [targetPath, fileBaseName(item.path)].filter(Boolean).join("/") : fileDestination(item.path, targetPath, false);
          let serverCascaded = false;
          await moveFile(item, destination, async () => {
            const res = await transferProjectFile(item.slug, item.path, destination, bundle.copy, targetSlug);
            serverCascaded = didServerCascadeFolderTransfer(res);
          });
          if (!bundle.copy) {
            movedFolders.set(`${item.slug}:${item.path}`, { destSlug: targetSlug, destPath: destination });
            await folderMoved(item.slug, item.path, destination, targetSlug, false, serverCascaded);
          }
          await Promise.all([loadDir(item.slug, fileParent(item.path), true), loadDir(targetSlug, targetPath, true)]);
        } catch (err) { failures.push(`${fileBaseName(item.path)}: ${err instanceof Error ? err.message : String(err)}`); }
      }
      const dirsToReload = new Map<string, { slug: string; path: string }>();
      await Promise.all(fileItems.map(async item => {
        if (version !== connectionVersion()) return;
        if (underMovedFolder(item.slug, fileParent(item.path))) return;
        try {
          const other = item.slug !== targetSlug;
          const destination = other ? [targetPath, fileBaseName(item.path)].filter(Boolean).join("/") : fileDestination(item.path, targetPath, false);
          await moveFile(item, destination, () => transferProjectFile(item.slug, item.path, destination, bundle.copy, targetSlug));
          dirsToReload.set(`${item.slug}:${fileParent(item.path)}`, { slug: item.slug, path: fileParent(item.path) });
          dirsToReload.set(`${targetSlug}:${targetPath}`, { slug: targetSlug, path: targetPath });
          if (!bundle.copy && p.selected() === `pf:${item.slug}:${item.path}`) p.open(`pf:${targetSlug}:${destination}`);
        } catch (err) { failures.push(`${fileBaseName(item.path)}: ${err instanceof Error ? err.message : String(err)}`); }
      }));
      if (dirsToReload.size && version === connectionVersion()) {
        await Promise.all([...dirsToReload.values()].map(d => loadDir(d.slug, d.path, true)));
      }
      if (!bundle.copy) {
        await Promise.all(cronItems.map(async item => {
          if (version !== connectionVersion()) return;
          const parentMove = item.folder ? underMovedFolder(item.slug, item.folder) : null;
          if (parentMove) return;
          try {
            await performMoveCron(item.slug, item.id, targetSlug, targetPath);
          } catch (err) { failures.push(`${item.name}: ${err instanceof Error ? err.message : String(err)}`); }
        }));
        // Missions (with the missions they launched) move together and in parallel.
        const byFolder = new Map<string, string[]>();
        for (const item of missionItems) {
          if (version !== connectionVersion()) break;
          const m = allKnownMissions().find(x => x.id === item.id);
          const mFolder = m ? missionFolder(m) : "";
          const parentMove = m?.project && mFolder ? underMovedFolder(m.project, mFolder) : null;
          if (parentMove) continue;
          byFolder.set(targetPath, [...(byFolder.get(targetPath) ?? []), item.id]);
        }
        const plans = [...byFolder].map(([dest, ids]) => planMissionMoves(ids, targetSlug, dest, allKnownMissions()));
        const missionFailures = (await Promise.all(plans.map(plan => moveMissions(plan, targetSlug, { approvalPolicy })))).flat();
        const approvalErr = missionFailures.find(
          f => f.error instanceof ApprovalTransferConfirmationRequiredError,
        )?.error as ApprovalTransferConfirmationRequiredError | undefined;
        if (approvalErr) {
          setApprovalTransferPrompt({
            error: approvalErr,
            confirm: (chosenPolicy) => {
              if (version !== connectionVersion()) return;
              const remainingMissions = [...byFolder.values()].flat().map(id => ({ kind: "mission" as const, id }));
              const retryRef = makeItemsReference(remainingMissions, false);
              void pasteItems(targetSlug, targetPath, retryRef, chosenPolicy);
            },
            cancel: () => {},
          });
          return;
        }
        for (const f of missionFailures) failures.push(`${f.id.slice(0, 8)}: ${f.error instanceof Error ? f.error.message : String(f.error)}`);
        const failedIds = new Set(missionFailures.map(f => f.id));
        for (const step of plans.flat()) if (!failedIds.has(step.id)) leaveProjects(step.id, targetSlug);
        const fromSlugs = new Set(plans.flat().filter(s => !failedIds.has(s.id) && s.from && s.from !== targetSlug).map(s => s.from!));
        await Promise.all([loadMissions(targetSlug), ...[...fromSlugs].map(s => loadMissions(s))]);
      }
      if (version !== connectionVersion()) return;
      setExpanded(targetPath ? `${targetSlug}:${targetPath}` : targetSlug, true);
      if (!bundle.copy && !failures.length) {
        consumedFileClipboard = text;
        retireClipboardReference(text);
        setFileClipboard("");
      }
      if (failures.length) setActionError(failures.join("; "));
      bumpProjects();
    } catch (e) { if (version === connectionVersion()) setActionError(String(e)); }
    finally {
      setFileBusy(false);
      // Files were reloaded from the server; items skipped inside a moved folder never ran.
      for (const key of previewed) { const move = pendingPlaceMoves().get(key); if (move && (move.kind === "file" || move.acceptedAt === undefined)) settleMove(key); }
    }
  };
  const multiSelectMenuItems = (treeIds: string[]): MenuEntry[] => {
    const items = treeIds.map(treeIdToClipboardItem).filter((x): x is ClipboardItem => !!x);
    const n = items.length;
    if (!n) return [];
    const onlyFiles = items.every(i => i.kind === "file");
    const onlyCrons = items.every(i => i.kind === "cron");
    const onlyMissions = items.every(i => i.kind === "mission");
    const moveLabel = onlyMissions
      ? `Move ${n} agents`
      : onlyCrons
        ? `Move ${n} crons`
        : `Move ${n} items`;
    const entries: MenuEntry[] = [
      { kind: "item", label: moveLabel, icon: Ic.CutIcon, onClick: () => void copySelectedItems(treeIds, false) },
    ];
    if (onlyFiles) {
      entries.push({ kind: "item", label: `Copy ${n} items`, icon: Ic.CopyIcon, onClick: () => void copySelectedItems(treeIds, true) });
    }
    if (onlyCrons) {
      const cronItems = items as Array<Extract<ClipboardItem, { kind: "cron" }>>;
      entries.push(
        { kind: "sep" },
        {
          kind: "item",
          label: `Delete ${n} crons…`,
          icon: Ic.TrashIcon,
          danger: true,
          onClick: () => {
            setMultiSelectMenu(null);
            setDeleteCronError(null);
            setDeleteCronTarget({
              slug: cronItems[0].slug,
              id: cronItems[0].id,
              name: cronItems[0].name,
              controller: false,
              items: cronItems.map((c) => ({ slug: c.slug, id: c.id, name: c.name })),
            });
          },
        },
      );
    }
    if (onlyMissions) {
      const firstId = (items[0] as { kind: "mission"; id: string }).id;
      entries.push(
        { kind: "item", label: `Archive ${n} conversations`, icon: Ic.ArchiveIcon, onClick: () => void archiveSelection(firstId) },
        { kind: "item", label: `Delete ${n} agents…`, icon: Ic.TrashIcon, danger: true, onClick: () => setDeleteTargets(items.map(i => (i as { kind: "mission"; id: string }).id)) },
      );
    }
    return entries;
  };
  const pasteMenuEntries = (slug: string, path: string): MenuEntry[] => {
    if (!slug) return [];
    const closeMenus = () => { setActionMenu(null); setMissionMenu(null); setControllerMenu(null); setFileMenu(null); setMultiSelectMenu(null); };
    const singleFileClip = readFileReference(fileClipboard());
    const singleCronClip = readCronReference(fileClipboard());
    const multiClip = readItemsReference(fileClipboard());
    const out: MenuEntry[] = [];
    if (singleFileClip) out.push({ kind: "item", label: singleFileClip.directory ? "Paste folder" : "Paste file", icon: Ic.PasteIcon, onClick: () => { closeMenus(); void pasteFile(slug, path, fileClipboard()); } });
    else if (multiClip && multiClip.items.length) out.push({ kind: "item", label: "Paste", icon: Ic.PasteIcon, onClick: () => { closeMenus(); void pasteItems(slug, path, fileClipboard()); } });
    else if (singleCronClip || cutCron()) out.push({ kind: "item", label: "Paste", icon: Ic.PasteIcon, onClick: () => { closeMenus(); void pasteCron(slug, path, singleCronClip ? fileClipboard() : undefined); } });
    if (cutId()) out.push({ kind: "item", label: pendingMoves().length > 1 ? `Move ${pendingMoves().length} agents here` : "Move here", icon: Ic.PasteIcon, onClick: () => { closeMenus(); pasteMission(slug, path); } });
    return out;
  };
  /** Folders organize both reference files and executable work. */
  const menuItems = (slug: string, path: string): MenuEntry[] => {
    const items: MenuEntry[] = [
      { kind: "item", label: "New agent", icon: Ic.NewAgentIcon, onClick: () => p.onNewAgent(slug, path) },
      ...(p.onNewCloudAgent ? [{ kind: "item" as const, label: "Cloud agent", icon: Ic.CloudIcon, onClick: () => p.onNewCloudAgent?.(slug, path) }] : []),
      { kind: "item", label: cronChecking() ? "Checking crons…" : "New cron", icon: Ic.BellIcon, onClick: () => { if (!cronChecking()) void beginCron(slug, path); } },
      { kind: "sep" },
      ...(path ? [{ kind: "item" as const, label: "New file", icon: Ic.FileIcon, onClick: () => beginFile(slug, path) }] : []),
      { kind: "item", label: "New folder", icon: Ic.FolderIcon, onClick: () => beginFolder(slug, path) },
    ];
    for (const entry of pasteMenuEntries(slug, path)) items.push({ kind: "sep" }, entry);
    if (path) {
      const folderBusy = isFilePathPending(slug, path);
      items.push(
        { kind: "sep" },
        { kind: "item", label: "Rename", icon: Ic.PencilIcon, disabled: folderBusy, onClick: () => beginFileAction(slug, path, "rename", true) },
        { kind: "item", label: "Move…", icon: Ic.FolderIcon, disabled: folderBusy, onClick: () => beginFileAction(slug, path, "move", true) },
        { kind: "item", label: "Cut", icon: Ic.CutIcon, disabled: folderBusy, onClick: () => void copyFile(slug, path, false, true) },
        { kind: "item", label: "Copy", icon: Ic.CopyIcon, disabled: folderBusy, onClick: () => void copyFile(slug, path, true, true) },
        { kind: "item", label: "Delete…", icon: Ic.TrashIcon, danger: true, disabled: folderBusy, onClick: () => beginFileAction(slug, path, "delete", true) },
      );
    }
    if (!path) items.push(
      { kind: "sep" },
      { kind: "item", label: "Project settings", icon: Ic.SlidersIcon, onClick: () => { setActionMenu(null); p.open(`ps:${slug}`); } },
      { kind: "item", label: "Rename", icon: Ic.PencilIcon, onClick: () => beginRename(slug) },
      { kind: "item", label: "Archive", icon: Ic.ArchiveIcon, onClick: () => void archive(slug) },
    );
    return items;
  };
  const archiveController = async (slug: string, archived: boolean) => {
    const version = connectionVersion();
    setActionError(null);
    try {
      const view = await controllerAction(slug, archived ? "restore" : "archive");
      if (version !== connectionVersion()) return;
      setControllers(slug, reconcile(view));
      if (archived) {
        setExpanded(slug, true);
        void loadMissions(slug);
        void loadDir(slug, "");
      }
    } catch (e) { if (version === connectionVersion()) setActionError(String(e)); }
  };
  const confirmDeleteCron = async () => {
    const target = deleteCronTarget();
    if (!target || deletingCron()) return;
    const version = connectionVersion();
    setDeletingCron(true);
    setDeleteCronError(null);
    try {
      if (target.items && target.items.length > 1) {
        const failures: string[] = [];
        const remaining: Array<{ slug: string; id: string; name: string }> = [];
        const deletedTreeIds = new Set<string>();
        const outcomes = await Promise.all(target.items.map(async item => {
          if (version !== connectionVersion()) return { item, ok: false as const, error: undefined };
          try {
            try {
              await deleteProjectCron(item.slug, item.id);
            } catch (err) {
              if (!(err instanceof ApiError && err.status === 404)) throw err;
            }
            return { item, ok: true as const };
          } catch (err) {
            return { item, ok: false as const, error: `${item.name}: ${err instanceof Error ? err.message : String(err)}` };
          }
        }));
        if (version !== connectionVersion()) return;
        for (const outcome of outcomes) {
          const { item } = outcome;
          if (outcome.ok) {
            cachePut(`c:${item.slug}:${item.id}`, { slug: item.slug, job: null, runs: [] });
            setCrons(item.slug, (list) => (list ?? []).filter((j) => j.id !== item.id));
            if (cutCron()?.id === item.id) setCutCron(null);
            if (readCronReference(fileClipboard())?.id === item.id) setFileClipboard("");
            if (cutItems().some((c) => c.kind === "cron" && c.id === item.id)) setFileClipboard("");
            if (p.selected() === `pc:${item.slug}:${item.id}`) p.open(null);
            deletedTreeIds.add(`pc:${item.slug}:${item.id}`);
            window.dispatchEvent(new CustomEvent("orb:cron-changed", { detail: { slug: item.slug, id: item.id, deleted: true } }));
          } else if (outcome.error) {
            remaining.push(item);
            failures.push(outcome.error);
          }
        }
        if (version !== connectionVersion()) return;
        if (deletedTreeIds.size) {
          setSelectedTreeIds((ids) => {
            const next = ids.filter((id) => !deletedTreeIds.has(id));
            if (!next.length) setSelectionActive(false);
            return next;
          });
          { const anchor = selectionAnchor(); if (anchor && deletedTreeIds.has(anchor)) setSelectionAnchor(null); }
          bumpProjects();
        }
        if (failures.length) {
          setDeleteCronTarget(
            remaining.length > 1
              ? { ...target, items: remaining }
              : remaining.length === 1
                ? { slug: remaining[0].slug, id: remaining[0].id, name: remaining[0].name, controller: false }
                : null,
          );
          setDeleteCronError(failures.join("; "));
          return;
        }
      } else if (target.controller) {
        const view = await deleteProjectController(target.slug);
        if (version !== connectionVersion()) return;
        cachePut(`c:${target.slug}:`, view);
        setControllers(target.slug, reconcile(view));
        if (p.selected() === `c:${target.slug}`) p.open(null);
      } else if (target.id) {
        try {
          await deleteProjectCron(target.slug, target.id);
        } catch (err) {
          if (!(err instanceof ApiError && err.status === 404)) throw err;
        }
        if (version !== connectionVersion()) return;
        cachePut(`c:${target.slug}:${target.id}`, { slug: target.slug, job: null, runs: [] });
        setCrons(target.slug, (list) => (list ?? []).filter((j) => j.id !== target.id));
        if (cutCron()?.id === target.id) setCutCron(null);
        if (readCronReference(fileClipboard())?.id === target.id) setFileClipboard("");
        if (cutItems().some((c) => c.kind === "cron" && c.id === target.id)) setFileClipboard("");
        if (p.selected() === `pc:${target.slug}:${target.id}`) p.open(null);
        const treeId = `pc:${target.slug}:${target.id}`;
        setSelectedTreeIds((ids) => {
          const next = ids.filter((id) => id !== treeId);
          if (!next.length) setSelectionActive(false);
          return next;
        });
        if (selectionAnchor() === treeId) setSelectionAnchor(null);
      }
      setDeleteCronTarget(null);
      bumpProjects();
    } catch (e) {
      if (version === connectionVersion()) setDeleteCronError(e instanceof Error ? e.message : String(e));
    } finally {
      setDeletingCron(false);
    }
  };
  const changeArchiveState = async (mission: Mission, restore: boolean) => {
    if (archiving.has(mission.id) || deletingIds().has(mission.id)) return false;
    const subtree = missionSubtree(allKnownMissions(), [mission.id]);
    const fullSubtree = subtree.some(m => m.id === mission.id) ? subtree : [mission, ...subtree];
    if (fullSubtree.some(m => deletingIds().has(m.id))) return false;
    if (!restore && fullSubtree.some(m => isWorking(m.status))) {
      setActionError("Stop or finish this agent before archiving it.");
      return false;
    }
    const targets = restore
      ? [mission, ...fullSubtree.filter(m => m.id !== mission.id && isArchived(m))]
      : fullSubtree.filter(m => !isArchived(m) && !archiving.has(m.id));
    if (!targets.length) return true;
    const id = mission.id, version = connectionVersion();
    const status = restore ? "paused" : "acknowledged";
    const previous = new Map(targets.map(t => [t.id, t.status]));
    const targetIds = new Set(targets.map(t => t.id));
    for (const t of targets) archiving.set(t.id, status);
    missionRevision++;
    setActionError(null);
    const updateStatus = (statusFor: (m: Mission) => string) => batch(() => {
      for (const slug of Object.keys(missions)) {
        setMissions(slug, m => targetIds.has(m.id), m => ({ ...m, status: statusFor(m) }));
        p.onProjectMissions?.(slug, missions[slug] ?? []);
      }
      setArchivedMissions(rows => {
        const rest = rows.filter(m => !targetIds.has(m.id));
        const nextArchived = targets
          .map(t => ({ ...t, status: statusFor(t) }))
          .filter(t => t.status === "acknowledged");
        return [...rest, ...nextArchived];
      });
    });
    // Archiving the open conversation deselects it: following it into the
    // Archived folder would expand the archive and scroll the sidebar away.
    if (!restore) batch(() => {
      const sel = p.selected();
      if (sel?.startsWith("m:") && targetIds.has(sel.slice(2))) p.open(null);
      setSelectedTreeIds(current => current.some(x => { const mid = missionIdFromTreeId(x); return !!mid && targetIds.has(mid); }) ? current.filter(x => { const mid = missionIdFromTreeId(x); return !mid || !targetIds.has(mid); }) : current);
      const anchor = selectionAnchor(), mid = anchor ? missionIdFromTreeId(anchor) : null;
      if (mid && targetIds.has(mid)) setSelectionAnchor(null);
    });
    updateStatus(() => status);
    try {
      if (!restore && targets.length > 1 && targets.some(t => t.id === mission.id)) {
        // Core cascades status=acknowledged to parent_mission_id descendants;
        // archiving the root first avoids N redundant POSTs while still
        // archiving callback-only children and confirming local origins.
        await archiveMission(mission.id);
        await Promise.all(targets.filter(t => t.id !== mission.id).map(t => archiveMission(t.id)));
      } else {
        await Promise.all(targets.map(t => restore ? reopenMission(t.id) : archiveMission(t.id)));
      }
      if (!currentConnection(version)) return;
      if (restore) {
        for (const t of targets) archivedInSession.delete(t.id);
        const slug = mission.project || Object.keys(missions).find(slug => missions[slug]?.some(m => m.id === id));
        if (slug) {
          setMissions(slug, rows => [
            ...targets.map(t => ({ ...t, status })),
            ...(rows ?? []).filter(m => !targetIds.has(m.id)),
          ]);
          setExpanded(slug, true);
          void loadDir(slug, "");
          const segments = missionFolder(mission).split("/").filter(Boolean);
          for (let i = 1; i <= segments.length; i++) {
            const path = segments.slice(0, i).join("/");
            setExpanded(`${slug}:${path}`, true);
            void loadDir(slug, path);
          }
        }
      }
      return true;
    } catch (e) {
      if (currentConnection(version)) {
        updateStatus(m => previous.get(m.id) ?? m.status);
        setActionError(e instanceof Error ? e.message : String(e));
      }
      return false;
    } finally { for (const t of targets) archiving.delete(t.id); missionRevision++; }
  };
  const archiveConversation = (mission: Mission) => changeArchiveState(mission, false);
  const reopenConversation = (mission: Mission) => changeArchiveState(mission, true);
  const archiveSelection = async (id: string) => {
    if (batchBusy()) return;
    const ids = [...selectedFor(id)], version = connectionVersion();
    const failures:string[]=[];
    setBatchBusy(true);
    try {
      await Promise.all(ids.map(async selected => {
        if (!currentConnection(version)) return;
        const row = Object.values(missions).flat().find(m => m.id === selected) ?? archivedMissions().find(m => m.id === selected);
        if (!row || isArchived(row)) return;
        const subtree = missionSubtree(allKnownMissions(), [row.id]);
        if (isWorking(row.status) || subtree.some(m => isWorking(m.status))) { failures.push(`${selected.slice(0,8)}: stop or finish this agent first`); return; }
        if (!await archiveConversation(row)) failures.push(`${selected.slice(0,8)}: ${actionError() ?? "archive failed"}`);
      }));
      if (currentConnection(version) && failures.length) setActionError(failures.join("; "));
    } finally { setBatchBusy(false); }
  };
  const archivedMissionRows = (slug?: string): Mission[] => {
    const rows = new Map<string, Mission>();
    for (const mission of archivedMissions()) rows.set(mission.id, mission);
    // Archived ancestors already shown around visible children have one row.
    const inMain = Object.keys(missions).flatMap(s => visibleMissions(s));
    return archiveOnlyRows([...rows.values()], inMain)
      .filter(m => slug === undefined || (m.project ?? "") === slug)
      .sort((a, b) => (b.updated_at ?? "").localeCompare(a.updated_at ?? ""));
  };
  const applyArchiveSelection = (maxAgeMs?: number, slug?: string) => {
    const deleting = deletingIds();
    const matching = filterArchivedMissionsByAge(
      archivedMissionRows(slug).filter(m => !deleting.has(m.id)),
      maxAgeMs,
    );
    const ids = matching.map(m => m.id);
    const slugs = new Set(matching.map(m => m.project ?? ""));
    batch(() => {
      setArchivesOpen(true);
      if (slug !== undefined) setArchiveExpanded(slug, true);
      for (const s of slugs) setArchiveExpanded(s, true);
      setSelectionActive(ids.length > 0);
      setSelectedAgents(ids);
      setSelectionAnchor(ids[0] ? `m:${ids[0]}` : null);
      setDeleteTargets(ids);
    });
  };
  const selectAndDeleteArchives = async (maxAgeMs?: number, slug?: string) => {
    setArchiveMenu(null); setMissionMenu(null); setMultiSelectMenu(null); setForkTarget(null);
    setArchivesOpen(true);
    if (slug !== undefined) setArchiveExpanded(slug, true);
    if (!archivesLoaded() || archivesLoading() || archivesMore()) {
      const version = connectionVersion();
      if (archivesLoading() && archivesRequest()) await archivesRequest();
      if (!currentConnection(version)) return;
      if (!archivesLoaded()) await loadArchives(false);
      while (currentConnection(version) && archivesMore() && !archivesError()) {
        await loadArchives(true);
      }
      if (!currentConnection(version) || archivesError()) return;
    }
    applyArchiveSelection(maxAgeMs, slug);
  };
  const archiveDeleteMenuItems = (slug?: string): MenuEntry[] => [
    { kind: "item", label: "Delete all…", icon: Ic.TrashIcon, danger: true, onClick: () => void selectAndDeleteArchives(undefined, slug) },
    { kind: "item", label: "Delete older than 1 day…", icon: Ic.TrashIcon, danger: true, onClick: () => void selectAndDeleteArchives(ARCHIVE_DAY_MS, slug) },
    { kind: "item", label: "Delete older than 1 week…", icon: Ic.TrashIcon, danger: true, onClick: () => void selectAndDeleteArchives(ARCHIVE_WEEK_MS, slug) },
  ];
  const openArchiveMenu = (e: MouseEvent, slug?: string) => {
    if ((e.target as HTMLElement | null)?.closest(".tree-entry")?.querySelector("button:disabled")) return;
    e.preventDefault();
    e.stopPropagation();
    setActionMenu(null);
    setMissionMenu(null);
    setMultiSelectMenu(null);
    setControllerMenu(null);
    setFileMenu(null);
    setForkTarget(null);
    if (!archivesLoaded() && !archivesLoading()) void loadArchives();
    setArchiveMenu({ x: e.clientX, y: e.clientY, slug });
  };
  const leaveSharedMission = async (mission: Mission) => {
    const uid = currentUser()?.id;
    setMissionMenu(null);
    if (!uid) return;
    setActionError(null);
    try {
      const { removeMissionShare } = await import("./missionSharesApi");
      await removeMissionShare(mission.id, uid);
      p.onDeleted?.([mission.id]);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : String(e));
    }
  };
  /** Fork the clicked mission without changing the currently open conversation. */
  const missionMenuItems = (mission: Mission, slug: string, folder: string): MenuEntry[] => {
    if (isMissionParticipant(mission)) {
      return [
        { kind: "item", label: "Copy mission ID", icon: Ic.CopyIcon, onClick: () => void copyMissionId(mission) },
        { kind: "item", label: "Mission settings", icon: Ic.SlidersIcon, onClick: () => { setMissionMenu(null); p.open(`ms:${mission.id}`); } },
        { kind: "sep" },
        { kind: "item", label: "Leave shared mission", icon: Ic.CloseIcon, danger: true, onClick: () => void leaveSharedMission(mission) },
      ];
    }
    const pasteEntries = !isArchived(mission) && !(cutId() === mission.id && pendingMoves().length <= 1 && !fileClipboard() && !cutCron() && (mission.project ?? "") === slug && missionFolder(mission) === folder)
      ? pasteMenuEntries(slug, folder)
      : [];
    const pasteSection: MenuEntry[] = pasteEntries.length ? [...pasteEntries, { kind: "sep" }] : [];
    const canShare = isConnected() && !isClientPlacement(mission);
    return selectedFor(mission.id).length > 1 ? [
      ...pasteSection,
      {kind: "item", label: `Move ${selectedFor(mission.id).length} agents`, icon: Ic.CutIcon, onClick: () => startMoveSelection(mission.id)},
      {kind: "item", label: `Archive ${selectedFor(mission.id).length} conversations`, icon: Ic.ArchiveIcon, onClick: () => void archiveSelection(mission.id)},
      {kind: "item", label: `Delete ${selectedFor(mission.id).length} agents…`, icon: Ic.TrashIcon, danger: true, onClick: () => setDeleteTargets([...selectedFor(mission.id)])},
      ...(isArchived(mission) ? [{ kind: "sep" as const }, ...archiveDeleteMenuItems()] : []),
    ] : [
      ...pasteSection,
      {kind: "item", label: "Delete agent…", icon: Ic.TrashIcon, danger: true, onClick: () => setDeleteTargets([mission.id])},
      ...(!mission.backend?.startsWith("cloud_") ? [{ kind: "item" as const, label: "Transfer to another agent", icon: Ic.BranchIcon, openOnHover: true, onClick: (anchor?: HTMLButtonElement) => { setForkTarget({ mission, anchor }); } }] : []),
      ...(isReopenable(mission.status)
        ? [{ kind: "item" as const, label: isArchived(mission) ? "Restore" : "Reopen", icon: Ic.ReopenIcon, onClick: () => void reopenConversation(mission) }] : []),
      { kind: "item", label: "Move", icon: Ic.CutIcon, onClick: () => startMoveSelection(mission.id) },
      { kind: "item", label: "Rename", icon: Ic.PencilIcon, onClick: () => beginMissionRename(mission) },
      ...(canShare ? [{ kind: "item" as const, label: "Share…", icon: Ic.UsersIcon, onClick: () => { setMissionMenu(null); setShareDialogMission(mission); } }] : []),
      { kind: "item", label: "Copy mission ID", icon: Ic.CopyIcon, onClick: () => void copyMissionId(mission) },
      { kind: "item", label: "Mission settings", icon: Ic.SlidersIcon, onClick: () => { setMissionMenu(null); p.open(`ms:${mission.id}`); } },
      ...(isArchivable(mission.status)
        ? [{ kind: "item" as const, label: "Archive", icon: Ic.ArchiveIcon, onClick: () => void archiveConversation(mission) }]
        : []),
    ];
  };
  /** Right-click handler shared by every agent row. Suppresses the native menu
   * and the sidebar-wide one without opening a different conversation. */
  const onMissionContext = (e: MouseEvent, mission: Mission, treeId = `m:${mission.id}`, slug = mission.project ?? "", folder = missionFolder(mission)) => {
    e.preventDefault();
    e.stopPropagation();
    if (deletingIds().has(mission.id)) return;
    setActionMenu(null);
    setArchiveMenu(null);
    setControllerMenu(null);
    setFileMenu(null);
    setMultiSelectMenu(null);
    setForkTarget(null);
    const group = contextSelectRow(treeId);
    if (!group.length) return;
    if (group.length > 1 && group.some(id => !missionIdFromTreeId(id))) {
      setMultiSelectMenu({ x: e.clientX, y: e.clientY, treeIds: group });
      return;
    }
    setMissionMenu({ x: e.clientX, y: e.clientY, mission, treeId, slug, folder });
  };
  let intentTimer: ReturnType<typeof setTimeout> | undefined;
  const cancelIntent = () => clearTimeout(intentTimer);
  const warmIntent = (slug: string, path?: string) => {
    cancelIntent();
    if (!cacheCanPrefetch()) return;
    intentTimer = setTimeout(() => {
      if (path === undefined) void warmupOne(slug);
      else void loadDir(slug, path);
    }, 100);
  };
  onCleanup(cancelIntent);
  const toggleProject = (slug: string) => {
    const next = !expanded[slug];
    setExpanded(slug, next);
    if (next) {
      // Paint the known conversations before the paged fetch returns, and
      // don't wait on that fetch before another project can open.
      if (missions[slug] === undefined) {
        const known = (p.activityMissions ?? []).filter(m => !isMissionParticipant(m) && (m.project ?? "") === slug);
        if (known.length) setMissions(slug, known);
      }
      void loadMissions(slug, { cached: true });
      void loadDir(slug, "");
      void loadController(slug, false);
      void loadCrons(slug);
    }
  };

  const toggleDir = (slug: string, path: string) => {
    const key = `${slug}:${path}`;
    const next = !expanded[key];
    setExpanded(key, next);
    if (next) loadDir(slug, path);
  };

  const performCutOrCopy = (treeId: string, copy: boolean, clipboardData?: DataTransfer | null): boolean => {
    const row = findNodeById(treeId);
    if (!row) return false;
    const group = selectionActive() && selectedTreeSet().has(treeId) ? selectedTreeFor(treeId) : [treeId];
    if (group.length > 1) {
      if (copy && group.some(tid => !tid.startsWith("pf:"))) return false;
      void copySelectedItems(group, copy, clipboardData);
      return true;
    }
    if (row.kind === "file" || row.kind === "folder") {
      void copyFile(row.slug, row.path!, copy, row.kind === "folder", clipboardData);
      return true;
    }
    if (!copy && row.kind === "cron" && !row.controller && row.job?.id) {
      void startCutCron(row.slug, row.job.id, row.label, row.job.folder ?? "", clipboardData);
      return true;
    }
    if (!copy && row.mission && !deletingIds().has(row.mission.id)) {
      startMoveSelection(row.mission.id, clipboardData);
      return true;
    }
    if (copy) {
      setCutId(null); setPendingMoves([]); setCutCron(null);
    }
    return false;
  };
  const applyPastePayload = (destSlug: string, destPath: string, text?: string): boolean => {
    if (pendingMoves().length > 1) {
      if (text) retireClipboardReference(text);
      pasteMission(destSlug, destPath);
      return true;
    }
    const localClip = fileClipboard();
    const hasActiveLocalFileClip = !!localClip && localClip !== consumedFileClipboard && !isClipboardReferenceRetired(localClip);
    if (hasActiveLocalFileClip && isUnsyncedClipboard(localClip)) {
      if (text && text !== localClip) retireClipboardReference(text);
      if (readItemsReference(localClip)) { void pasteItems(destSlug, destPath, localClip); return true; }
      if (readFileReference(localClip)) { void pasteFile(destSlug, destPath, localClip); return true; }
      if (readCronReference(localClip)) { void pasteCron(destSlug, destPath, localClip); return true; }
    }
    if (hasUnsyncedCutClipboard()) {
      if (text) retireClipboardReference(text);
      pasteMission(destSlug, destPath);
      return true;
    }
    if (text && !isClipboardReferenceRetired(text)) {
      if (readItemsReference(text)) { void pasteItems(destSlug, destPath, text); return true; }
      if (readFileReference(text)) { void pasteFile(destSlug, destPath, text); return true; }
      if (readCronReference(text)) { void pasteCron(destSlug, destPath, text); return true; }
      if (readCutMission(text, getApiUrl())) { pasteMission(destSlug, destPath, text); return true; }
    }
    if (hasActiveLocalFileClip) {
      if (readItemsReference(localClip)) { void pasteItems(destSlug, destPath, localClip); return true; }
      if (readFileReference(localClip)) { void pasteFile(destSlug, destPath, localClip); return true; }
      if (readCronReference(localClip)) { void pasteCron(destSlug, destPath, localClip); return true; }
    }
    if (cutCron()) { void pasteCron(destSlug, destPath); return true; }
    if (hasCutClipboard() || cutId()) {
      pasteMission(destSlug, destPath, text && !isClipboardReferenceRetired(text) ? text : undefined);
      return true;
    }
    return false;
  };
  const moveKey = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      const prevClip = fileClipboard();
      if (cutFile() || cutItems().length || readCronReference(prevClip)) {
        consumedFileClipboard = prevClip;
        retireClipboardReference(prevClip);
      } else if (isUnsyncedClipboard(prevClip)) {
        retireClipboardReference(prevClip);
      }
      setFileClipboard(""); syncToCommitted(); setPendingMoves([]); setCutId(null); setCutCron(null);
      return;
    }
    if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
    const target = event.target as HTMLElement;
    if (target.closest('input, textarea, [contenteditable="true"]')) return;
    const id = target.closest<HTMLElement>('.tree-entry')?.dataset.treeId;
    if (!id) return;
    const key = event.key.toLowerCase();
    if (key === "x" || key === "c") {
      if (performCutOrCopy(id, key === "c")) { event.preventDefault(); event.stopPropagation(); }
    } else if (key === "v") {
      const dest = resolveTreeDestination(id);
      if (!dest) return;
      event.preventDefault(); event.stopPropagation();
      const { slug: destSlug, path: destPath } = dest;
      if (pendingMoves().length > 1) { pasteMission(destSlug, destPath); return; }
      const version = connectionVersion();
      void navigator.clipboard.readText().then(text => {
        if (version !== connectionVersion()) return;
        const usable = isClipboardReferenceRetired(text) ? undefined : text;
        if (!applyPastePayload(destSlug, destPath, usable)) pasteMission(destSlug, destPath, usable);
      }, () => {
        // Clipboard read refused (no permission or gesture): fall back to in-app cuts.
        if (version !== connectionVersion()) return;
        if (!applyPastePayload(destSlug, destPath)) setActionError("Clipboard access was refused. Use Move here from the menu.");
      });
    }
  };
  const toggleArchives = () => {
    const open = !archivesOpen(); setArchivesOpen(open);
    if (open) {
      void loadArchives();
      for (const project of projects()) void loadController(project.slug);
    }
  };
  let dropTree:HTMLDivElement|undefined;
  let pointerPos: { x: number; y: number } | null = null;
  const [importing,setImporting]=createSignal(false),[importStatus,setImportStatus]=createSignal('');
  const [pendingLargeImport, setPendingLargeImport] = createSignal<{
    slug: string;
    folder: string;
    files: Array<{ source: UploadSource; size: number }>;
  } | null>(null);
  const dropContainerElement = (slug: string, folder: string): HTMLElement | undefined => {
    if (!dropTree) return undefined;
    const containerId = folder ? `pf:${slug}:${folder}` : `project:${slug}`;
    for (const entry of dropTree.querySelectorAll<HTMLElement>(".tree-entry")) {
      if (entry.dataset.treeId === containerId) return entry.querySelector<HTMLElement>("[data-drop-project]") ?? undefined;
    }
    return undefined;
  };
  const dropAt = (x: number, y: number): HTMLElement | undefined => {
    const hit = document.elementFromPoint(x, y);
    if (!hit || !dropTree?.contains(hit)) return undefined;
    const direct = hit.closest<HTMLElement>("[data-drop-project]");
    if (direct && dropTree.contains(direct)) return direct;
    const entry = hit.closest<HTMLElement>(".tree-entry");
    const dest = entry?.dataset.treeId ? resolveTreeDestination(entry.dataset.treeId) : null;
    return dest ? dropContainerElement(dest.slug, dest.path) : undefined;
  };
  const rowToDragSource = (treeId: string): DragSourceItem | null => {
    const row = findNodeById(treeId, tree());
    if (!row) return null;
    if (row.kind === "mission" && row.mission && !deletingIds().has(row.mission.id)) {
      return { treeId, kind: 0, srcSlug: row.mission.project ?? row.slug, srcPath: missionFolder(row.mission), srcParent: "", label: row.label };
    }
    if (row.kind === "folder" && row.path) {
      return { treeId, kind: 1, srcSlug: row.slug, srcPath: row.path, srcParent: fileParent(row.path), label: row.label };
    }
    if (row.kind === "file" && row.path) {
      return { treeId, kind: 2, srcSlug: row.slug, srcPath: row.path, srcParent: fileParent(row.path), label: row.label };
    }
    if (row.kind === "cron" && !row.controller && row.job?.id) {
      return { treeId, kind: 3, srcSlug: row.slug, srcPath: row.job.folder ?? "", srcParent: "", label: row.label };
    }
    return null;
  };
  const executeMoveSources = (sources: readonly DragSourceItem[], destSlug: string, destPath: string) => {
    if (!isGroupMoveAdmitted(rowDrag.ords, sources, destSlug, destPath)) return;
    const items = sources.map(s => treeIdToClipboardItem(s.treeId)).filter((x): x is ClipboardItem => !!x);
    if (!items.length) return;
    if (items.every(i => i.kind === "mission")) {
      const ids = [...new Set(items.map(i => (i as { kind: "mission"; id: string }).id))];
      const known = allKnownMissions();
      const plan = planMissionMoves(ids, destSlug, destPath, known);
      const changed = plan.some(step => {
        const m = known.find(x => x.id === step.id);
        return !m || (m.project ?? "") !== destSlug || missionFolder(m) !== step.folder;
      });
      if (changed) moveDirect(ids, destSlug, destPath);
      return;
    }
    if (items.length === 1 && items[0].kind === "cron") {
      const c = items[0];
      if (!movingCron()) {
        setMovingCron(true); setActionError(null);
        void performMoveCron(c.slug, c.id, destSlug, destPath)
          .catch(err => setActionError(`Couldn’t move cron: ${err instanceof Error ? err.message : String(err)}`))
          .finally(() => setMovingCron(false));
      }
      return;
    }
    void pasteItems(destSlug, destPath, makeItemsReference(items, false));
  };
  const warmProjectFolders = async (slug: string) => {
    await Promise.all([loadDir(slug, ""), loadMissions(slug, { transcripts: false, cached: true }), loadCrons(slug)]);
    for (const entry of dirs[`${slug}:`] ?? []) {
      if (entry.kind === "dir" && entry.name !== "attachments") void loadDir(slug, entry.name);
    }
  };
  const knownFoldersForProject = (slug: string): string[] => {
    const found = new Set<string>();
    const walk = (dirPath: string) => {
      const away = filesMovedAway(slug, dirPath);
      const list = [...(dirs[`${slug}:${dirPath}`] ?? []).filter(e => !away.has(e.name) && !(dirPath === "" && e.name === "attachments"))];
      for (const arriving of filesMovedInto(slug, dirPath)) {
        if (!list.some(e => e.name === arriving.name)) list.push(arriving);
      }
      for (const entry of list) {
        if (entry.kind !== "dir") continue;
        const full = dirPath ? `${dirPath}/${entry.name}` : entry.name;
        if (!found.has(full)) { found.add(full); walk(full); }
      }
    };
    walk("");
    const extraPaths = [
      ...(missions[slug] ?? []).filter(m => !isArchived(m)).map(missionFolder),
      ...(crons[slug] ?? []).map(j => j.folder ?? ""),
    ];
    for (const raw of extraPaths) {
      const parts = raw.split("/").filter(Boolean);
      for (let i = 1; i <= parts.length; i++) found.add(parts.slice(0, i).join("/"));
    }
    return [...found].sort((a, b) => a.localeCompare(b));
  };
  const currentContainerKey = (sources: readonly DragSourceItem[]): string | undefined => {
    if (!sources.length) return undefined;
    const keyOf = (s: DragSourceItem) => `${s.srcSlug}:${s.kind === 1 || s.kind === 2 ? s.srcParent : s.srcPath}`;
    const first = keyOf(sources[0]!);
    return sources.every(s => keyOf(s) === first) ? first : undefined;
  };
  const movePickerItems = (sources: readonly DragSourceItem[]): PickerItem[] => {
    const out: PickerItem[] = [];
    for (const proj of projects()) {
      const projTitle = proj.title || proj.slug;
      out.push({
        id: `${proj.slug}:`,
        label: projTitle,
        description: "Project root",
        group: projTitle,
        disabled: !isGroupMoveAdmitted(rowDrag.ords, sources, proj.slug, ""),
        icon: <SidebarIcon.Folder size={14} />,
      });
      for (const folderPath of knownFoldersForProject(proj.slug)) {
        const selfSubtree = sources.some(s =>
          s.kind === 1 && s.srcSlug === proj.slug && (folderPath === s.srcPath || folderPath.startsWith(`${s.srcPath}/`)));
        if (selfSubtree) continue;
        out.push({
          id: `${proj.slug}:${folderPath}`,
          label: folderLabel(proj.slug, folderPath) || folderPath,
          description: folderPath.includes("/") ? `${projTitle} · ${folderPath}` : projTitle,
          group: projTitle,
          disabled: !isGroupMoveAdmitted(rowDrag.ords, sources, proj.slug, folderPath),
          icon: <SidebarIcon.Folder size={14} />,
        });
      }
    }
    return out;
  };
  const rowDrag = createSidebarRowDrag({
    getTreeEl: () => dropTree,
    resolveSources: (treeId) => {
      const primary = rowToDragSource(treeId);
      if (!primary) return [];
      const group = selectionActive() && selectedTreeSet().has(treeId) ? selectedTreeFor(treeId) : [treeId];
      const rest = group.filter(id => id !== treeId).map(rowToDragSource).filter((x): x is DragSourceItem => !!x);
      return [primary, ...rest];
    },
    resolveTargetAt: (x, y) => {
      const element = dropAt(x, y);
      const slug = element?.dataset.dropProject;
      if (!element || !slug) return undefined;
      const path = element.dataset.dropFolder ?? "";
      const collapsed = path ? !expanded[`${slug}:${path}`] : !expanded[slug];
      return { slug, path, collapsed, element };
    },
    expandContainer: (slug, path) => {
      if (path) {
        if (!expanded[`${slug}:${path}`]) {
          setExpanded(`${slug}:${path}`, true);
          void loadDir(slug, path);
        }
      } else if (!expanded[slug]) {
        toggleProject(slug);
      }
    },
    commitDrop: (sources, dstSlug, dstPath) => executeMoveSources(sources, dstSlug, dstPath),
    openMovePicker: (sources, anchor) => {
      setActionMenu(null); setMissionMenu(null); setArchiveMenu(null);
      setControllerMenu(null); setFileMenu(null); setMultiSelectMenu(null); setForkTarget(null);
      if (sources.length <= 1) syncToCommitted();
      setMovePicker({ sources, anchor, treeId: sources[0]!.treeId });
      for (const proj of projects()) void warmProjectFolders(proj.slug);
    },
    dismissTooltip: () => rowTip.hide(),
    onQuickTap: (treeId, entry) => {
      const row = findNodeById(treeId, tree());
      if (!row || (row.kind !== "project" && row.kind !== "folder")) return;
      entry.dataset.toggled = "1";
      if (row.kind === "project") toggleProject(row.slug);
      else toggleDir(row.slug, row.path ?? "");
      setTimeout(() => { delete entry.dataset.toggled; }, 0);
    },
  });
  onCleanup(() => rowDrag.cancel());
  onMount(() => {
    const editableTarget = (t: EventTarget | null) =>
      t instanceof Element && !!t.closest('input, textarea, [contenteditable="true"], [role="dialog"], dialog');
    const onCutOrCopy = (event: ClipboardEvent) => {
      if (!isSidebarActive() || editableTarget(event.target)) return;
      if (!(window.getSelection()?.isCollapsed ?? true)) return;
      const copy = event.type === "copy";
      const entryId = event.target instanceof Element ? event.target.closest<HTMLElement>(".tree-entry")?.dataset.treeId : undefined;
      const fallbackId = !entryId
        ? (selectionActive() ? (selectionAnchor() ?? [...(selectedRowIds() ?? [])][0]) : (!copy && p.selected()?.startsWith("m:") ? p.selected()! : undefined))
        : undefined;
      const treeId = entryId ?? fallbackId;
      if (treeId && performCutOrCopy(treeId, copy, event.clipboardData)) {
        event.preventDefault();
        event.stopPropagation();
      }
    };
    const onPasteEvent = (event: ClipboardEvent) => {
      if (!isSidebarActive() || editableTarget(event.target)) return;
      const entryId = event.target instanceof Element ? event.target.closest<HTMLElement>(".tree-entry")?.dataset.treeId : undefined;
      let dest = entryId ? resolveTreeDestination(entryId) : null;
      if (!dest) {
        const hoverEl = pointerPos ? dropAt(pointerPos.x, pointerPos.y) : undefined;
        if (hoverEl?.dataset.dropProject) dest = { slug: hoverEl.dataset.dropProject, path: hoverEl.dataset.dropFolder ?? "" };
        else if (selectionAnchor()) dest = resolveTreeDestination(selectionAnchor()!);
      }
      if (!dest) return;
      const text = event.clipboardData?.getData("text/plain") ?? "";
      if (applyPastePayload(dest.slug, dest.path, text)) {
        event.preventDefault();
        event.stopPropagation();
      }
    };
    document.addEventListener("cut", onCutOrCopy);
    document.addEventListener("copy", onCutOrCopy);
    document.addEventListener("paste", onPasteEvent);
    onCleanup(() => {
      document.removeEventListener("cut", onCutOrCopy);
      document.removeEventListener("copy", onCutOrCopy);
      document.removeEventListener("paste", onPasteEvent);
    });
  });
  const runImportFiles = async (slug: string, folder: string, sources: UploadSource[], confirmedLarge = false) => {
    const version = connectionVersion();
    setImporting(true); setImportStatus('Importing files to shared context…'); setActionError(null);
    try {
      const result = await importProjectFiles(slug, folder, sources, {
        confirmedLarge,
        onBackgroundStarted: () => {
          void loadDir(slug, folder, true);
        },
      });
      if (!currentConnection(version)) return;
      if (result.largeFiles?.length) {
        setPendingLargeImport({ slug, folder, files: result.largeFiles });
      }
      if (result.paths.length) {
        await loadDir(slug, folder, true);
        setExpanded(`${slug}:${folder}`, true);
        setImportStatus(
          confirmedLarge
            ? `Uploading ${result.paths.length} large file(s) in the background…`
            : `${result.paths.length} file(s) saved to shared context. Available with @; connected agents synchronize automatically.`,
        );
      } else {
        setImportStatus('');
      }
      if (result.warnings.length) setActionError(result.warnings.join('\n'));
    } catch (error) {
      setImportStatus('');
      setActionError(String(error));
    } finally {
      setImporting(false);
    }
  };
  const importFiles=async(sources:UploadSource[],target:HTMLElement)=>{
   if(importing()){setActionError('An import is already in progress. Wait before dropping more files.');return;}
   const slug=target.dataset.dropProject!,folder=target.dataset.dropFolder??'';
   await runImportFiles(slug, folder, sources, false);
  };
  nativeComposerDrop(()=>dropTree,importFiles,dropAt);
  // Navigation (fork, search, history) owns the current selection. An old
  // range selection must not keep highlighting a different conversation.
  createEffect(on(p.selected, selected => syncToCommitted(selected)));
  const activityMissionsSource = (): Mission[] => {
    const byId = new Map<string, Mission>();
    for (const m of Object.values(missions).flat()) byId.set(m.id, m);
    for (const m of p.activityMissions ?? []) {
      const prev = byId.get(m.id);
      byId.set(m.id, prev ? mergeMission(prev, m, "partial") : m);
    }
    const cur = currentMission();
    if (cur) {
      const prev = byId.get(cur.id);
      byId.set(cur.id, prev ? mergeMission(prev, cur, "partial") : cur);
    }
    return withMovedMissions([...byId.values()]);
  };
  const activity = createMemo(() => folderActivity(activityMissionsSource()));
  const scheduledActivity = createMemo(() => folderActivity(activityMissionsSource(), m => missionStatusPresentation(rowEffectiveStatus(m), undefined, m.continuation).tone === "scheduled"));
  // Observe identity/location, not every polling update. This also runs when a
  // restored conversation's metadata arrives after the initial selection.
  const currentLocation = createMemo(() => {
    const mission = currentMission();
    return mission?.project ? JSON.stringify([mission.id, mission.project, missionFolder(mission), isArchived(mission)]) : null;
  });
  let lastLoadedLocationKey = "";
  createEffect(on(connectionVersion, () => { lastLoadedLocationKey = ""; }, { defer: true }));
  createEffect(on(currentLocation, location => {
    if (!location) return;
    const [id, slug, folder, archived] = JSON.parse(location) as [string, string, string, boolean];
    const folderKey = `${slug}\0${folder}\0${archived ? 1 : 0}`;
    if (archived) {
      setArchivesOpen(true); setArchiveExpanded(slug, true);
      if (lastLoadedLocationKey !== folderKey) {
        lastLoadedLocationKey = folderKey;
        void loadArchives();
      }
      return;
    }
    setExpanded(slug, true);
    const parts = folder.split("/").filter(Boolean);
    for (let i = 1; i <= parts.length; i++) {
      const path = parts.slice(0, i).join("/");
      setExpanded(`${slug}:${path}`, true);
      if (dirs[`${slug}:${path}`] === undefined) {
        void loadDir(slug, path);
      }
    }
    const missionListed = missions[slug] !== undefined && missions[slug].some(m => m.id === id);
    if (!missionListed) {
      void loadMissions(slug);
    }
    if (dirs[`${slug}:`] === undefined) {
      void loadDir(slug, "");
    }
    lastLoadedLocationKey = folderKey;
  }));
  let hoverTranscriptTimer: ReturnType<typeof setTimeout> | undefined;
  const cancelHoverTranscript = () => {
    clearTimeout(hoverTranscriptTimer);
    hoverTranscriptTimer = undefined;
  };
  const scheduleHoverTranscript = (missionId: string) => {
    cancelHoverTranscript();
    hoverTranscriptTimer = setTimeout(() => {
      hoverTranscriptTimer = undefined;
      prefetchTranscript(missionId);
    }, 120);
  };
  onCleanup(cancelHoverTranscript);
  const currentParents = createMemo(() => {
    const mission = currentMission();
    if (!mission?.project || isArchived(mission)) return "";
    const parents: string[] = [], seen = new Set([mission.id]);
    const rows = missions[mission.project] ?? [];
    const leader = forkLeaders(rows.filter(m => !isArchived(m))).get(mission.id);
    let root = mission;
    if (leader && leader.id !== mission.id && !seen.has(leader.id)) {
      seen.add(leader.id);
      parents.push(`m:${leader.id}`);
      root = leader;
    }
    let parent = missionParent(root);
    while (parent && !seen.has(parent)) {
      seen.add(parent); parents.push(`m:${parent}`);
      const ancestor = rows.find(m => m.id === parent);
      if (ancestor) root = ancestor;
      parent = ancestor ? missionParent(ancestor) : undefined;
    }
    if (controllerRow(mission.project) && controllerLaunched(root)) parents.push(`c:${mission.project}`);
    return JSON.stringify([mission.id, parents]);
  });
  createEffect(on(currentParents, value => {
    if (!value) return;
    const [, parents] = JSON.parse(value) as [string, string[]];
    for (const id of parents) setExpanded(id, true);
  }));
  const launchedToggle = (row: TreeRow<RowData>, d: RowData) => launchedToggleView(row, d, { deleting: id => deletingIds().has(id), setExpanded: (id, open) => setExpanded(id, open) });
  const renderRow = (row: TreeRow<RowData>) => {
    const d = row.data;
    const contextMenu = (e: MouseEvent) => {
      e.preventDefault(); e.stopPropagation(); setMissionMenu(null); setArchiveMenu(null); setControllerMenu(null); setFileMenu(null); setMultiSelectMenu(null); setActionFocus(false);
      if (d.kind === "folder" && selectionActive() && selectedTreeSet().has(row.id) && selectedTreeFor(row.id).length > 1) {
        setMultiSelectMenu({ x: e.clientX, y: e.clientY, treeIds: selectedTreeFor(row.id) });
        return;
      }
      setActionMenu({ x: e.clientX, y: e.clientY, slug: d.slug, path: d.path ?? "" });
    };
    if (d.kind === "archive-project") return <button class="row archive-project-row" aria-expanded={row.expanded} onClick={() => setArchiveExpanded(d.slug, !archiveExpanded[d.slug])} onContextMenu={e => openArchiveMenu(e, d.slug)}>
      <span class="row-ico" style={{ color: projectColor(d.slug) ?? "var(--fg-3)" }}><Show when={row.expanded} fallback={<SidebarIcon.Folder />}><SidebarIcon.FolderOpen /></Show></span>
      <span class="row-label">{d.label}</span>
      <SidebarIcon.ChevronRight size={12} class={`history-chevron ${row.expanded ? "open" : ""}`} />
    </button>;
    if (d.kind === "project") return <div class={`row project ${isCurrentProject(d.slug) ? "contains-current" : ""}`} data-drop-project={d.slug} data-drop-folder={d.path ?? ""} onContextMenu={contextMenu}>
      <button type="button" class="row-main" aria-label={d.label} aria-expanded={row.expanded} onPointerEnter={() => warmIntent(d.slug)} onPointerLeave={cancelIntent} onFocus={() => warmIntent(d.slug)} onBlur={cancelIntent} onClick={e => { const entry = e.currentTarget.closest<HTMLElement>(".tree-entry"); if (entry?.dataset.toggled) { delete entry.dataset.toggled; return; } toggleProject(d.slug); }}>
        <FolderActivityIcon expanded={row.expanded} color={projectColor(d.slug)} count={activity().get(d.slug)?.get(d.path ?? "") ?? 0} scheduled={scheduledActivity().get(d.slug)?.get(d.path ?? "") ?? 0} />
        <span class="row-label">{d.label}</span>
        <Show when={!row.expanded && isCurrentProject(d.slug)}><span class="current-location-label">Open</span></Show>
      </button>
      <Show when={row.expanded}><ContextBadge slug={d.slug} compact/></Show>
      <button class="row-action" aria-label={`Project actions for ${d.label}`} title="Project actions"
        onPointerDown={e => setActionFocus(e.pointerType !== "mouse")}
        onKeyDown={e => { if (e.key === "Enter" || e.key === " ") setActionFocus(true); }}
        onClick={e => { e.stopPropagation(); e.currentTarget.focus({ preventScroll: true }); const box = e.currentTarget.getBoundingClientRect(); setActionMenu({ x: Math.max(8, box.right - 176), y: box.bottom + 4, slug: d.slug, path: "" }); }}><Ic.PlusIcon size={13} /></button>
    </div>;
    if (d.kind === "note") return <div class="row note" role="status" data-drop-project={d.slug} data-drop-folder={d.path??""}>{d.label}<Show when={d.path !== undefined && dirErrors[`${d.slug}:${d.path}`]}><button onClick={() => void loadDir(d.slug, d.path!, true)}>Retry</button></Show></div>;
    if (d.kind === "cron-error") return <div class="cron-unavailable row" role="status" title={cronUnsupported() ? "This backend does not support project crons yet. Update the backend, then check again. Existing project content is unchanged." : `Crons could not refresh. Cached jobs are retained. ${cronErrors[d.slug]}`}>
      <Ic.BellIcon size={12} /><button class="cron-status-label" onClick={() => setCronInfo(d.slug)}>{cronUnsupported() ? "Crons need backend update" : cronRetryable[d.slug] ? "Crons temporarily unavailable" : "Crons unavailable"}</button>
      <Show when={!cronUnsupported() && cronRetryable[d.slug]}><button class="cron-retry" aria-label="Retry crons" title="Retry crons" onClick={() => void loadCrons(d.slug, true)}>↻</button></Show>
    </div>;
    if (d.kind === "folder") {
      const folderTip = rowTip.bind(rowDetail(d.label));
      return <div class={`row folder ${(cutFile()?.slug === d.slug && cutFile()?.path === d.path) || isItemCut(row.id) ? "mission-cut" : ""} ${rowDrag.isLifted(row.id) ? "drag-source" : ""} ${(selectionActive() && selectedTreeSet().has(row.id)) || movePicker()?.treeId === row.id ? "active" : ""}`} data-drop-project={d.slug} data-drop-folder={d.path ?? ""} onContextMenu={contextMenu}>
        <button type="button" class="row-main" aria-label={d.label} aria-expanded={row.expanded} {...folderTip} onPointerEnter={e => { if (rowDrag.phase() === 0) folderTip.onPointerEnter(e); warmIntent(d.slug, d.path!); }} onPointerLeave={() => { folderTip.onPointerLeave(); cancelIntent(); }} onFocus={e => { folderTip.onFocus(e); warmIntent(d.slug, d.path!); }} onBlur={() => { folderTip.onBlur(); cancelIntent(); }} onClick={e => { const entry = e.currentTarget.closest<HTMLElement>(".tree-entry"); if (entry?.dataset.toggled) { delete entry.dataset.toggled; return; } if (e.metaKey || e.ctrlKey || e.shiftKey) clickSelectableRow(e, row.id, () => toggleDir(d.slug, d.path!)); else { setSelectionAnchor(row.id); toggleDir(d.slug, d.path!); } }}>
          <FolderActivityIcon expanded={row.expanded} color={projectColor(d.slug)} count={activity().get(d.slug)?.get(d.path ?? "") ?? 0} scheduled={scheduledActivity().get(d.slug)?.get(d.path ?? "") ?? 0} /><span class="row-label">{d.label}</span>
        </button>
        <button class="row-action" aria-label={`Folder actions for ${d.label}`} title="Folder actions"
          onPointerDown={e => setActionFocus(e.pointerType !== "mouse")}
          onKeyDown={e => { if (e.key === "Enter" || e.key === " ") setActionFocus(true); }}
          onClick={e => { e.stopPropagation(); e.currentTarget.focus({ preventScroll: true }); const box = e.currentTarget.getBoundingClientRect(); setActionMenu({ x: Math.max(8, box.right - 176), y: box.bottom + 4, slug: d.slug, path: d.path! }); }}><Ic.PlusIcon size={13} /></button>
      </div>;
    }
    if (d.kind === "cron") {
      const ticking = () => d.controller && (controllers[d.slug]?.runs ?? []).some(r => r.status === "running" || r.status === "claimed");
      const isCronCut = () => !d.controller && (cutCron()?.id === d.job?.id || readCronReference(fileClipboard())?.id === d.job?.id || isItemCut(row.id));
      const cronTip = rowTip.bind(rowDetail(d.label, [d.controller ? "Controller" : "Cron", d.job?.folder || undefined]));
      return <><button class={`row agent cron ${d.job?.archived ? "done" : ""} ${isCronCut() ? "mission-cut" : ""} ${rowDrag.isLifted(row.id) ? "drag-source" : ""} ${isRowActive(row.id) ? "active" : ""}`} aria-expanded={d.launched ? row.expanded : undefined} {...cronTip} onPointerEnter={e => { if (rowDrag.phase() === 0) cronTip.onPointerEnter(e); }} onClick={e => { if (!d.controller && d.job?.id) clickSelectableRow(e, row.id, () => p.open(row.id)); else p.open(row.id); }}
        onKeyDown={e => { if (d.launched && ((e.key === "ArrowRight" && !row.expanded) || (e.key === "ArrowLeft" && row.expanded))) { e.preventDefault(); e.stopPropagation(); setExpanded(row.id, !row.expanded); } }} onContextMenu={e => {
        e.preventDefault(); e.stopPropagation();
        setActionMenu(null); setMissionMenu(null); setArchiveMenu(null); setFileMenu(null); setMultiSelectMenu(null);
        if (!d.controller && d.job?.id) {
          const group = contextSelectRow(row.id);
          if (group.length > 1) {
            setMultiSelectMenu({ x: e.clientX, y: e.clientY, treeIds: group });
            return;
          }
        } else {
          syncToCommitted();
        }
        setControllerMenu({x:e.clientX,y:e.clientY,slug:d.slug,id:d.controller ? undefined : d.job?.id,name:d.label,folder:d.job?.folder ?? "",controller:!!d.controller,archived:!!d.job?.archived});
      }}>
        <span class="row-ico glyph"><CronGlyph job={d.job!} running={!!ticking()} /></span><span class="row-label">{d.label}</span>
        <span class="row-machine"><Show when={!d.job!.enabled || d.job!.state === "paused"} fallback={<span class="row-machine-name cron-next">{ticking() ? "ticking" : untilLabel(d.job!.next_run_at, Date.now())}</span>}>
          <span class="cron-paused-indicator" role="img" aria-label="Paused" title={ticking() ? "Paused · current run finishing" : "Paused"}><Ic.PauseIcon size={14} /></span>
        </Show></span>
      </button>{launchedToggle(row, d)}</>;
    }
    const deleting = () => d.mission ? deletingIds().has(d.mission.id) : false;
    const isMissionCut = () => !!d.mission && (!d.placeholder || !expanded[d.mission.project ?? ""]) && (d.mission.id === cutId() || pendingMoves().includes(d.mission.id) || isItemCut(row.id));
    const effectiveMissionStatus = () => d.mission ? rowEffectiveStatus(d.mission) : "";
    const tipDetail = () => rowDetail(d.label, [d.mission && isArchived(d.mission) ? [projects().find(project => project.slug === d.slug)?.title || d.slug, missionFolder(d.mission)].filter(Boolean).join(" / ") : undefined, d.mission ? missionMachine(d.mission) : undefined, d.mission?.backend, d.mission?.model_override, d.mission?.id, d.mission ? (deleting() ? "Deleting…" : missionStatusPresentation(effectiveMissionStatus(), pendingMissionInteraction(d.mission.id)).label) : undefined]);
    const tip = rowTip.bind(tipDetail());
    return <><button disabled={deleting()} aria-busy={deleting() ? true : undefined} aria-current={isSelectedRow(row.id) ? "page" : undefined} aria-expanded={d.launched || d.versions ? row.expanded : undefined}
      onKeyDown={e => { if (deleting()) return; if ((d.launched || d.versions) && ((e.key === "ArrowRight" && !row.expanded) || (e.key === "ArrowLeft" && row.expanded))) { e.preventDefault(); e.stopPropagation(); setExpanded(row.id, !row.expanded); } }}
      aria-description={d.mission ? (deleting() ? "Deleting…" : missionStatusPresentation(effectiveMissionStatus(), pendingMissionInteraction(d.mission.id)).label) : undefined} class={`row ${d.kind === "mission" ? "agent" : "file"} ${d.mission && pendingPlaceMoves().has(missionMoveKey(d.mission.id)) ? "mission-arriving" : ""} ${deleting() ? "mission-deleting" : ""} ${d.kind === "file" && ((cutFile()?.slug === d.slug && cutFile()?.path === d.path) || isItemCut(row.id)) ? "mission-cut" : ""} ${d.mission && !LIVE.has(effectiveMissionStatus()) ? "done" : ""} ${isMissionCut() ? "mission-cut" : ""} ${rowDrag.isLifted(row.id) ? "drag-source" : ""} ${!deleting() && isRowActive(row.id) ? "active" : ""}`} {...tip}
      onPointerEnter={e => { if (deleting()) return; if (rowDrag.phase() === 0) rowTip.bind(tipDetail()).onPointerEnter(e); if (d.mission) scheduleHoverTranscript(d.mission.id); else cachePrefetch(row.id, () => readProjectFile(d.slug, d.path!).then(text => cachePut(row.id, text))); }}
      onPointerLeave={() => { tip.onPointerLeave(); if (d.mission) cancelHoverTranscript(); }}
      onFocus={e => rowTip.bind(tipDetail()).onFocus(e)}
      onContextMenu={e => { if (d.mission) { if (deleting()) { e.preventDefault(); e.stopPropagation(); return; } const dest = resolveTreeDestination(row.id); onMissionContext(e, d.mission, row.id, dest?.slug ?? (isArchived(d.mission) ? "" : d.slug), dest?.path ?? ""); } else {
        e.preventDefault(); e.stopPropagation(); setActionMenu(null); setMissionMenu(null); setArchiveMenu(null); setControllerMenu(null); setMultiSelectMenu(null);
        const group = contextSelectRow(row.id);
        if (group.length > 1) {
          setMultiSelectMenu({ x: e.clientX, y: e.clientY, treeIds: group });
          return;
        }
        setFileMenu({ slug: d.slug, path: d.path!, x: e.clientX, y: e.clientY });
      } }} onClick={e => { if (d.mission) { if (deleting()) return; clickAgent(e, d.mission.id, row.id); } else { clickSelectableRow(e, row.id, () => p.open(row.id)); } }}>
      <span class={`row-ico glyph ${d.mission ? "mission-lead" : ""}`}><Show when={d.mission} fallback={<Ic.FileIcon />}>{m => <Show when={isArchived(m())} fallback={<MissionGlyph missionId={m().id} status={rowEffectiveStatus(m())} unread={isMissionUnread(m(), isCurrentMissionId(m().id) ? m().id : undefined, Boolean(pendingMissionInteraction(m().id)))} continuation={m().continuation} identity={m().backend?.startsWith("cloud_") ? <ProviderLogo type={m().backend!} /> : undefined} />}><SidebarIcon.MessageCircle size={15} /></Show>}</Show></span>
      <span class="row-label">{d.label}</span><Show when={d.version}><span class="row-version-tag">earlier</span></Show><Show when={!d.launched && !d.versions}><MachineBadge name={d.mission ? missionMachine(d.mission) : undefined} /></Show>
    </button>
    {launchedToggle(row, d)}</>;
  };

  return (
    <>
      <Show when={sharedWithMeMissions().length > 0}>
        <div class="section" data-testid="shared-with-me-section">Shared with me</div>
        <div class="sb-shared-list">
          <For each={sharedWithMeMissions()}>
            {m => (
              <button
                type="button"
                class={`row agent ${!LIVE.has(m.status) ? "done" : ""} ${isSelectedRow(`m:${m.id}`) ? "active" : ""}`}
                aria-current={isSelectedRow(`m:${m.id}`) ? "page" : undefined}
                onClick={() => p.open(`m:${m.id}`)}
                onContextMenu={e => onMissionContext(e, m, `m:${m.id}`, "", "")}
              >
                <span class="row-ico glyph mission-lead">
                  <MissionGlyph
                    missionId={m.id}
                    status={presentedStatus(m)}
                    unread={isMissionUnread(m, isCurrentMissionId(m.id) ? m.id : undefined, Boolean(pendingMissionInteraction(m.id)))}
                    continuation={m.continuation}
                    identity={m.backend?.startsWith("cloud_") ? <ProviderLogo type={m.backend!} /> : undefined}
                  />
                </span>
                <span class="row-label">{m.title || "Untitled conversation"}</span>
                <Show when={m.owner_username}>
                  <span class="row-machine">
                    <span class="row-machine-name">@{m.owner_username}</span>
                  </span>
                </Show>
              </button>
            )}
          </For>
        </div>
      </Show>
      <div class="section section-row">
        <span>Projects</span>
        <button class="section-add" title="New project" onClick={e => { e.currentTarget.focus(); p.onNewProject(e.currentTarget); }}>
          <Ic.PlusIcon size={13} />
        </button>
      </div>
      <Show when={error()}>
        <div class="row note">{error()} <button class="text-btn" onClick={() => refresh(true)}>Retry</button></div>
      </Show>
      <ErrorToast error={cronWarning()} onDismiss={() => setCronWarning(null)} />
      <ErrorToast error={!deleteTargets().length ? actionError() : null} title="This action couldn’t be completed" onDismiss={() => setActionError(null)} />
      <Show when={importStatus()}><div class="row note" role="status">{importStatus()}</div></Show>
      <For each={backgroundUploads().filter(t => t.scope?.startsWith("project:"))}>
        {task => {
          const pct = () => Math.min(100, Math.round((task.uploadedBytes / Math.max(1, task.totalBytes)) * 100));
          return (
            <div class="row note bg-upload-sidebar-row" role="status">
              <div class="bg-upload-sidebar-main">
                <span class="bg-upload-sidebar-name" title={task.name}>{task.name}</span>
                <span class="bg-upload-sidebar-meta">
                  {task.state === "completed"
                    ? "Synced ✓"
                    : task.state === "paused"
                      ? `Paused · ${pct()}%`
                      : task.state === "failed"
                        ? "Failed"
                        : `${pct()}%${task.speedBps > 0 ? ` · ${formatFileSize(task.speedBps)}/s` : ""}`}
                </span>
                <Show when={task.state === "uploading"}>
                  <button type="button" class="text-btn" onClick={() => pauseBackgroundUpload(task.id)}>Pause</button>
                </Show>
                <Show when={task.state === "paused" || task.state === "failed"}>
                  <button type="button" class="text-btn" onClick={() => resumeBackgroundUpload(task.id)}>Resume</button>
                </Show>
                <Show when={task.state !== "completed"}>
                  <button type="button" class="text-btn" onClick={() => cancelBackgroundUpload(task.id)}>×</button>
                </Show>
              </div>
              <div class="bg-upload-bar"><span style={{ width: `${pct()}%` }} /></div>
            </div>
          );
        }}
      </For>
      <div ref={dropTree} onPointerDown={rowDrag.onPointerDown} onPointerMove={e => { pointerPos = { x: e.clientX, y: e.clientY }; }} onPointerLeave={() => { pointerPos = null; }} onDragOver={e=>{if(!Array.from(e.dataTransfer?.types??[]).includes('Files'))return;e.preventDefault();const target=dropAt(e.clientX,e.clientY);dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));target?.classList.add('drop-active');if(e.dataTransfer)e.dataTransfer.dropEffect=target?'copy':'none';}} onDragLeave={e=>{if(!dropTree?.contains(e.relatedTarget as globalThis.Node))dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));}} onDrop={e=>{e.preventDefault();e.stopPropagation();dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));const target=dropAt(e.clientX,e.clientY);if(target)void importFiles(Array.from(e.dataTransfer?.files??[]).map(file=>({name:file.name,file})),target);}} onKeyDown={moveKey}><SidebarTree nodes={tree()} label="Projects" selected={p.selected()} selectedIds={selectedRowIds()} render={renderRow} /></div>
      <Show when={projectsLoading() && projects().length === 0 && !error()}>
        <div class="sidebar-projects-skeleton" role="status" aria-label="Loading projects">
          <div class="row note sidebar-skel-row"><span class="sk-bar sidebar-sk-bar w1" /></div>
          <div class="row note sidebar-skel-row"><span class="sk-bar sidebar-sk-bar w2" /></div>
          <div class="row note sidebar-skel-row"><span class="sk-bar sidebar-sk-bar w3" /></div>
        </div>
      </Show>
      <Show when={!projectsLoading() && projects().length === 0 && !error()}>
        <div class="row note">No projects on the core backend.</div>
      </Show>
      <button class="section archive-section-toggle" aria-expanded={archivesOpen()} aria-controls="sidebar-archives" onClick={toggleArchives} onContextMenu={e => openArchiveMenu(e)}>
        <span class="archive-section-label">Archived</span>
        <Show when={(archivesLoading() && archivesOpen()) || archivedMissions().some(m => deletingIds().has(m.id))}><span class="archive-loading-icon" aria-hidden="true"><Ic.Spinner size={13} /></span></Show>
        <span class="archive-section-chevron"><SidebarIcon.ChevronRight size={12} class={`history-chevron ${archivesOpen() ? "open" : ""}`} /></span>
      </button>
      <Show when={archivesOpen()}>
        <div id="sidebar-archives" aria-busy={archivesLoading()} onKeyDown={moveKey} onContextMenu={e => openArchiveMenu(e)}>
          <SidebarTree nodes={archiveNodes()} label="Archived conversations" selected={p.selected()} selectedIds={selectedRowIds()} render={renderRow} />
          <Show when={archivesLoading()}><span class="archive-loading-announcement" role="status">Loading archives</span></Show>
          <ErrorToast error={archivesOpen() && archivesError() ? `Couldn’t load archives: ${archivesError()}` : null} title="Couldn’t load archives" background action={{ label: "Retry", run: () => loadArchives() }} />
          <Show when={archivesError()}><div class="row note">Archives could not be loaded.</div></Show>
          <Show when={!archivesLoading() && !archivesError() && !archiveNodes().length}><div class="row note">No archived conversations.</div></Show>
          <Show when={archivesMore()}><button class="row note" disabled={archivesLoading()} onClick={() => void loadArchives(true)}>Load older conversations</button></Show>
        </div>
      </Show>
      <Show when={stopPrompt()}>{prompt => (
        <ConfirmDialog title={`${prompt().workers} worker${prompt().workers === 1 ? " is" : "s are"} still running`} destructive action="Stop and delete"
          description={`Stop ${prompt().workers === 1 ? "it" : "them"} and delete ${prompt().roots.length === 1 ? "the conversation" : `the ${prompt().roots.length} conversations`}? Stopping ends the running work. ${descendantsSentence(deleteList(prompt().roots))} Their history is deleted too.`}
          busy={false} error={null} onConfirm={confirmStopAndDelete} onClose={() => setStopPrompt(null)}/>
      )}</Show>
      <Show when={deleteTargets().length}>
        <ConfirmDialog title={`Delete ${deleteTargets().length} agent${deleteTargets().length === 1 ? "" : "s"}?`} destructive
          action={deleteList(deleteTargets()).length ? `Delete ${deleteTargets().length + deleteList(deleteTargets()).length} sessions` : "Delete"}
          description={deleteList(deleteTargets()).length
            ? `${descendantsSentence(deleteList(deleteTargets()))} Their history and workspace files are permanently deleted with ${deleteTargets().length === 1 ? "it" : "them"}.`
            : "This permanently deletes the selected conversations and their workspace files."}
          busy={deleteConfirmBusy()} error={actionError()} onConfirm={() => void deleteSelected()} onClose={() => {setActionError(null);setDeleteTargets([]);}}/>
      </Show>
      <Show when={pendingLargeImport()} keyed>{pending => (
        <ConfirmDialog
          title={`Upload large file${pending.files.length === 1 ? "" : "s"} to shared context?`}
          destructive={false}
          action="Upload in background"
          description={`${pending.files.map(f => `${f.source.name} (${formatFileSize(f.size)})`).join(", ")} exceed${pending.files.length === 1 ? "s" : ""} the 10 MB default sync limit. Confirm to upload ${pending.files.length === 1 ? "it" : "them"} in the background using resumable chunks so you can keep working and resume if interrupted.`}
          busy={importing()}
          onConfirm={() => {
            const target = pending;
            setPendingLargeImport(null);
            void runImportFiles(target.slug, target.folder, target.files.map(f => f.source), true);
          }}
          onClose={() => setPendingLargeImport(null)}
        />
      )}</Show>
      <Show when={archiveMenu()} keyed>{menu => <PopupMenu x={menu.x} y={menu.y} focus={false} items={archiveDeleteMenuItems(menu.slug)} onClose={() => setArchiveMenu(null)} />}</Show>
      <Show when={multiSelectMenu()} keyed>{menu => <PopupMenu x={menu.x} y={menu.y} focus={false} items={multiSelectMenuItems(menu.treeIds)} onClose={() => setMultiSelectMenu(null)} />}</Show>
      <Show when={controllerMenu()} keyed>{menu => {
        const paste = !menu.archived ? pasteMenuEntries(menu.slug, menu.folder ?? "") : [];
        return <PopupMenu x={menu.x} y={menu.y} focus={false} items={[
          ...(paste.length ? [...paste, { kind: "sep" as const }] : []),
          ...(menu.controller ? [{kind:"item" as const,label:menu.archived ? "Restore" : "Archive",icon:menu.archived ? Ic.ReopenIcon : Ic.ArchiveIcon,onClick:()=>void archiveController(menu.slug,menu.archived)},{kind:"sep" as const}] : []),
          ...(!menu.controller && menu.id ? [
            {kind:"item" as const,label:"Move",icon:Ic.CutIcon,onClick:()=>void startCutCron(menu.slug,menu.id!,menu.name,menu.folder ?? "")},
            {kind:"sep" as const},
          ] : []),
          {kind:"item",label:"Delete…",icon:Ic.TrashIcon,danger:true,onClick:()=>{setControllerMenu(null);setDeleteCronError(null);setDeleteCronTarget({slug:menu.slug,id:menu.id,name:menu.name,controller:menu.controller});}}
        ]} onClose={()=>setControllerMenu(null)} />;
      }}</Show>
      <Show when={deleteCronTarget()} keyed>{target => {
        const count = target.items && target.items.length > 1 ? target.items.length : 1;
        return (
          <ConfirmDialog destructive
            title={count > 1 ? `Delete ${count} crons?` : "Delete cron?"}
            description={
              count > 1
                ? `Delete ${count} crons from Hermes? This cannot be undone.`
                : `Delete ${target.name} from Hermes? This cannot be undone.`
            }
            action="Delete"
            busy={deletingCron()}
            error={deleteCronError()}
            onConfirm={() => void confirmDeleteCron()}
            onClose={() => !deletingCron() && setDeleteCronTarget(null)}
          />
        );
      }}</Show>
      <Show when={fileMenu()} keyed>{menu => {
        const paste = pasteMenuEntries(menu.slug, fileParent(menu.path));
        const itemBusy = () => isFilePathPending(menu.slug, menu.path);
        return <PopupMenu x={menu.x} y={menu.y} focus={false} onClose={() => setFileMenu(null)} items={[
          ...(paste.length ? [...paste, { kind: "sep" as const }] : []),
          { kind: "item", label: "Rename", icon: Ic.PencilIcon, disabled: itemBusy(), onClick: () => beginFileAction(menu.slug, menu.path, "rename") },
          { kind: "item", label: "Move…", icon: Ic.FolderIcon, disabled: itemBusy(), onClick: () => beginFileAction(menu.slug, menu.path, "move") },
          { kind: "sep" },
          { kind: "item", label: "Cut", icon: Ic.CutIcon, disabled: itemBusy(), onClick: () => void copyFile(menu.slug, menu.path, false) },
          { kind: "item", label: "Copy", icon: Ic.CopyIcon, disabled: itemBusy(), onClick: () => void copyFile(menu.slug, menu.path, true) },
          { kind: "sep" },
          { kind: "item", label: "Delete…", icon: Ic.TrashIcon, danger: true, disabled: itemBusy(), onClick: () => beginFileAction(menu.slug, menu.path, "delete") },
        ]} />;
      }}</Show>
      <Show when={fileAction()} keyed>{target => {
        const actionPending = () => isFilePathPending(target.slug, target.path);
        return <Show when={target.kind === "delete"} fallback={
          <NameDialog allowEmpty={target.kind === "move"} title={`${target.kind === "rename" ? "Rename" : "Move"} ${target.directory ? "folder" : "file"}`} hint={target.kind === "move" ? "Destination folder within this project. Leave empty for the project root." : target.directory ? `${target.path} — its files, agents and crons keep their place inside.` : target.path}
            label={target.kind === "rename" ? (target.directory ? "Folder name" : "File name") : "Destination folder"} value={fileActionValue()} onInput={setFileActionValue}
            action={target.kind === "rename" ? "Rename" : "Move"} busy={actionPending()} error={fileActionError()}
            disabled={(target.kind === "rename" && !fileActionValue().trim()) || actionPending()} onAction={() => void saveFileAction()} onClose={() => !actionPending() && setFileAction(null)} />
        }><ConfirmDialog destructive title={target.directory ? "Delete folder?" : "Delete file?"} description={target.directory ? `Delete ${target.path} and all files and subfolders inside? This cannot be undone.` : `Delete ${target.path}?`} action="Delete" busy={actionPending()} error={fileActionError()} onConfirm={() => void saveFileAction()} onClose={() => !actionPending() && setFileAction(null)} /></Show>;
      }}</Show>
      <Show when={actionMenu()}>
        {(menu) => <PopupMenu {...menu()} focus={actionFocus()} items={menuItems(menu().slug, menu().path)} onClose={() => setActionMenu(null)} />}
      </Show>
      <Show when={missionMenu()}>
        {(menu) => <PopupMenu x={menu().x} y={menu().y} focus={false} items={missionMenuItems(menu().mission, menu().slug, menu().folder)} onDismissSubmenu={() => setForkTarget(null)} onClose={() => { setForkTarget(null); setMissionMenu(null); }}>
          <Show when={forkTarget()}>{target =>
            <Suspense><ForkMission mission={target().mission} choices={p.forkChoices?.(target().mission) ?? p.harnessChoices} onOpen={() => p.onForkOpen?.(target().mission)} destination={missionDestination(target().mission)}
              anchor={target().anchor} onClose={() => setForkTarget(null)}
              onFork={mission => { setForkTarget(null); setMissionMenu(null); p.onFork(mission); }} /></Suspense>
          }</Show>
        </PopupMenu>}
      </Show>
      <Show when={shareDialogMission()}>
        {m => (
          <Suspense>
            <ShareMissionDialog mission={m()} onClose={() => setShareDialogMission(null)} />
          </Suspense>
        )}
      </Show>
      <Show when={rowDrag.pill()}>
        {pill => (
          <Portal>
            <div class="sidebar-drag-pill" role="status" aria-live="polite" style={{ transform: `translate3d(${pill().x + 12}px, ${pill().y + 12}px, 0)` }}>
              <span class="sidebar-drag-pill-label">{pill().label}</span>
              <Show when={pill().count > 1}><span class="sidebar-drag-pill-count">+{pill().count - 1}</span></Show>
            </div>
          </Portal>
        )}
      </Show>
      <Show when={movePicker()} keyed>
        {mp => (
          <Picker
            label="Move to"
            searchLabel="Move to project or folder"
            anchor={mp.anchor}
            placement="right-start"
            width={260}
            items={movePickerItems(mp.sources)}
            selected={currentContainerKey(mp.sources)}
            onSelect={id => {
              const sep = id.indexOf(":");
              const slug = sep >= 0 ? id.slice(0, sep) : id;
              const path = sep >= 0 ? id.slice(sep + 1) : "";
              setMovePicker(null);
              executeMoveSources(mp.sources, slug, path);
            }}
            onClose={() => setMovePicker(null)}
          />
        )}
      </Show>
      {rowTip.surface}
      <Show when={rename()}>
        {(target) => (
          <NameDialog
            title={"missionId" in target() ? "Rename agent" : "path" in target() ? "Rename folder" : "Rename project"}
            hint={"path" in target() ? "Display name saved on this device. Files and agent paths stay the same." : "slug" in target() ? (target() as { slug: string }).slug : undefined}
            label={"missionId" in target() ? "Mission name" : "path" in target() ? "Folder name" : "Project name"}
            placeholder={"missionId" in target() ? "Mission name" : "path" in target() ? "Folder name" : "Project name"}
            value={renameValue()}
            onInput={setRenameValue}
            action="Rename"
            disabled={!renameValue().trim()}
            error={renameError()}
            onAction={() => void saveRename()}
            onClose={() => setRename(null)}
          />
        )}
      </Show>
      <Show when={newFolder()}>
        {(target) => (
          <NameDialog
            title="New folder"
            hint={`in ${target().path ? `${target().slug}/${target().path}` : target().slug}`}
            label="Folder name"
            placeholder="Folder name"
            value={folderName()}
            onInput={setFolderName}
            action="Create"
            busy={makingFolder()}
            disabled={!folderName().trim()}
            error={folderError()}
            onAction={() => void createFolder()}
            onClose={() => !makingFolder() && setNewFolder(null)}
          />
        )}
      </Show>
      <Show when={newFile()}>
        {(target) => (
          <NameDialog
            title="New file"
            hint={`in ${target().path ? `${target().slug}/${target().path}` : target().slug}`}
            label="File name"
            placeholder={`notes${REFERENCE_FILE_EXT}`}
            value={fileName()}
            onInput={setFileName}
            action="Create"
            busy={makingFile()}
            disabled={!fileName().trim()}
            error={fileError()}
            onAction={() => void createFile()}
            onClose={() => !makingFile() && setNewFile(null)}
            footer={<span>Markdown by default — a name with no extension gets {REFERENCE_FILE_EXT}.</span>}
          />
        )}
      </Show>
      <Show when={approvalTransferPrompt()}>
        {(prompt) => (
          <Suspense>
            <ApprovalTransferDialog prompt={prompt()} onDismiss={() => setApprovalTransferPrompt(null)} />
          </Suspense>
        )}
      </Show>
      <Show when={cronInfo()}>{(slug) => <Dialog title="Project crons" onClose={() => setCronInfo(null)} footer={<><DialogButton disabled={cronChecking()} onClick={async () => { if (!isConnected()) return; const version = connectionVersion(); setCronChecking(true); await loadCrons(slug(), true); if (!currentConnection(version)) return; setCronChecking(false); if (!cronUnsupported() && !cronErrors[slug()]) setCronInfo(null); }}>Check again</DialogButton></>}>
        <p>{cronUnsupported() ? "This backend does not support project crons yet. Update the connected backend, then choose Check again. Your canonical controller and existing project content remain available." : cronRetryable[slug()] ? "Project crons could not refresh. Previously loaded jobs are retained. Try again when the scheduler is available." : "The backend rejected this cron request. Check backend access and configuration, then check again. Previously loaded jobs are retained."}</p>
      </Dialog>}</Show>
      <Show when={newCron()}>
        {(slug) => <Dialog size="wide" busy={makingCron()} title={cronFolder() ? `New cron · ${cronFolder()}` : "New cron"} onClose={() => !makingCron() && setNewCron(null)}>
          <CronForm creating deliveryRoute={{ ready: cronDefaults()?.route_ready ?? false, loading: !cronDefaults() && !defaultsError(), error: defaultsError() }} onBusyChange={setMakingCron} draftKey={`create:${slug()}:${cronFolder()}`} view={{ slug: slug(), job: { id: "", name: "", schedule: "every 1h", enabled: true, failure_streak: 0 }, runs: [] }}
            save={async (draft) => getProjectCronFromJob(slug(), await createProjectCron(slug(), { ...draft, folder: cronFolder() }))}
            onClose={() => setNewCron(null)} onSaved={(view, warning) => {
              setCronWarning(warning ? `Cron created. ${warning}` : null);
              setExpanded(slug(), true);
              loadDir(slug(), "", true);
              loadMissions(slug());
              loadController(slug());
              loadCrons(slug(), true);
              p.open(`pc:${slug()}:${view.job!.id}`);
              setNewCron(null);
            }} />
        </Dialog>}

      </Show>
    </>
  );
}

/** Markdown view/editor for a file hosted on the core backend. Autosaves. */
export function ProjectFileView(p: { slug: string; path: string }) {
  const fileKey = () => `pf:${p.slug}:${p.path}`;
  const cached = cachePeek<string>(fileKey());
  const [text, setText] = createSignal<string | null>(cached ?? null);
  // Shared with the ⌘/ handler in App.tsx; the button and the shortcut drive
  // the same state, so they can never disagree.
  const editing = mdSource;
  const setEditing = setMdSource;
  const [state, setState] = createSignal<"loading" | "saved" | "saving" | "error">(cached != null ? "saved" : "loading");
  const [error, setError] = createSignal<string | null>(null);
  let revision: number | undefined;
  let saving = false;
  let halted = false;
  let saveTimer: ReturnType<typeof setTimeout> | undefined;
  cacheRemember(fileKey());

  let invalidated=false;
  let editVersion=0;
  const reload = () => {const version=editVersion;return readProjectFileVersion(p.slug,p.path).then(row=>{if(version!==editVersion || pending!==null || saving)return;revision=row.revision;setText(row.content);cachePut(fileKey(),row.content);setState("saved");setError(null);halted=false;}).catch(e=>{setError(String(e));setState("error");});};
  onMount(() => {
    void reload();
    const stop=subscribeProjectContext(p.slug,()=>{invalidated=true;if(pending===null&&!saving&&!halted&&!editing()){invalidated=false;void reload();}},failure=>setError(String(failure)));
    onCleanup(stop);
  });
  let pending: string | null = null;
  createEffect(()=>{if(!editing()&&invalidated&&pending===null&&!saving&&!halted){invalidated=false;void reload();}});
  const flush = () => {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = undefined;
    if (pending === null || saving || halted) return;
    saving = true;
    const t = pending;
    pending = null;
    writeProjectFile(p.slug, p.path, t, revision)
      .then(result => { revision=result.revision; cachePut(fileKey(), t); setState(pending === null ? "saved" : "saving"); })
      .catch((e) => {
        halted = true;
        if (pending === null) pending = t;
        setError(e instanceof Error ? e.message : String(e));
        setState("error");
      }).finally(() => { saving=false; if (pending !== null && !halted) flush(); else if(invalidated&&!halted&&!editing()){invalidated=false;void reload();} });
  };
  // Don't lose a debounced edit when the user switches files mid-save.
  onCleanup(flush);

  const onInput = (t: string) => {
    editVersion++;
    setText(t);
    setState("saving");
    pending = t;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(flush, 800);
  };

  const name = () => p.path.split("/").pop() ?? p.path;

  return (
    <>
      <div class="pf-bar">
        <span class="pf-path">{p.slug}/{p.path}</span>
        <ContextBadge slug={p.slug}/>
        <span class="dlg-spacer" />
        <ContextHistory slug={p.slug} path={p.path} onRestore={() => { if(pending===null&&!saving) void reload(); }}/>
        <Show when={state() === "saving"}>
          <span class="pf-state">Saving…</span>
        </Show>
        <Show when={state() === "saved"}>
          <span class="pf-state dim">Saved</span>
        </Show>
        <button class="s-btn" title="Toggle source and preview (⌘/)" onClick={() => setEditing(!editing())}>
          {editing() ? "Preview" : "Edit"}
        </button>
      </div>
      <FileDocument text={text()} name={name()} error={state() === "error" ? error() : null} onInput={onInput} />
    </>
  );
}

/** The body of an open text file: rendered Markdown, or its source while editing
 * (⌘/ toggles both, shared with project files). Used by project files and skills. */
export function FileDocument(p: { text: string | null; name: string; error?: string | null; onInput: (text: string) => void; readOnly?: boolean; markdown?: boolean }) {
  const markdown = () => p.markdown ?? /\.(md|markdown)$/i.test(p.name);
  return (
    <>
      <ErrorToast error={p.error} title={`Couldn’t save ${p.name}`} />
      <Show
        when={mdSource() || !markdown()}
        fallback={
          <div class="scroll">
            <div class="col">
              <Show when={p.text !== null} fallback={<FileSkeleton />}>
                <MdView text={p.text ?? ""} />
              </Show>
            </div>
          </div>
        }
      >
        <div class="file-view">
          <Show when={p.text !== null} fallback={<p class="s-lead shimmer">Loading {p.name}…</p>}>
            <MdSource text={p.text ?? ""} onInput={p.onInput} readOnly={p.readOnly} />
          </Show>
        </div>
      </Show>
    </>
  );
}
