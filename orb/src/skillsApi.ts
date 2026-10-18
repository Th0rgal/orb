// Library skill CRUD, project skill selection and delivery preview.
// Newer endpoints are feature-detected: a 404 means "backend too old", not an error.
import { ApiError, api, apiText, getLibrarySkill, type LibrarySkill } from "./api";

const enc = encodeURIComponent;
const skillPath = (name: string) => `/api/library/skill/${enc(name)}`;
const filePath = (name: string, rel: string) => `${skillPath(name)}/files/${rel.split("/").map(enc).join("/")}`;
const json = (body: unknown): RequestInit => ({ headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export class UnsupportedEndpoint extends Error {}

const isNotFound = (e: unknown) => e instanceof ApiError && e.status === 404;

export function fetchLibrarySkill(name: string): Promise<LibrarySkill> {
  return getLibrarySkill(name);
}

export async function putLibrarySkill(name: string, content: string): Promise<void> {
  await apiText(skillPath(name), { method: "PUT", ...json({ content }) });
}

export async function deleteLibrarySkill(name: string): Promise<void> {
  await apiText(skillPath(name), { method: "DELETE" });
}

export function readSkillFile(name: string, rel: string): Promise<string> {
  return apiText(filePath(name, rel));
}

export async function putSkillFile(name: string, rel: string, content: string): Promise<void> {
  await apiText(filePath(name, rel), { method: "PUT", ...json({ content }) });
}

export async function deleteSkillFile(name: string, rel: string): Promise<void> {
  await apiText(filePath(name, rel), { method: "DELETE" });
}

/** Reference files of a Library skill: markdown files come inline, others by path. */
export function referencePaths(skill: Pick<LibrarySkill, "files" | "references">): string[] {
  const set = new Set<string>();
  for (const f of skill.files ?? []) {
    const rel = f.path || f.name;
    if (rel && rel !== "SKILL.md") set.add(rel);
  }
  for (const r of skill.references ?? []) if (r && r !== "SKILL.md") set.add(r);
  return [...set].sort();
}

export interface ProjectSkillSelection {
  skills: string[];
  missing: string[];
}

export async function getProjectSkills(slug: string): Promise<ProjectSkillSelection> {
  try {
    const res = await api<Partial<ProjectSkillSelection>>(`/api/projects/${enc(slug)}/skills`, { method: "GET" });
    return { skills: res?.skills ?? [], missing: res?.missing ?? [] };
  } catch (e) {
    if (isNotFound(e)) throw new UnsupportedEndpoint("This backend does not support project skill selection yet.");
    throw e;
  }
}

export async function putProjectSkills(slug: string, skills: string[]): Promise<ProjectSkillSelection> {
  try {
    const res = await api<Partial<ProjectSkillSelection> | undefined>(`/api/projects/${enc(slug)}/skills`, { method: "PUT", ...json({ skills }) });
    return { skills: res?.skills ?? skills, missing: res?.missing ?? [] };
  } catch (e) {
    if (isNotFound(e)) throw new UnsupportedEndpoint("This backend does not support project skill selection yet.");
    throw e;
  }
}

export interface DeliveredSkill {
  name: string;
  reasons: string[];
}

export interface SkillDelivery {
  skills: DeliveredSkill[];
  missing: string[];
}

export async function getSkillDelivery(project: string, workspaceId?: string): Promise<SkillDelivery> {
  const q = new URLSearchParams();
  if (workspaceId) q.set("workspace_id", workspaceId);
  if (project) q.set("project", project);
  try {
    const res = await api<Partial<SkillDelivery>>(`/api/library/skill-delivery?${q}`, { method: "GET" });
    return { skills: res?.skills ?? [], missing: res?.missing ?? [] };
  } catch (e) {
    if (isNotFound(e)) throw new UnsupportedEndpoint("This backend does not report skill delivery yet.");
    throw e;
  }
}
