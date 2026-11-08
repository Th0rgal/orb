/**
 * Shared Lean WASM follow-up queue reconciliation adapter (`SM-24`, `G-ORB-8`).
 *
 * Keeps all admission, CAS revision checking, duplicate suppression, and
 * `(client_msg_id, posted_after_seq)` turn retirement delegated to
 * `orbFollowupQueueStep` (`orb_followup_queue_step` in `orb_kernel.wasm`)
 * without importing `./api` (preserving partial `../src/api` test mocks).
 */
import { orbFollowupQueueStep } from "./orbKernel";

export const FOLLOWUP_OP_POLL_RECONCILE = 0;
export const FOLLOWUP_OP_EDIT_CAS = 1;
export const FOLLOWUP_OP_ENQUEUE_OPTIMISTIC = 2;
export const FOLLOWUP_OP_TRANSCRIPT_TURN_RECONCILE = 3;

export const FOLLOWUP_REASON_MALFORMED = 0;
export const FOLLOWUP_REASON_APPLIED = 1;
export const FOLLOWUP_REASON_STALE_REV = 2;
export const FOLLOWUP_REASON_DUPLICATE_ID = 3;
export const FOLLOWUP_REASON_NOT_RETIRED = 4;
export const FOLLOWUP_REASON_REV_SATURATED = 5;

const FNV_OFFSET_64 = 0xcbf29ce484222325n;
const FNV_PRIME_64 = 0x100000001b3n;
const MASK_64 = 0xffff_ffff_ffff_ffffn;
const MAX_U32 = 0xffff_ffff;

/** Deterministic non-zero 64-bit FNV-1a hash for `client_msg_id` / turn key tokens. */
export function hashFollowupMsgIdU64(value: string): bigint {
  const trimmed = value.trim();
  if (!trimmed) return 0n;
  let hash = FNV_OFFSET_64;
  for (let i = 0; i < trimmed.length; i++) {
    hash ^= BigInt(trimmed.charCodeAt(i) & 0xff);
    hash = (hash * FNV_PRIME_64) & MASK_64;
    const hi = (trimmed.charCodeAt(i) >>> 8) & 0xff;
    if (hi !== 0) {
      hash ^= BigInt(hi);
      hash = (hash * FNV_PRIME_64) & MASK_64;
    }
  }
  return hash === 0n ? 1n : hash;
}

export function normalizeFollowupRev(rev: number | bigint | null | undefined, fallback = 1): number {
  if (rev === null || rev === undefined) return fallback;
  const num = typeof rev === "bigint" ? Number(rev) : Math.trunc(rev);
  if (!Number.isFinite(num) || num <= 0) return fallback;
  return num > MAX_U32 ? MAX_U32 : num >>> 0;
}

export function normalizeFollowupPrompt(text: string): string {
  return text.replace(/\r\n/g, "\n").trim();
}

const observedMissionQueueRevs = new Map<string, number>();

export function noteObservedMissionQueueRevision(
  scopeKey: string,
  explicitRev: number | bigint | null | undefined,
): number | undefined {
  if (explicitRev === null || explicitRev === undefined) {
    return observedMissionQueueRevs.get(scopeKey);
  }
  const num = typeof explicitRev === "bigint" ? Number(explicitRev) : Math.trunc(explicitRev);
  if (!Number.isFinite(num) || num <= 0) return observedMissionQueueRevs.get(scopeKey);
  const clamped = num > MAX_U32 ? MAX_U32 : num >>> 0;
  const prev = observedMissionQueueRevs.get(scopeKey) ?? 1;
  const step = orbFollowupQueueStep({
    op: FOLLOWUP_OP_POLL_RECONCILE,
    serverRev: prev,
    incomingServerRev: clamped,
    expectedServerRev: prev,
    clientMsgId: 0n,
    trackedMsgId: 0n,
    deliveredMsgId: 0n,
    postedAfterSeq: 0n,
    turnSeq: 0n,
    optimisticSending: false,
    serverListed: false,
    contentMatched: false,
    alreadyDelivered: false,
  });
  if (step.admitted) {
    observedMissionQueueRevs.set(scopeKey, step.nextServerRev);
    return step.nextServerRev;
  }
  return prev;
}

export function peekObservedMissionQueueRevision(scopeKey: string): number | undefined {
  return observedMissionQueueRevs.get(scopeKey);
}

export function clearObservedMissionQueueRevision(scopeKey: string): void {
  observedMissionQueueRevs.delete(scopeKey);
}

/** Stepper wrapper for server queue poll reconciliation (`op = 0`). */
export function stepFollowupPollReconcile(params: {
  serverRev: number;
  incomingServerRev: number;
  clientMsgId?: string;
  postedAfterSeq?: number | bigint;
  turnSeq?: number | bigint;
  optimisticSending?: boolean;
  serverListed?: boolean;
  alreadyDelivered?: boolean;
}) {
  return orbFollowupQueueStep({
    op: FOLLOWUP_OP_POLL_RECONCILE,
    serverRev: normalizeFollowupRev(params.serverRev, 1),
    incomingServerRev: normalizeFollowupRev(params.incomingServerRev, 1),
    expectedServerRev: normalizeFollowupRev(params.serverRev, 1),
    clientMsgId: params.clientMsgId ? hashFollowupMsgIdU64(params.clientMsgId) : 0n,
    trackedMsgId: 0n,
    deliveredMsgId: 0n,
    postedAfterSeq: params.postedAfterSeq ?? 0n,
    turnSeq: params.turnSeq ?? 0n,
    optimisticSending: Boolean(params.optimisticSending),
    serverListed: Boolean(params.serverListed),
    contentMatched: false,
    alreadyDelivered: Boolean(params.alreadyDelivered),
  });
}

/** Stepper wrapper for atomic CAS queue editing (`op = 1`). */
export function stepFollowupEditCas(params: {
  serverRev: number;
  expectedServerRev: number;
  clientMsgId: string;
  serverListed: boolean;
  alreadyDelivered: boolean;
}) {
  const idHash = hashFollowupMsgIdU64(params.clientMsgId);
  return orbFollowupQueueStep({
    op: FOLLOWUP_OP_EDIT_CAS,
    serverRev: normalizeFollowupRev(params.serverRev, 1),
    incomingServerRev: normalizeFollowupRev(params.serverRev, 1),
    expectedServerRev: normalizeFollowupRev(params.expectedServerRev, 1),
    clientMsgId: idHash,
    trackedMsgId: idHash,
    deliveredMsgId: 0n,
    postedAfterSeq: 0n,
    turnSeq: 0n,
    optimisticSending: false,
    serverListed: params.serverListed,
    contentMatched: false,
    alreadyDelivered: params.alreadyDelivered,
  });
}

/** Stepper wrapper for optimistic follow-up admission (`op = 2`). */
export function stepFollowupEnqueueOptimistic(params: {
  serverRev: number;
  clientMsgId: string;
  trackedMsgId?: string;
  postedAfterSeq?: number | bigint;
  alreadyDelivered: boolean;
}) {
  return orbFollowupQueueStep({
    op: FOLLOWUP_OP_ENQUEUE_OPTIMISTIC,
    serverRev: normalizeFollowupRev(params.serverRev, 1),
    incomingServerRev: normalizeFollowupRev(params.serverRev, 1),
    expectedServerRev: normalizeFollowupRev(params.serverRev, 1),
    clientMsgId: hashFollowupMsgIdU64(params.clientMsgId),
    trackedMsgId: params.trackedMsgId ? hashFollowupMsgIdU64(params.trackedMsgId) : 0n,
    deliveredMsgId: 0n,
    postedAfterSeq: params.postedAfterSeq ?? 0n,
    turnSeq: params.postedAfterSeq ?? 0n,
    optimisticSending: true,
    serverListed: false,
    contentMatched: false,
    alreadyDelivered: params.alreadyDelivered,
  });
}

/** Stepper wrapper for transcript / cloud turn retirement (`op = 3`). */
export function stepFollowupTurnReconcile(params: {
  serverRev?: number;
  clientMsgId: string;
  deliveredMsgId?: string | null;
  postedAfterSeq: number | bigint;
  turnSeq: number | bigint;
  contentMatched: boolean;
  serverListed?: boolean;
  alreadyDelivered?: boolean;
}) {
  const idHash = hashFollowupMsgIdU64(params.clientMsgId);
  const deliveredHash = params.deliveredMsgId ? hashFollowupMsgIdU64(params.deliveredMsgId) : 0n;
  return orbFollowupQueueStep({
    op: FOLLOWUP_OP_TRANSCRIPT_TURN_RECONCILE,
    serverRev: normalizeFollowupRev(params.serverRev, 1),
    incomingServerRev: normalizeFollowupRev(params.serverRev, 1),
    expectedServerRev: normalizeFollowupRev(params.serverRev, 1),
    clientMsgId: idHash,
    trackedMsgId: idHash,
    deliveredMsgId: deliveredHash,
    postedAfterSeq: params.postedAfterSeq,
    turnSeq: params.turnSeq,
    optimisticSending: false,
    serverListed: Boolean(params.serverListed),
    contentMatched: params.contentMatched,
    alreadyDelivered: Boolean(params.alreadyDelivered),
  });
}
