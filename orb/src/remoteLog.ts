/** Recover human text from remote terminal receipts. Raw diagnostics always
 * remain available in collapsed details, regardless of the harness format. */
export function remoteLog(raw: string): { text: string; details?: string } {
  if (!/^Remote node '[^']+' job [0-9a-f-]{36} (?:finished with|reached) state '/.test(raw)) return { text: raw };
  const marker = raw.indexOf("\n\nlog tail:\n");
  if (marker < 0) return { text: raw };
  const log = raw.slice(marker + "\n\nlog tail:\n".length);
  const parts: string[] = [];
  const seen = new Set<string>();
  for (const line of log.split("\n")) {
    try {
      const event = JSON.parse(line);
      if (typeof event?.sessionID !== "string" || !event.sessionID.startsWith("ses_") || event.type !== "text" || typeof event.part?.text !== "string") continue;
      const id = event.part.id;
      if (typeof id === "string" && seen.has(id)) continue;
      if (typeof id === "string") seen.add(id);
      parts.push(event.part.text);
    } catch { /* A log tail can begin in the middle of a JSON line. */ }
  }
  if (!parts.length) {
    // Claude's remote runner already returns plain Markdown. Only unwrap the
    // exact successful receipt. Other logs belong in diagnostics, not Markdown.
    const success = /^Remote node '[^']+' job [0-9a-f-]{36} finished with state 'succeeded' \(exit Some\(0\)\)$/.test(raw.slice(0, marker));
    if (success && log.trim() && !structuredHarnessLog(log)) return { text: log, details: raw };
    return { text: raw.slice(0, marker), details: raw };
  }
  const failed = !/finished with state 'succeeded'/.test(raw.slice(0, marker));
  return { text: (failed ? raw.slice(0, marker) + "\n\n" : "") + parts.join("\n\n"), details: raw };
}

function structuredHarnessLog(log: string): boolean {
  return log.split("\n").some(line => {
    try {
      const event = JSON.parse(line);
      if (!event || typeof event !== "object" || Array.isArray(event)) return false;
      // Recognize transport envelopes, not arbitrary requested JSON responses.
      if (typeof event.sessionID === "string" && event.sessionID.startsWith("ses_")) {
        return ["text", "tool_use", "step_start", "step_finish", "error"].includes(event.type)
          && event.part != null;
      }
      const payload = event.event === "step_update" ? event.step_update : event.event === "result" ? event.result : null;
      if (!payload || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(payload.conversation_id ?? "")) return false;
      return event.event === "step_update"
        ? Number.isInteger(payload.step_index) && ["ACTIVE", "DONE", "ERROR"].includes(payload.state)
        : ["SUCCESS", "ERROR"].includes(payload.status) && typeof payload.duration_seconds === "number";
    } catch { return false; }
  });
}
