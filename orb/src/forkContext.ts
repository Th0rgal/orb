export interface ForkContext {
  source_mission_id: string;
  source_title?: string | null;
  messages: { role: "user" | "assistant" | "context"; content: string }[];
  /** An edited message: the visible request, sent after the collapsed history. */
  request?: string;
}
const PREAMBLES = ["Continue the work from this conversation in a fresh native session.", "The user edited a message in this conversation and sent it again."];
const OPEN = "\n<fork_context>\n";
const CLOSE = "\n</fork_context>";
const REQUEST = `${CLOSE}\n\nCurrent request:\n`;
/** Only collapse the complete, structured fork envelope; malformed text stays visible. */
export function forkContext(text: string): ForkContext | null {
  if (!PREAMBLES.some(preamble => text.startsWith(preamble))) return null;
  const start = text.indexOf(OPEN);
  if (start < 0) return null;
  // The JSON escapes `<`, so the first closing tag ends it.
  const end = text.indexOf(CLOSE, start);
  if (end < 0) return null;
  const rest = text.slice(end);
  const request = rest === CLOSE ? undefined : rest.startsWith(REQUEST) ? rest.slice(REQUEST.length) : null;
  if (request === null) return null;
  try {
    const value = JSON.parse(text.slice(start + OPEN.length, end));
    // Antigravity's bounded history is a single "context" excerpt.
    if (typeof value.source_mission_id !== "string" || !Array.isArray(value.messages) || !value.messages.every((m: { role?: string; content?: string }) => m && ["user", "assistant", "context"].includes(m.role ?? "") && typeof m.content === "string")) return null;
    return request === undefined ? value : { ...value, request };
  } catch { return null; }
}
