import { movedMission, withMovedMissions } from "./moves";
import { renamedTitle, withRenamedTitles } from "./renames";
import { readString, writeString } from "./storage";
import { nodeLabel } from "./machines/nodes";
import { isLive } from "./missionStatus";
import { swallow } from "./log";
import { connectClientLink, reportClientHarnesses, type RemoteStart } from "./clientLink";
import {requireSpeedSupport} from './CodexSpeedPicker';
import { Menu } from "./Menu";
import { missionParent } from "./missionTree";
import { draftCyber, setDraftCyber, requireCyberSupport } from "./cyberAccess";
import {trackScrollbarHover} from "./scrollbarHover";
import {WorkingDirectoryPicker} from "./WorkingDirectoryPicker";
import { MessageCircle } from "./sidebarIcons";
import {MentionProjectContext} from "./PromptEditor";
import { startLocalWakeups } from "./localWakeups";
import { startClientDelegations } from "./clientDelegations";
import { navigationShortcut, shortcutLabel } from "./keyboardShortcuts";
import {preferSparkAdministration} from "./machineDestinations";
import { CloudAgentPage } from "./CloudAgents";
import { monitorSoftware } from "./softwareInventory";
import {startLocalQueueWorker} from "./localMessageQueue";
import {BtwSettings} from "./btwSettings";
import {type PlanProgressData} from "./PlanProgress";
import { startLocalOrigin, localAgentForLaunch } from "./localAgents";
import { MachineLoadBadge, byLeastLoaded, firstAvailableNodeId, recordFleet, recordMissions } from "./machineLoad";
import { imagePrompt, stageLocalImages, stageRemoteImages, type DraftImage } from "./imageAttachments";
import { FilePanelProvider, FilePanelButton } from "./FilePanel";
import { ErrorToast } from "./toast";
import { rememberLaunch, recalledLaunch, missionDestination, launchRefusal, isAdministrationNode, remoteLaunchPreflight, remoteHarnessSupport, remoteLaunchUnconfirmed, missionGoal, type LaunchReceipt, type LaunchRefusal, type RemoteSupport } from "./missionLaunch";
import { goalDraft, goalPrompt, planObjective, missionTitle, displayTitle, EMPTY_GOAL_ERROR } from "./goal";
import { chipToAttachment, type AttachChip } from "./attach";
import { DEFAULT_PROJECT, ensureDefaultProject, projectChoices } from "./defaultProject";
import { ProjectPicker, ProjectCreation } from "./ProjectPicker";
import { hasOverlay } from "./overlayLayer";
import { For, Show, Switch, Match, lazy, createMemo, createSignal, createEffect, on, onCleanup, onMount, batch } from "solid-js";
import * as Ic from "./icons";
const Settings=lazy(()=>import("./Settings").then(module=>({default:module.Settings})));
import { ProviderLogo } from "./ProviderLogo";
import { SessionPreview, type SessionPreviewData } from "./SessionPreview";
import { RoutingSettings, confirmLeaveRouting } from "./RoutingSettings";
import { MACHINES, Machines } from "./Machines";
const Providers=lazy(()=>import("./Providers").then(module=>({default:module.Providers})));
import { PopupMenu, type MenuEntry } from "./Menu";
import { mdSource, toggleMdSource } from "./Markdown";
import { applyPendingMoves } from "./missionMove";
import { cacheRecents } from "./pageCache";
import { effortLabel, normalizeEffort } from "./effort";
import { loadTranscript, peekReadyTranscript, prefetchTranscript, transcriptVersion } from "./missionCache";
import { mergeById, pollWhileVisible } from "./poll";
import { getSecretBroker } from "./bitwardenApi";
import { syncSecretRequestNotices } from "./secretRequestNotices";
import { listApprovalDevices, thisDeviceEnrollment } from "./deviceApproval";
import { LiveProjectsSection, ProjectFileView, isMissionDeleting } from "./ProjectFiles";
const ProjectSettings=lazy(()=>import("./ProjectSettings").then(module=>({default:module.ProjectSettings})));
import {
  bindWorkspace,
  installedIds,
  localBinding,
  localAgentsScanning,
  localWorkspace,
  localDirectory,
  materializeMentions,
  refreshLocalAgents,
  writeLocalFiles,
} from "./localAgents";
import { ControllerView } from "./Controller";
import {
  createMission,
  getMission,
  getRemoteNodes,
  isConnected,
  listCompletedMissions,
  listMissions,
  listProjectMissions,
  listProjects,
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
const BitwardenSettings = lazy(() => import("./BitwardenSettings").then(module => ({ default: module.BitwardenSettings })));
import { InboxPage } from "./Inbox";
import { requestInboxDigest } from "./inboxDigest";
import { countUnreadInboxMissions, listUnreadInboxCandidates } from "./inboxModel";
import { InboxSettings, inboxConfig } from "./inboxSettings";
import { pendingMissionInteraction } from "./missionAttention";
import { markMissionRead, unreadVersion } from "./missionUnread";

import { harnessChoices, harnessPick, effectivePick, refreshHarnessChoices, refreshNodeAntigravityModels, type HarnessPick } from "./harnessPick";
import { Composer } from "./composer/Composer";
import { MissionView, NativeMissionView } from "./mission/MissionView";


const PAGES = new Set(["inbox", "cloud-agent", "settings", "inbox-settings", "btw-settings", "hermes-settings", "skills-settings", "bitwarden-settings", "usage-settings", "routing", "machines", "providers", "execution"]);

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

  const [rawMissions, setMissions] = createSignal<Mission[]>([]);
  // Pending moves show every mission in its new project before Core confirms.
  const missions = createMemo(() => withMovedMissions(rawMissions()));
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
    return withMovedMissions(withRenamedTitles("mission", prevInboxMissions, m => m.id));
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
    const found = openMission()?.id === id ? openMission() : missions().find(m => m.id === id);
    const mission = found ? movedMission(found) : found;
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

  const onSettings = () => selected() === "settings" || selected() === "execution" || selected() === "routing" || selected() === "inbox-settings" || selected() === "btw-settings" || selected() === "hermes-settings" || selected() === "skills-settings" || selected() === "bitwarden-settings" || selected() === "usage-settings";
  const openSettings = () => {
    open("settings");
  };
  const leaveSettings = () => {
    const h = history();
    for (let i = hIdx() - 1; i >= 0; i--) {
      if (h[i] !== "settings" && h[i] !== "routing" && h[i] !== "inbox-settings" && h[i] !== "btw-settings" && h[i] !== "hermes-settings" && h[i] !== "skills-settings" && h[i] !== "bitwarden-settings" && h[i] !== "usage-settings") {
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
                    currentMission={openMission()?.id === currentMissionId() && openMission() ? movedMission(openMission()!) : undefined}
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
            <button class={`row ${selected() === "usage-settings" ? "active" : ""}`} onClick={() => open("usage-settings")}><span class="row-ico"><Ic.UsageIcon /></span><span class="row-label">Usage</span></button>
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
            <Match when={selected() === "usage-settings"}><span>Settings · Usage</span></Match>
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
          <Match when={selected() === "usage-settings"}><UsageSettings /></Match>
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

