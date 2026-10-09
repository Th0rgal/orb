import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import * as Ic from "./icons";
import { Select } from "./Select";
import {
  connectionVersion,
  getLibrarySkill,
  getRemoteNodes,
  isConnected,
  listLibrarySkills,
  listProjectFiles,
  listProjects,
  readProjectFile,
  saveLibrarySkill,
  writeProjectFile,
  mkdirProjectFile,
  type LibrarySkillSummary,
  type ProjectSummary,
  type RemoteNodeView,
} from "./api";
import {
  localInstalled,
  localSkillsStatus,
  localSkillsSync,
  refreshLocalAgents,
  type DiscoveredSkill,
  type HarnessSkillTarget,
  type LocalSkillsReport,
  type SyncSkillPayload,
} from "./localAgents";
import { refreshSoftware, softwareMachines } from "./softwareInventory";

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

export interface UnifiedSkillEntry {
  name: string;
  description: string;
  origin: "Library" | "Paloma" | "Agent Skills" | "Identity" | "User";
  originDetail: string;
  harnesses: string[];
  inLibrary: boolean;
  contentPreview?: string | null;
}

export interface ProjectSkillGroup {
  slug: string;
  title: string;
  skills: Array<{
    name: string;
    path: string;
    description?: string;
  }>;
  loading?: boolean;
  error?: string;
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

function classifyOrigin(raw: string, inLibrary: boolean): UnifiedSkillEntry["origin"] {
  const lower = raw.toLowerCase();
  if (lower.includes("identity")) return "Identity";
  if (lower.includes("paloma")) return "Paloma";
  if (lower.includes("agent skills")) return "Agent Skills";
  if (inLibrary || lower.includes("library")) return "Library";
  return "User";
}

export function SkillsSettings(p: { onOpenPage?: (id: string) => void } = {}) {
  const [machine, setMachine] = createSignal<string>("local");
  const [remoteNodes, setRemoteNodes] = createSignal<RemoteNodeView[]>([]);
  const [localReport, setLocalReport] = createSignal<LocalSkillsReport | null>(null);
  const [librarySkills, setLibrarySkills] = createSignal<LibrarySkillSummary[]>([]);
  const [libraryError, setLibraryError] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(false);
  const [syncing, setSyncing] = createSignal(false);
  const [syncNotice, setSyncNotice] = createSignal<string | null>(null);
  const [syncError, setSyncError] = createSignal<string | null>(null);
  const [search, setSearch] = createSignal("");
  const [originFilter, setOriginFilter] = createSignal<string>("all");
  const [expandedSkill, setExpandedSkill] = createSignal<string | null>(null);
  const [skillContentCache, setSkillContentCache] = createSignal<Record<string, string>>({});
  const [loadingSkillContent, setLoadingSkillContent] = createSignal<string | null>(null);
  const [projectGroups, setProjectGroups] = createSignal<ProjectSkillGroup[]>([]);
  const [projectsLoading, setProjectsLoading] = createSignal(false);
  const [creatingProjectSkill, setCreatingProjectSkill] = createSignal<string | null>(null);
  const [newSkillName, setNewSkillName] = createSignal("");
  const [newSkillDesc, setNewSkillDesc] = createSignal("");
  const [newSkillSaving, setNewSkillSaving] = createSignal(false);
  const [newSkillError, setNewSkillError] = createSignal<string | null>(null);

  const loadAll = async (force = false) => {
    setLoading(true);
    setSyncError(null);
    try {
      const tasks: Promise<unknown>[] = [
        refreshLocalAgents(force).catch(() => []),
        refreshSoftware(force).catch(() => {}),
        localSkillsStatus()
          .then((rep) => {
            if (rep) {
              setLocalReport(rep);
              rememberKnownSkillNames(rep.skills.map((s) => s.name));
            }
          })
          .catch((e) => {
            setSyncError(e instanceof Error ? e.message : String(e));
          }),
      ];

      if (isConnected()) {
        tasks.push(
          listLibrarySkills()
            .then((items) => {
              setLibrarySkills(items);
              setLibraryError(null);
              rememberKnownSkillNames(items.map((s) => s.name));
            })
            .catch((e) => {
              setLibraryError(e instanceof Error ? e.message : String(e));
            }),
        );
        tasks.push(
          getRemoteNodes()
            .then((res) => setRemoteNodes(res.nodes ?? []))
            .catch(() => {}),
        );
        tasks.push(loadProjectSkills());
      } else {
        setLibrarySkills([]);
        setProjectGroups([]);
      }

      await Promise.all(tasks);
    } finally {
      setLoading(false);
    }
  };

  const loadProjectSkills = async () => {
    if (!isConnected()) return;
    setProjectsLoading(true);
    try {
      const projs: ProjectSummary[] = await listProjects().catch(() => []);
      const initial: ProjectSkillGroup[] = projs.map((proj) => ({
        slug: proj.slug,
        title: proj.title || proj.slug,
        skills: [],
        loading: true,
      }));
      setProjectGroups(initial);

      const resolved = await Promise.all(
        projs.map(async (proj): Promise<ProjectSkillGroup> => {
          try {
            const entries = await listProjectFiles(proj.slug, "skills");
            const dirs = entries.filter((e) => e.kind === "dir" && !e.name.startsWith("."));
            const skills = await Promise.all(
              dirs.map(async (d) => {
                const path = `skills/${d.name}/SKILL.md`;
                let description: string | undefined;
                try {
                  const content = await readProjectFile(proj.slug, path);
                  const descMatch = content.match(/description:\s*["']?([^\n"']+)["']?/i);
                  if (descMatch?.[1] && !["|", ">", "|-", ">-"].includes(descMatch[1].trim())) {
                    description = descMatch[1].trim();
                  }
                } catch {
                  /* optional description */
                }
                return { name: d.name, path, description };
              }),
            );
            rememberKnownSkillNames(skills.map((s) => s.name));
            return {
              slug: proj.slug,
              title: proj.title || proj.slug,
              skills,
              loading: false,
            };
          } catch {
            return {
              slug: proj.slug,
              title: proj.title || proj.slug,
              skills: [],
              loading: false,
            };
          }
        }),
      );
      setProjectGroups(resolved);
    } finally {
      setProjectsLoading(false);
    }
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
      for (const node of remoteNodes()) {
        opts.push({
          id: node.id,
          label: `${node.id} (${node.status})`,
        });
      }
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
    return rep.harnesses.filter((h) => h.canonical_total > 0 && h.synced_count < h.canonical_total).length;
  });

  const unifiedSkills = createMemo<UnifiedSkillEntry[]>(() => {
    const map = new Map<string, UnifiedSkillEntry>();
    const libSet = new Set(librarySkills().map((s) => s.name));

    for (const item of localReport()?.skills ?? []) {
      const inLib = libSet.has(item.name);
      map.set(item.name, {
        name: item.name,
        description: item.description || "Skill instructions and reference workflow.",
        origin: classifyOrigin(item.origin, inLib),
        originDetail: item.origin,
        harnesses: [...item.harnesses],
        inLibrary: inLib,
        contentPreview: item.content_preview,
      });
    }

    for (const lib of librarySkills()) {
      const existing = map.get(lib.name);
      if (existing) {
        existing.inLibrary = true;
        if (!existing.description || existing.description === "Skill instructions and reference workflow.") {
          if (lib.description) existing.description = lib.description;
        }
      } else {
        map.set(lib.name, {
          name: lib.name,
          description: lib.description || "Shared skill in the Core Library.",
          origin: "Library",
          originDetail: "Core Library (/api/library/skill)",
          harnesses: [],
          inLibrary: true,
          contentPreview: null,
        });
      }
    }

    return [...map.values()].sort((a, b) => a.name.localeCompare(b.name));
  });

  const filteredSkills = createMemo(() => {
    const q = search().trim().toLowerCase();
    const filter = originFilter();
    return unifiedSkills().filter((skill) => {
      if (filter !== "all") {
        if (filter === "drift" && skill.harnesses.length >= LOCAL_SYNC_HARNESS_IDS.length) return false;
        if (filter === "library" && !skill.inLibrary && skill.origin !== "Library") return false;
        if (filter === "paloma" && skill.origin !== "Paloma" && skill.origin !== "Identity") return false;
        if (filter === "local" && skill.origin !== "Agent Skills" && skill.origin !== "User") return false;
      }
      if (!q) return true;
      return (
        skill.name.toLowerCase().includes(q) ||
        skill.description.toLowerCase().includes(q) ||
        skill.origin.toLowerCase().includes(q)
      );
    });
  });

  const handleSyncAll = async () => {
    if (syncing()) return;
    setSyncing(true);
    setSyncNotice(null);
    setSyncError(null);
    try {
      const payloads: SyncSkillPayload[] = [];
      if (isConnected() && librarySkills().length > 0) {
        const fetched = await Promise.all(
          librarySkills().map(async (s) => {
            try {
              const full = await getLibrarySkill(s.name);
              return {
                name: full.name,
                content: full.content,
                files: (full.files ?? [])
                  .filter((f) => f.path !== "SKILL.md" && f.name !== "SKILL.md")
                  .map((f) => ({ rel: f.path || f.name, content: f.content })),
              } satisfies SyncSkillPayload;
            } catch {
              return null;
            }
          }),
        );
        for (const item of fetched) {
          if (item) payloads.push(item);
        }
      }

      const result = await localSkillsSync({ librarySkills: payloads, pruneRemoved: false });
      setLocalReport(result.report);
      rememberKnownSkillNames(result.report.skills.map((s) => s.name));
      setSyncNotice(
        `Synchronized ${result.synced_skills} skills across all 5 local harness directories (${
          result.harnesses_updated
        } updated${result.skipped_unmanaged.length ? `, ${result.skipped_unmanaged.length} user-owned preserved` : ""}).`,
      );
    } catch (e) {
      setSyncError(e instanceof Error ? e.message : String(e));
    } finally {
      setSyncing(false);
    }
  };

  const toggleSkillPreview = async (skill: UnifiedSkillEntry) => {
    if (expandedSkill() === skill.name) {
      setExpandedSkill(null);
      return;
    }
    setExpandedSkill(skill.name);
    if (skill.contentPreview || skillContentCache()[skill.name]) return;
    if (isConnected() && skill.inLibrary) {
      setLoadingSkillContent(skill.name);
      try {
        const full = await getLibrarySkill(skill.name);
        setSkillContentCache((prev) => ({ ...prev, [skill.name]: full.content }));
      } catch {
        /* ignore preview fetch failure */
      } finally {
        setLoadingSkillContent(null);
      }
    }
  };

  const pushSkillToLibrary = async (skill: UnifiedSkillEntry) => {
    const content = skill.contentPreview ?? skillContentCache()[skill.name];
    if (!content || !isConnected()) return;
    setSyncError(null);
    try {
      await saveLibrarySkill(skill.name, content);
      const updated = await listLibrarySkills();
      setLibrarySkills(updated);
      setSyncNotice(`Published "${skill.name}" to the Core Library.`);
    } catch (e) {
      setSyncError(e instanceof Error ? e.message : String(e));
    }
  };

  const createNewProjectSkill = async (slug: string) => {
    const rawName = newSkillName().trim().toLowerCase().replace(/[^a-z0-9-_]+/g, "-").replace(/^-+|-+$/g, "");
    if (!rawName) {
      setNewSkillError("Enter a valid skill folder name (e.g. lean-prover).");
      return;
    }
    const desc = newSkillDesc().trim() || `Project skill ${rawName} for ${slug}.`;
    const template = `---\nname: ${rawName}\ndescription: "${desc.replace(/"/g, '\\"')}"\n---\n\n# ${rawName}\n\n${desc}\n\n## Instructions\n\n- Describe the domain workflow, invariants, or commands here.\n`;
    setNewSkillSaving(true);
    setNewSkillError(null);
    try {
      await mkdirProjectFile(slug, `skills/${rawName}`).catch(() => {});
      await writeProjectFile(slug, `skills/${rawName}/SKILL.md`, template);
      setCreatingProjectSkill(null);
      setNewSkillName("");
      setNewSkillDesc("");
      await loadProjectSkills();
      p.onOpenPage?.(`pf:${slug}:skills/${rawName}/SKILL.md`);
    } catch (e) {
      setNewSkillError(e instanceof Error ? e.message : String(e));
    } finally {
      setNewSkillSaving(false);
    }
  };

  const preflight = () => localReport()?.preflight;

  return (
    <div class="s-body settings-body">
      <div class="s-inner skills-settings-page">
        <div class="skills-head">
          <div>
            <h2>Skills</h2>
            <p class="s-lead">
              Unified skill discovery and synchronization across Claude Code, Codex, Antigravity, OpenCode, Grok, and Hermes controllers.
            </p>
          </div>
          <div class="skills-head-actions">
            <button
              type="button"
              class="s-btn sm"
              disabled={loading() || syncing()}
              onClick={() => void loadAll(true)}
              title="Re-scan local and remote skill directories"
            >
              {loading() ? "Scanning…" : "Refresh"}
            </button>
            <button
              type="button"
              class="s-btn sm primary"
              disabled={syncing()}
              onClick={() => void handleSyncAll()}
            >
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
          <h3>Runtime preflight &amp; canonical sources</h3>
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
                    <div class="s-row-title">{src.label}</div>
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

        <section class="s-sec" aria-label="Global and Library skills catalog">
          <div class="skills-sec-head">
            <h3>Global &amp; Library catalog ({filteredSkills().length})</h3>
            <div class="skills-catalog-controls">
              <div class="skills-filter-pills" role="tablist" aria-label="Filter skills by source">
                <button
                  type="button"
                  role="tab"
                  aria-selected={originFilter() === "all"}
                  class={`skills-filter-pill ${originFilter() === "all" ? "on" : ""}`}
                  onClick={() => setOriginFilter("all")}
                >
                  All
                </button>
                <button
                  type="button"
                  role="tab"
                  aria-selected={originFilter() === "drift"}
                  class={`skills-filter-pill ${originFilter() === "drift" ? "on" : ""}`}
                  onClick={() => setOriginFilter("drift")}
                >
                  Unsynced
                </button>
                <button
                  type="button"
                  role="tab"
                  aria-selected={originFilter() === "paloma"}
                  class={`skills-filter-pill ${originFilter() === "paloma" ? "on" : ""}`}
                  onClick={() => setOriginFilter("paloma")}
                >
                  Paloma
                </button>
                <button
                  type="button"
                  role="tab"
                  aria-selected={originFilter() === "library"}
                  class={`skills-filter-pill ${originFilter() === "library" ? "on" : ""}`}
                  onClick={() => setOriginFilter("library")}
                >
                  Library
                </button>
              </div>
              <input
                type="search"
                aria-label="Filter skills"
                class="s-input skills-search"
                placeholder="Filter skills…"
                value={search()}
                onInput={(e) => setSearch(e.currentTarget.value)}
              />
            </div>
          </div>

          <Show when={libraryError()}>
            {(err) => <p class="skills-sub-note">Core Library status: {err()}</p>}
          </Show>

          <div class="s-card skills-catalog-card">
            <Show
              when={filteredSkills().length > 0}
              fallback={
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-desc">No skills match the current filter.</div>
                  </div>
                </div>
              }
            >
              <For each={filteredSkills()}>
                {(skill) => {
                  const isOpen = () => expandedSkill() === skill.name;
                  const preview = () => skill.contentPreview ?? skillContentCache()[skill.name];
                  const coverageCount = () =>
                    LOCAL_SYNC_HARNESS_IDS.filter((id) => skill.harnesses.includes(id)).length;
                  return (
                    <div class={`skills-item ${isOpen() ? "open" : ""}`} data-skill={skill.name}>
                      <button
                        type="button"
                        class="skills-item-head"
                        aria-expanded={isOpen()}
                        onClick={() => void toggleSkillPreview(skill)}
                      >
                        <span class="skills-harness-Chevron">{isOpen() ? "⌄" : "›"}</span>
                        <div class="skills-item-body">
                          <div class="skills-item-top">
                            <code class="skills-item-name">{skill.name}</code>
                            <span class="skills-origin-tag">{skill.origin}</span>
                            <Show when={skill.inLibrary && skill.origin !== "Library"}>
                              <span class="skills-origin-tag">Core Library</span>
                            </Show>
                          </div>
                          <div class="skills-item-desc">{skill.description}</div>
                        </div>
                        <div class="skills-coverage" title={`Installed in ${coverageCount()}/${LOCAL_SYNC_HARNESS_IDS.length} local harnesses`}>
                          <For each={LOCAL_SYNC_HARNESS_IDS}>
                            {(hid) => (
                              <span
                                class={`skills-cov-pill ${skill.harnesses.includes(hid) ? "on" : ""}`}
                                title={`${HARNESS_META[hid].name}: ${
                                  skill.harnesses.includes(hid) ? "Installed" : "Missing"
                                }`}
                              >
                                {hid === "claudecode"
                                  ? "CC"
                                  : hid === "codex"
                                    ? "CX"
                                    : hid === "antigravity"
                                      ? "AG"
                                      : hid === "opencode"
                                        ? "OC"
                                        : hid === "vibe" ? "VB" : "GK"}
                              </span>
                            )}
                          </For>
                        </div>
                      </button>
                      <Show when={isOpen()}>
                        <div class="skills-item-drawer">
                          <div class="skills-drawer-meta">
                            <span>Source: {skill.originDetail}</span>
                            <Show when={isConnected() && !skill.inLibrary && preview()}>
                              <button
                                type="button"
                                class="s-btn sm"
                                onClick={() => void pushSkillToLibrary(skill)}
                              >
                                Publish to Core Library
                              </button>
                            </Show>
                          </div>
                          <Show
                            when={preview()}
                            fallback={
                              <p class="skills-preview-empty">
                                {loadingSkillContent() === skill.name
                                  ? "Loading SKILL.md…"
                                  : "SKILL.md preview unavailable."}
                              </p>
                            }
                          >
                            {(text) => <pre class="skills-md-preview">{text()}</pre>}
                          </Show>
                        </div>
                      </Show>
                    </div>
                  );
                }}
              </For>
            </Show>
          </div>
        </section>

        <section class="s-sec" aria-label="Project skills">
          <div class="skills-sec-head">
            <h3>Project skills (@context/skills)</h3>
            <span class="skills-sub-note">
              Synchronized automatically to every local and remote mission in that project
            </span>
          </div>

          <div class="s-card">
            <Show
              when={isConnected()}
              fallback={
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">Connect to Core to inspect project skills</div>
                    <div class="s-row-desc">
                      Project-scoped skills live under <code>skills/&lt;name&gt;/SKILL.md</code> in each project's shared context.
                    </div>
                  </div>
                </div>
              }
            >
              <Show
                when={projectGroups().length > 0}
                fallback={
                  <div class="s-row">
                    <div class="s-row-text">
                      <div class="s-row-desc">
                        {projectsLoading() ? "Checking project skill folders…" : "No active projects found."}
                      </div>
                    </div>
                  </div>
                }
              >
                <For each={projectGroups()}>
                  {(group) => (
                    <div class="skills-project-group" data-project-skills={group.slug}>
                      <div class="s-row skills-project-row">
                        <div class="s-row-text">
                          <div class="s-row-title">
                            {group.title}
                            <span class="p-chip">
                              {group.loading
                                ? "Checking…"
                                : `${group.skills.length} skill${group.skills.length === 1 ? "" : "s"}`}
                            </span>
                          </div>
                          <Show
                            when={group.skills.length > 0}
                            fallback={
                              <div class="s-row-desc">
                                No project-specific skills in <code>skills/*/SKILL.md</code>.
                              </div>
                            }
                          >
                            <div class="skills-project-chips">
                              <For each={group.skills}>
                                {(sk) => (
                                  <button
                                    type="button"
                                    class="skills-proj-chip"
                                    title={sk.description || sk.path}
                                    onClick={() => p.onOpenPage?.(`pf:${group.slug}:${sk.path}`)}
                                  >
                                    <Ic.FileIcon size={12} />
                                    <span>{sk.name}</span>
                                  </button>
                                )}
                              </For>
                            </div>
                          </Show>
                        </div>
                        <div class="s-row-ctrl">
                          <button
                            type="button"
                            class="s-btn sm"
                            onClick={() => {
                              setCreatingProjectSkill(
                                creatingProjectSkill() === group.slug ? null : group.slug,
                              );
                              setNewSkillName("");
                              setNewSkillDesc("");
                              setNewSkillError(null);
                            }}
                          >
                            {creatingProjectSkill() === group.slug ? "Cancel" : "New skill"}
                          </button>
                        </div>
                      </div>

                      <Show when={creatingProjectSkill() === group.slug}>
                        <div class="skills-new-form">
                          <div class="skills-new-inputs">
                            <input
                              type="text"
                              aria-label={`New skill name for ${group.title}`}
                              class="s-input"
                              placeholder="skill-name (e.g. proof-tactics)"
                              value={newSkillName()}
                              onInput={(e) => setNewSkillName(e.currentTarget.value)}
                            />
                            <input
                              type="text"
                              aria-label={`New skill description for ${group.title}`}
                              class="s-input"
                              placeholder="Short trigger description for YAML frontmatter"
                              value={newSkillDesc()}
                              onInput={(e) => setNewSkillDesc(e.currentTarget.value)}
                            />
                            <button
                              type="button"
                              class="s-btn sm primary"
                              disabled={newSkillSaving()}
                              onClick={() => void createNewProjectSkill(group.slug)}
                            >
                              {newSkillSaving() ? "Creating…" : "Create SKILL.md"}
                            </button>
                          </div>
                          <Show when={newSkillError()}>
                            {(err) => <p class="skills-form-err" role="alert">{err()}</p>}
                          </Show>
                        </div>
                      </Show>
                    </div>
                  )}
                </For>
              </Show>
            </Show>
          </div>
        </section>
      </div>
    </div>
  );
}
