import { api, ApiError, getApiUrl, getJwt, connectionVersion, listProjectCrons, type Mission } from "./api";
import { copyText } from "./clipboard";
import { localContextFile } from "./projectContext";

export interface FileClipboard { slug: string; path: string; copy: boolean; backend: string; account: string; nonce: string }
const prefix = "orb:file:";
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
  if (rename && (!input || input.includes("/") || input.includes("\\"))) throw new Error("Enter a file name without slashes.");
  const destination = rename ? [fileParent(path), input].filter(Boolean).join("/") : [input, fileName(path)].filter(Boolean).join("/");
  if (destination.includes("\\") || /[\x00-\x1f\x7f]/.test(destination) || destination.split("/").some(p => !p || p === "." || p === ".."))
    throw new Error("Use a relative project path without '.' or '..'.");
  if (destination === path) throw new Error("Choose a different name or folder.");
  return destination;
}
export async function transferProjectFile(slug: string, path: string, destination: string, copy = false): Promise<void> {
  const version = connectionVersion();
  const local = await localContextFile(slug, copy ? "copy" : "move", path, destination);
  if (local) return;
  if (version !== connectionVersion()) throw new Error("Connection changed. Try again.");
  try {
    await api(`/api/projects/${encodeURIComponent(slug)}/file/transfer`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path, destination, copy }),
    });
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) throw new Error("Update the backend to enable file rename, move and copy.");
    throw error;
  }
}
export async function copyFileReference(slug: string, path: string, copy: boolean): Promise<string> {
  const text = prefix + JSON.stringify({ slug, path, copy, backend: getApiUrl(), account: clipboardAccount(), nonce: crypto.randomUUID() });
  await copyText(text);
  return text;
}
export function readFileReference(text: string): FileClipboard | null {
  if (!text.startsWith(prefix)) return null;
  try {
    const value = JSON.parse(text.slice(prefix.length));
    return value.backend === getApiUrl() && value.account === clipboardAccount() && typeof value.slug === "string" && typeof value.path === "string" && typeof value.copy === "boolean" && typeof value.nonce === "string" ? value : null;
  } catch { return null; }
}

/** Keep executable work visible: removing documents must not orphan its folder. */
export async function assertFolderHasNoWork(slug: string, path: string): Promise<void> {
  const version = connectionVersion();
  const contains = (folder: string) => folder === path || folder.startsWith(`${path}/`);
  const checkConnection = () => { if (version !== connectionVersion()) throw new Error("Connection changed. Try again."); };
  const hasMission = (mission: Mission) => mission.project === slug && (mission.tags ?? []).some(tag => tag.startsWith("orb-folder:") && contains(tag.slice(11)));
  const local = await import("./localOrigins").then(m => m.localOrigins());
  checkConnection();
  if (local.some(hasMission)) throw new Error("Move the agents out of this folder before deleting it.");
  for (let offset = 0; ; offset += 200) {
    const missions = await api<Mission[]>(`/api/control/missions?project=${encodeURIComponent(slug)}&limit=200&offset=${offset}&all=true`);
    checkConnection();
    if (missions.some(hasMission)) throw new Error("Move the agents out of this folder before deleting it.");
    if (missions.length < 200) break;
  }
  const crons = await listProjectCrons(slug);
  checkConnection();
  if (crons.some(job => contains(job.folder ?? ""))) throw new Error("Move or delete the crons in this folder before deleting it.");
}
