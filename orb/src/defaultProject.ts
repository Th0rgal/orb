import { connectionVersion, createProject, listProjects, type ProjectSummary } from "./api";

export const DEFAULT_PROJECT = { slug: "default", title: "Default" };

/** Offer the catch-all before it is persisted; retain an existing project's title. */
export function projectChoices(projects: ProjectSummary[]) {
  const fallback = projects.find(project => project.slug === DEFAULT_PROJECT.slug) ?? DEFAULT_PROJECT;
  return [fallback, ...projects.filter(project => project.slug !== DEFAULT_PROJECT.slug)
    .sort((a, b) => (b.updated_at ?? "").localeCompare(a.updated_at ?? ""))]
    .map(project => ({ id: project.slug, name: project.title ?? project.slug }));
}

/** Re-read before the first launch so an existing record is never overwritten. */
export async function ensureDefaultProject(): Promise<ProjectSummary> {
  const version = connectionVersion();
  const projects = await listProjects();
  if (connectionVersion() !== version) throw new Error("The backend changed. Try again; your draft is kept.");
  return projects.find(project => project.slug === DEFAULT_PROJECT.slug) ?? await createProject(DEFAULT_PROJECT);
}

/** A sidebar selection may precede the WebView roster. Verify the selected slug before dispatch. */
export async function requireLaunchProject(slug: string): Promise<void> {
  const version = connectionVersion();
  const projects = await listProjects(true, false);
  if (connectionVersion() !== version) throw new Error("The backend changed. Try again; your draft is kept.");
  if (!projects.some(project => project.slug === slug)) {
    throw new Error(`Project “${slug}” is unavailable. Choose another project or retry. Your draft is kept.`);
  }
}
