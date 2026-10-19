import { nativeEvents } from "./native";
import { swallow } from "./log";
import { appendClientTranscript, getApiUrl, getJwt } from "./api";
import type { ClientRunReceipt } from "./clientRuns";
import { nativeInvoke } from "./clientRuns";

const connection = () => ({ api_url: getApiUrl(), token: getJwt() ?? "" });

/**
 * Wait until Core acknowledged everything the client link journaled for this
 * run (its converter finished and every event was acknowledged). Call before
 * any status that closes the run, or the tail would be fenced out.
 * Returns false when the link is not in use or could not drain in time.
 */
export async function flushClientLink(id: string, timeoutMs = 15000): Promise<boolean> {
  // Not gated on the handshake: a run can finish before `welcome` arrives.
  // Native flush is false for any run the link did not carry.
  const invoke = nativeInvoke();
  if (!invoke) return false;
  try { return await invoke("client_link_flush", { connection: connection(), mission: id, timeoutMs }) === true; }
  catch { return false; }
}

/**
 * Deliver a local run's final answer before its status closes the run. With
 * the client link in use the journal carries the text (and any tool calls or
 * error, even for an empty answer), so wait until Core has acknowledged it;
 * if it cannot drain in time, post the transcript instead (a rare duplicate
 * beats a lost answer, and late journal events are fenced).
 */
export async function deliverAssistantText(id: string, text: string, receipt?: ClientRunReceipt, eventId?: Parameters<typeof appendClientTranscript>[3]): Promise<void> {
  if (await flushClientLink(id)) return;
  if (text.trim()) await appendClientTranscript(id, "assistant", text, eventId, receipt);
}

/** A start requested from another device (iOS, Android, web) for this computer. */
export interface RemoteStart {
  request_id: string;
  prompt: string;
  backend: string;
  title?: string | null;
  project?: string | null;
  model_override?: string | null;
  model_effort?: string | null;
  working_directory?: string | null;
}

let stopListening: (() => void) | undefined;
/**
 * Open the client link for the signed-in account (so this computer is listed
 * as online) and handle remote starts. Each start is answered exactly once.
 */
export async function connectClientLink(start: (request: RemoteStart) => Promise<string>): Promise<void> {
  const invoke = nativeInvoke();
  if (!invoke) return;
  try { if (await invoke("client_link_connect", { connection: connection() }) !== true) return; }
  catch { return; }
  const events = nativeEvents();
  if (!events || stopListening) return;
  const seen = new Set<string>();
  stopListening = await events.listen<RemoteStart>("client-link-start", ({ payload }) => {
    if (!payload?.request_id || seen.has(payload.request_id)) return;
    seen.add(payload.request_id);
    const answer = (ok: boolean, missionId?: string, error?: string) =>
      invoke("client_link_start_result", { connection: connection(), requestId: payload.request_id, ok, missionId: missionId ?? null, error: error ?? null }).catch(swallow("clientLink.startResult", { requestId: payload.request_id, ok }));
    void start(payload).then(id => answer(true, id), (e: unknown) => answer(false, undefined, e instanceof Error ? e.message : String(e)));
  });
}

/** Tell Core which harnesses (and models) this computer can run. */
export async function reportClientHarnesses(harnesses: { backend: string; name: string; models: { value: string; label: string }[] }[]): Promise<void> {
  const invoke = nativeInvoke();
  if (!invoke || !harnesses.length) return;
  try { await invoke("client_link_set_capabilities", { connection: connection(), harnesses }); } catch { /* best effort */ }
}
