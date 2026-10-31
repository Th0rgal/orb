import { jsonSignal } from "./storage";
import type {CodexServiceTier} from './api';
import { destinationHarnessChoices } from "./harness-models";
import { createSignal } from "solid-js";
import { normalizeEffort } from "./effort";
import {
  localInstalled,
} from "./localAgents";
import {
  ApiError,
  listHarnessChoices,
  type HarnessChoice,
  connectionVersion,
  listNodeAntigravityModels,
} from "./api";


/** Harness + model chosen for new agents; persisted per user. `effort` is
 * absent for "let the backend decide", and is dropped whenever the selected
 * harness does not accept that level (see `effort.ts`). */
export type HarnessPick = { backend: string; model: string; effort?: string; service_tier?: CodexServiceTier };
const PICK_KEY = "orb.harnessPick";
export const [remoteHarnessChoices, setRemoteHarnessChoices] = createSignal<HarnessChoice[]>([]);
export const [nodeAntigravityModels, setNodeAntigravityModels] = createSignal<Record<string, [string,string][]>>({});
const nodeModelRequests = new Set<string>();
export async function refreshNodeAntigravityModels(machine: string) {
  if (!machine || machine === "local" || machine === "side") return;
  const version = connectionVersion(), key = `${version}:${machine}`;
  if (nodeModelRequests.has(key)) return;
  nodeModelRequests.add(key);
  try {
    const models = await listNodeAntigravityModels(machine);
    if (version === connectionVersion()) setNodeAntigravityModels(old => ({...old, [key]:models}));
  } catch (error) {
    // A slow or failed lookup must not hide Antigravity on this machine for the whole
    // session: keep whatever was known and retry shortly unless the node does not exist.
    const permanent = error instanceof ApiError && (error.status === 404 || error.status === 409);
    if (!permanent && version === connectionVersion()) setTimeout(() => void refreshNodeAntigravityModels(machine), 15_000);
  }
  finally { nodeModelRequests.delete(key); }
}
export const harnessChoices = (machine = "core"): HarnessChoice[] => {
  const version = connectionVersion(), nodeModels = nodeAntigravityModels();
  const models = machine === "local"
    ? (localInstalled().find(row => row.id === "antigravity")?.models ?? [])
    : (nodeModels[`${version}:${machine}`]?.length ? nodeModels[`${version}:${machine}`] : (nodeModels[`${version}:core`] ?? []));
  const claude = machine === "local" ? (localInstalled().find(row => row.id === "claudecode")?.models ?? []) : [];
  return destinationHarnessChoices(remoteHarnessChoices(), machine, models, localInstalled().some(row => row.id === "vibe" && row.installed), claude);
};
export const [harnessPick, setHarnessPick] = jsonSignal<HarnessPick | null>(PICK_KEY, null);
/** Preserve an explicit selection; launch validation reports unavailable models.
 * A stored effort is normalized against the stored harness on every read, so a
 * level that harness never accepted can't survive into a create payload. */
export const effectivePick = (machine = "core"): HarnessPick | null => {
  const choices = harnessChoices(machine);
  if (!choices.length) return null;
  const stored = harnessPick();
  if (stored) {
    const effort = normalizeEffort(stored.effort, stored.backend);
    return { ...stored, effort: effort ?? undefined };
  }
  const first = choices.find((c) => c.backend.id === "claudecode") ?? choices[0];
  return { backend: first.backend.id, model: first.models[0].value };
};
export async function refreshHarnessChoices() {
  try {
    setRemoteHarnessChoices(await listHarnessChoices());
  } catch {
    /* keep last */
  }
}

