import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import * as Ic from "./icons";
import { Select } from "./Select";
import { ConfirmDialog, Field, NameDialog } from "./Dialog";
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
import { AUDIENCES, newSkillTemplate, normalizeSkillName, parseSkillMeta } from "./skillModel";
import { buildSkillRows, filterSkillRows, type ProblemFilter, type ProjectContextSkill, type SkillRow } from "./skillRows";
import { deleteLibrarySkill, fetchLibrarySkill, putLibrarySkill, putSkillFile, readSkillFile } from "./skillsApi";
import { SkillBadges, SkillDetail } from "./SkillDetail";
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
  chatgpt_ui: {
    name: "ChatGPT UI",
    globalRel: "—",
    projectRel: "—",
    mechanism: "Browser session harness; local filesystem skills are not mounted",
    warning: "Rejects local project skill launches by design to prevent silent drops",
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
  "chatgpt_ui",
] as const;

const LOCAL_SYNC_HARNESS_IDS = ["claudecode", "codex", "antigravity", "opencode", "grok", "vibe"] as const;

let cachedSkillNames: string[] = [
  "controllers-policy",
  "project-manager",
  "sandboxed-sh-missions",
  "development-identity",
  "paloma-backends",
  "paloma-ssh-servers",
];

/** Reactive list of known skill names for autocomplete in ControllerSettings. */
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

const PROBLEM_FILTERS: Array<[ProblemFilter, string]> = [
  ["all", "All"],
  ["problems", "Problems"],
  ["drift", "Drift"],
  ["divergent", "Divergent"],
  ["legacy", "Only legacy"],
  ["lint", "Lint"],
];

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

export function SkillsSettings(p: { onOpenPage?: (id: string) => void } = {}) {
  const [machine, setMachine] = createSignal<string>("local");
  const [remoteNodes, setRemoteNodes] = createSignal<RemoteNodeView[]>([]);
  const [localReport, setLocalReport] = createSignal<LocalSkillsReport | null>(null);
  const [librarySkills, setLibrarySkills] = createSignal<LibrarySkillSummary[]>([]);
  const [libraryFull, setLibraryFull] = createSignal<Record<string, LibrarySkill>>({});
  const [libraryLoaded, setLibraryLoaded] = createSignal(false);
  const [libraryError, setLibraryError] = createSignal<string | null>(null);
  const [projects, setProjects] = createSignal<ProjectSummary[]>([]);
  const [projectSkills, setProjectSkills] = createSignal<ProjectContextSkill[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [syncing, setSyncing] = createSignal(false);
  const [syncNotice, setSyncNotice] = createSignal<string | null>(null);
  const [syncError, setSyncError] = createSignal<string | null>(null);
  const [search, setSearch] = createSignal("");
  const [audienceFilter, setAudienceFilter] = createSignal("all");
  const [scopeFilter, setScopeFilter] = createSignal("all");
  const [problemFilter, setProblemFilter] = createSignal<ProblemFilter>("all");
  const [openSkill, setOpenSkill] = createSignal<string | null>(null);
  const [confirmPrune, setConfirmPrune] = createSignal<string[] | null>(null);
  const [creating, setCreating] = createSignal(false);
  const [newName, setNewName] = createSignal("");
  const [newDesc, setNewDesc] = createSignal("");
  const [createBusy, setCreateBusy] = createSignal(false);
  const [createError, setCreateError] = createSignal<string | null>(null);

  const harnessTotal = () => localReport()?.harnesses.length || LOCAL_SYNC_HARNESS_IDS.length;

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
  const loadLibrary = async () => {
    const items = await listLibrarySkills();
    const fetched = await Promise.all(items.map((s) => fetchLibrarySkill(s.name).catch(() => null)));
    const map: Record<string, LibrarySkill> = {};
    for (const skill of fetched) if (skill) map[skill.name] = skill;
    setLibrarySkills(items);
    setLibraryFull(map);
    setLibraryLoaded(true);
    setLibraryError(null);
    rememberKnownSkillNames(items.map((s) => s.name));
  };

  const refreshReport = async () => {
    const rep = await localSkillsStatus(libraryPayloads());
    if (rep) {
      setLocalReport(rep);
      rememberKnownSkillNames(rep.skills.map((s) => s.name));
    }
  };

  const loadAll = async (force = false) => {
    setLoading(true);
    setSyncError(null);
    try {
      const side: Promise<unknown>[] = [refreshLocalAgents(force).catch(() => []), refreshSoftware(force).catch(() => {})];
      if (isConnected()) {
        await loadLibrary().catch((e) => {
          setLibraryLoaded(false);
          setLibraryError(errorText(e));
        });
        side.push(getRemoteNodes().then((res) => setRemoteNodes(res.nodes ?? [])).catch(() => {}));
        side.push(loadProjectSkills());
      } else {
        setLibrarySkills([]);
        setLibraryFull({});
        setLibraryLoaded(false);
        setProjects([]);
        setProjectSkills([]);
      }
      side.push(refreshReport().catch((e) => setSyncError(errorText(e))));
      await Promise.all(side);
    } finally {
      setLoading(false);
    }
  };

  const loadProjectSkills = async () => {
    if (!isConnected()) return;
    const projs: ProjectSummary[] = await listProjects().catch(() => []);
    setProjects(projs);
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
    void loadAll(false);
    const onRefresh = () => void loadAll(true);
    window.addEventListener("orb:refresh", onRefresh);
    onCleanup(() => window.removeEventListener("orb:refresh", onRefresh));
  });

  createEffect(() => {
    connectionVersion();
    if (isConnected()) void loadAll(false);
  });

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
      if (id === "chatgpt_ui") {
        return {
          id,
          name: meta.name,
          installed: true,
          version: "Web session",
          binPath: null,
          globalRel: meta.globalRel,
          projectRel: meta.projectRel,
          skillCount: 0,
          syncedCount: 0,
          canonicalTotal: 0,
          missingSkills: [],
          state: "unsupported",
          statusLabel: "Unsupported",
          mechanism: meta.mechanism,
          warning: meta.warning,
        };
      }

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
      localHarnessIds: LOCAL_SYNC_HARNESS_IDS,
    }),
  );
  const filteredRows = createMemo(() =>
    filterSkillRows(rows(), { query: search(), audience: audienceFilter(), scope: scopeFilter(), problem: problemFilter(), harnessTotal: harnessTotal() }),
  );
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
      const n = result.report.harnesses.length;
      const parts = [`${result.harnesses_updated} updated`];
      if (result.pruned?.length) parts.push(`${result.pruned.length} removed`);
      if (result.skipped_unmanaged.length) parts.push(`${result.skipped_unmanaged.length} user-owned preserved`);
      setSyncNotice(`${label ? `${label} ` : ""}Synchronized ${result.synced_skills} skills across all ${n} local harness directories (${parts.join(", ")}).`);
    } catch (e) {
      setSyncError(errorText(e));
    } finally {
      setSyncing(false);
    }
  };

  const handleSyncAll = () => {
    if (syncing()) return;
    const rep = localReport();
    const stale = rep?.library_known ? [...new Set(rep.harnesses.flatMap((h) => h.stale_managed ?? []))] : [];
    if (stale.length && libraryLoaded()) setConfirmPrune(stale);
    else void syncNow(libraryLoaded());
  };

  const refetchSkill = async (name: string) => {
    const skill = await fetchLibrarySkill(name);
    setLibraryFull((prev) => ({ ...prev, [name]: skill }));
    if (!librarySkills().some((s) => s.name === name)) setLibrarySkills(await listLibrarySkills());
  };

  const saveSkill = async (name: string, content: string) => {
    await putLibrarySkill(name, content);
    await refetchSkill(name);
    await syncNow(false, `Saved "${name}".`);
  };

  const importSkill = async (name: string, src: SkillSourceRef, rels: string[]) => {
    if (!src.content) throw new Error("This copy has no readable SKILL.md.");
    // Read only the files the user kept checked; the native side re-applies the allowlist.
    const files = await readLegacySkillFiles(src.id, name, rels);
    await putLibrarySkill(name, src.content);
    for (const f of files) await putSkillFile(name, f.rel, f.content);
    setLibrarySkills(await listLibrarySkills());
    await refetchSkill(name);
    await syncNow(false, `Imported "${name}" from ${src.label}.`);
  };

  const removeSkill = async (name: string) => {
    await deleteLibrarySkill(name);
    setLibrarySkills((list) => list.filter((s) => s.name !== name));
    setLibraryFull((prev) => {
      const next = { ...prev };
      delete next[name];
      return next;
    });
    await syncNow(true, `Deleted "${name}".`);
  };

  const filesChanged = async (name: string) => {
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
      setLibrarySkills(await listLibrarySkills());
      await refetchSkill(name);
      setCreating(false);
      setNewName("");
      setNewDesc("");
      setOpenSkill(name);
      void syncNow(false, `Created "${name}".`);
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
        <div class="skills-head">
          <div>
            <h2>Skills</h2>
            <p class="s-lead">
              The Library is the single source of skills. Orb installs Library skills meant for <code>local</code> use into every local harness
              and flags copies that only live in legacy folders.
            </p>
          </div>
          <div class="skills-head-actions">
            <button type="button" class="s-btn sm" disabled={loading() || syncing()} onClick={() => void loadAll(true)} title="Re-scan local and remote skill directories">
              {loading() ? "Scanning…" : "Refresh"}
            </button>
            <button type="button" class="s-btn sm primary" disabled={syncing()} onClick={handleSyncAll}>
              {syncing() ? "Syncing…" : driftCount() > 0 ? `Sync all harnesses (${driftCount()} drifted)` : "Sync all harnesses"}
            </button>
          </div>
        </div>

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

        <section class="s-sec" aria-label="Global and Library skills catalog">
          <div class="skills-sec-head">
            <h3>Skills ({filteredRows().length})</h3>
            <div class="skills-catalog-controls">
              <input type="search" aria-label="Filter skills" class="s-input skills-search" placeholder="Search skills…" value={search()} onInput={(e) => setSearch(e.currentTarget.value)} />
              <Show when={isConnected()}>
                <button type="button" class="s-btn sm" onClick={() => { setCreating(true); setCreateError(null); }}>New skill</button>
              </Show>
            </div>
          </div>
          <div class="skills-filter-bar">
            <Select aria-label="Filter by audience" class="s-input" value={audienceFilter()} onChange={(e) => setAudienceFilter(e.currentTarget.value)}>
              <option value="all">All audiences</option>
              <For each={AUDIENCES}>{(a) => <option value={a}>{a}</option>}</For>
            </Select>
            <Select aria-label="Filter by scope" class="s-input" value={scopeFilter()} onChange={(e) => setScopeFilter(e.currentTarget.value)}>
              <option value="all">Any scope</option>
              <option value="global">Global</option>
              <option value="on-demand">On demand</option>
            </Select>
            <div class="skills-filter-pills" role="tablist" aria-label="Filter skills by problem">
              <For each={PROBLEM_FILTERS}>{([id, label]) => (
                <button type="button" role="tab" aria-selected={problemFilter() === id} class={`skills-filter-pill ${problemFilter() === id ? "on" : ""}`} onClick={() => setProblemFilter(id)}>
                  {label}
                </button>
              )}</For>
            </div>
          </div>

          <Show when={libraryError()}>{(err) => <p class="skills-sub-note">Core Library unavailable: {err()}. Local status only; syncing will not remove anything.</p>}</Show>
          <Show when={!isConnected()}><p class="skills-sub-note">Connect to Core to load the Library, the canonical skill source.</p></Show>

          <div class="s-card skills-catalog-card">
            <For each={filteredRows()} fallback={<div class="s-row"><div class="s-row-text"><div class="s-row-desc">No skills match the current filter.</div></div></div>}>
              {(row) => (
                <div class="skills-item" data-skill={row.name}>
                  <button type="button" class="skills-item-head" onClick={() => openRowDetail(row)}>
                    <div class="skills-item-body">
                      <div class="skills-item-top">
                        <code class="skills-item-name">{row.name}</code>
                        <SkillBadges row={row} harnessTotal={harnessTotal()} />
                        <Show when={row.lint.length}><span class="skills-lint-count" title={row.lint.map((l) => l.message).join("\n")}>{row.lint.length} warning{row.lint.length === 1 ? "" : "s"}</span></Show>
                      </div>
                      <div class="skills-item-desc">{row.description || "No description."}</div>
                    </div>
                  </button>
                </div>
              )}
            </For>
          </div>
        </section>

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
      </div>

      <Show when={openRow()}>
        {(row) => (
          <SkillDetail
            row={row()}
            library={libraryFull()[row().name]}
            connected={isConnected()}
            harnessTotal={harnessTotal()}
            onClose={() => setOpenSkill(null)}
            onSave={saveSkill}
            onImport={importSkill}
            onDelete={removeSkill}
            onFilesChanged={filesChanged}
            onOpenProjectFile={(slug, path) => p.onOpenPage?.(`pf:${slug}:${path}`)}
          />
        )}
      </Show>
      <Show when={confirmPrune()}>
        {(stale) => (
          <ConfirmDialog
            title="Remove skills that left the Library?"
            description={`Sync will remove ${stale().length} Orb-managed skill${stale().length === 1 ? "" : "s"} no longer in the Library (or not meant for local use): ${stale().slice(0, 8).join(", ")}${stale().length > 8 ? ` +${stale().length - 8} more` : ""}. Import any you want to keep first. Your own unmanaged skills are never touched.`}
            action="Sync and remove"
            destructive
            onClose={() => setConfirmPrune(null)}
            onConfirm={() => { setConfirmPrune(null); void syncNow(true); }}
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
