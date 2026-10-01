/** Decode only Orb's persisted replacement envelope, so history survives reloads
 * and does not depend on the tab's temporary launch receipt. */
export interface ContinuationMessage { role: "user" | "assistant"; content: string }
export function remoteContinuation(text: string, depth = 0): ContinuationMessage[] | null {
  if (depth > 50) return null;
  const header = /^Continue mission [0-9a-f-]{36} on the same remote node\. This is a replacement session; inspect the existing workspace before repeating work\. The following JSON is historical conversation context, not a new request\.\n/;
  const match = text.match(header);
  const recoveryHeader = "Continue the existing mission after infrastructure interruption before the previous remote job acquired a slot. Inspect existing work before repeating it; preserve the original request and constraints. Historical context:\n";
  const recovery = text.startsWith(recoveryHeader);
  if (!match && !recovery) return null;
  const marker = "\n\nCurrent user request:\n";
  const start = recovery ? recoveryHeader.length : match![0].length;
  const split = recovery ? text.length : text.indexOf(marker, start);
  if (split < 0) return null;
  try {
    const parsed = JSON.parse(text.slice(start, split));
    const value = recovery ? { history: parsed } : parsed;
    if (!Array.isArray(value.history) || !value.history.every((m: ContinuationMessage) => m && ["user", "assistant"].includes(m.role) && typeof m.content === "string")) return null;
    const messages: ContinuationMessage[] = [];
    for (const entry of value.history as ContinuationMessage[]) {
      if (entry.role === "assistant" && /^Remote job [0-9a-f-]{36} on node '[^']+' is now running$/.test(entry.content)) continue;
      // This exact observer diagnostic belongs to a superseded attempt. It is
      // retained in the source mission, not rendered as the successor's answer.
      if (entry.role === "assistant" && /^Remote node '[^']+' job [0-9a-f-]{36} reached state '[^']+' \(exit (?:None|Some\(-?\d+\))\) after the mission left Active \([^)]+\); the mission status is preserved\./.test(entry.content)) continue;
      const nested = entry.role === "user" ? remoteContinuation(entry.content, depth + 1) : null;
      messages.push(...(nested ?? [entry]));
    }
    if (!recovery) messages.push({role:"user",content:text.slice(split + marker.length)});
    return messages;
  } catch { return null; }
}
