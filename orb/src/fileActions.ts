import { api, ApiError, getApiUrl, getJwt, connectionVersion, listProjectCrons, updateProjectCron, type Mission } from "./api";
import { copyText } from "./clipboard";
import { localContextFile } from "./projectContext";
import { moveMission } from "./missionMove";

export interface FileClipboard { slug: string; path: string; copy: boolean; directory?: boolean; backend: string; account: string; nonce: string }
export interface CronClipboard { slug: string; id: string; name: string; folder?: string; backend: string; account: string; nonce: string }
export type ClipboardItem =
  | { kind: "file"; slug: string; path: string; directory?: boolean }
  | { kind: "cron"; slug: string; id: string; name: string; folder?: string }
  | { kind: "mission"; id: string };
export interface ItemsClipboard { items: ClipboardItem[]; copy: boolean; backend: string; account: string; nonce: string }
const prefix = "orb:file:";
const cronPrefix = "orb:cron:";
const itemsPrefix = "orb:items:";
function clipboardAccount(): string {
  try {
    const payload = getJwt()?.split(".")[1];
    const sub = payload && JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/"))).sub;
    return typeof sub === "string" ? sub : "";
  } catch { return ""; }
}
export const fileParent = (path: string) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
export const fileName = (path: string) => path.split("/").at(-1)!;
export function fileDestination(path: string, value: string, rename: boolean): string {
  const input = value.trim();
  if (rename && (!input || input.includes("/") || input.includes("\\"))) throw new Error("Enter a name without slashes.");
  const destination = rename ? [fileParent(path), input].filter(Boolean).join("/") : [input, fileName(path)].filter(Boolean).join("/");
  if (destination.includes("\\") || /[\x00-\x1f\x7f]/.test(destination) || destination.split("/").some(p => !p || p === "." || p === ".."))
    throw new Error("Use a relative project path without '.' or '..'.");
  if (destination === path) throw new Error("Choose a different name or folder.");
  return destination;
}
/** Files and folders share one transfer; another project receives a copy before the source is removed. */
export async function transferProjectFile(slug: string, path: string, destination: string, copy = false, project = slug): Promise<void> {
  const version = connectionVersion();
  if (project !== slug) {
    // This computer's copy would happily create a project Core no longer has.
    const known = await api<{ projects?: Array<{ slug?: string; status?: string }> }>("/api/projects");
    if (version !== connectionVersion()) throw new Error("Connection changed. Try again.");
    if (!known.projects?.some(row => row.slug === project && row.status !== "archived" && row.status !== "deleted")) throw new Error("The destination project no longer exists. Refresh the project list.");
  }
  const local = await localContextFile(slug, copy ? "copy" : "move", path, destination, undefined, project === slug ? undefined : project);
  if (local) return;
  if (version !== connectionVersion()) throw new Error("Connection changed. Try again.");
  try {
    // A separate route: an older backend must refuse, not move within the source project.
    await api(`/api/projects/${encodeURIComponent(slug)}/file/transfer${project === slug ? "" : `/${encodeURIComponent(project)}`}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path, destination, copy }),
    });
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) throw new Error(project === slug ? "Update the backend to enable file rename, move and copy." : "Update the backend to move files between projects.");
    throw error;
  }
}
export async function copyFileReference(slug: string, path: string, copy: boolean, directory = false): Promise<string> {
  const text = prefix + JSON.stringify({ slug, path, copy, ...(directory ? { directory } : {}), backend: getApiUrl(), account: clipboardAccount(), nonce: crypto.randomUUID() });
  await copyText(text);
  return text;
}
export function readFileReference(text: string): FileClipboard | null {
  if (!text.startsWith(prefix)) return null;
  try {
    const value = JSON.parse(text.slice(prefix.length));
    return value.backend === getApiUrl() && value.account === clipboardAccount() && typeof value.slug === "string" && typeof value.path === "string" && typeof value.copy === "boolean" && ["undefined", "boolean"].includes(typeof value.directory) && typeof value.nonce === "string" ? value : null;
  } catch { return null; }
}
export async function copyCronReference(slug: string, id: string, name: string, folder?: string): Promise<string> {
  const text = cronPrefix + JSON.stringify({ slug, id, name, ...(folder ? { folder } : {}), backend: getApiUrl(), account: clipboardAccount(), nonce: crypto.randomUUID() });
  await copyText(text);
  return text;
}
export function readCronReference(text: string): CronClipboard | null {
  if (!text.startsWith(cronPrefix)) return null;
  try {
    const value = JSON.parse(text.slice(cronPrefix.length));
    return value.backend === getApiUrl() && value.account === clipboardAccount() && typeof value.slug === "string" && typeof value.id === "string" && typeof value.name === "string" && typeof value.nonce === "string" ? value : null;
  } catch { return null; }
}
export async function copyItemsReference(items: ClipboardItem[], copy: boolean): Promise<string> {
  const text = itemsPrefix + JSON.stringify({ items, copy, backend: getApiUrl(), account: clipboardAccount(), nonce: crypto.randomUUID() });
  await copyText(text);
  return text;
}
export function readItemsReference(text: string): ItemsClipboard | null {
  if (!text.startsWith(itemsPrefix)) return null;
  try {
    const value = JSON.parse(text.slice(itemsPrefix.length));
    return value.backend === getApiUrl() && value.account === clipboardAccount() && Array.isArray(value.items) && typeof value.copy === "boolean" && typeof value.nonce === "string" ? value : null;
  } catch { return null; }
}

/** Agents and crons filed in a folder or below it. */
async function folderWork(slug: string, path: string, first = false) {
  const version = connectionVersion();
  const contains = (folder: string) => folder === path || folder.startsWith(`${path}/`);
  const checkConnection = () => { if (version !== connectionVersion()) throw new Error("Connection changed. Try again."); };
  const folder = (mission: Mission) => mission.project === slug ? (mission.tags ?? []).find(tag => tag.startsWith("orb-folder:") && contains(tag.slice(11)))?.slice(11) : undefined;
  const missions = new Map<string, string>();
  const collect = (list: Mission[]) => { for (const mission of list) { const at = folder(mission); if (at !== undefined) missions.set(mission.id, at); } };
  collect(await import("./localOrigins").then(m => m.localOrigins()));
  checkConnection();
  if (first && missions.size) return { missions, crons: [] };
  for (let offset = 0; ; offset += 200) {
    const page = await api<Mission[]>(`/api/control/missions?project=${encodeURIComponent(slug)}&limit=200&offset=${offset}&all=true`);
    checkConnection();
    collect(page);
    if (first && missions.size) return { missions, crons: [] };
    if (page.length < 200) break;
  }
  const crons = (await listProjectCrons(slug)).filter(job => contains(job.folder ?? ""));
  checkConnection();
  return { missions, crons };
}
/** Keep executable work visible: removing documents must not orphan its folder. */
export async function assertFolderHasNoWork(slug: string, path: string, action = "deleting"): Promise<void> {
  const work = await folderWork(slug, path, true);
  if (work.missions.size) throw new Error(`Move the agents out of this folder before ${action} it.`);
  if (work.crons.length) throw new Error(`Move or delete the crons in this folder before ${action} it.`);
}
/** After a folder changes path, its agents and crons follow. Safe to repeat: work already moved is not found again. */
export async function moveFolderWork(slug: string, path: string, destination: string): Promise<void> {
  const work = await folderWork(slug, path), failed: string[] = [];
  const target = (folder: string) => destination + folder.slice(path.length);
  for (const [id, folder] of work.missions) await moveMission(id, slug, target(folder)).catch(() => failed.push(id.slice(0, 8)));
  for (const job of work.crons) await updateProjectCron(slug, job.id, { folder: target(job.folder ?? "") }).catch(() => failed.push(job.name));
  if (failed.length) throw new Error(`The folder moved, but ${failed.join(", ")} could not follow. They remain visible under the previous path; move them to ${destination}.`);
}
