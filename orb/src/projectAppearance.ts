import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl } from "./api";

export const projectColors = [
  { name: "Default", value: "" }, { name: "Blue", value: "#8aaed4" },
  { name: "Green", value: "#94b89a" }, { name: "Amber", value: "#c5aa70" },
  { name: "Rose", value: "#cb929f" }, { name: "Purple", value: "#ad9acb" },
] as const;
// Preserve the reactive store when Vite replaces a settings module while the
// sidebar remains mounted; both surfaces must keep the same notification signal.
const revisionStore = import.meta.hot?.data?.projectColorRevision ?? createSignal(0);
if (import.meta.hot?.data) import.meta.hot.data.projectColorRevision = revisionStore;
const [revision, setRevision] = revisionStore as ReturnType<typeof createSignal<number>>;
const key = (slug: string) => `orb.projectColor:${getApiUrl()}:${slug}`;
export function projectColor(slug: string): string | undefined {
  revision(); connectionVersion();
  try { const color = localStorage.getItem(key(slug)); return projectColors.find(c => c.value === color)?.value || undefined; }
  catch { return undefined; }
}
export function setProjectColor(slug: string, color: string) {
  if (!projectColors.some(c => c.value === color)) return;
  if (color) localStorage.setItem(key(slug), color); else localStorage.removeItem(key(slug));
  setRevision(v => v + 1);
}
