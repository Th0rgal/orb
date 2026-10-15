import { appendClientTranscript, getApiUrl, getJwt } from "./api";
import type { ClientRunReceipt } from "./clientRuns";
import { nativeInvoke } from "./clientRuns";

const connection = () => ({ api_url: getApiUrl(), token: getJwt() ?? "" });

/** Whether Orb desktop streams local runs to Core over the client link. */
export async function clientLinkActive(): Promise<boolean> {
  const invoke = nativeInvoke();
  if (!invoke) return false;
  try { return await invoke("client_link_active", { connection: connection() }) === true; }
  catch { return false; }
}

/**
 * Deliver a local run's final answer before its status closes the run. With
 * the client link in use the journal carries the text, so wait until Core has
 * acknowledged it; if it cannot drain in time, post the transcript instead
 * (a rare duplicate beats a lost answer, and late journal events are fenced).
 */
export async function deliverAssistantText(id: string, text: string, receipt?: ClientRunReceipt, eventId?: Parameters<typeof appendClientTranscript>[3]): Promise<void> {
  if (!text.trim()) return;
  const invoke = nativeInvoke();
  if (invoke && await clientLinkActive()) {
    try {
      if (await invoke("client_link_flush", { connection: connection(), mission: id, timeoutMs: 15000 }) === true) return;
    } catch { /* fall back to the transcript */ }
  }
  await appendClientTranscript(id, "assistant", text, eventId, receipt);
}
