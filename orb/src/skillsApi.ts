// Library skill CRUD, project skill selection and delivery preview.
// Newer endpoints are feature-detected: a 404 means "backend too old", not an error.
import { ApiError, api, apiText, connectionVersion, getLibrarySkill, type LibrarySkill } from "./api";
import { createSidebarRequests } from "./sidebarRequests";

const skillDeliveryCache = createSidebarRequests(20_000);

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
  skillDeliveryCache.clear();
}

export async function deleteLibrarySkill(name: string): Promise<void> {
  await apiText(skillPath(name), { method: "DELETE" });
  skillDeliveryCache.clear();
}

export function readSkillFile(name: string, rel: string): Promise<string> {
  return apiText(filePath(name, rel));
}

export async function putSkillFile(name: string, rel: string, content: string): Promise<void> {
  await apiText(filePath(name, rel), { method: "PUT", ...json({ content }) });
  skillDeliveryCache.clear();
}

export async function deleteSkillFile(name: string, rel: string): Promise<void> {
  await apiText(filePath(name, rel), { method: "DELETE" });
  skillDeliveryCache.clear();
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
    skillDeliveryCache.clear();
    return { skills: res?.skills ?? skills, missing: res?.missing ?? [] };
  } catch (e) {
    if (isNotFound(e)) throw new UnsupportedEndpoint("This backend does not support project skill selection yet.");
    throw e;
  }
}

export interface DeliveredSkill {
  name: string;
  description?: string | null;
  reasons: string[];
}

export interface SkillDelivery {
  skills: DeliveredSkill[];
  missing: string[];
}

export async function getSkillDelivery(project: string, workspaceId?: string): Promise<SkillDelivery> {
  return skillDeliveryCache.read(
    `${connectionVersion()}:${project}:${workspaceId ?? ""}`,
    async () => {
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
    },
  );
}

/** Library repo state for the Skills header ("Th0rgal/sandboxed-library · synced 2 min ago"). */
export interface LibraryStatus {
  path?: string;
  revision?: string | null;
  remote?: string;
  branch: string;
  clean: boolean;
  ahead: number;
  behind: number;
  modified_files: string[];
  /** Unix seconds of the last fetch; absent on older cores. */
  last_synced_at?: number;
}
export const getLibraryStatus = () => api<LibraryStatus>("/api/library/status");
/** Pull from the remote. */
export const syncLibrary = async () => {
  const res = await apiText("/api/library/sync", { method: "POST" });
  skillDeliveryCache.clear();
  return res;
};
/** Reset local Library checkout to match the remote branch (`POST /api/library/force-sync`). */
export const forceSyncLibrary = async () => {
  const res = await apiText("/api/library/force-sync", { method: "POST" });
  skillDeliveryCache.clear();
  return res;
};
/** Force-push local Library commits over a diverged remote branch (`POST /api/library/force-push`). */
export const forcePushLibrary = () => apiText("/api/library/force-push", { method: "POST" });

export interface UpdateLibraryRemoteResult {
  library_remote: string | null;
  library_reinitialized: boolean;
  library_error?: string;
}

export function normalizeLibraryRemote(remote?: string | null): string {
  return (remote ?? "").trim().replace(/\/+$/, "").replace(/\.git$/i, "").toLowerCase();
}

export function sameLibraryRemote(a?: string | null, b?: string | null): boolean {
  const na = normalizeLibraryRemote(a);
  const nb = normalizeLibraryRemote(b);
  return na.length > 0 && na === nb;
}

export function needsLibraryRemoteInit(
  nextRemote: string | null,
  activeRepoRemote?: string | null,
  failedInitRemote?: string | null,
): boolean {
  if (!nextRemote || !nextRemote.trim()) return false;
  if (failedInitRemote && sameLibraryRemote(nextRemote, failedInitRemote)) return true;
  return !sameLibraryRemote(nextRemote, activeRepoRemote);
}

export async function updateLibraryRemote(
  libraryRemote: string | null,
  forceReinitialize = false,
): Promise<UpdateLibraryRemoteResult> {
  const res = await api<UpdateLibraryRemoteResult>("/api/settings/library-remote", {
    method: "PUT",
    ...json(
      forceReinitialize
        ? { library_remote: libraryRemote, force_reinitialize: true }
        : { library_remote: libraryRemote },
    ),
  });
  skillDeliveryCache.clear();
  return res;
}

export function isDivergedLibraryError(err: unknown): boolean {
  if (err instanceof ApiError && err.status === 409) return true;
  const msg = err instanceof Error ? err.message : String(err);
  return msg.includes("DIVERGED_HISTORY") || /\bdiverged\b/i.test(msg);
}

/** Commit the Library and push it, so a save lands in the repo. */
export async function commitAndPush(message: string): Promise<void> {
  await apiText("/api/library/commit", { method: "POST", ...json({ message }) });
  await apiText("/api/library/push", { method: "POST" });
}

/** "git@github.com:Th0rgal/sandboxed-library.git" → "Th0rgal/sandboxed-library". */
export function repoLabel(remote?: string): string {
  if (!remote) return "Library";
  const m = remote.replace(/\.git$/, "").match(/[:/]([^/:]+\/[^/:]+)$/);
  return m ? m[1] : remote;
}

export interface SkillVersion { rev: string; author: string; timestamp: number; subject: string }
/** Git versions of a skill's SKILL.md; older cores answer 404 (UnsupportedEndpoint). */
export async function getSkillHistory(name: string): Promise<SkillVersion[]> {
  try { return await api<SkillVersion[]>(`${skillPath(name)}/history`); }
  catch (e) { if (isNotFound(e)) throw new UnsupportedEndpoint("history"); throw e; }
}
export const getSkillAt = (name: string, rev: string) => apiText(`${skillPath(name)}/history/${enc(rev)}`);

let cachedSkillNames: string[] = [];
let skillNamesVersion = -1;

function currentSkillNames(): string[] {
  const version = connectionVersion();
  if (version !== skillNamesVersion) {
    skillNamesVersion = version;
    cachedSkillNames = [];
  }
  return cachedSkillNames;
}

/** Reactive list of known skill names for autocomplete in ControllerSettings. */
export function knownSkillNames(): string[] {
  return currentSkillNames();
}

export function rememberKnownSkillNames(names: Iterable<string>) {
  const merged = new Set(currentSkillNames());
  for (const name of names) {
    const trimmed = name.trim();
    if (trimmed) merged.add(trimmed);
  }
  cachedSkillNames = [...merged].sort();
}
