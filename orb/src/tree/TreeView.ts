import type { ControllerJob, ControllerView, Mission, ProjectFileEntry, ProjectSummary } from "../api";
import { folderLabel } from "../folderLabels";
import { displayTitle } from "../goal";
import { isWorking } from "../missionStatus";
import { countNested, countVersions, forkTitle, holds, missionParent, nestMissions, versionLabel, type NestedMission } from "../missionTree";
import { excludeBtwMissions, resolveParent, seenMission, trackHierarchyResolution } from "../missionHierarchy";
import { filesMovedAway, filesMovedInto } from "../moves";
import { renamedTitle } from "../renames";
import type { TreeNode } from "../treeModel";

export type RowData = {
  kind: "archive-project" | "project" | "folder" | "file" | "mission" | "cron" | "cron-error" | "note";
  slug: string; label: string; path?: string; mission?: Mission;
  job?: ControllerJob; controller?: boolean;
  /** Missions launched by this one, at any depth, and how many still run. */
  launched?: number; launchedLive?: number;
  /** Earlier versions of this conversation (forks), listed inside it; `version` marks one of them. */
  versions?: number; version?: boolean;
  /** Stand-in for a parent that is not loaded yet; its children are held inside it. */
  placeholder?: boolean;
};
export type Node = TreeNode<RowData>;

/** The folder a mission is filed under inside its project ("" = project root). */
/**
 * Stand-in row for a parent that is not in the loaded rows (paged out, filed in
 * another project, or still being fetched). The resolver fetches it; only a
 * parent confirmed gone (404) returns undefined, letting its children be roots.
 */
export function placeholderParent(slug: string) {
  return (parentId: string, child: Mission): Mission | undefined => {
    if (resolveParent(parentId) === "gone") return undefined;
    const known = seenMission(parentId);
    return { id: parentId, title: known?.title ?? null, status: known?.status ?? "unknown", project: known?.project ?? slug,
      tags: (child.tags ?? []).filter(t => t.startsWith("orb-folder:")), history: [], created_at: child.created_at, updated_at: child.updated_at, orb_placeholder: true };
  };
}

export const missionFolder = (mission: Mission) => mission.tags?.find(t => t.startsWith("orb-folder:"))?.slice("orb-folder:".length) ?? "";

export function missionTreeId(id: string, placeholderScope?: string): string {
  return placeholderScope !== undefined ? `mp:${placeholderScope}:${id}` : `m:${id}`;
}

export function missionIdFromTreeId(treeId: string): string | null {
  if (treeId.startsWith("m:")) return treeId.slice(2);
  if (treeId.startsWith("mp:")) {
    const sep = treeId.lastIndexOf(":");
    return sep > 2 ? treeId.slice(sep + 1) : null;
  }
  return null;
}

/**
 * Builds the sidebar's project tree and archive tree from the loaded state.
 * Pure derivation: every input is read through `deps`, so the result tracks
 * the same reactive sources the component owns.
 */
export function createProjectTree(deps: {
  projects: () => ProjectSummary[];
  expanded: Record<string, boolean>;
  missions: Record<string, Mission[]>;
  dirs: Record<string, ProjectFileEntry[]>;
  dirErrors: Record<string, string | null>;
  crons: Record<string, ControllerJob[]>;
  controllers: Record<string, ControllerView>;
  cronUnsupported: () => boolean;
  cronErrors: Record<string, string | null>;
  archiveExpanded: Record<string, boolean>;
  visibleMissions: (slug: string) => Mission[];
  archivedMissionRows: () => Mission[];
  selected: () => string | null;
}) {
  const { expanded, missions, dirs, dirErrors, crons, controllers, cronErrors } = deps;
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
    const away = filesMovedAway(slug, path);
    const entries = dirs[key].filter(e => !away.has(e.name) && !(path === "" && e.name === "attachments"));
    for (const arriving of filesMovedInto(slug, path)) if (!entries.some(e => e.name === arriving.name)) entries.push(arriving);
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
  const rootMissions = (slug: string) => nestMissions(deps.visibleMissions(slug), { placeholder: placeholderParent(slug) });
  // A mission the project's controller created (a Hermes session, no parent
  // mission) is listed under the controller, like a child under its parent.
  const controllerLaunched = (mission: Mission) => !missionParent(mission) && mission.origin === "hermes" && !!mission.origin_session_id;
  const controllerRow = (slug: string) => { const job = controllers[slug]?.job; return !!job && !job.archived; };
  const controllerRoots = (slug: string) => controllerRow(slug) ? rootMissions(slug).filter(root => controllerLaunched(root.mission)) : [];
  const missionNode = (slug: string, nested: NestedMission<Mission>, archive = false): Node => {
    const mission = nested.mission;
    const id = mission.orb_placeholder ? missionTreeId(mission.id, archive ? `archive:${slug}` : slug) : missionTreeId(mission.id);
    const data: RowData = { kind: "mission", slug, mission, label: nested.version ? versionLabel(mission) : displayTitle(forkTitle(renamedTitle("mission", mission.id, mission.title))) || (mission.orb_placeholder ? "Parent mission" : mission.id), ...(nested.version ? { version: true } : {}), ...(mission.orb_placeholder ? { placeholder: true } : {}) };
    if (!nested.children.length) return { id, data };
    const selected = deps.selected();
    const open = expanded[id] ?? (!!selected?.startsWith("m:") && holds(nested, selected.slice(2)));
    return { id, data: { ...data, launched: countNested(nested), launchedLive: countNested(nested, child => isWorking(child.status)), versions: countVersions(nested) },
      expanded: open, children: open ? nested.children.map(child => missionNode(slug, child, archive)) : [] };
  };
  const tree = (): Node[] => deps.projects().map(project => {
    const slug = project.slug, open = !!expanded[slug];
    const children: Node[] = [];
    if (open) {
      const job = controllers[slug]?.job;
      if (job && !job.archived) {
        const launched = controllerRoots(slug), id = `c:${slug}`, selected = deps.selected();
        const inside = !!selected?.startsWith("m:") && launched.some(root => root.mission.id === selected.slice(2) || holds(root, selected.slice(2)));
        const open = launched.length ? (expanded[id] ?? inside) : undefined;
        const count = launched.reduce((sum, root) => sum + 1 + countNested(root), 0);
        const live = launched.reduce((sum, root) => sum + Number(isWorking(root.mission.status)) + countNested(root, child => isWorking(child.status)), 0);
        children.push({ id, data: { kind: "cron", slug, label: job.name, job, controller: true, ...(launched.length ? { launched: count, launchedLive: live } : {}) },
          ...(launched.length ? { expanded: open, children: open ? launched.map(root => missionNode(slug, root)) : [] } : {}) });
      }
      if (deps.cronUnsupported() || cronErrors[slug]) children.push({ id: `crons-error:${slug}`, data: { kind: "cron-error", slug, label: "Crons unavailable" } });

      if (missions[slug] === undefined) children.push({ id: `loading-missions:${slug}`, data: { kind: "note", slug, label: "Loading missions…" } });
      children.push(...workNodes(slug, ""));
      children.push(...fileNodes(slug, ""));
      if (!children.length) children.push({ id: `empty:${slug}`, data: { kind: "note", slug, label: "No missions or files yet." } });
    }
    return { id: `project:${slug}`, data: { kind: "project", slug, label: renamedTitle("project", slug, project.title) || slug }, expanded: open, children };
  });
  const archiveNodes = (): Node[] => {
    trackHierarchyResolution();
    const byProject = new Map<string, Mission[]>();
    for (const m of excludeBtwMissions(deps.archivedMissionRows())) {
      const slug = m.project ?? "";
      byProject.set(slug, [...(byProject.get(slug) ?? []), m]);
    }
    const groups = new Map<string, Node[]>();
    for (const [slug, rows] of byProject) {
      groups.set(slug, nestMissions(rows, { placeholder: placeholderParent(slug) }).map(root => missionNode(slug, root, true)));
    }
    for (const project of deps.projects()) {
      const job = controllers[project.slug]?.job;
      if (job?.archived) {
        const node: Node = {id:`c:${project.slug}`,data:{kind:"cron",slug:project.slug,label:job.name,job,controller:true}};
        groups.set(project.slug, [...(groups.get(project.slug) ?? []), node]);
      }
    }
    return [...groups].map(([slug, children]) => ({
      id: `archive-project:${slug}`,
      data: {kind: "archive-project" as const, slug, label: deps.projects().find(project => project.slug === slug)?.title || slug || "No project"},
      expanded: !!deps.archiveExpanded[slug], children,
    })).sort((a,b) => a.data.label.localeCompare(b.data.label));
  };
  return { tree, archiveNodes, controllerRow, controllerLaunched };
}
