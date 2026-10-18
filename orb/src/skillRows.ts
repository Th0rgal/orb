// One row per skill, merged from the Library, the local report and project context skills.
import type { LibrarySkill, LibrarySkillSummary } from "./api";
import type { LocalSkillsReport, SkillSourceRef } from "./localAgents";
import { effectiveAudience, lintSkill, parseSkillMeta, type SkillLint } from "./skillModel";

export type SourceKind = "Library" | "legacy" | "project" | "identity" | "user";

export interface SkillRow {
  name: string;
  description: string;
  audience: string[];
  scope?: string | null;
  sourceKinds: SourceKind[];
  sources: SkillSourceRef[];
  inLibrary: boolean;
  legacyOnly: boolean;
  divergent: boolean;
  desired: boolean;
  /** Local harnesses where the skill is installed. */
  harnessCount: number;
  staleCount: number;
  lines: number;
  content?: string;
  lint: SkillLint[];
  projectFile?: { slug: string; path: string };
}

export interface ProjectContextSkill {
  slug: string;
  name: string;
  path: string;
  description?: string;
}

export type ProblemFilter = "all" | "problems" | "drift" | "divergent" | "legacy" | "lint";

export function rowProblems(row: SkillRow, harnessTotal: number) {
  const drift = row.desired && (row.harnessCount < harnessTotal || row.staleCount > 0);
  return { drift, divergent: row.divergent, legacy: row.legacyOnly, lint: row.lint.length > 0 };
}

export function buildSkillRows(input: {
  report: LocalSkillsReport | null;
  summaries: LibrarySkillSummary[];
  library: Record<string, LibrarySkill>;
  projectSkills: ProjectContextSkill[];
  localHarnessIds: readonly string[];
}): SkillRow[] {
  const rows = new Map<string, SkillRow>();
  const reportByName = new Map((input.report?.skills ?? []).map((s) => [s.name, s]));

  for (const summary of input.summaries) {
    const full = input.library[summary.name];
    const content = full?.content;
    const meta = content ? parseSkillMeta(content) : undefined;
    const local = reportByName.get(summary.name);
    rows.set(summary.name, {
      name: summary.name,
      description: summary.description || meta?.description || "",
      audience: summary.audience?.length ? summary.audience : meta ? effectiveAudience(meta) : local?.audience ?? ["mission", "local"],
      scope: summary.scope ?? meta?.scope ?? local?.scope ?? null,
      sourceKinds: ["Library"],
      sources: local?.sources ?? [],
      inLibrary: true,
      legacyOnly: false,
      divergent: !!local?.divergent,
      desired: local?.desired ?? false,
      harnessCount: 0,
      staleCount: local?.stale_harnesses?.length ?? 0,
      lines: content ? content.split("\n").length : local?.lines ?? 0,
      content,
      lint: content ? lintSkill(summary.name, content) : [],
    });
  }

  for (const skill of input.report?.skills ?? []) {
    let row = rows.get(skill.name);
    const legacySources = (skill.sources ?? []).filter((s) => s.legacy);
    const identity = (skill.sources ?? []).some((s) => s.id === "development-identity");
    if (!row) {
      const content = (skill.sources ?? []).find((s) => s.content)?.content ?? skill.content_preview ?? undefined;
      row = {
        name: skill.name,
        description: skill.description ?? "",
        audience: skill.audience ?? [],
        scope: skill.scope ?? null,
        sourceKinds: [],
        sources: skill.sources ?? [],
        inLibrary: false,
        legacyOnly: !!skill.legacy_only,
        divergent: !!skill.divergent,
        desired: !!skill.desired,
        harnessCount: 0,
        staleCount: skill.stale_harnesses?.length ?? 0,
        lines: skill.lines ?? 0,
        content,
        lint: content && (legacySources.length || identity) ? lintSkill(skill.name, content) : [],
      };
      rows.set(skill.name, row);
    }
    if (identity && !row.sourceKinds.includes("identity")) row.sourceKinds.push("identity");
    if (legacySources.length && !row.sourceKinds.includes("legacy")) row.sourceKinds.push("legacy");
    if (!row.sourceKinds.length) row.sourceKinds.push("user");
    row.harnessCount = input.localHarnessIds.filter((h) => skill.harnesses.includes(h)).length;
  }

  for (const ps of input.projectSkills) {
    const existing = rows.get(ps.name);
    if (existing) {
      if (!existing.sourceKinds.includes("project")) existing.sourceKinds.push("project");
      existing.projectFile ??= { slug: ps.slug, path: ps.path };
      continue;
    }
    rows.set(`project:${ps.slug}:${ps.name}`, {
      name: ps.name,
      description: ps.description ?? `Project skill in ${ps.slug}`,
      audience: [],
      scope: null,
      sourceKinds: ["project"],
      sources: [],
      inLibrary: false,
      legacyOnly: false,
      divergent: false,
      desired: false,
      harnessCount: 0,
      staleCount: 0,
      lines: 0,
      lint: [],
      projectFile: { slug: ps.slug, path: ps.path },
    });
  }

  return [...rows.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function filterSkillRows(rows: SkillRow[], f: { query: string; audience: string; scope: string; problem: ProblemFilter; harnessTotal: number }): SkillRow[] {
  const q = f.query.trim().toLowerCase();
  return rows.filter((row) => {
    if (f.audience !== "all" && !row.audience.includes(f.audience)) return false;
    if (f.scope === "global" && row.scope !== "global") return false;
    if (f.scope === "on-demand" && row.scope === "global") return false;
    if (f.problem !== "all") {
      const p = rowProblems(row, f.harnessTotal);
      if (f.problem === "problems" && !(p.drift || p.divergent || p.legacy || p.lint)) return false;
      if (f.problem !== "problems" && !p[f.problem]) return false;
    }
    if (!q) return true;
    return row.name.toLowerCase().includes(q) || row.description.toLowerCase().includes(q) || row.sourceKinds.some((k) => k.toLowerCase().includes(q));
  });
}
