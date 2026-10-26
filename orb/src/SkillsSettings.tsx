import { HARNESS_IDS } from "./harnesses";
import { swallow } from "./log";
import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, onMount } from "solid-js";
import * as Ic from "./icons";
import { Select } from "./Select";
import { ConfirmDialog, Field, NameDialog } from "./Dialog";
import { PopupMenu, type MenuEntry } from "./Menu";
import {
  connectionVersion,
  getRemoteNodes,
  isConnected,
  listLibrarySkills,
  listProjectFiles,
  listProjects,
  readProjectFile,
  type LibrarySkill,
  type LibrarySkillSummary,
  type ProjectSummary,
  type RemoteNodeView,
} from "./api";
import {
  localInstalled,
  localSkillsStatus,
  localSkillsSync,
  readLegacySkillFiles,
  refreshLocalAgents,
  type HarnessSkillTarget,
  type LocalSkillsReport,
  type SkillSourceRef,
  type SyncSkillPayload,
} from "./localAgents";
import { refreshSoftware, softwareMachines } from "./softwareInventory";
import { effectiveAudience, newSkillTemplate, normalizeSkillName, parseSkillMeta, setSandboxedMeta } from "./skillModel";
import { SKILL_BADGE_LABEL, buildSkillRows, needsAttention, skillBadge, type ProjectContextSkill, type SkillRow } from "./skillRows";
import { commitAndPush, deleteLibrarySkill, fetchLibrarySkill, getLibraryStatus, getProjectSkills, putLibrarySkill, putProjectSkills, putSkillFile, readSkillFile, repoLabel, syncLibrary, type LibraryStatus } from "./skillsApi";
import { orbRelativeTimeString } from "./orbKernel";
import { SkillDetail, dropsSandboxedMetadata } from "./SkillDetail";
import { SkillDeliveryPreview } from "./SkillDelivery";

export interface HarnessCatalogRow {
  id: string;
  name: string;
  installed: boolean;
  version: string | null;
  binPath: string | null;
  globalRel: string;
  projectRel: string;
  skillCount: number;
  syncedCount: number;
  canonicalTotal: number;
  missingSkills: string[];
  state: "synced" | "drift" | "attention" | "unsupported" | "missing";
  statusLabel: string;
  mechanism: string;
  warning?: string;
}

const HARNESS_META: Record<
  string,
  {
    name: string;
    globalRel: string;
    projectRel: string;
    mechanism: string;
    warning?: string;
  }
> = {
  claudecode: {
    name: "Claude Code",
    globalRel: "~/.claude/skills",
    projectRel: ".claude/skills",
    mechanism: "Native SKILL.md discovery in project and user directories",
  },
  codex: {
    name: "Codex",
    globalRel: "~/.codex/skills · ~/.agents/skills",
    projectRel: ".agents/skills",
    mechanism: "Scans .agents/skills from cwd to repo root plus ~/.codex/skills",
  },
  vibe: { name: "Mistral Vibe", globalRel: "~/.vibe/skills", projectRel: ".vibe/skills", mechanism: "Native Vibe skill discovery" },
  antigravity: {
    name: "Antigravity",
    globalRel: "~/.agents/skills",
    projectRel: ".agents/skills",
    mechanism: "Workspace .agents/skills and global ~/.agents/skills",
  },
  opencode: {
    name: "OpenCode",
    globalRel: "~/.config/opencode/skills",
    projectRel: ".opencode/skills",
    mechanism: "Walks .opencode/skills and .claude/skills compatibility paths",
  },
  grok: {
    name: "Grok",
    globalRel: "~/.grok/skills",
    projectRel: ".grok/skills",
    mechanism: "Loads .grok/skills, .claude/skills, and .agents/skills when trusted",
    warning: "Requires directory trust in ~/.grok/user-settings.json for project skills",
  },
  hermes: {
    name: "Hermes Coordinator",
    globalRel: "/var/lib/hermes-assistant/skills",
    projectRel: "Cron skills[]",
    mechanism: "Preloads skills attached to each project controller cron on Core",
  },
};

const HARNESS_ORDER = [
  "claudecode",
  "codex",
  "antigravity",
  "vibe",
  "opencode",
  "grok",
  "hermes",
] as const;


let cachedSkillNames: string[] = [
  "controllers-policy",
  "project-manager",
  "sandboxed-sh-missions",
  "development-identity",
  "paloma-backends",
  "paloma-ssh-servers",
];

/** Reactive list of known skill names for autocomplete in ControllerSettings. */
let cachedReport: LocalSkillsReport | null = null;

export function knownSkillNames(): string[] {
  return cachedSkillNames;
}

export function rememberKnownSkillNames(names: Iterable<string>) {
  const merged = new Set(cachedSkillNames);
  for (const name of names) {
    const trimmed = name.trim();
    if (trimmed) merged.add(trimmed);
  }
  cachedSkillNames = [...merged].sort();
}


const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));
/** Plain words instead of a raw 500 dump; the detail stays in the message for support. */
function deleteMessage(name: string, e: unknown): string {
  const raw = errorText(e).replace(/^\d{3}\s+/, "");
  if (/gpg|sign/i.test(raw)) return `Core couldn’t sign the Library commit, so ${name} is still there. (${raw.slice(0, 120)})`;
  if (/push|rejected|denied/i.test(raw)) return `Core couldn’t push the Library, so the delete isn’t saved yet. (${raw.slice(0, 120)})`;
  return `Couldn’t delete ${name}: ${raw}`;
}

export function SkillsSettings(p: { onOpenPage?: (id: string) => void } = {}) {
  const [machine, setMachine] = createSignal<string>("local");
  const [remoteNodes, setRemoteNodes] = createSignal<RemoteNodeView[]>([]);
  // Per-harness reads are cached for the session; reopening shows them at once and refreshes behind.
  const [localReport, setLocalReport] = createSignal<LocalSkillsReport | null>(cachedReport);
  const [librarySkills, setLibrarySkills] = createSignal<LibrarySkillSummary[]>([]);
  const [libraryFull, setLibraryFull] = createSignal<Record<string, LibrarySkill>>({});
  const [libraryLoaded, setLibraryLoaded] = createSignal(false);
  const [libraryError, setLibraryError] = createSignal<string | null>(null);
  const [projects, setProjects] = createSignal<ProjectSummary[]>([]);
  const [projectSkills, setProjectSkills] = createSignal<ProjectContextSkill[]>([]);
  // Library skills each project lists (PUT /api/projects/:slug/skills), keyed by project slug.
  const [projectSelections, setProjectSelections] = createSignal<Record<string, string[]>>({});
  const [loading, setLoading] = createSignal(false);
  const [syncing, setSyncing] = createSignal(false);
  const [syncNotice, setSyncNotice] = createSignal<string | null>(null);
  const [syncError, setSyncError] = createSignal<string | null>(null);
  const [search, setSearch] = createSignal("");
  const [attentionOnly, setAttentionOnly] = createSignal(false);
  const [advancedOpen, setAdvancedOpen] = createSignal(false);
  // Rows being deleted are hidden at once and come back if the delete fails.
  const [deleting, setDeleting] = createSignal<ReadonlySet<string>>(new Set());
  const [rowMenu, setRowMenu] = createSignal<{ row: SkillRow; x: number; y: number } | null>(null);
  const [openView, setOpenView] = createSignal<"edit" | "history">("edit");
  const [confirmRowDelete, setConfirmRowDelete] = createSignal<string | null>(null);
  const [rowDeleteBusy, setRowDeleteBusy] = createSignal(false);
  const [rowDeleteError, setRowDeleteError] = createSignal<string | null>(null);
  const [repo, setRepo] = createSignal<LibraryStatus | null>(null);
  const [pulling, setPulling] = createSignal(false);
  const [openSkill, setOpenSkill] = createSignal<string | null>(null);
  const [creating, setCreating] = createSignal(false);
  const [newName, setNewName] = createSignal("");
  const [newDesc, setNewDesc] = createSignal("");
  const [createBusy, setCreateBusy] = createSignal(false);
  const [createError, setCreateError] = createSignal<string | null>(null);

  const harnessTotal = () => localReport()?.harnesses.length || HARNESS_IDS.length;

  const payloadFor = (skill: LibrarySkill, summary?: LibrarySkillSummary, extra: SyncSkillPayload["files"] = []): SyncSkillPayload => ({
    name: skill.name,
    content: skill.content,
    files: [
      ...(skill.files ?? []).filter((f) => (f.path || f.name) !== "SKILL.md").map((f) => ({ rel: f.path || f.name, content: f.content })),
      ...(extra ?? []),
    ],
    audience: summary?.audience ?? null,
    scope: summary?.scope ?? null,
  });

  const libraryPayloads = (): SyncSkillPayload[] | undefined => {
    if (!libraryLoaded()) return undefined;
    const full = libraryFull();
    return librarySkills().flatMap((s) => (full[s.name] ? [payloadFor(full[s.name], s)] : []));
  };

  /** Fetch every Library skill body; the Library is the canonical source for local sync. */
  // Rows render from the Library index at once; bodies (needed for drift and
  // divergence) arrive in the background and land in one update.
  const loadLibrary = async (): Promise<{ bodies: Promise<void> }> => {
    const items = await listLibrarySkills();
    setLibrarySkills(items);
    setLibraryError(null);
    rememberKnownSkillNames(items.map((s) => s.name));
    const bodies = (async () => {
      const fetched = await Promise.all(items.map((s) => fetchLibrarySkill(s.name).catch(() => null)));
      const map: Record<string, LibrarySkill> = {};
      for (const skill of fetched) if (skill) map[skill.name] = skill;
      setLibraryFull(map);
      setLibraryLoaded(true);
    })();
    // Wrapped: an async function returning a bare promise would wait for it.
    return { bodies };
  };

  const refreshReport = async () => {
    const rep = await localSkillsStatus(libraryPayloads());
    if (rep) {
      cachedReport = rep;
      setLocalReport(rep);
      rememberKnownSkillNames(rep.skills.map((s) => s.name));
    }
  };

  const loadAll = async (force = false) => {
    setLoading(true);
    setSyncError(null);
    try {
      const side: Promise<unknown>[] = [refreshLocalAgents(force).catch(() => []), refreshSoftware(force).catch(swallow("skills.refreshSoftware"))];
      if (isConnected()) {
        const { bodies } = await loadLibrary().catch((e) => {
          setLibraryLoaded(false);
          setLibraryError(errorText(e));
          return { bodies: Promise.resolve() };
        });
        void getLibraryStatus().then(setRepo).catch(() => setRepo(null));
        // Drift needs the bodies; it fills the badges in when ready.
        side.push(bodies.then(() => refreshReport()).catch((e) => setSyncError(errorText(e))));
        side.push(getRemoteNodes().then((res) => setRemoteNodes(res.nodes ?? [])).catch(swallow("skills.remoteNodes")));
        side.push(loadProjectSkills());
      } else {
        setLibrarySkills([]);
        setLibraryFull({});
        setLibraryLoaded(false);
        setProjects([]);
        setProjectSkills([]);
      }
      if (!isConnected()) side.push(refreshReport().catch((e) => setSyncError(errorText(e))));
      setLoading(false);
      await Promise.all(side);
    } finally {
      setLoading(false);
    }
  };

  const loadProjectSkills = async () => {
    if (!isConnected()) return;
    const projs: ProjectSummary[] = await listProjects().catch(() => []);
    setProjects(projs);
    void Promise.all(projs.map(async (proj) => [proj.slug, (await getProjectSkills(proj.slug).catch(() => ({ skills: [] as string[] }))).skills] as const))
      .then((pairs) => setProjectSelections(Object.fromEntries(pairs)));
    const resolved = await Promise.all(
      projs.map(async (proj) => {
        try {
          const entries = await listProjectFiles(proj.slug, "skills");
          const dirs = entries.filter((e) => e.kind === "dir" && !e.name.startsWith("."));
          return await Promise.all(
            dirs.map(async (d): Promise<ProjectContextSkill> => {
              const path = `skills/${d.name}/SKILL.md`;
              let description: string | undefined;
              try {
                description = parseSkillMeta(await readProjectFile(proj.slug, path)).description;
              } catch {
                /* optional description */
              }
              return { slug: proj.slug, name: d.name, path, description };
            }),
          );
        } catch {
          return [];
        }
      }),
    );
    const flat = resolved.flat();
    rememberKnownSkillNames(flat.map((s) => s.name));
    setProjectSkills(flat);
  };

  onMount(() => {
    const onRefresh = () => void loadAll(true);
    window.addEventListener("orb:refresh", onRefresh);
    onCleanup(() => window.removeEventListener("orb:refresh", onRefresh));
  });

  // The one load on open (and on reconnect); online it also reads the Library.
  createEffect(on(connectionVersion, () => void loadAll(false)));

  const machineOptions = createMemo(() => {
    const opts = [{ id: "local", label: "This Mac (Local Harnesses)" }];
    if (isConnected()) {
      opts.push({ id: "core", label: "Core (agent-core)" });
      for (const node of remoteNodes()) opts.push({ id: node.id, label: `${node.id} (${node.status})` });
    }
    return opts;
  });

  const harnessRows = createMemo<HarnessCatalogRow[]>(() => {
    const targetMachine = machine();
    const report = localReport();
    const localClis = localInstalled();
    const softMachine = softwareMachines().find((m) => m.id === targetMachine);
    const libCount = librarySkills().length;

    return HARNESS_ORDER.map((id) => {
      const meta = HARNESS_META[id];

      if (id === "hermes") {
        const connected = isConnected();
        return {
          id,
          name: meta.name,
          installed: connected,
          version: connected ? "Gateway active" : null,
          binPath: "/usr/local/bin/hermes",
          globalRel: meta.globalRel,
          projectRel: meta.projectRel,
          skillCount: libCount,
          syncedCount: libCount,
          canonicalTotal: libCount,
          missingSkills: [],
          state: connected ? "synced" : "missing",
          statusLabel: connected ? "Controller skills ready" : "Connect backend",
          mechanism: meta.mechanism,
        };
      }

      if (targetMachine === "local") {
        const cli = localClis.find((c) => c.id === id);
        const soft = softMachine?.inventory?.components.find((c) => c.id === id);
        const target: HarnessSkillTarget | undefined = report?.harnesses.find((h) => h.id === id);
        const installed = Boolean(cli?.installed || soft?.installed || target?.exists);
        const version = cli?.version ?? soft?.version ?? null;
        const binPath = cli?.path ?? soft?.path ?? null;
        const skillCount = target?.skill_count ?? 0;
        const syncedCount = target?.synced_count ?? 0;
        const canonicalTotal = target?.canonical_total ?? 0;
        const missingSkills = target?.missing_skills ?? [];

        let state: HarnessCatalogRow["state"] = "synced";
        let statusLabel = `${skillCount} skill${skillCount === 1 ? "" : "s"}`;

        if (!installed && skillCount === 0) {
          state = "missing";
          statusLabel = "CLI not installed";
        } else if (canonicalTotal > 0 && syncedCount < canonicalTotal) {
          state = "drift";
          statusLabel = `Out of sync · ${syncedCount}/${canonicalTotal}`;
        } else if (id === "grok") {
          state = "attention";
          statusLabel = `Synced · ${skillCount} (trust required)`;
        } else if (canonicalTotal > 0) {
          state = "synced";
          statusLabel = `Synced · ${skillCount} skills`;
        }

        return {
          id,
          name: meta.name,
          installed,
          version,
          binPath,
          globalRel: target?.global_rel ?? meta.globalRel,
          projectRel: target?.project_rel ?? meta.projectRel,
          skillCount,
          syncedCount,
          canonicalTotal,
          missingSkills,
          state,
          statusLabel,
          mechanism: meta.mechanism,
          warning: meta.warning,
        };
      }

      // Remote machine (Core or Fleet node)
      const soft = softMachine?.inventory?.components.find((c) => c.id === id);
      const installed = Boolean(soft?.installed);
      const version = soft?.version ?? null;
      const binPath = soft?.path ?? null;
      const isCore = targetMachine === "core";

      let state: HarnessCatalogRow["state"] = installed ? "synced" : "missing";
      let statusLabel = !installed
        ? "Not installed on node"
        : isCore
          ? `Library synced · ${libCount} skills`
          : "Project & identity skills on launch";

      if (installed && id === "grok") {
        state = "attention";
        statusLabel = "Installed · requires trust";
      }

      return {
        id,
        name: meta.name,
        installed,
        version,
        binPath,
        globalRel: isCore ? "~/.sandboxed-sh/library/skill" : meta.globalRel,
        projectRel: meta.projectRel,
        skillCount: isCore ? libCount : 1,
        syncedCount: isCore ? libCount : 1,
        canonicalTotal: isCore ? libCount : 1,
        missingSkills: [],
        state,
        statusLabel,
        mechanism: isCore
          ? "Core syncs Library skills into Default Host + prepares @context/skills per mission"
          : "Node materializes @context/skills and development-identity into the mission worktree",
        warning: meta.warning,
      };
    });
  });

  const driftCount = createMemo(() => {
    const rep = localReport();
    if (!rep) return 0;
    return rep.harnesses.filter((h) => (h.canonical_total > 0 && h.synced_count < h.canonical_total) || (rep.library_known && (h.stale_managed?.length ?? 0) > 0)).length;
  });

  const rows = createMemo(() =>
    buildSkillRows({
      report: localReport(),
      summaries: librarySkills(),
      library: libraryFull(),
      projectSkills: projectSkills(),
      localHarnessIds: HARNESS_IDS,
    }),
  );
  const membership = (name: string) => Object.entries(projectSelections()).filter(([, names]) => names.includes(name)).map(([slug]) => slug).sort();
  const searched = createMemo(() => {
    const q = search().trim().toLowerCase();
    return q ? rows().filter((row) => row.name.toLowerCase().includes(q) || row.description.toLowerCase().includes(q)) : rows();
  });
  const attentionCount = createMemo(() => searched().filter(needsAttention).length);
  const filteredRows = createMemo(() => (attentionOnly() ? searched().filter(needsAttention) : searched()).filter((row) => !deleting().has(row.name)));
  const saveProjects = async (name: string, next: string[]) => {
    const current = projectSelections();
    const changed = projects().filter((proj) => (current[proj.slug] ?? []).includes(name) !== next.includes(proj.slug));
    const updated = { ...current };
    for (const proj of changed) {
      const list = current[proj.slug] ?? [];
      const skills = next.includes(proj.slug) ? [...list, name] : list.filter((n) => n !== name);
      updated[proj.slug] = (await putProjectSkills(proj.slug, skills)).skills;
    }
    setProjectSelections(updated);
  };
  const openRow = createMemo(() => rows().find((r) => r.name === openSkill() && !r.name.startsWith("project:")) ?? null);

  /** Sync local harnesses from the Library snapshot. Pruning removes Orb-managed leftovers only. */
  const syncNow = async (prune: boolean, label?: string) => {
    setSyncing(true);
    setSyncNotice(null);
    setSyncError(null);
    try {
      const base = libraryPayloads() ?? [];
      // Non-markdown reference files are not inlined in the skill body; fetch them for install.
      const payloads = await Promise.all(base.map(async (pl) => {
        const refs = (libraryFull()[pl.name]?.references ?? []).filter((r) => !pl.files?.some((f) => f.rel === r));
        if (!refs.length) return pl;
        const extra = await Promise.all(refs.map(async (rel) => ({ rel, content: await readSkillFile(pl.name, rel).catch(() => "") })));
        return { ...pl, files: [...(pl.files ?? []), ...extra] };
      }));
      const result = await localSkillsSync({ librarySkills: payloads, pruneRemoved: prune && libraryLoaded() });
      setLocalReport(result.report);
      rememberKnownSkillNames(result.report.skills.map((s) => s.name));
      cachedReport = result.report;
      if (label) setSyncNotice(label);
    } catch (e) {
      setSyncError(errorText(e));
    } finally {
      setSyncing(false);
    }
  };

  /** Pull from the repo, then bring every harness up to date. */
  const pull = async () => {
    if (pulling()) return;
    setPulling(true);
    setSyncError(null);
    try {
      await syncLibrary();
      await loadAll(true);
      await syncNow(false);
    } catch (e) {
      setSyncError(`Couldn’t pull the Library: ${errorText(e)}`);
    } finally {
      setPulling(false);
    }
  };

  // Out-of-date harnesses are brought in line automatically once drift is known.
  let autoSynced = false;
  createEffect(() => {
    if (!autoSynced && libraryLoaded() && driftCount() > 0 && !syncing()) { autoSynced = true; void syncNow(false); }
  });

  /** Keep this Mac's edit: it becomes the Library version. */
  const keepLocal = async (row: SkillRow) => {
    const local = row.sources.find((src) => src.id !== "library" && src.content);
    if (!local?.content) throw new Error("This copy has no readable SKILL.md.");
    // A local copy without metadata.sandboxed must not silently drop who uses the skill.
    const lib = libraryFull()[row.name]?.content;
    const content = dropsSandboxedMetadata(lib, local.content) ? setSandboxedMeta(local.content, effectiveAudience(parseSkillMeta(lib!)), parseSkillMeta(lib!).scope ?? null, row.name) : local.content;
    await saveSkill(row.name, content);
  };

  const refetchSkill = async (name: string) => {
    const skill = await fetchLibrarySkill(name);
    setLibraryFull((prev) => ({ ...prev, [name]: skill }));
    if (!librarySkills().some((s) => s.name === name)) setLibrarySkills(await listLibrarySkills());
  };

  /** Save to the Library and land it in the repo (commit + push), then sync harnesses. */
  const saveSkill = async (name: string, content: string, message = `skill: update ${name}`) => {
    await putLibrarySkill(name, content);
    await commitAndPush(message);
    void getLibraryStatus().then(setRepo).catch(() => {});
    await refetchSkill(name);
    await syncNow(false);
  };

  const importSkill = async (name: string, src: SkillSourceRef, rels: string[]) => {
    if (!src.content) throw new Error("This copy has no readable SKILL.md.");
    // Read only the files the user kept checked; the native side re-applies the allowlist.
    const files = await readLegacySkillFiles(src.id, name, rels);
    await putLibrarySkill(name, src.content);
    for (const f of files) await putSkillFile(name, f.rel, f.content);
    await commitAndPush(`skill: import ${name}`);
    setLibrarySkills(await listLibrarySkills());
    await refetchSkill(name);
    await syncNow(false, `Imported "${name}" from ${src.label} and saved it to the repo.`);
  };

  /** Delete from the Library and the repo. The row hides at once and returns on failure.
   * Retry-safe: a skill already gone from the Library (an earlier try that failed at commit)
   * only needs the commit and push. */
  const removeSkill = async (name: string) => {
    setDeleting((prev) => new Set([...prev, name]));
    try {
      await deleteLibrarySkill(name).catch((e) => { if (!/not found|404/i.test(errorText(e))) throw e; });
      await commitAndPush(`skill: delete ${name}`);
    } catch (e) {
      setDeleting((prev) => { const next = new Set(prev); next.delete(name); return next; });
      throw new Error(deleteMessage(name, e));
    }
    setLibrarySkills((list) => list.filter((s) => s.name !== name));
    setLibraryFull((prev) => {
      const next = { ...prev };
      delete next[name];
      return next;
    });
    setDeleting((prev) => { const next = new Set(prev); next.delete(name); return next; });
    void syncNow(true);
  };

  const confirmDeleteRow = async () => {
    const name = confirmRowDelete();
    if (!name || rowDeleteBusy()) return;
    setRowDeleteBusy(true);
    setRowDeleteError(null);
    try { await removeSkill(name); setConfirmRowDelete(null); }
    catch (e) { setRowDeleteError(errorText(e)); }
    finally { setRowDeleteBusy(false); }
  };

  const menuFor = (row: SkillRow): MenuEntry[] => {
    const badge = skillBadge(row);
    const local = row.sources.find((x) => x.id !== "library" && x.content);
    const act = (fn: () => Promise<void>) => () => { setSyncError(null); void fn().catch((e) => setSyncError(errorText(e))); };
    return [
      { kind: "item", label: "Edit", icon: Ic.PencilIcon, onClick: () => { setOpenView("edit"); openRowDetail(row); } },
      ...(row.inLibrary ? [{ kind: "item" as const, label: "History", icon: Ic.ReopenIcon, onClick: () => { setOpenView("history"); openRowDetail(row); } }] : []),
      ...(badge === "edited" && isConnected() ? [
        { kind: "sep" as const },
        { kind: "item" as const, label: "Keep this Mac’s version", onClick: act(() => keepLocal(row)) },
        { kind: "item" as const, label: "Discard this Mac’s edit", onClick: act(() => syncNow(false)) },
      ] : []),
      ...(badge === "old-folder" && local && isConnected() ? [
        { kind: "sep" as const },
        { kind: "item" as const, label: "Import to the Library", onClick: act(() => importSkill(row.name, local, local.files?.map((f) => f.rel) ?? [])) },
      ] : []),
      ...(row.inLibrary && isConnected() ? [
        { kind: "sep" as const },
        { kind: "item" as const, label: "Delete…", icon: Ic.TrashIcon, danger: true, onClick: () => { setRowDeleteError(null); setConfirmRowDelete(row.name); } },
      ] : []),
    ];
  };

  const filesChanged = async (name: string) => {
    await commitAndPush(`skill: update ${name} files`);
    await refetchSkill(name);
    await syncNow(false);
  };

  const createSkill = async () => {
    const name = normalizeSkillName(newName());
    if (!name) {
      setCreateError("Enter a skill name such as lean-prover.");
      return;
    }
    if (librarySkills().some((s) => s.name === name)) {
      setCreateError(`"${name}" already exists in the Library.`);
      return;
    }
    setCreateBusy(true);
    setCreateError(null);
    try {
      await putLibrarySkill(name, newSkillTemplate(name, newDesc()));
      await commitAndPush(`skill: create ${name}`);
      setLibrarySkills(await listLibrarySkills());
      await refetchSkill(name);
      setCreating(false);
      setNewName("");
      setNewDesc("");
      setOpenSkill(name);
      void syncNow(false);
    } catch (e) {
      setCreateError(errorText(e));
    } finally {
      setCreateBusy(false);
    }
  };

  const openRowDetail = (row: SkillRow) => {
    if (!row.inLibrary && !row.sources.length && row.projectFile) {
      p.onOpenPage?.(`pf:${row.projectFile.slug}:${row.projectFile.path}`);
      return;
    }
    setOpenSkill(row.name);
  };

  const preflight = () => localReport()?.preflight;

  return (
    <div class="s-body settings-body">
      <div class="s-inner skills-settings-page">
        <Show when={syncNotice()}>
          {(msg) => (
            <div class="skills-banner ok" role="status">
              <Ic.CheckIcon size={14} />
              <span>{msg()}</span>
              <button type="button" class="icon-btn" aria-label="Dismiss notice" onClick={() => setSyncNotice(null)}>
                <Ic.CloseIcon size={12} />
              </button>
            </div>
          )}
        </Show>

        <Show when={syncError()}>
          {(err) => (
            <div class="skills-banner error" role="alert">
              <span>{err()}</span>
              <button type="button" class="icon-btn" aria-label="Dismiss error" onClick={() => setSyncError(null)}>
                <Ic.CloseIcon size={12} />
              </button>
            </div>
          )}
        </Show>

        <section class="s-sec" aria-label="Library skills">
          <div class="skills-toolbar">
            <Show when={isConnected()} fallback={<span class="skills-repo dim">Connect to Core to load the Library.</span>}>
              <span class="skills-repo" title={repo()?.remote ?? ""}>
                {repoLabel(repo()?.remote)}
                <span class="dim"> · {pulling() ? "pulling…" : repo()?.last_synced_at ? (() => { const t = orbRelativeTimeString(Date.now() / 1000 - repo()!.last_synced_at!); return t === "now" ? "synced just now" : `synced ${t} ago`; })() : repo() && !repo()!.clean ? `${repo()!.modified_files.length} unsaved changes` : "not synced yet"}</span>
              </span>
              <button type="button" class="icon-btn settings-refresh" classList={{ spinning: pulling() || syncing() }} aria-label="Pull from the repo" title="Pull from the repo and update every agent" disabled={pulling()} onClick={() => void pull()}>
                <Ic.RefreshIcon size={14} />
              </button>
            </Show>
            <input type="search" aria-label="Filter skills" class="s-input skills-search" placeholder="Search skills…" value={search()} onInput={(e) => setSearch(e.currentTarget.value)} />
            <Show when={isConnected()}>
              <button type="button" class="s-btn sm" onClick={() => { setCreating(true); setCreateError(null); }}>+ New</button>
            </Show>
          </div>
          <Show when={attentionCount() > 0 || attentionOnly()}>
            <div class="skills-filter-pills">
              <button type="button" aria-pressed={attentionOnly()} class={`skills-filter-pill ${attentionOnly() ? "on" : ""}`} onClick={() => setAttentionOnly(!attentionOnly())}>
                Needs attention <span class="dim">{attentionCount()}</span>
              </button>
            </div>
          </Show>

          <Show when={libraryError()}>{(err) => <p class="skills-sub-note">Core Library unavailable: {err()}. Showing this Mac only.</p>}</Show>

          <div class="s-card skills-catalog-card">
            <Show when={!(loading() && !rows().length)} fallback={<For each={[0, 1, 2, 3, 4, 5]}>{() => <div class="skills-item skeleton" aria-hidden="true"><div class="skills-item-head"><span class="spend-skel skills-skel-name" /><span class="spend-skel skills-skel-desc" /></div></div>}</For>}>
              <For each={filteredRows()} fallback={<div class="s-row"><div class="s-row-text"><div class="s-row-desc">{attentionOnly() ? "Nothing needs attention." : "No skills match."}</div></div></div>}>
                {(row) => {
                  const badge = () => skillBadge(row);
                  return (
                    <div class="skills-item" data-skill={row.name} onContextMenu={(e) => { e.preventDefault(); setRowMenu({ row, x: e.clientX, y: e.clientY }); }}>
                      <button type="button" class="skills-item-head" onClick={() => { setOpenView("edit"); openRowDetail(row); }}>
                        <Ic.FileIcon size={14} />
                        <span class="skills-item-name">{row.name}</span>
                        <span class="skills-item-desc">{row.description || "No description."}</span>
                        <Show when={badge()}>{(b) => <span class={`skills-badge ${b()}`}>{SKILL_BADGE_LABEL[b()]}</span>}</Show>
                        <Show when={!badge() && row.lint.length}><span class="skills-badge lint" title={row.lint.map((l) => l.message).join("\n")}>Needs a fix</span></Show>
                      </button>
                      <button type="button" class="icon-btn skills-item-more" aria-label={`Actions for ${row.name}`} aria-haspopup="menu" onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); setRowMenu({ row, x: r.right - 200, y: r.bottom + 4 }); }}>
                        <span aria-hidden="true">···</span>
                      </button>
                    </div>
                  );
                }}
              </For>
            </Show>
          </div>
        </section>

        <details class="settings-advanced skills-advanced" onToggle={(e) => { if (e.currentTarget.open) setAdvancedOpen(true); }}>
          <summary>Harnesses, delivery and preflight <Ic.ChevronDown size={14} /></summary>
          <Show when={advancedOpen()}>
        <Show when={isConnected()}>
          <SkillDeliveryPreview projects={projects()} librarySkills={librarySkills().map((s) => s.name)} />
        </Show>

        <section class="s-sec" aria-label="Harness compatibility">
          <div class="skills-sec-head">
            <h3>Harness compatibility &amp; discovery</h3>
            <div class="skills-machine-pick">
              <span>Target</span>
              <Select
                aria-label="Inspect machine"
                class="s-input"
                value={machine()}
                onChange={(e) => setMachine(e.currentTarget.value)}
              >
                <For each={machineOptions()}>
                  {(opt) => <option value={opt.id}>{opt.label}</option>}
                </For>
              </Select>
            </div>
          </div>

          <div class="s-card skills-harness-card">
            <For each={harnessRows()}>
              {(row) => (
                <details class="skills-harness-row" data-harness={row.id}>
                  <summary class="skills-harness-summary">
                    <span class="skills-harness-Chevron">›</span>
                    <div class="skills-harness-main">
                      <div class="skills-harness-title">
                        <span class="skills-harness-name">{row.name}</span>
                        <Show when={row.version}>
                          <span class="skills-harness-ver">{row.version}</span>
                        </Show>
                      </div>
                      <div class="skills-harness-paths">
                        <code title="Project skill directory">{row.projectRel}</code>
                        <span class="p-dot">·</span>
                        <code title="Global skill directory">{row.globalRel}</code>
                      </div>
                    </div>
                    <span class={`skills-badge ${row.state}`}>{row.statusLabel}</span>
                  </summary>
                  <div class="skills-harness-detail">
                    <p class="skills-harness-mech">{row.mechanism}</p>
                    <Show when={row.binPath}>
                      <div class="skills-detail-kv">
                        <span>Executable</span>
                        <code>{row.binPath}</code>
                      </div>
                    </Show>
                    <Show when={row.warning}>
                      <p class="skills-harness-warn">{row.warning}</p>
                    </Show>
                    <Show when={row.missingSkills.length > 0}>
                      <div class="skills-missing-box">
                        <span>Missing {row.missingSkills.length} canonical skills in {row.globalRel}:</span>
                        <div class="skills-chip-list">
                          <For each={row.missingSkills.slice(0, 12)}>
                            {(name) => <code class="skills-mini-chip">{name}</code>}
                          </For>
                          <Show when={row.missingSkills.length > 12}>
                            <span class="skills-more">+{row.missingSkills.length - 12} more</span>
                          </Show>
                        </div>
                      </div>
                    </Show>
                  </div>
                </details>
              )}
            </For>
          </div>
        </section>

        <section class="s-sec" aria-label="Skill preparation preflight">
          <h3>Runtime preflight &amp; sources</h3>
          <div class="s-card">
            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Project skill materializer (Python 3 + PyYAML)</div>
                <div class="s-row-desc">
                  Validates <code>SKILL.md</code> frontmatter and creates atomic symlinks before mission launch.
                </div>
              </div>
              <div class="s-row-ctrl">
                <Show
                  when={preflight()}
                  fallback={<span class="skills-badge missing">Desktop required</span>}
                >
                  {(pf) => (
                    <span class={`skills-badge ${pf().python3_ready && pf().pyyaml_ready ? "synced" : "drift"}`}>
                      {pf().python3_ready && pf().pyyaml_ready
                        ? `Ready · Python ${pf().python3_version ?? "3"} + PyYAML`
                        : pf().preflight_error || "Missing PyYAML"}
                    </span>
                  )}
                </Show>
              </div>
            </div>

            <div class="s-row">
              <div class="s-row-text">
                <div class="s-row-title">Paloma development identity</div>
                <div class="s-row-desc">
                  Injects <code>development-identity</code> skill, SSH fleet access, and GPG signing into workspaces.
                </div>
              </div>
              <div class="s-row-ctrl">
                <Show
                  when={preflight()}
                  fallback={<span class="skills-badge missing">Unchecked</span>}
                >
                  {(pf) => (
                    <span class={`skills-badge ${pf().identity_ready ? "synced" : "attention"}`}>
                      {pf().identity_ready
                        ? `Active · ${pf().identity_fingerprint?.slice(-8) ?? "verified"}`
                        : "Not provisioned locally"}
                    </span>
                  )}
                </Show>
              </div>
            </div>

            <For each={localReport()?.sources ?? []}>
              {(src) => (
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">
                      {src.label}
                      <Show when={src.legacy}><span class="p-chip" title="Scanned for import; never synced to harnesses">legacy</span></Show>
                    </div>
                    <div class="s-row-desc">
                      <code>{src.path}</code>
                    </div>
                  </div>
                  <div class="s-row-ctrl">
                    <span class={`skills-badge ${src.exists && src.skill_count > 0 ? "synced" : "missing"}`}>
                      {src.exists ? `${src.skill_count} skill${src.skill_count === 1 ? "" : "s"}` : "Not found"}
                    </span>
                  </div>
                </div>
              )}
            </For>
          </div>
        </section>
          </Show>
        </details>
      </div>

      <Show when={rowMenu()}>{(m) => <PopupMenu x={m().x} y={m().y} items={menuFor(m().row)} onClose={() => setRowMenu(null)} />}</Show>
      <Show when={confirmRowDelete()}>{(name) =>
        <ConfirmDialog title={`Delete ${name()}?`} description="It leaves the Library and every agent on this Mac." destructive
          action={rowDeleteError() ? "Retry" : "Delete"} busy={rowDeleteBusy()} error={rowDeleteError()}
          onClose={() => setConfirmRowDelete(null)} onConfirm={() => void confirmDeleteRow()} />
      }</Show>
      <Show when={openRow()}>
        {(row) => (
          <SkillDetail
            row={row()}
            initialView={openView()}
            library={libraryFull()[row().name]}
            connected={isConnected()}
            harnessTotal={harnessTotal()}
            onClose={() => setOpenSkill(null)}
            onSave={saveSkill}
            onImport={importSkill}
            onDelete={removeSkill}
            onFilesChanged={filesChanged}
            projects={projects().map((proj) => ({ slug: proj.slug, title: proj.title ?? undefined }))}
            projectMembership={membership(row().name)}
            onSaveProjects={saveProjects}
            onOpenProjectFile={(slug, path) => p.onOpenPage?.(`pf:${slug}:${path}`)}
          />
        )}
      </Show>
      <Show when={creating()}>
        <NameDialog title="New Library skill" label="Name" placeholder="lean-prover" value={newName()} onInput={setNewName} action="Create" busy={createBusy()} error={createError()}
          onAction={() => void createSkill()} onClose={() => setCreating(false)}>
          <Field label="Description" description="When should an agent load this skill? Aim for one specific sentence.">
            <input class="s-input" value={newDesc()} disabled={createBusy()} onInput={(e) => setNewDesc(e.currentTarget.value)} />
          </Field>
        </NameDialog>
      </Show>
    </div>
  );
}
