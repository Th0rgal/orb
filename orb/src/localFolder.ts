/**
 * The working directory of a local ("This computer") mission follows its
 * project. A mission started on its project's default workspace
 * (`local_agents_workspace`, `<root>/<slug>`) runs its next turn in the new
 * project's workspace after a move. A folder the user chose explicitly stays.
 * A turn in progress, or follow-ups already queued for the old folder, keep
 * the folder they were prepared for.
 *
 * Some harnesses key their session store by working directory: Claude Code
 * keeps `~/.claude/projects/<encoded cwd>/<session>.jsonl` and OpenCode
 * scopes sessions to the project directory, so `--resume <id>` from the new
 * folder finds nothing. For those, the switch starts a fresh session seeded
 * with the conversation so far. Codex threads are global and resume as is.
 */
import { conversationEvents, byteTail, publicEvents } from "./btwContext";
import { localBinding, localRunActive, localWorkspace, rememberBinding, type LocalBinding } from "./localAgents";
import { queuedLocalMessages } from "./localMessageQueue";

const trim = (path: string) => path.replace(/[\\/]+$/, "");
const parent = (path: string) => trim(path).replace(/[\\/][^\\/]*$/, "");

/**
 * Whether `cwd` is some project's default workspace, i.e. a sibling of
 * `workspace` (another project's default folder) under the same root.
 */
export function isProjectWorkspace(cwd: string, workspace: string): boolean {
  const a = trim(cwd), b = trim(workspace);
  return !!a && !!b && a !== parent(a) && parent(a) === parent(b);
}

/** The folder the next turn should use, given the binding and the current project's workspace. */
export function nextTurnFolder(cwd: string, workspace: string): string {
  return trim(cwd) !== trim(workspace) && isProjectWorkspace(cwd, workspace) ? workspace : cwd;
}

/** Nothing is running or waiting for this mission: its folder may change. */
export function folderCanChange(id: string): boolean {
  return !localRunActive(id) && !queuedLocalMessages(id).some(row => row.state !== "accepted");
}

/** Harnesses whose sessions cannot be resumed from a different working directory. */
export const CWD_SCOPED_SESSIONS: ReadonlySet<string> = new Set(["claudecode", "claude", "opencode"]);

const SEED_KEY = "orb.localFolderSeed";
const SEED_BYTES = 12_000;
const pendingSeeds = (): Record<string, string> => { try { return JSON.parse(localStorage.getItem(SEED_KEY) ?? "{}") ?? {}; } catch { return {}; } };
const writeSeeds = (seeds: Record<string, string>) => { try { localStorage.setItem(SEED_KEY, JSON.stringify(seeds)); } catch { /* best effort */ } };
/** Call once the seeded follow-up is queued: later turns resume the new session. */
export function seedDelivered(id: string): void { const seeds = pendingSeeds(); if (id in seeds) { delete seeds[id]; writeSeeds(seeds); } }

type Events = (id: string) => Promise<import("./stream").StoredEvent[]>;

/** The conversation so far, as text for the first turn of a fresh session. */
export async function conversationSeed(id: string, cwd: string, events: Events = id => conversationEvents(id)): Promise<string> {
  const rows = publicEvents(await events(id)).filter(e => e.event_type === "user_message" || e.event_type === "assistant_message" || e.event_type === "assistant_message_canonical");
  const text = rows.map(e => `${e.event_type === "user_message" ? "User" : "Assistant"}: ${e.content.trim()}`).filter(line => !/^\w+: $/.test(line)).join("\n\n");
  return [
    `This conversation moved to another project. You now work in ${cwd}; the previous session could not be resumed there.`,
    "Conversation so far:",
    "<conversation>",
    byteTail(text, SEED_BYTES) || "(no earlier messages)",
    "</conversation>",
    "Continue from there. The new message follows.",
  ].join("\n");
}

/** Prefix `prompt` with a pending seed, if the binding's session was reset. */
export const seededPrompt = (prompt: string, seed?: string) => seed ? `${seed}\n\n${prompt}` : prompt;

export type NextTurn = { binding: LocalBinding; seed?: string };

/**
 * The binding to use for the next turn of `id` in `project`: rebinds a
 * default-workspace binding to the project's workspace when the mission
 * moved, and returns the stored binding unchanged otherwise. For a
 * cwd-scoped harness the session is dropped and `seed` carries the history.
 */
export async function followProjectFolder(id: string, project: string, workspace: (slug: string) => Promise<string> = localWorkspace, events?: Events): Promise<NextTurn | undefined> {
  const binding = localBinding(id);
  if (!binding) return undefined;
  const pending = pendingSeeds()[id];
  if (!folderCanChange(id)) return { binding };
  // A seed not yet delivered (send failed after the switch) is offered again.
  if (pending && !binding.sessionId) return { binding, seed: pending };
  const target = await workspace(project);
  const cwd = nextTurnFolder(binding.cwd, target);
  if (cwd === binding.cwd) return { binding };
  const reset = CWD_SCOPED_SESSIONS.has(binding.harness) && !!binding.sessionId;
  const seed = reset ? await conversationSeed(id, cwd, events) : undefined;
  // Re-read: a turn may have started while the workspace was resolved.
  const current = localBinding(id);
  if (!current || current.cwd !== binding.cwd || !folderCanChange(id)) return current ? { binding: current } : undefined;
  const next: LocalBinding = { ...current, cwd };
  if (reset) delete next.sessionId;
  if (seed) writeSeeds({ ...pendingSeeds(), [id]: seed });
  await rememberBinding(id, next);
  return { binding: localBinding(id) ?? next, ...(seed ? { seed } : {}) };
}
