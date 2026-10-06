import {nativeComposerDrop} from "./composerDrop";
import {importProjectFiles} from "./projectFileImport";
import type {UploadSource} from "./uploads";
import {subscribeProjectContext} from "./projectContext";
import { assertFolderHasNoWork, moveFolderWork, copyFileReference, readFileReference, fileDestination, fileParent, fileName as fileBaseName, transferProjectFile } from "./fileActions";
import { FolderActivityIcon, folderActivity } from "./FolderActivity";
import { createSidebarRequests } from "./sidebarRequests";
import { folderLabel, setFolderLabel } from "./folderLabels";
import { projectColor } from "./projectAppearance";
import { ProviderLogo } from "./ProviderLogo";
import { ContextBadge } from "./ContextBadge";
import { ContextHistory } from "./ContextHistory";
import { readProjectFileVersion } from "./projectContext";
import { cutMission, readCutMission, moveMission } from "./missionMove";
import { ForkMission } from "./ForkMission";
import { ErrorNotice, ErrorDialog } from "./ErrorNotice";
import { For, Show, createMemo, createSignal, onCleanup, onMount, createEffect, on, batch } from "solid-js";
import { mergeById, pollWhileVisible } from "./poll";
import { createStore, reconcile } from "solid-js/store";
import * as Ic from "./icons";
import * as SidebarIcon from "./sidebarIcons";
import { pendingMissionInteraction } from "./missionAttention";
import { MissionGlyph, missionStatusPresentation } from "./MissionGlyph";
import { MdSource, MdView, mdSource, setMdSource } from "./Markdown";
import { displayTitle } from "./goal";
import { missionDestination, nodeLabel } from "./missionLaunch";
import {
  api,
  isConnected,
  getApiUrl,
  ApiError,
  connectionVersion,
  listProjectFiles,
  listProjectMissions,
  listProjects,
  updateProject,
  renameMission,
  archiveMission,
  listArchivedMissions,
  isBtwMission,
  reopenMission,
  archiveProject,
  bumpProjects,
  createProjectCron,
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
  type ControllerView as ControllerData,
} from "./api";
import { CronGlyph, untilLabel } from "./Controller";
import { ConfirmDialog, Dialog, DialogButton, PromptSheet } from "./Dialog";
import { PopupMenu, type MenuEntry } from "./Menu";
import { copyText } from "./clipboard";
import { CronForm } from "./ControllerSettings";
import { getProjectCronFromJob } from "./cronSchema";
import { loadTranscript, prefetchTranscript } from "./missionCache";
import { cacheCanPrefetch, cacheLoad, cachePeek, cachePrefetch, cachePut, cacheRemember, prefetchProjectLimit } from "./pageCache";
import { SidebarTree } from "./Tree";
import { visibleTree, type TreeNode, type TreeRow } from "./treeModel";
import { FileSkeleton } from "./Skeleton";
import { countNested, holds, nestMissions, missionParent, missionSubtree, missionTreeRows, archiveOnlyRows, ARCHIVE_DAY_MS, ARCHIVE_WEEK_MS, filterArchivedMissionsByAge, expandMissionDescendants, type NestedMission } from "./missionTree";

const [deletingIds, setDeletingIds] = createSignal<ReadonlySet<string>>(new Set());
export const isMissionDeleting = (id: string): boolean => deletingIds().has(id);

/** Sidebar section listing the core backend's projects with their missions
 * and hosted files. Replaces the demo projects when connected. */
/** Known placement only: remote node, then workspace. Never invented. */
export function missionMachine(m: { backend?: string; remote_job?: { node_id?: string } | null; remote_node_id?: string | null; workspace_name?: string | null }): string | undefined {
  if (m.backend?.startsWith("cloud_")) return ({cloud_chatgpt:"ChatGPT",cloud_grok_bot:"Grok Bot",cloud_cursor:"Cursor Cloud",cloud_hermes:"Paloma"} as Record<string,string>)[m.backend];
  const id = m.remote_job?.node_id ?? m.remote_node_id ?? m.workspace_name;
  return id ? nodeLabel(id) : undefined;
}

export type RowTipContent = { title: string; meta: string[] };
const ROW_TIP_ID = "orb-row-tip";

/** Full title plus known repo/branch/machine lines. Never invented. */
export function rowDetail(title: string, extra: Array<string | undefined | null> = []): RowTipContent {
  return { title, meta: extra.map((part) => part?.trim()).filter((part): part is string => !!part) };
}

/** Prefer overlapping the row's trailing edge (Cursor); otherwise below. Clamp to the viewport. */
export function placeRowTip(
  row: { top: number; left: number; right: number; bottom: number },
  size: { width: number; height: number },
  view: { width: number; height: number },
  gap = 8,
) {
  const pad = 8;
  const overlap = Math.min(32, Math.max(12, row.right - row.left - 40));
  const start = row.right - overlap;
  const beside = view.width - start - pad >= Math.min(size.width, 120);
  const x = beside ? start : row.left;
  const y = beside ? row.top : row.bottom + gap;
  return {
    x: Math.max(pad, Math.min(x, view.width - size.width - pad)),
    y: Math.max(pad, Math.min(y, view.height - size.height - pad)),
  };
}

/**
 * The id to put on the clipboard for a sidebar agent row: the sandboxed mission
 * UUID exactly as the core stores it. Never the `m:` sidebar routing prefix,
 * never the durable remote job id (`remote_job.job_id`), and never a harness
 * session id — those identify an execution attempt, not the mission the
 * `/api/control/missions/:id` endpoints take.
 */
export function missionCopyId(mission: { id: string }): string {
  return mission.id;
}

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

/** Where an agent runs: the workspace/machine name behind a server glyph.
 * Per agent, not per project — one project can run on several machines. */
function MachineBadge(p: { name?: string | null }) {
  return (
    <Show when={p.name}>
      <span class="row-machine" aria-hidden="true">
        <SidebarIcon.Server size={16} />
      </span>
    </Show>
  );
}

function useRowTip() {
  const [tip, setTip] = createSignal<{ title: string; meta: string[]; x: number; y: number } | null>(null);
  let timer = 0;
  let gen = 0;
  let owner: HTMLElement | null = null;
  let card: HTMLDivElement | undefined;
  const unlink = () => { owner?.removeAttribute("aria-describedby"); owner = null; };
  const hide = () => { window.clearTimeout(timer); timer = 0; gen++; unlink(); setTip(null); };
  const place = (el: HTMLElement, content: RowTipContent, size = { width: 240, height: 44 }) => {
    const pos = placeRowTip(el.getBoundingClientRect(), size, { width: window.innerWidth, height: window.innerHeight });
    setTip({ ...content, ...pos });
    requestAnimationFrame(() => {
      if (owner !== el || !card || card.hidden) return;
      const next = placeRowTip(el.getBoundingClientRect(), { width: card.offsetWidth, height: card.offsetHeight }, { width: window.innerWidth, height: window.innerHeight });
      setTip((cur) => cur && owner === el && (cur.x !== next.x || cur.y !== next.y) ? { ...cur, ...next } : cur);
    });
  };
  const show = (content: RowTipContent, el: HTMLElement) => {
    window.clearTimeout(timer);
    const id = ++gen;
    timer = window.setTimeout(() => {
      if (id !== gen || !el.isConnected) return;
      timer = 0;
      unlink();
      owner = el;
      el.setAttribute("aria-describedby", ROW_TIP_ID);
      place(el, content);
    }, 480);
  };
  const bind = (content: RowTipContent) => ({
    onPointerEnter: (e: { currentTarget: HTMLElement }) => show(content, e.currentTarget),
    onPointerLeave: hide,
    onPointerDown: hide,
    onFocus: (e: { currentTarget: HTMLElement }) => {
      if (!e.currentTarget.matches(":focus-visible") || e.currentTarget.closest('.sidebar-tree[data-pointer-focus="true"]')) return;
      show(content, e.currentTarget);
    },
    onBlur: hide,
  });
  onMount(() => {
    const dismiss = (e: Event) => {
      if (!timer && !tip()) return;
      if (e.type === "keydown") {
        if ((e as KeyboardEvent).key !== "Escape") return;
        e.preventDefault();
        e.stopPropagation();
      }
      hide();
    };
    window.addEventListener("scroll", dismiss, true);
    window.addEventListener("keydown", dismiss, true);
    window.addEventListener("pointerdown", dismiss, true);
    window.addEventListener("resize", dismiss);
    onCleanup(() => {
      window.removeEventListener("scroll", dismiss, true);
      window.removeEventListener("keydown", dismiss, true);
      window.removeEventListener("pointerdown", dismiss, true);
      window.removeEventListener("resize", dismiss);
    });
  });
  onCleanup(hide);
  return { tip, bind, hide, id: ROW_TIP_ID, setCard: (el: HTMLDivElement) => { card = el; } };
}

export function LiveProjectsSection(p: {
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
  /** "+" on the section header: create a project (opens the picker flow). */
  onNewProject: (anchor: HTMLButtonElement) => void;
}) {
  const activity = createMemo(() => folderActivity(p.activityMissions ?? []));
  const scheduledActivity = createMemo(() => folderActivity(p.activityMissions ?? [], m => missionStatusPresentation(m.status, undefined, m.continuation).tone === "scheduled"));
  const [projects, setProjects] = createSignal<ProjectSummary[]>([]);
  const [error, setError] = createSignal<string | null>(null);
  const [expanded, setExpanded] = createStore<Record<string, boolean>>({});
  const [archivesOpen, setArchivesOpen] = createSignal(false);
  const [archiveExpanded, setArchiveExpanded] = createStore<Record<string, boolean>>({});
  const [archivedMissions, setArchivedMissions] = createSignal<Mission[]>([]);
  const [archivesLoading, setArchivesLoading] = createSignal(false);
  const [archivesError, setArchivesError] = createSignal<string | null>(null);
  const [archivesMore, setArchivesMore] = createSignal(false);
  const [archiveMenu, setArchiveMenu] = createSignal<{ x: number; y: number; slug?: string } | null>(null);
  let archivesOffset = 0;
  let archivesLoaded = false;
  let archivesRequest: Promise<void> | null = null;
  const isArchived = (mission: Mission) => mission.status === "acknowledged";
  const RUNNING = new Set(["active", "pending", "queued", "resuming", "running", "starting", "waiting_background"]);
  const LIVE = new Set(["active", "pending", "queued", "awaiting_user", "resuming", "running", "starting", "blocked", "paused", "waiting_background"]);
  const visibleMissions = (slug: string) => {
    const rows = missions[slug] ?? [];
    const current = currentMission();
    // A paginated project list may not contain an older open conversation.
    const withCurrent = current?.project === slug && !isArchived(current) && !rows.some(m => m.id === current.id)
      ? [current, ...rows] : rows;
    const extraArchived = archivedMissions().filter(m => (m.project ?? "") === slug && !withCurrent.some(r => r.id === m.id));
    return missionTreeRows([...withCurrent, ...extraArchived], m => !isArchived(m));
  };
  const allKnownMissions = (): Mission[] => {
    const byId = new Map<string, Mission>();
    for (const m of archivedMissions()) byId.set(m.id, m);
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
  const [controllerMenu, setControllerMenu] = createSignal<{x:number;y:number;slug:string;archived:boolean} | null>(null);
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
  const [missionMenu, setMissionMenu] = createSignal<{ x: number; y: number; mission: Mission } | null>(null);
  const [selectedAgents, setSelectedAgents] = createSignal<string[]>([]);
  const [selectionActive, setSelectionActive] = createSignal(false);
  const selectedAgentSet = createMemo(() => new Set(selectedAgents()));
  const selectedRowIds = createMemo(() => selectionActive() ? new Set(selectedAgents().map(id => `m:${id}`)) : undefined);
  const [deleteTargets, setDeleteTargets] = createSignal<string[]>([]);
  const [batchBusy, setBatchBusy] = createSignal(false);
  const [pendingMoves, setPendingMoves] = createSignal<string[]>([]);
  let selectionAnchor: string | null = null;
  const deletedInSession = new Set<string>();
  const deleteQueue: string[] = [];
  const queuedDeletes = new Set<string>();
  const deletingDescendants = new Map<string, string[]>();
  const deleteFailures: string[] = [];
  let activeDeleteWorkers = 0;
  let pendingRemoved = new Set<string>();
  let pendingUnmark = new Set<string>();
  let flushTimer: ReturnType<typeof setTimeout> | undefined;
  setDeletingIds(new Set<string>());
  onCleanup(() => {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = undefined; }
  });
  const clickAgent = (e: MouseEvent, id: string) => batch(() => {
    if (deletingIds().has(id)) return;
    setSelectionActive(true);
    // Only range selection needs the full tree. A normal click should navigate
    // immediately, without rebuilding every expanded project and directory.
    if (e.shiftKey && selectionAnchor && !deletingIds().has(selectionAnchor)) {
      const deleting = deletingIds();
      const visible = visibleTree([...tree(), ...(archivesOpen() ? archiveNodes() : [])])
        .flatMap(row => row.data.mission && !deleting.has(row.data.mission.id) ? [row.data.mission.id] : []);
      const a = visible.indexOf(selectionAnchor), b = visible.indexOf(id);
      if (a >= 0 && b >= 0) {
        const range = visible.slice(Math.min(a, b), Math.max(a, b) + 1);
        setSelectedAgents(e.metaKey || e.ctrlKey ? [...new Set([...selectedAgents().filter(x => !deleting.has(x)), ...range])] : range);
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      setSelectedAgents(ids => ids.includes(id) ? ids.filter(x => x !== id) : [...ids, id]);
      selectionAnchor = id;
    } else {
      setSelectedAgents([id]); selectionAnchor = id; p.open(`m:${id}`);
    }
  });
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
      setArchivedMissions(rows => {
        if (!rows.some(m => removed.has(m.id))) return rows;
        const next = rows.filter(m => !removed.has(m.id));
        archivesOffset = Math.max(0, archivesOffset - (rows.length - next.length));
        return next;
      });
      setSelectedAgents(current => current.some(x => removed.has(x)) ? current.filter(x => !removed.has(x)) : current);
    });
  };
  const removeRow = (id: string) => removeRows([id]);
  const forgetDeleted = (ids: string[]) => {
    const removed = new Set(ids);
    if (!removed.size) return;
    removeRows(ids);
    setDeleteTargets(current => current.some(id => removed.has(id)) ? current.filter(id => !removed.has(id)) : current);
    setPendingMoves(current => current.some(id => removed.has(id)) ? current.filter(id => !removed.has(id)) : current);
    if (cutId() && removed.has(cutId()!)) setCutId(null);
    if (selectionAnchor && removed.has(selectionAnchor)) selectionAnchor = null;
    if (p.onDeleted) p.onDeleted(ids);
    else if (ids.some(id => p.selected() === `m:${id}`)) p.open(null);
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
        if (deleteFailures.length) {
          const failures = deleteFailures.splice(0, deleteFailures.length);
          setActionError(`Couldn’t delete ${failures.length} agent(s). ${failures.join("; ")}`);
        }
        bumpProjects();
      }
    });
  };
  const scheduleDeleteFlush = (version: number) => {
    if (deleteQueue.length <= 8) flushDeleteBatch(version, false);
    else if (!flushTimer) flushTimer = setTimeout(() => flushDeleteBatch(version, false), 32);
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
          const mission = await api<Mission>(`/api/control/missions/${id}`);
          if (version !== connectionVersion()) break;
          // Preserve live and explicitly paused agents. DELETE also checks
          // all descendants against the current server runner registry.
          if (["active", "waiting_background", "paused"].includes(mission.status)
            || subtree.some(m => m.id !== id && ["active", "waiting_background", "paused"].includes(m.status)))
            throw new Error("Stop or finish this agent before deleting it.");
          const result = await api<{deleted_ids?: string[]}>(`/api/control/missions/${id}`, {method: "DELETE"});
          if (version !== connectionVersion()) break;
          const serverDeleted = new Set(result?.deleted_ids ?? []);
          for (const extraId of subtree.map(m => m.id)) {
            if (extraId !== id && !serverDeleted.has(extraId)) {
              const child = knownById.get(extraId);
              if (child && !child.parent_mission_id && child.callback_parent_mission_id) {
                await api(`/api/control/missions/${extraId}`, {method: "DELETE"}).catch(() => {});
              }
            }
          }
          const removed = [...new Set([id, ...covered, ...serverDeleted, ...subtree.map(m => m.id)])];
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
            for (const rid of covered) {
              deletedInSession.add(rid);
              pendingRemoved.add(rid);
              pendingUnmark.add(rid);
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
    setDeleteTargets([]);
    if (!targets.length) return;
    setActionError(null);
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
      if (selectionAnchor && targetSet.has(selectionAnchor)) selectionAnchor = null;
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
      else if (allDeleting.some(id => p.selected() === `m:${id}`)) p.open(null);
    });
    const freshTargets = targets.filter(id => !queuedDeletes.has(id) && !deletedInSession.has(id));
    for (const id of freshTargets) queuedDeletes.add(id);
    deleteQueue.unshift(...freshTargets);
    const desiredWorkers = deleteQueue.length + activeDeleteWorkers > 4 ? 6 : 1;
    while (activeDeleteWorkers < desiredWorkers && deleteQueue.length > 0) {
      void runDeleteWorker(version);
    }
  };
  const selectedFor = (id: string) => {
    const deleting = deletingIds();
    const current = selectedAgents().filter(x => !deleting.has(x));
    return current.includes(id) ? current : (deleting.has(id) ? [] : [id]);
  };
  const startMoveSelection = (id: string) => {
    setFileClipboard("");
    const ids = [...selectedFor(id)];
    if (!ids.length) return;
    if (ids.length === 1) { setPendingMoves([]); beginMove(id); }
    else { setPendingMoves(ids); setCutId(ids[0]); setActionError(null); }
  };
  const [forkTarget, setForkTarget] = createSignal<{ x: number; y: number; mission: Mission } | null>(null);
  const [makingCron, setMakingCron] = createSignal(false);
  const [cronWarning, setCronWarning] = createSignal<string | null>(null);
  const [cronFolder, setCronFolder] = createSignal("");
  const [newCron, setNewCron] = createSignal<string | null>(null);
  const [actionFocus, setActionFocus] = createSignal(true);
  const [fileMenu, setFileMenu] = createSignal<{ slug: string; path: string; x: number; y: number } | null>(null);
  const [fileAction, setFileAction] = createSignal<{ slug: string; path: string; kind: "rename" | "move" | "delete"; directory?: boolean } | null>(null);
  const [fileActionValue, setFileActionValue] = createSignal("");
  const [fileActionError, setFileActionError] = createSignal<string | null>(null);
  const [fileBusy, setFileBusy] = createSignal(false);
  const [fileClipboard, setFileClipboard] = createSignal("");
  let consumedFileClipboard = "";
  const cutFile = createMemo(() => { const item = readFileReference(fileClipboard()); return item && !item.copy ? item : null; });
  const beginFileAction = (slug: string, path: string, kind: "rename" | "move" | "delete", directory = false) => {
    setFileMenu(null); setActionMenu(null);
    setFileAction({ slug, path, kind, directory });
    // A folder renamed on this device before paths could change keeps that name as the suggestion.
    setFileActionValue(kind === "rename" ? (directory ? folderLabel(slug, path) : fileBaseName(path)) : fileParent(path));
    setFileActionError(null);
  };
  const refreshFileParents = async (slug: string, path: string, destination?: string) => {
    await loadDir(slug, fileParent(path), true);
    if (destination && fileParent(destination) !== fileParent(path)) await loadDir(slug, fileParent(destination), true);
  };
  const folderMoved = async (slug: string, path: string, destination: string, project = slug) => {
    setFolderLabel(slug, path, fileBaseName(path));
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
    const selected = p.selected(), prefix = `pf:${slug}:${path}`;
    if (selected === prefix || selected?.startsWith(`${prefix}/`)) p.open(`pf:${project}:${destination}${selected.slice(prefix.length)}`);
    try { if (project === slug) await moveFolderWork(slug, path, destination); }
    finally { await Promise.all([loadMissions(slug), loadCrons(slug, true)]); }
  };
  const saveFileAction = async () => {
    const target = fileAction(), version = connectionVersion();
    if (!target || fileBusy()) return;
    setFileBusy(true); setFileActionError(null);
    try {
      const destination = target.kind === "delete" ? undefined : fileDestination(target.path, fileActionValue(), target.kind === "rename");
      if (destination) {
        await transferProjectFile(target.slug, target.path, destination);
        if (target.directory) {
          setFileAction(null);
          try { await folderMoved(target.slug, target.path, destination); }
          finally { await refreshFileParents(target.slug, target.path, destination); }
          return;
        }
      } else {
        if (target.directory) await assertFolderHasNoWork(target.slug, target.path);
        await deleteProjectFile(target.slug, target.path);
      }
      if (version !== connectionVersion()) return;
      if (p.selected() === `pf:${target.slug}:${target.path}` || (target.directory && p.selected()?.startsWith(`pf:${target.slug}:${target.path}/`))) p.open(destination ? `pf:${target.slug}:${destination}` : null);
      setFileAction(null);
      await refreshFileParents(target.slug, target.path, destination);
    } catch (e) { if (version === connectionVersion()) { if (fileAction()) setFileActionError(String(e)); else setActionError(String(e)); } }
    finally { setFileBusy(false); }
  };
  const copyFile = async (slug: string, path: string, copy: boolean, directory = false) => {
    const version = connectionVersion(); setFileMenu(null); setActionMenu(null);
    try {
      const text = await copyFileReference(slug, path, copy, directory);
      if (version !== connectionVersion()) return;
      setFileClipboard(text); setCutId(null); setPendingMoves([]); setActionError(null);
    } catch (e) { if (version === connectionVersion()) setActionError(String(e)); }
  };
  const pasteFile = async (slug: string, path: string, text: string) => {
    const item = readFileReference(text), version = connectionVersion();
    if (!item || fileBusy() || text === consumedFileClipboard) return;
    setFileBusy(true); setActionMenu(null); setActionError(null);
    try {
      const other = item.slug !== slug;
      const destination = other ? [path, fileBaseName(item.path)].filter(Boolean).join("/") : fileDestination(item.path, path, false);
      // Agents and crons belong to their project: only documents cross over.
      if (other && item.directory && !item.copy) await assertFolderHasNoWork(item.slug, item.path, "moving");
      await transferProjectFile(item.slug, item.path, destination, item.copy, slug);
      if (version !== connectionVersion()) return;
      if (!item.copy) { consumedFileClipboard = text; setFileClipboard(""); }
      await Promise.all([loadDir(item.slug, fileParent(item.path), true), loadDir(slug, path, true)]);
      setExpanded(path ? `${slug}:${path}` : slug, true);
      if (item.copy) return;
      if (item.directory) await folderMoved(item.slug, item.path, destination, slug);
      else if (p.selected() === `pf:${item.slug}:${item.path}`) p.open(`pf:${slug}:${destination}`);
    } catch (e) { if (version === connectionVersion()) setActionError(String(e)); }
    finally { setFileBusy(false); }
  };
  const [rename, setRename] = createSignal<({ slug: string; title: string; path?: string } | { missionId: string; title: string }) | null>(null);
  const [renameValue, setRenameValue] = createSignal("");
  const [renameError, setRenameError] = createSignal<string | null>(null);
  const [renaming, setRenaming] = createSignal(false);
  const [actionError, setActionError] = createSignal<string | null>(null);
  const rowTip = useRowTip();
  const currentConnection = (version: number) => isConnected() && connectionVersion() === version;
  const requests = createSidebarRequests();
  const warmed = new Set<string>();
  const warmupQueue: string[] = [];
  let warmupActive = 0;
  const loadController = (slug: string, force = true) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    return requests.read(`controller:${version}:${slug}`, () => getProjectController(slug, 3), force)
      .then((view) => { if (currentConnection(version)) setControllers(slug, reconcile(view)); })
      .catch(() => {});
  };
  const missingCronApi = (error: unknown) => error instanceof ApiError && [404, 405].includes(error.status) && !/project not found/i.test(error.detail);
  const cronFailure = (slug: string, error: unknown) => {
    if (missingCronApi(error)) setCronUnsupported(true);
    else { setCronRetryable(slug, !(error instanceof ApiError) || error.status >= 500 || [408, 429].includes(error.status)); setCronErrors(slug, error instanceof Error ? error.message : String(error)); }
  };
  const cronLoads = new Map<string, Promise<void>>();
  const loadCrons = (slug: string, force = false): Promise<void> => {
    if (!isConnected() || (cronUnsupported() && !force)) return Promise.resolve();
    const version = connectionVersion();
    const key = `${version}:${slug}`;
    const pending = cronLoads.get(key);
    if (pending) return pending;
    const request = (async () => {
      try {
        const jobs = await requests.read(`crons:${version}:${slug}`, () => listProjectCrons(slug), force);
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
    setRename(null); setActionMenu(null); setFileMenu(null); setFileAction(null); setFileClipboard(""); setArchiveMenu(null);
    setSelectionActive(false); setSelectedAgents([]); selectionAnchor = null; setPendingMoves([]); setDeleteTargets([]); setMissionMenu(null);
    setArchiveExpanded({}); setArchivesOpen(false); setArchivedMissions([]); setArchivesLoading(false); setArchivesError(null); setArchivesMore(false); archivesOffset = 0; archivesLoaded = false; archivesRequest = null;
    setCronUnsupported(false);
    setCronChecking(false);
    setCronInfo(null);
    requests.clear();
    cancelIntent(); setError(null);
    setProjects([]); setMissions(reconcile({})); setDirs(reconcile({}));
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

  let refreshingVersion: number | undefined;
  const refresh = () => {
    if (!isConnected()) return;
    const version = connectionVersion();
    if (refreshingVersion === version) return;
    refreshingVersion = version;
    listProjects()
      .then((list) => {
        if (!currentConnection(version)) return;
        setProjects(list);
        setError(null);
        warmupProjects(list);
      })
      .catch((e) => {
        if (!currentConnection(version)) return;
        const msg = e instanceof Error ? e.message : String(e);
        setError(
          /^(404|405)\b/.test(msg)
            ? "This backend build doesn't expose projects yet — update the core."
            : msg,
        );
      }).finally(() => { if (refreshingVersion === version) refreshingVersion = undefined; });
  };
  createEffect(on(projectsVersion, () => refresh(), { defer: true }));
  onMount(() => {
    refresh();
    // Mission statuses under expanded projects would otherwise freeze at
    // expand time (the flat "Sandboxed" list polls, this tree didn't).
    const stop = pollWhileVisible(() => {
      if (!isConnected()) return;
      if (error()) refresh();
      for (const project of projects()) {
        if (!expanded[project.slug]) continue;
        loadMissions(project.slug);
        loadController(project.slug);
        loadCrons(project.slug);
        void loadDir(project.slug,"",true);
        for (const key of Object.keys(expanded)) {
          if(expanded[key] && key.startsWith(`${project.slug}:`))void loadDir(project.slug,key.slice(project.slug.length+1),true);
        }
      }
    }, 10000);
    onCleanup(stop);
  });

  let missionRevision = 0;
  const archiving = new Map<string, string>();
  const loadMissions = (slug: string, opts?: { transcripts?: boolean; cached?: boolean }) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    const revision = missionRevision;
    return requests.read(`missions:${version}:${revision}:${slug}`, () => listProjectMissions(slug), !opts?.cached)
      .then((list) => {
        if (!currentConnection(version)) return;
        if (revision !== missionRevision) return;
        const visibleList = list.filter(m => !deletedInSession.has(m.id));
        const merged = mergeById((missions[slug] ?? []).filter(m => !deletedInSession.has(m.id)), visibleList.map(m => archiving.has(m.id) ? {...m, status: archiving.get(m.id)!} : m));
        if (merged !== missions[slug]) setMissions(slug, merged);
        if (opts?.transcripts === false) return;
        const live = new Set(["active", "pending", "queued", "awaiting_user", "resuming", "running", "starting"]);
        const deleting = deletingIds();
        for (const m of merged) if (live.has(m.status) && !deleting.has(m.id)) prefetchTranscript(m.id);
      })
      .catch(() => {
        if (currentConnection(version) && !missions[slug]) setMissions(slug, []);
      });
  };

  const loadDir = (slug: string, path: string, force = false) => {
    if (!isConnected()) return Promise.resolve();
    const version = connectionVersion();
    const key = `${slug}:${path}`;
    setDirErrors(key, null);
    return requests.read(`files:${version}:${key}`, () => listProjectFiles(slug, path), force)
      .then((entries) => { if (currentConnection(version)) setDirs(key, reconcile(entries, {key: "name"})); })
      .catch((e) => { if (currentConnection(version)) setDirErrors(key, e instanceof Error ? e.message : String(e)); });
  };

  const warmupOne = async (slug: string) => {
    await Promise.all([
      loadMissions(slug, { transcripts: false, cached: true }),
      loadDir(slug, ""),
      loadController(slug, false),
      loadCrons(slug),
    ]);
  };
  const pumpWarmup = () => {
    if (!cacheCanPrefetch()) return;
    while (warmupActive < 2 && warmupQueue.length) {
      const slug = warmupQueue.shift()!;
      warmupActive++;
      void warmupOne(slug).finally(() => {
        warmupActive--;
        pumpWarmup();
      });
    }
  };
  const warmupProjects = (list: ProjectSummary[]) => {
    const limit = Math.min(4, prefetchProjectLimit());
    if (!limit) return;
    const active = new Set((p.activityMissions ?? []).filter(m => ["active", "running", "starting", "resuming"].includes(m.status)).map(m => m.project));
    const prioritized = [...list].sort((a, b) => Number(!!expanded[b.slug] || active.has(b.slug)) - Number(!!expanded[a.slug] || active.has(a.slug)));
    for (const p of prioritized.slice(0, limit)) {
      if (warmed.has(p.slug)) continue;
      warmed.add(p.slug);
      warmupQueue.push(p.slug);
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
    setMakingFolder(true);
    setFolderError(null);
    try {
      await mkdirProjectFile(target.slug, target.path ? `${target.path}/${name}` : name);
      loadDir(target.slug, target.path, true);
      setExpanded(target.path ? `${target.slug}:${target.path}` : target.slug, true);
      setNewFolder(null);
    } catch (e) {
      setFolderError(e instanceof Error ? e.message : String(e));
    } finally {
      setMakingFolder(false);
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
    setRename({ slug, title });
    setRenameValue(title);
    setRenameError(null);
  };
  const beginMissionRename = (mission: Mission) => {
    setMissionMenu(null);
    setForkTarget(null);
    setRename({ missionId: mission.id, title: mission.title ?? "" });
    setRenameValue(mission.title ?? "");
    setRenameError(null);
  };
  const saveRename = async () => {
    const target = rename();
    const title = renameValue().trim();
    if (!target || renaming()) return;
    if (!title) { setRenameError("Enter a name."); return; }
    setRenaming(true);
    setRenameError(null);
    try {
      if ("missionId" in target) {
        await renameMission(target.missionId, title);
        for (const slug of Object.keys(missions)) {
          setMissions(slug, m => m.id === target.missionId, "title", title);
        }
      } else {
        await updateProject({ slug: target.slug, title });
        setProjects(list => list.map(project => project.slug === target.slug ? {...project, title} : project));
        bumpProjects();
      }
      setRename(null);
    } catch (e) {
      setRenameError(e instanceof Error ? e.message : String(e));
    } finally {
      setRenaming(false);
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
    if (fileClipboard()) items.push(
      { kind: "sep" },
      { kind: "item", label: readFileReference(fileClipboard())?.directory ? "Paste folder" : "Paste file", icon: Ic.PasteIcon, onClick: () => void pasteFile(slug, path, fileClipboard()) },
    );
    if (cutId()) items.push(
      { kind: "sep" },
      { kind: "item", label: pendingMoves().length > 1 ? `Move ${pendingMoves().length} agents here` : "Move here", icon: Ic.PasteIcon, onClick: () => pasteMission(slug, path, true) },
    );
    if (path) items.push(
      { kind: "sep" },
      { kind: "item", label: "Rename", icon: Ic.PencilIcon, onClick: () => beginFileAction(slug, path, "rename", true) },
      { kind: "item", label: "Move…", icon: Ic.FolderIcon, onClick: () => beginFileAction(slug, path, "move", true) },
      { kind: "item", label: "Cut", icon: Ic.CutIcon, onClick: () => void copyFile(slug, path, false, true) },
      { kind: "item", label: "Copy", icon: Ic.CopyIcon, onClick: () => void copyFile(slug, path, true, true) },
      { kind: "item", label: "Delete…", icon: Ic.TrashIcon, danger: true, onClick: () => beginFileAction(slug, path, "delete", true) },
    );
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
  const changeArchiveState = async (mission: Mission, restore: boolean) => {
    if (archiving.has(mission.id) || deletingIds().has(mission.id)) return false;
    const subtree = missionSubtree(allKnownMissions(), [mission.id]);
    const fullSubtree = subtree.some(m => m.id === mission.id) ? subtree : [mission, ...subtree];
    if (fullSubtree.some(m => deletingIds().has(m.id))) return false;
    if (!restore && fullSubtree.some(m => RUNNING.has(m.status))) {
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
        setMissions(slug, rows => rows.map(m => targetIds.has(m.id) ? { ...m, status: statusFor(m) } : m));
      }
      setArchivedMissions(rows => {
        const rest = rows.filter(m => !targetIds.has(m.id));
        const nextArchived = targets
          .map(t => ({ ...t, status: statusFor(t) }))
          .filter(t => t.status === "acknowledged");
        return [...rest, ...nextArchived];
      });
    });
    updateStatus(() => status);
    try {
      await Promise.all(targets.map(t => restore ? reopenMission(t.id) : archiveMission(t.id)));
      if (!currentConnection(version)) return;
      if (restore) {
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
      for (const selected of ids) {
        if (!currentConnection(version)) break;
        const row = Object.values(missions).flat().find(m => m.id === selected) ?? archivedMissions().find(m => m.id === selected);
        if (!row || isArchived(row)) continue;
        const subtree = missionSubtree(allKnownMissions(), [row.id]);
        if (RUNNING.has(row.status) || subtree.some(m => RUNNING.has(m.status))) { failures.push(`${selected.slice(0,8)}: stop or finish this agent first`); continue; }
        if (!await archiveConversation(row)) failures.push(`${selected.slice(0,8)}: ${actionError() ?? "archive failed"}`);
      }
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
      selectionAnchor = ids[0] ?? null;
      setDeleteTargets(ids);
    });
  };
  const selectAndDeleteArchives = async (maxAgeMs?: number, slug?: string) => {
    setArchiveMenu(null); setMissionMenu(null); setForkTarget(null);
    setArchivesOpen(true);
    if (slug !== undefined) setArchiveExpanded(slug, true);
    if (!archivesLoaded || archivesLoading() || archivesMore()) {
      const version = connectionVersion();
      if (archivesLoading() && archivesRequest) await archivesRequest;
      if (!currentConnection(version)) return;
      if (!archivesLoaded) await loadArchives(false);
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
    setControllerMenu(null);
    setFileMenu(null);
    setForkTarget(null);
    if (!archivesLoaded && !archivesLoading()) void loadArchives();
    setArchiveMenu({ x: e.clientX, y: e.clientY, slug });
  };
  /** Fork the clicked mission without changing the currently open conversation. */
  const missionMenuItems = (mission: Mission, x: number, y: number): MenuEntry[] => selectedFor(mission.id).length > 1 ? [
    {kind: "item", label: `Move ${selectedFor(mission.id).length} agents`, icon: Ic.CutIcon, onClick: () => startMoveSelection(mission.id)},
    {kind: "item", label: `Archive ${selectedFor(mission.id).length} conversations`, icon: Ic.ArchiveIcon, onClick: () => void archiveSelection(mission.id)},
    {kind: "item", label: `Delete ${selectedFor(mission.id).length} agents…`, icon: Ic.TrashIcon, danger: true, onClick: () => setDeleteTargets([...selectedFor(mission.id)])},
    ...(isArchived(mission) ? [{ kind: "sep" as const }, ...archiveDeleteMenuItems()] : []),
  ] : [
    {kind: "item", label: "Delete agent…", icon: Ic.TrashIcon, danger: true, onClick: () => setDeleteTargets([mission.id])},
    ...(!mission.backend?.startsWith("cloud_") ? [{ kind: "item" as const, label: "Fork conversation", icon: Ic.BranchIcon, openOnHover: true, onClick: (anchor?: HTMLButtonElement) => { const rect = anchor?.parentElement?.getBoundingClientRect(); setForkTarget({ mission, x: rect ? rect.right + 3 : x, y: anchor?.getBoundingClientRect().top ?? y }); } }] : []),
    ...(["completed", "failed", "interrupted", "acknowledged", "cancelled"].includes(mission.status)
      ? [{ kind: "item" as const, label: isArchived(mission) ? "Restore" : "Reopen", icon: Ic.ReopenIcon, onClick: () => void reopenConversation(mission) }] : []),
    { kind: "item", label: "Move", icon: Ic.CutIcon, onClick: () => startMoveSelection(mission.id) },
    { kind: "item", label: "Rename", icon: Ic.PencilIcon, onClick: () => beginMissionRename(mission) },
    { kind: "item", label: "Copy mission ID", icon: Ic.CopyIcon, onClick: () => void copyMissionId(mission) },
    ...(["awaiting_user", "blocked", "paused", "interrupted", "failed", "completed", "cancelled"].includes(mission.status)
      ? [{ kind: "item" as const, label: "Archive", icon: Ic.ArchiveIcon, onClick: () => void archiveConversation(mission) }]
      : []),
    ...(isArchived(mission) ? [{ kind: "sep" as const }, ...archiveDeleteMenuItems()] : []),
  ];
  /** Right-click handler shared by every agent row. Suppresses the native menu
   * and the sidebar-wide one without opening a different conversation. */
  const onMissionContext = (e: MouseEvent, mission: Mission) => {
    e.preventDefault();
    e.stopPropagation();
    if (deletingIds().has(mission.id)) return;
    setActionMenu(null);
    setArchiveMenu(null);
    setControllerMenu(null);
    setFileMenu(null);
    setForkTarget(null);
    setSelectionActive(true);
    if (!selectedAgentSet().has(mission.id)) { setSelectedAgents([mission.id]); selectionAnchor = mission.id; }
    setMissionMenu({ x: e.clientX, y: e.clientY, mission });
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
      loadMissions(slug, { cached: true });
      loadDir(slug, "");
      loadController(slug, false);
      loadCrons(slug);
    }
  };

  const toggleDir = (slug: string, path: string) => {
    const key = `${slug}:${path}`;
    const next = !expanded[key];
    setExpanded(key, next);
    if (next) loadDir(slug, path);
  };

  type RowData = {
    kind: "archive-project" | "project" | "folder" | "file" | "mission" | "cron" | "cron-error" | "note";
    slug: string; label: string; path?: string; mission?: Mission;
    job?: import("./api").ControllerJob; controller?: boolean;
    /** Missions launched by this one, at any depth, and how many still run. */
    launched?: number; launchedLive?: number;
  };
  type Node = TreeNode<RowData>;
  const [cutId, setCutId] = createSignal<string | null>(null);
  let moving = false;
  let consumedCut = "";
  let cutClipboard = "";
  const beginMove = (id: string) => {
    if (moving) return;
    const version = connectionVersion();
    void cutMission(id).then(text => {
      if (version !== connectionVersion()) return;
      cutClipboard = text; setCutId(id); setActionError(null);
    }).catch(e => setActionError(String(e)));
  };
  const pasteMission = (slug: string, path: string, fromMenu = false) => {
    if (moving) return;
    if (pendingMoves().length) {
      moving = true;
      const ids = [...pendingMoves()], version = connectionVersion();
      void (async () => {
        const failed: string[] = [];
        for (const id of ids) {
          if (version !== connectionVersion()) break;
          try {
            await moveMission(id, slug, path);
            if (version !== connectionVersion()) break;
            removeRow(id);
          } catch (error) { failed.push(id); setActionError(`Couldn’t move ${id.slice(0, 8)}: ${String(error)}`); }
        }
        if (version !== connectionVersion()) return;
        setPendingMoves(failed); setCutId(failed[0] ?? null);
        setExpanded(slug, true); if (path) setExpanded(`${slug}:${path}`, true);
        await loadMissions(slug); bumpProjects();
      })().finally(() => { moving = false; });
      return;
    }
    moving = true;
    const version = connectionVersion();
    void (async () => {
      const clipboard = fromMenu ? cutClipboard : await navigator.clipboard.readText();
      if (clipboard === consumedCut) return;
      const missionId = readCutMission(clipboard, getApiUrl());
      if (!missionId || version !== connectionVersion()) return;
      await moveMission(missionId, slug, path);
      if (version !== connectionVersion()) return;
      consumedCut = clipboard; cutClipboard = "";
      setCutId(null); setActionError(null);
      for (const source of Object.keys(missions)) setMissions(source, list => list.filter(m => m.id !== missionId));
      setExpanded(slug, true);
      if (path) setExpanded(`${slug}:${path}`, true);
      await loadMissions(slug);
      bumpProjects();
    })().catch(e => setActionError(`Couldn’t move conversation: ${String(e)}`)).finally(() => { moving = false; });
  };
  const moveKey = (event: KeyboardEvent) => {
    if (event.key === "Escape") { if (cutFile()) consumedFileClipboard = fileClipboard(); setFileClipboard(""); setSelectedAgents([]); setPendingMoves([]); setCutId(null); selectionAnchor = null; return; }
    if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
    const target = event.target as HTMLElement;
    if (target.closest('input, textarea, [contenteditable="true"]')) return;
    const id = target.closest<HTMLElement>('.tree-entry')?.dataset.treeId;
    if (!id) return;
    const find = (nodes: Node[]): RowData | undefined => {
      for (const node of nodes) { if (node.id === id) return node.data; const child = node.children && find(node.children); if (child) return child; }
    };
    const row = find([...tree(), ...(archivesOpen() ? archiveNodes() : [])]);
    if (!row) return;
    if ((row.kind === "file" || row.kind === "folder") && ['x', 'c'].includes(event.key.toLowerCase())) {
      event.preventDefault(); event.stopPropagation();
      void copyFile(row.slug, row.path!, event.key.toLowerCase() === 'c', row.kind === "folder");
    } else if (event.key.toLowerCase() === 'x' && row.mission && !deletingIds().has(row.mission.id)) {
      setFileClipboard("");
      event.preventDefault(); event.stopPropagation();
      startMoveSelection(row.mission.id);
    } else if (event.key.toLowerCase() === 'v' && (row.kind === 'project' || row.kind === 'folder')) {
      event.preventDefault(); event.stopPropagation();
      const version = connectionVersion();
      void navigator.clipboard.readText().then(text => {
        if (version !== connectionVersion()) return;
        if (readFileReference(text)) void pasteFile(row.slug, row.path ?? '', text);
        else pasteMission(row.slug, row.path ?? '');
      }).catch(e => setActionError(String(e)));
    } else if (event.key.toLowerCase() === 'c') { setCutId(null); setPendingMoves([]); }
  };
  const missionFolder = (mission: Mission) => mission.tags?.find(t => t.startsWith("orb-folder:"))?.slice("orb-folder:".length) ?? "";
  const workNodes = (slug: string, path: string): Node[] => {
    const out: Node[] = (crons[slug] ?? []).filter(job => (job.folder ?? "") === path).map(job => ({ id: `pc:${slug}:${job.id}`, data: { kind: "cron", slug, label: job.name, job } }));
    out.push(...rootMissions(slug).filter(root => missionFolder(root.mission) === path && !(controllerRow(slug) && controllerLaunched(root.mission))).map(root => missionNode(slug, root)));
    return out;
  };
  const fileNodes = (slug: string, path: string): Node[] => {
    const key = `${slug}:${path}`;
    const work = path ? workNodes(slug, path) : [];
    if (dirErrors[key] && !dirs[key]) return [...work, { id: `error:${key}`, data: { kind: "note", slug, path, label: `Files unavailable: ${dirErrors[key]}` } }];
    if (!dirs[key]) return [...work, { id: `loading:${key}`, data: { kind: "note", slug, path, label: "Loading files…" } }];
    const entries = [...dirs[key]];
    // Preserve visibility if a referenced folder listing is stale or its physical directory was removed.
    const paths = [...rootMissions(slug).map(root => missionFolder(root.mission)), ...(crons[slug] ?? []).map(j => j.folder ?? "")];
    for (const folder of paths) {
      const relative = path ? (folder.startsWith(path + "/") ? folder.slice(path.length + 1) : "") : folder;
      const name = relative.split("/")[0];
      if (name && !entries.some(e => e.name === name)) entries.push({ name, kind: "dir" });
    }
    if (!entries.length && !work.length && !dirErrors[key]) return path ? [{ id: `empty:${key}`, data: { kind: "note", slug, path, label: "Empty folder" } }] : [];
    return [...work, ...(dirErrors[key] ? [{ id: `error:${key}`, data: { kind: "note" as const, slug, path, label: "Couldn’t refresh files. Showing saved list." } }] : []), ...entries.map((entry): Node => {
      const childPath = path ? `${path}/${entry.name}` : entry.name;
      const open = !!expanded[`${slug}:${childPath}`];
      return { id: `pf:${slug}:${childPath}`, data: { kind: entry.kind === "dir" ? "folder" : "file", slug, path: childPath, label: entry.kind === "dir" ? folderLabel(slug, childPath) : entry.name },
        ...(entry.kind === "dir" ? { expanded: open, children: open ? fileNodes(slug, childPath) : [] } : {}) };
    })];
  };
  // Missions a mission launched are listed inside it. Closed by default,
  // except around the conversation that is open.
  const rootMissions = (slug: string) => nestMissions(visibleMissions(slug));
  // A mission the project's controller created (a Hermes session, no parent
  // mission) is listed under the controller, like a child under its parent.
  const controllerLaunched = (mission: Mission) => !missionParent(mission) && mission.origin === "hermes" && !!mission.origin_session_id;
  const controllerRow = (slug: string) => { const job = controllers[slug]?.job; return !!job && !job.archived; };
  const controllerRoots = (slug: string) => controllerRow(slug) ? rootMissions(slug).filter(root => controllerLaunched(root.mission)) : [];
  const missionNode = (slug: string, nested: NestedMission<Mission>): Node => {
    const mission = nested.mission, id = `m:${mission.id}`;
    const data: RowData = { kind: "mission", slug, mission, label: displayTitle(mission.title) || mission.id };
    if (!nested.children.length) return { id, data };
    const selected = p.selected();
    const open = expanded[id] ?? (!!selected?.startsWith("m:") && holds(nested, selected.slice(2)));
    return { id, data: { ...data, launched: countNested(nested), launchedLive: countNested(nested, child => RUNNING.has(child.status)) },
      expanded: open, children: open ? nested.children.map(child => missionNode(slug, child)) : [] };
  };
  const tree = (): Node[] => projects().map(project => {
    const slug = project.slug, open = !!expanded[slug];
    const children: Node[] = [];
    if (open) {
      const job = controllers[slug]?.job;
      if (job && !job.archived) {
        const launched = controllerRoots(slug), id = `c:${slug}`, selected = p.selected();
        const inside = !!selected?.startsWith("m:") && launched.some(root => root.mission.id === selected.slice(2) || holds(root, selected.slice(2)));
        const open = launched.length ? (expanded[id] ?? inside) : undefined;
        const count = launched.reduce((sum, root) => sum + 1 + countNested(root), 0);
        const live = launched.reduce((sum, root) => sum + Number(RUNNING.has(root.mission.status)) + countNested(root, child => RUNNING.has(child.status)), 0);
        children.push({ id, data: { kind: "cron", slug, label: job.name, job, controller: true, ...(launched.length ? { launched: count, launchedLive: live } : {}) },
          ...(launched.length ? { expanded: open, children: open ? launched.map(root => missionNode(slug, root)) : [] } : {}) });
      }
      if (cronUnsupported() || cronErrors[slug]) children.push({ id: `crons-error:${slug}`, data: { kind: "cron-error", slug, label: "Crons unavailable" } });

      if (missions[slug] === undefined) children.push({ id: `loading-missions:${slug}`, data: { kind: "note", slug, label: "Loading missions…" } });
      children.push(...workNodes(slug, ""));
      children.push(...fileNodes(slug, ""));
      if (!children.length) children.push({ id: `empty:${slug}`, data: { kind: "note", slug, label: "No missions or files yet." } });
    }
    return { id: `project:${slug}`, data: { kind: "project", slug, label: project.title || slug }, expanded: open, children };
  });
  const archiveNodes = (): Node[] => {
    const byProject = new Map<string, Mission[]>();
    for (const m of archivedMissionRows()) {
      const slug = m.project ?? "";
      byProject.set(slug, [...(byProject.get(slug) ?? []), m]);
    }
    const groups = new Map<string, Node[]>();
    for (const [slug, rows] of byProject) {
      groups.set(slug, nestMissions(rows).map(root => missionNode(slug, root)));
    }
    for (const project of projects()) {
      const job = controllers[project.slug]?.job;
      if (job?.archived) {
        const node: Node = {id:`c:${project.slug}`,data:{kind:"cron",slug:project.slug,label:job.name,job,controller:true}};
        groups.set(project.slug, [...(groups.get(project.slug) ?? []), node]);
      }
    }
    return [...groups].map(([slug, children]) => ({
      id: `archive-project:${slug}`,
      data: {kind: "archive-project" as const, slug, label: projects().find(project => project.slug === slug)?.title || slug || "No project"},
      expanded: !!archiveExpanded[slug], children,
    })).sort((a,b) => a.data.label.localeCompare(b.data.label));
  };
  const loadArchives = (more = false): Promise<void> => {
    if (archivesLoading()) return archivesRequest ?? Promise.resolve();
    const version = connectionVersion(), revision = missionRevision;
    setArchivesLoading(true); setArchivesError(null);
    let run: Promise<void> | undefined;
    run = (async () => {
      try {
        const rows = await listArchivedMissions(more ? archivesOffset : 0);
        if (!currentConnection(version) || revision !== missionRevision) return;
        const projected = rows.filter(m => !isBtwMission(m) && !deletedInSession.has(m.id)).map(m => archiving.has(m.id) ? {...m,status:archiving.get(m.id)!} : m);
        setArchivedMissions(previous => more ? [...previous, ...projected.filter(m => !previous.some(old => old.id === m.id))] : projected);
        archivesOffset = (more ? archivesOffset : 0) + rows.length;
        archivesLoaded = true;
        setArchivesMore(rows.length === 100);
      } catch (error) { if (currentConnection(version)) setArchivesError(String(error)); }
      finally {
        if (archivesRequest === run) archivesRequest = null;
        if (currentConnection(version)) setArchivesLoading(false);
      }
    })();
    archivesRequest = run;
    return run;
  };
  const toggleArchives = () => {
    const open = !archivesOpen(); setArchivesOpen(open);
    if (open) {
      void loadArchives();
      for (const project of projects()) void loadController(project.slug);
    }
  };
  let dropTree:HTMLDivElement|undefined;
  const [importing,setImporting]=createSignal(false),[importStatus,setImportStatus]=createSignal('');
  const dropAt=(x:number,y:number)=>{const el=document.elementFromPoint(x,y)?.closest<HTMLElement>('[data-drop-project]');return el&&dropTree?.contains(el)?el:undefined;};
  const importFiles=async(sources:UploadSource[],target:HTMLElement)=>{
   if(importing()){setActionError('An import is already in progress. Wait before dropping more files.');return;}
   const slug=target.dataset.dropProject!,folder=target.dataset.dropFolder??'',version=connectionVersion();
   setImporting(true);setImportStatus('Importing files to shared context…');setActionError(null);
   try{const result=await importProjectFiles(slug,folder,sources);if(!currentConnection(version))return;
    await loadDir(slug,folder,true);setExpanded(`${slug}:${folder}`,true);
    setImportStatus(result.paths.length?`${result.paths.length} file(s) saved to shared context. Available with @; connected agents synchronize automatically.`:'');
    if(result.warnings.length)setActionError(result.warnings.join('\n'));
   }catch(error){setImportStatus('');setActionError(String(error));}finally{setImporting(false);}
  };
  nativeComposerDrop(()=>dropTree,importFiles,dropAt);
  // Navigation (fork, search, history) owns the current selection. An old
  // range selection must not keep highlighting a different conversation.
  createEffect(on(p.selected, selected => {
    setSelectionActive(false); setSelectedAgents([]); selectionAnchor = null;
    if (!selected?.startsWith("m:")) return;
    selectionAnchor = selected.slice(2); setSelectedAgents([selectionAnchor]);
  }));
  const currentMission = createMemo(() => {
    const selected = p.selected();
    if (!selected?.startsWith("m:")) return undefined;
    const id = selected.slice(2);
    return (p.currentMission?.id === id ? p.currentMission : undefined)
      ?? p.activityMissions?.find(m => m.id === id)
      ?? Object.values(missions).flat().find(m => m.id === id)
      ?? archivedMissions().find(m => m.id === id);
  });
  // Observe identity/location, not every polling update. This also runs when a
  // restored conversation's metadata arrives after the initial selection.
  const currentLocation = createMemo(() => {
    const mission = currentMission();
    return mission?.project ? JSON.stringify([mission.id, mission.project, missionFolder(mission), isArchived(mission)]) : null;
  });
  createEffect(on(currentLocation, location => {
    if (!location) return;
    const [, slug, folder, archived] = JSON.parse(location) as [string, string, string, boolean];
    if (archived) {
      setArchivesOpen(true); setArchiveExpanded(slug, true);
      void loadArchives();
      return;
    }
    setExpanded(slug, true);
    const parts = folder.split("/").filter(Boolean);
    for (let i = 1; i <= parts.length; i++) {
      const path = parts.slice(0, i).join("/");
      setExpanded(`${slug}:${path}`, true);
      void loadDir(slug, path);
    }
    void loadMissions(slug);
    void loadDir(slug, "");
  }));
  const currentParents = createMemo(() => {
    const mission = currentMission();
    if (!mission?.project || isArchived(mission)) return "";
    const parents: string[] = [], seen = new Set([mission.id]);
    const rows = missions[mission.project] ?? [];
    let root = mission, parent = missionParent(mission);
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
  const launchedToggle = (row: TreeRow<RowData>, d: RowData) => <Show when={d.launched}><button class={`launched-toggle ${d.launchedLive ? "live" : ""}`} tabindex={-1} aria-expanded={row.expanded}
    disabled={d.mission ? deletingIds().has(d.mission.id) : false}
    aria-label={`${row.expanded ? "Hide" : "Show"} the ${d.launched} mission${d.launched === 1 ? "" : "s"} launched by ${d.label}`}
    title={`${d.launched} launched mission${d.launched === 1 ? "" : "s"}${d.launchedLive ? ` · ${d.launchedLive} running` : ""}`}
    onClick={e => { e.stopPropagation(); setExpanded(row.id, !row.expanded); }}>
    <span class="launched-count">{d.launchedLive ? `${d.launchedLive}/${d.launched}` : d.launched}</span>
    <SidebarIcon.ChevronRight size={12} class={`launched-chevron ${row.expanded ? "open" : ""}`} />
  </button></Show>;
  const renderRow = (row: TreeRow<RowData>) => {
    const d = row.data;
    const contextMenu = (e: MouseEvent) => {
      e.preventDefault(); e.stopPropagation(); setMissionMenu(null); setArchiveMenu(null); setControllerMenu(null); setFileMenu(null); setActionFocus(false);
      setActionMenu({ x: e.clientX, y: e.clientY, slug: d.slug, path: d.path ?? "" });
    };
    if (d.kind === "archive-project") return <button class="row archive-project-row" aria-expanded={row.expanded} onClick={() => setArchiveExpanded(d.slug, !archiveExpanded[d.slug])} onContextMenu={e => openArchiveMenu(e, d.slug)}>
      <span class="row-ico" style={{ color: projectColor(d.slug) ?? "var(--fg-3)" }}><Show when={row.expanded} fallback={<SidebarIcon.Folder />}><SidebarIcon.FolderOpen /></Show></span>
      <span class="row-label">{d.label}</span>
      <SidebarIcon.ChevronRight size={12} class={`history-chevron ${row.expanded ? "open" : ""}`} />
    </button>;
    if (d.kind === "project") return <div class={`row project ${currentMission()?.project === d.slug ? "contains-current" : ""}`} data-drop-project={d.slug} data-drop-folder={d.path ?? ""} onContextMenu={contextMenu}>
      <button class="row-main" aria-label={d.label} aria-expanded={row.expanded} onPointerEnter={() => warmIntent(d.slug)} onPointerLeave={cancelIntent} onFocus={() => warmIntent(d.slug)} onBlur={cancelIntent} onClick={() => toggleProject(d.slug)}>
        <FolderActivityIcon expanded={row.expanded} color={projectColor(d.slug)} count={activity().get(d.slug)?.get(d.path ?? "") ?? 0} scheduled={scheduledActivity().get(d.slug)?.get(d.path ?? "") ?? 0} />
        <span class="row-label">{d.label}</span>
        <Show when={!row.expanded && currentMission()?.project === d.slug}><span class="current-location-label">Open</span></Show>
      </button>
      <Show when={row.expanded}><ContextBadge slug={d.slug}/></Show>
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
    if (d.kind === "folder") return <div class="row folder" data-drop-project={d.slug} data-drop-folder={d.path ?? ""} onContextMenu={contextMenu}>
      <button class="row-main" aria-label={d.label} aria-expanded={row.expanded} {...rowTip.bind(rowDetail(d.label))} onPointerEnter={() => warmIntent(d.slug, d.path!)} onPointerLeave={cancelIntent} onFocus={() => warmIntent(d.slug, d.path!)} onBlur={cancelIntent} onClick={() => toggleDir(d.slug, d.path!)}>
        <FolderActivityIcon expanded={row.expanded} color={projectColor(d.slug)} count={activity().get(d.slug)?.get(d.path ?? "") ?? 0} scheduled={scheduledActivity().get(d.slug)?.get(d.path ?? "") ?? 0} /><span class="row-label">{d.label}</span>
      </button>
      <button class="row-action" aria-label={`Folder actions for ${d.label}`} title="Folder actions"
        onPointerDown={e => setActionFocus(e.pointerType !== "mouse")}
        onKeyDown={e => { if (e.key === "Enter" || e.key === " ") setActionFocus(true); }}
        onClick={e => { e.stopPropagation(); e.currentTarget.focus({ preventScroll: true }); const box = e.currentTarget.getBoundingClientRect(); setActionMenu({ x: Math.max(8, box.right - 176), y: box.bottom + 4, slug: d.slug, path: d.path! }); }}><Ic.PlusIcon size={13} /></button>
    </div>;
    if (d.kind === "cron") {
      const ticking = () => d.controller && (controllers[d.slug]?.runs ?? []).some(r => r.status === "running" || r.status === "claimed");
      return <><button class={`row agent cron ${d.job?.archived ? "done" : ""} ${p.selected() === row.id ? "active" : ""}`} aria-expanded={d.launched ? row.expanded : undefined} {...rowTip.bind(rowDetail(d.label, [d.controller ? "Controller" : "Cron"]))} onClick={() => p.open(row.id)}
        onKeyDown={e => { if (d.launched && ((e.key === "ArrowRight" && !row.expanded) || (e.key === "ArrowLeft" && row.expanded))) { e.preventDefault(); e.stopPropagation(); setExpanded(row.id, !row.expanded); } }} onContextMenu={e => {
        if (!d.controller) return;
        e.preventDefault(); e.stopPropagation();
        setActionMenu(null); setMissionMenu(null); setArchiveMenu(null); setFileMenu(null);
        setControllerMenu({x:e.clientX,y:e.clientY,slug:d.slug,archived:!!d.job?.archived});
      }}>
        <span class="row-ico glyph"><CronGlyph job={d.job!} running={!!ticking()} /></span><span class="row-label">{d.label}</span>
        <span class="row-machine"><Show when={!d.job!.enabled || d.job!.state === "paused"} fallback={<span class="row-machine-name cron-next">{ticking() ? "ticking" : untilLabel(d.job!.next_run_at, Date.now())}</span>}>
          <span class="cron-paused-indicator" role="img" aria-label="Paused" title={ticking() ? "Paused · current run finishing" : "Paused"}><Ic.PauseIcon size={14} /></span>
        </Show></span>
      </button>{launchedToggle(row, d)}</>;
    }
    const deleting = () => d.mission ? deletingIds().has(d.mission.id) : false;
    const tip = rowTip.bind(rowDetail(d.label, [d.mission && isArchived(d.mission) ? [projects().find(project => project.slug === d.slug)?.title || d.slug, missionFolder(d.mission)].filter(Boolean).join(" / ") : undefined, d.mission ? missionMachine(d.mission) : undefined, d.mission?.backend, d.mission?.model_override, d.mission?.id, d.mission ? (deleting() ? "Deleting…" : missionStatusPresentation(d.mission.status, pendingMissionInteraction(d.mission.id)).label) : undefined]));
    return <><button disabled={deleting()} aria-busy={deleting() ? true : undefined} aria-current={p.selected() === row.id ? "page" : undefined} aria-expanded={d.launched ? row.expanded : undefined}
      onKeyDown={e => { if (deleting()) return; if (d.launched && ((e.key === "ArrowRight" && !row.expanded) || (e.key === "ArrowLeft" && row.expanded))) { e.preventDefault(); e.stopPropagation(); setExpanded(row.id, !row.expanded); } }}
      aria-description={d.mission ? (deleting() ? "Deleting…" : missionStatusPresentation(d.mission.status, pendingMissionInteraction(d.mission.id)).label) : undefined} class={`row ${d.kind === "mission" ? "agent" : "file"} ${deleting() ? "mission-deleting" : ""} ${d.kind === "file" && cutFile()?.slug === d.slug && cutFile()?.path === d.path ? "mission-cut" : ""} ${d.mission && !LIVE.has(d.mission.status) ? "done" : ""} ${d.mission && (d.mission.id === cutId() || pendingMoves().includes(d.mission.id)) ? "mission-cut" : ""} ${d.mission ? (!deleting() && (selectionActive() ? selectedAgentSet().has(d.mission.id) : p.selected() === row.id)) ? "active" : "" : p.selected() === row.id ? "active" : ""}`} {...tip}
      onPointerEnter={e => { if (deleting()) return; tip.onPointerEnter(e); if (d.mission) void loadTranscript(d.mission.id).catch(() => {}); else cachePrefetch(row.id, () => readProjectFile(d.slug, d.path!).then(text => cachePut(row.id, text))); }} onContextMenu={e => { if (d.mission) { if (deleting()) { e.preventDefault(); e.stopPropagation(); return; } onMissionContext(e, d.mission); } else {
        e.preventDefault(); e.stopPropagation(); setActionMenu(null); setMissionMenu(null); setArchiveMenu(null); setControllerMenu(null);
        setFileMenu({ slug: d.slug, path: d.path!, x: e.clientX, y: e.clientY });
      } }} onClick={e => { if (d.mission) { if (deleting()) return; clickAgent(e, d.mission.id); } else { setSelectionActive(false); setSelectedAgents([]); p.open(row.id); } }}>
      <span class={`row-ico glyph ${d.mission ? "mission-lead" : ""}`}><Show when={d.mission} fallback={<Ic.FileIcon />}>{m => <Show when={isArchived(m())} fallback={<MissionGlyph missionId={m().id} status={m().status} continuation={m().continuation} identity={m().backend?.startsWith("cloud_") ? <ProviderLogo type={m().backend!} /> : undefined} />}><SidebarIcon.MessageCircle size={15} /></Show>}</Show></span>
      <span class="row-label">{d.label}</span><Show when={!d.launched}><MachineBadge name={d.mission ? missionMachine(d.mission) : undefined} /></Show>
    </button>
    {launchedToggle(row, d)}</>;
  };

  return (
    <>
      <div class="section section-row">
        <span>Projects</span>
        <button class="section-add" title="New project" onClick={e => { e.currentTarget.focus(); p.onNewProject(e.currentTarget); }}>
          <Ic.PlusIcon size={13} />
        </button>
      </div>
      <Show when={error()}>
        <div class="row note">{error()} <button class="text-btn" onClick={refresh}>Retry</button></div>
      </Show>
      <Show when={cronWarning()}><ErrorNotice error={cronWarning()!} /></Show>
      <Show when={actionError()}>{error => <ErrorDialog error={error()} onClose={() => setActionError(null)} />}</Show>
      <Show when={importStatus()}><div class="row note" role="status">{importStatus()}</div></Show>
      <div ref={dropTree} onDragOver={e=>{if(!Array.from(e.dataTransfer?.types??[]).includes('Files'))return;e.preventDefault();const target=dropAt(e.clientX,e.clientY);dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));target?.classList.add('drop-active');if(e.dataTransfer)e.dataTransfer.dropEffect=target?'copy':'none';}} onDragLeave={e=>{if(!dropTree?.contains(e.relatedTarget as globalThis.Node))dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));}} onDrop={e=>{e.preventDefault();e.stopPropagation();dropTree?.querySelectorAll('.drop-active').forEach(el=>el.classList.remove('drop-active'));const target=dropAt(e.clientX,e.clientY);if(target)void importFiles(Array.from(e.dataTransfer?.files??[]).map(file=>({name:file.name,file})),target);}} onKeyDown={moveKey}><SidebarTree nodes={tree()} label="Projects" selected={p.selected()} selectedIds={selectedRowIds()} render={renderRow} /></div>
      <Show when={projects().length === 0 && !error()}>
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
          <Show when={archivesError()}><div class="row note" role="alert">Couldn’t load archives. <button onClick={() => void loadArchives()}>Retry</button></div></Show>
          <Show when={!archivesLoading() && !archivesError() && !archiveNodes().length}><div class="row note">No archived conversations.</div></Show>
          <Show when={archivesMore()}><button class="row note" disabled={archivesLoading()} onClick={() => void loadArchives(true)}>Load older conversations</button></Show>
        </div>
      </Show>
      <Show when={deleteTargets().length}>
        <Dialog title={`Delete ${deleteTargets().length} agent${deleteTargets().length === 1 ? "" : "s"}?`} onClose={() => setDeleteTargets([])}
          footer={<><DialogButton onClick={() => setDeleteTargets([])}>Cancel</DialogButton><DialogButton variant="destructive" onClick={() => void deleteSelected()}>Delete</DialogButton></>}>
          <p>This permanently deletes the selected conversations, their child agents and associated workspace files. Agents still running or paused will be kept.</p>
        </Dialog>
      </Show>
      <Show when={archiveMenu()} keyed>{menu => <PopupMenu x={menu.x} y={menu.y} focus={false} items={archiveDeleteMenuItems(menu.slug)} onClose={() => setArchiveMenu(null)} />}</Show>
      <Show when={controllerMenu()} keyed>{menu => <PopupMenu x={menu.x} y={menu.y} focus={false} items={[
        {kind:"item",label:menu.archived ? "Restore" : "Archive",icon:menu.archived ? Ic.ReopenIcon : Ic.ArchiveIcon,onClick:()=>void archiveController(menu.slug,menu.archived)}
      ]} onClose={()=>setControllerMenu(null)} />}</Show>
      <Show when={fileMenu()} keyed>{menu => <PopupMenu x={menu.x} y={menu.y} focus={false} onClose={() => setFileMenu(null)} items={[
        { kind: "item", label: "Rename", icon: Ic.PencilIcon, onClick: () => beginFileAction(menu.slug, menu.path, "rename") },
        { kind: "item", label: "Move…", icon: Ic.FolderIcon, onClick: () => beginFileAction(menu.slug, menu.path, "move") },
        { kind: "sep" },
        { kind: "item", label: "Cut", icon: Ic.CutIcon, onClick: () => void copyFile(menu.slug, menu.path, false) },
        { kind: "item", label: "Copy", icon: Ic.CopyIcon, onClick: () => void copyFile(menu.slug, menu.path, true) },
        { kind: "sep" },
        { kind: "item", label: "Delete…", icon: Ic.TrashIcon, danger: true, onClick: () => beginFileAction(menu.slug, menu.path, "delete") },
      ]} />}</Show>
      <Show when={fileAction()} keyed>{target => <Show when={target.kind === "delete"} fallback={
        <PromptSheet title={`${target.kind === "rename" ? "Rename" : "Move"} ${target.directory ? "folder" : "file"}`} hint={target.kind === "move" ? "Destination folder within this project. Leave empty for the project root." : target.directory ? `${target.path} — its files, agents and crons keep their place inside.` : target.path}
          label={target.kind === "rename" ? (target.directory ? "Folder name" : "File name") : "Destination folder"} value={fileActionValue()} onInput={setFileActionValue}
          action={target.kind === "rename" ? "Rename" : "Move"} busy={fileBusy()} error={fileActionError()}
          disabled={target.kind === "rename" && !fileActionValue().trim()} onAction={() => void saveFileAction()} onClose={() => !fileBusy() && setFileAction(null)} />
      }><ConfirmDialog title={target.directory ? "Delete folder?" : "Delete file?"} description={target.directory ? `Delete ${target.path} and all files and subfolders inside? This cannot be undone.` : `Delete ${target.path}?`} action="Delete" busy={fileBusy()} error={fileActionError()} onConfirm={() => void saveFileAction()} onClose={() => !fileBusy() && setFileAction(null)} /></Show>}</Show>
      <Show when={actionMenu()}>
        {(menu) => <PopupMenu {...menu()} focus={actionFocus()} items={menuItems(menu().slug, menu().path)} onClose={() => setActionMenu(null)} />}
      </Show>
      <Show when={missionMenu()}>
        {(menu) => <PopupMenu x={menu().x} y={menu().y} focus={false} items={missionMenuItems(menu().mission, menu().x, menu().y)} onDismissSubmenu={() => setForkTarget(null)} onClose={() => { setForkTarget(null); setMissionMenu(null); }}>
          <Show when={forkTarget()}>{target =>
            <ForkMission mission={target().mission} choices={p.forkChoices?.(target().mission) ?? p.harnessChoices} onOpen={() => p.onForkOpen?.(target().mission)} destination={missionDestination(target().mission)}
              position={{ x: target().x, y: target().y }} onClose={() => setForkTarget(null)}
              onFork={mission => { setForkTarget(null); setMissionMenu(null); p.onFork(mission); }} />
          }</Show>
        </PopupMenu>}
      </Show>
      <div ref={rowTip.setCard} id={rowTip.id} class="row-tip" role="tooltip" hidden={!rowTip.tip()} style={rowTip.tip() ? { left: `${rowTip.tip()!.x}px`, top: `${rowTip.tip()!.y}px` } : undefined}>
        <Show when={rowTip.tip()}>{(tip) => (
          <>
            <div class="row-tip-title">{tip().title}</div>
            <For each={tip().meta}>{(line) => <div class="row-tip-meta">{line}</div>}</For>
          </>
        )}</Show>
      </div>
      <Show when={rename()}>
        {(target) => (
          <PromptSheet
            title="Rename"
            hint={"path" in target() ? "Display name saved on this device. Files and agent paths stay the same." : "slug" in target() ? (target() as { slug: string }).slug : undefined}
            label={"missionId" in target() ? "Mission name" : "path" in target() ? "Folder name" : "Project name"}
            placeholder={"missionId" in target() ? "Mission name" : "path" in target() ? "Folder name" : "Project name"}
            value={renameValue()}
            onInput={setRenameValue}
            action="Save"
            busy={renaming()}
            disabled={!renameValue().trim()}
            error={renameError()}
            onAction={() => void saveRename()}
            onClose={() => !renaming() && setRename(null)}
          />
        )}
      </Show>
      <Show when={newFolder()}>
        {(target) => (
          <PromptSheet
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
          <PromptSheet
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
      <Show when={cronInfo()}>{(slug) => <Dialog title="Project crons" onClose={() => setCronInfo(null)} footer={<><DialogButton disabled={cronChecking()} onClick={async () => { if (!isConnected()) return; const version = connectionVersion(); setCronChecking(true); await loadCrons(slug(), true); if (!currentConnection(version)) return; setCronChecking(false); if (!cronUnsupported() && !cronErrors[slug()]) setCronInfo(null); }}>Check again</DialogButton></>}>
        <p>{cronUnsupported() ? "This backend does not support project crons yet. Update the connected backend, then choose Check again. Your canonical controller and existing project content remain available." : cronRetryable[slug()] ? "Project crons could not refresh. Previously loaded jobs are retained. Try again when the scheduler is available." : "The backend rejected this cron request. Check backend access and configuration, then check again. Previously loaded jobs are retained."}</p>
      </Dialog>}</Show>
      <Show when={newCron()}>
        {(slug) => <Dialog size="wide" busy={makingCron()} title={cronFolder() ? `New cron · ${cronFolder()}` : "New cron"} onClose={() => !makingCron() && setNewCron(null)} footer={<span>Unfinished drafts are kept until saved or discarded.</span>}>
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
      <Show
        when={editing()}
        fallback={
          <div class="scroll">
            <div class="col">
              <Show when={state() === "error"}>
                <ErrorNotice error={error()!} />
              </Show>
              <Show when={text() !== null} fallback={<FileSkeleton />}>
                <MdView text={text() ?? ""} />
              </Show>
            </div>
          </div>
        }
      >
        <div class="file-view">
          <Show when={state() === "error"}><ErrorNotice error={error()!}/></Show>
          <Show when={text() !== null} fallback={<p class="s-lead shimmer">Loading {name()}…</p>}>
            <MdSource text={text() ?? ""} onInput={onInput} />
          </Show>
        </div>
      </Show>
    </>
  );
}
