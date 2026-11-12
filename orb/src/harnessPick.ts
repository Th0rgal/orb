import { jsonSignal } from "./storage";
import type {CodexServiceTier} from './api';
import { destinationHarnessChoices } from "./harness-models";
import { isAutoManagedTarget } from "./machines/nodes";
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
const RETIRED_DEFAULT_MODELS = new Set([
  "claude-fable-5-1",
  "anthropic/claude-fable-5-1",
  "claude-fable-5",
  "anthropic/claude-fable-5",
]);
export const [remoteHarnessChoices, setRemoteHarnessChoices] = createSignal<HarnessChoice[]>([]);
export const [nodeAntigravityModels, setNodeAntigravityModels] = createSignal<Record<string, [string,string][]>>({});
const nodeModelRequests = new Set<string>();
const nodeModelRetryTimers = new Map<string, ReturnType<typeof setTimeout>>();
const nodeModelFailures = new Map<string, number>();
const NODE_MODEL_RETRY_MS = [15_000, 45_000, 120_000] as const;

export async function refreshNodeAntigravityModels(machine: string) {
  if (!machine || machine === "local" || machine === "side" || isAutoManagedTarget(machine)) return;
  const version = connectionVersion(), key = `${version}:${machine}`;
  if (nodeModelRequests.has(key)) return;
  const pendingTimer = nodeModelRetryTimers.get(key);
  if (pendingTimer !== undefined) {
    clearTimeout(pendingTimer);
    nodeModelRetryTimers.delete(key);
  }
  nodeModelRequests.add(key);
  try {
    const models = await listNodeAntigravityModels(machine);
    if (version === connectionVersion()) {
      nodeModelFailures.delete(key);
      setNodeAntigravityModels(old => ({...old, [key]:models}));
    }
  } catch (error) {
    // A slow or failed lookup must not hide Antigravity on this machine for the whole
    // session: keep whatever was known and retry with bounded backoff unless permanent.
    const permanent = error instanceof ApiError && (error.status === 404 || error.status === 409);
    const attempt = nodeModelFailures.get(key) ?? 0;
    if (!permanent && version === connectionVersion() && attempt < NODE_MODEL_RETRY_MS.length) {
      nodeModelFailures.set(key, attempt + 1);
      const delay = NODE_MODEL_RETRY_MS[attempt];
      const timer = setTimeout(() => {
        nodeModelRetryTimers.delete(key);
        if (typeof document !== "undefined" && document.hidden) return;
        void refreshNodeAntigravityModels(machine);
      }, delay);
      nodeModelRetryTimers.set(key, timer);
    }
  }
  finally { nodeModelRequests.delete(key); }
}
export const harnessChoices = (machine = "core"): HarnessChoice[] => {
  const version = connectionVersion(), nodeModels = nodeAntigravityModels();
  const models = machine === "local"
    ? (localInstalled().find(row => row.id === "antigravity")?.models ?? [])
    : (nodeModels[`${version}:${machine}`]?.length ? nodeModels[`${version}:${machine}`] : (nodeModels[`${version}:core`] ?? []));
  const claude = machine === "local" ? (localInstalled().find(row => row.id === "claudecode")?.models ?? []) : [];
  const opencode = machine === "local" ? (localInstalled().find(row => row.id === "opencode")?.models ?? []) : [];
  return destinationHarnessChoices(remoteHarnessChoices(), machine, models, localInstalled().some(row => row.id === "vibe" && row.installed), claude, opencode);
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
    const choice = choices.find((c) => c.backend.id === stored.backend);
    if (RETIRED_DEFAULT_MODELS.has(stored.model)) {
      const fallback = choice?.models[0]?.value;
      if (fallback && !RETIRED_DEFAULT_MODELS.has(fallback)) {
        return { ...stored, model: fallback, effort: effort ?? undefined };
      }
    }
    // On this computer, Core-scoped OpenCode IDs (e.g. `builtin/fast`) map to
    // the local OpenCode provider namespace (e.g. `orbrouter/builtin/fast`) or
    // the user's configured default local OpenCode model.
    if (
      machine === "local" &&
      stored.backend === "opencode" &&
      choice?.models.length &&
      !choice.models.some((m) => m.value === stored.model)
    ) {
      const bare = stored.model.replace(/^sandboxed-sh\//, "");
      const matched =
        choice.models.find((m) => m.value === `orbrouter/${bare}`) ??
        choice.models.find((m) => m.value.endsWith(`/${bare}`)) ??
        choice.models[0];
      return { ...stored, model: matched.value, effort: effort ?? undefined };
    }
    // Conversely, on Core or fleet/cloud nodes (`machine !== "local"`), local
    // OpenCode provider-prefixed IDs (e.g. `orbrouter/builtin/smart`) map back
    // to Core's canonical chain/model IDs (e.g. `builtin/smart`).
    if (
      machine !== "local" &&
      stored.backend === "opencode" &&
      choice?.models.length &&
      !choice.models.some((m) => m.value === stored.model) &&
      (stored.model.startsWith("orbrouter/") || stored.model.startsWith("sandboxed-sh/"))
    ) {
      const bare = stored.model.replace(/^(?:orbrouter|sandboxed-sh)\//, "");
      const matched =
        choice.models.find((m) => m.value === bare) ??
        choice.models.find((m) => m.value === `builtin/${bare}`) ??
        choice.models.find((m) => m.value.endsWith(`/${bare}`)) ??
        choice.models[0];
      return { ...stored, model: matched.value, effort: effort ?? undefined };
    }
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

