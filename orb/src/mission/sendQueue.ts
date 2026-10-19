/**
 * Delivering queued follow-ups in order ("Send now"). Each message keeps one
 * id for every retry: Core ignores a repeated id, so a retry after a lost
 * response can never deliver it twice.
 */
import type { Mission, MissionAttachment, MessageReceipt } from "../api";
import { messagePresentation } from "../messagePresentation";

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Run `attempt` up to `attempts` times, waiting `delayMs` between tries, as
 * long as `retryable` accepts the error. `stopped` ends the loop early
 * (resolving to `undefined`), e.g. when the conversation changed.
 */
export async function retry<T>(attempt: (index: number) => Promise<T>, o: { attempts: number; delayMs: number; retryable: (error: unknown) => boolean; stopped?: () => boolean }): Promise<T | undefined> {
  for (let index = 0; ; index++) {
    if (o.stopped?.()) return undefined;
    try { return await attempt(index); }
    catch (error) {
      if (index >= o.attempts - 1 || !o.retryable(error)) throw error;
      await sleep(o.delayMs);
    }
  }
}

/** Core answers this while the previous turn is still stopping. */
export const stillStopping = (error: unknown) => /still has a remote job|stopping|409/i.test(error instanceof Error ? error.message : String(error));

export type QueuedRow = { id: string; content: string; attached?: boolean };
type Send = (mission: string, text: string, attachments: MissionAttachment[], id: string) => Promise<MessageReceipt>;

export type DeliveryResult =
  | { kind: "delivered" }
  | { kind: "stale" }
  | { kind: "replaced"; replacement: Mission; forwardError?: unknown; undelivered: QueuedRow[] };

/**
 * Send `rows` to `mission` one after another. When Core answers with a
 * replacement mission, the remaining rows are forwarded to it in order; the
 * first forwarding failure stops forwarding and is reported with the rows
 * that did not arrive, instead of being dropped silently.
 */
export async function deliverInOrder(o: {
  mission: string;
  rows: QueuedRow[];
  attempts: number;
  delayMs?: number;
  send: Send;
  attachments: (text: string) => MissionAttachment[];
  stale: () => boolean;
  newId?: () => string;
  onDelivered: (row: QueuedRow, receipt: MessageReceipt, text: string, attachments: MissionAttachment[]) => void;
  onReplacement?: (replacement: Mission, text: string) => void;
}): Promise<DeliveryResult> {
  const newId = o.newId ?? (() => crypto.randomUUID());
  for (let i = 0; i < o.rows.length; i++) {
    if (o.stale()) return { kind: "stale" };
    const row = o.rows[i];
    const text = messagePresentation(row.content).text;
    const attachments = o.attachments(text);
    const id = newId();
    const receipt = await retry(() => o.send(o.mission, text, attachments, id), { attempts: o.attempts, delayMs: o.delayMs ?? 250, retryable: stillStopping, stopped: o.stale });
    if (!receipt || o.stale()) return { kind: "stale" };
    if (receipt.replacement) {
      const replacement = receipt.replacement;
      o.onReplacement?.(replacement, text);
      const rest = o.rows.slice(i + 1);
      for (let r = 0; r < rest.length; r++) {
        const restText = messagePresentation(rest[r].content).text;
        try { await o.send(replacement.id, restText, o.attachments(restText), newId()); }
        catch (forwardError) { return { kind: "replaced", replacement, forwardError, undelivered: rest.slice(r) }; }
      }
      return { kind: "replaced", replacement, undelivered: [] };
    }
    o.onDelivered(row, receipt, text, attachments);
  }
  return { kind: "delivered" };
}
