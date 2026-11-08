import { nativeEvents } from "./native";
import { swallow } from "./log";
import { appendClientTranscript, currentCapabilityEpochKey, getApiUrl, getJwt, getServerBuild } from "./api";
import type { ClientRunReceipt } from "./clientRuns";
import { nativeInvoke } from "./clientRuns";

const connection = () => ({ api_url: getApiUrl(), token: getJwt() ?? "" });
let unsupportedClientLinkEpoch: string | null = null;

export interface ClientLinkJournalEnqueueReceipt {
  seq: number;
  unacked_count: number;
  last_acked_seq: number;
  head_seq: number;
}

export interface ClientLinkResyncSummary {
  replay_from_seq: number;
  head_seq: number;
  replay_count: number;
  frames: Array<{ seq: number; mission: string; payload: unknown }>;
}

export function isClientLinkUnsupportedForCurrentEpoch(): boolean {
  return unsupportedClientLinkEpoch !== null && unsupportedClientLinkEpoch === currentCapabilityEpochKey();
}

export function recordClientLinkHttpStatus(status: number): void {
  if (status === 404 || status === 501) {
    unsupportedClientLinkEpoch = currentCapabilityEpochKey();
  }
}

/**
 * Enqueue one outbound frame in `orb-locald`'s 256-frame client-link journal ring (`SM-26`).
 * Rejects with `"client_link_journal_backpressure"` at 256 unacked frames rather than silently dropping.
 */
export async function enqueueClientLinkFrame(id: string, payload: unknown): Promise<ClientLinkJournalEnqueueReceipt | null> {
  if (isClientLinkUnsupportedForCurrentEpoch()) return null;
  const invoke = nativeInvoke();
  if (!invoke) return null;
  return await invoke("client_link_flush", {
    connection: connection(),
    action: "enqueue",
    mission: id,
    payload,
  }) as ClientLinkJournalEnqueueReceipt;
}

/** Acknowledge cumulative `ackSeq` on `orb-locald`'s client-link journal ring (`SM-26`). */
export async function ackClientLinkFrames(ackSeq: number): Promise<void> {
  const invoke = nativeInvoke();
  if (!invoke) return;
  await invoke("client_link_flush", {
    connection: connection(),
    action: "ack",
    ack_seq: ackSeq,
  });
}

/** Compute reconnect replay window after `(last_acked_seq, head_seq)` resync (`SM-26`). */
export async function resyncClientLinkFrames(peerAckSeq: number): Promise<ClientLinkResyncSummary | null> {
  const invoke = nativeInvoke();
  if (!invoke) return null;
  return await invoke("client_link_flush", {
    connection: connection(),
    action: "resync",
    peer_ack_seq: peerAckSeq,
  }) as ClientLinkResyncSummary;
}

/**
 * Wait until Core acknowledged everything the client link journaled for this
 * run (its converter finished and every event was acknowledged). Call before
 * any status that closes the run, or the tail would be fenced out.
 * Returns false when the link is not in use or could not drain in time.
 */
export async function flushClientLink(id: string, timeoutMs = 15000): Promise<boolean> {
  if (isClientLinkUnsupportedForCurrentEpoch()) return false;
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
  if (isClientLinkUnsupportedForCurrentEpoch()) return;
  const invoke = nativeInvoke();
  if (!invoke) return;
  try {
    const serverBuild = getServerBuild();
    const ok = await invoke("client_link_connect", {
      connection: connection(),
      ...(serverBuild ? { server_build: serverBuild } : {}),
    });
    if (ok !== true) return;
  }
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
  if (isClientLinkUnsupportedForCurrentEpoch()) return;
  const invoke = nativeInvoke();
  if (!invoke || !harnesses.length) return;
  try {
    const serverBuild = getServerBuild();
    await invoke("client_link_set_capabilities", {
      connection: connection(),
      harnesses,
      ...(serverBuild ? { server_build: serverBuild } : {}),
    });
  } catch { /* best effort */ }
}
