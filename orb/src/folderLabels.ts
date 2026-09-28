import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, getJwt } from "./api";

// Labels leave folder identity intact, including open files and running agents.
const revisionStore = import.meta.hot?.data?.folderLabelRevision ?? createSignal(0);
if (import.meta.hot?.data) import.meta.hot.data.folderLabelRevision = revisionStore;
const [revision, setRevision] = revisionStore as ReturnType<typeof createSignal<number>>;
const basename = (path: string) => path.split("/").at(-1) ?? path;
function key(slug: string, path: string): string {
  let account = "default";
  try {
    const payload = getJwt()?.split(".")[1];
    if (payload) {
      const claims = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
      if (typeof claims.sub === "string") account = claims.sub;
    }
  } catch { /* Older connections may not use a JWT. */ }
  return `orb.folderLabel:${JSON.stringify([getApiUrl(), account, slug, path])}`;
}
export function folderLabel(slug: string, path: string): string {
  revision(); connectionVersion();
  try { return localStorage.getItem(key(slug, path)) || basename(path); }
  catch { return basename(path); }
}
export function setFolderLabel(slug: string, path: string, raw: string): void {
  const label = raw.trim();
  if (!label) throw new Error("Enter a folder name.");
  if (/[\x00-\x1f\x7f]/.test(label)) throw new Error("Use a folder name without control characters.");
  if (label === basename(path)) localStorage.removeItem(key(slug, path));
  else localStorage.setItem(key(slug, path), label);
  setRevision(value => value + 1);
}
