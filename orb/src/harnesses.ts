/**
 * The harnesses Orb can launch, in composer order (native agents first, then
 * routers). Every list of harness ids and every display name comes from here.
 */
export const HARNESSES = [
  { id: "claudecode", name: "Claude Code", goal: true, remoteNeedsProxy: true },
  { id: "codex", name: "Codex", goal: true, remoteNeedsProxy: true },
  { id: "grok", name: "Grok", goal: true, remoteNeedsProxy: false },
  { id: "opencode", name: "OpenCode", goal: true, remoteNeedsProxy: true },
  { id: "antigravity", name: "Antigravity CLI", goal: true, remoteNeedsProxy: false },
  { id: "vibe", name: "Mistral Vibe", goal: false, remoteNeedsProxy: false },
] as const;

export type HarnessId = (typeof HARNESSES)[number]["id"];
export const HARNESS_IDS: readonly HarnessId[] = HARNESSES.map(h => h.id);

const BY_ID = new Map<string, (typeof HARNESSES)[number]>(HARNESSES.map(h => [h.id, h]));
/** Names for backends that older missions may still carry. */
const LEGACY_NAMES: Record<string, string> = { gemini: "Gemini", hermes: "Hermes" };

export const isHarness = (id: string | null | undefined): id is HarnessId => !!id && BY_ID.has(id);
export const harnessName = (id: string): string => BY_ID.get(id)?.name ?? LEGACY_NAMES[id] ?? id;
/** Harnesses whose runners understand `/goal`. */
export const GOAL_HARNESSES: ReadonlySet<string> = new Set(HARNESSES.filter(h => h.goal).map(h => h.id));
/** Default when a server does not list `requires_proxy_harnesses`. */
export const REMOTE_PROXY_HARNESSES: ReadonlySet<string> = new Set(HARNESSES.filter(h => h.remoteNeedsProxy).map(h => h.id));
/** Side questions run on these, in the order the settings offer them. */
export const SIDE_QUESTION_HARNESSES: readonly HarnessId[] = ["opencode", "claudecode", "codex", "grok"];
/** Composer order; unknown backends sort last. */
export const harnessRank = (id: string): number => { const i = HARNESS_IDS.indexOf(id as HarnessId); return i < 0 ? 99 : i; };
