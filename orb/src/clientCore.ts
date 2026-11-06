/**
 * Verified client-core reducers and framing gates (`lean/OrbClient/{Spec,Reducers}.lean`),
 * checked mechanically in CI against Lean-generated `shared/orb-spec/fixtures/client-core.json`.
 */

export const ORB_PATCH_MAGIC_0 = 0x4f; // 'O'
export const ORB_PATCH_MAGIC_1 = 0x52; // 'R'
export const ORB_PATCH_MAGIC_2 = 0x42; // 'B'
export const ORB_PATCH_MAGIC_3 = 0x50; // 'P'
export const ORB_PATCH_MAX_PAYLOAD_BYTES = 65_535;
export const ORB_PATCH_HEADER_BYTES = 8;

export interface SyncCursorState {
  epoch: bigint;
  seq: bigint;
}

const U64_MAX = 0xffff_ffff_ffff_ffffn;
const U32_MAX = 0xffff_ffff;

function asExactU64(v: bigint | number): bigint | null {
  if (typeof v === "bigint") {
    return v >= 0n && v <= U64_MAX ? v : null;
  }
  if (!Number.isSafeInteger(v) || v < 0) return null;
  return BigInt(v);
}

function asExactU32(v: number): number | null {
  if (!Number.isInteger(v) || v < 0 || v > U32_MAX) return null;
  return v >>> 0;
}

/**
 * Mirrors `OrbClient.Spec.verifyClientSyncCursor` (`orb_client_verify_sync_cursor`).
 */
export function verifyClientSyncCursor(
  localEpoch: bigint | number,
  incomingEpoch: bigint | number,
  localSeq: bigint | number,
  incomingSeq: bigint | number,
  frameValid: boolean,
  authOk: boolean,
): boolean {
  const le = asExactU64(localEpoch);
  const ie = asExactU64(incomingEpoch);
  const ls = asExactU64(localSeq);
  const isq = asExactU64(incomingSeq);
  if (le === null || ie === null || ls === null || isq === null) return false;
  return (
    frameValid &&
    authOk &&
    ie > 0n &&
    (le < ie || (le === ie && ls < isq))
  );
}

/**
 * Mirrors `OrbClient.Reducers.stepSyncCursor`: monotonically advances `(epoch, seq)` iff admitted.
 */
export function stepSyncCursor(
  cur: SyncCursorState,
  incomingEpoch: bigint | number,
  incomingSeq: bigint | number,
  frameValid: boolean,
  authOk: boolean,
): { stepped: boolean; state: SyncCursorState } {
  const ie = asExactU64(incomingEpoch);
  const isq = asExactU64(incomingSeq);
  if (
    ie !== null &&
    isq !== null &&
    verifyClientSyncCursor(cur.epoch, ie, cur.seq, isq, frameValid, authOk)
  ) {
    return { stepped: true, state: { epoch: ie, seq: isq } };
  }
  return { stepped: false, state: cur };
}

/**
 * Mirrors `OrbClient.Spec.projectTranscript` (`orb_client_project_transcript_counts`):
 * `isReplayFromLog` is strictly projection-invariant (`transcript_projection_replay_invariant`).
 */
export function projectTranscriptCounts(
  userTurns: number,
  toolTurns: number,
  thinkingOpen: boolean,
  _isReplayFromLog: boolean,
): { visibleEntries: number; thinkingActive: boolean } {
  const u = asExactU32(userTurns) ?? 0;
  const t = asExactU32(toolTurns) ?? 0;
  return {
    visibleEntries: (u + t) >>> 0,
    thinkingActive: thinkingOpen,
  };
}

/**
 * Mirrors `OrbClient.Spec.verifyBundleBudget` (`orb_client_verify_bundle_budget`).
 */
export function verifyBundleBudget(
  eagerBytes: bigint | number,
  budgetBytes: bigint | number,
  singleAppEntry: boolean,
  hasEagerHeavyVendor: boolean,
): boolean {
  const eb = asExactU64(eagerBytes);
  const bb = asExactU64(budgetBytes);
  if (eb === null || bb === null) return false;
  return singleAppEntry && !hasEagerHeavyVendor && bb > 0n && eb <= bb;
}

/**
 * Mirrors `OrbClient.Reducers.encodeOrbClientPatch?`:
 * 8-byte `"ORBP"` header (`schema` in `1..=255`, big-endian `payload.byteLength` in `1..=65535`).
 */
export function encodeOrbClientPatch(
  schema: number,
  payload: Uint8Array,
): Uint8Array | null {
  if (
    !Number.isInteger(schema) ||
    schema < 1 ||
    schema > 255 ||
    payload.byteLength < 1 ||
    payload.byteLength > ORB_PATCH_MAX_PAYLOAD_BYTES
  ) {
    return null;
  }
  const len = payload.byteLength;
  const frame = new Uint8Array(ORB_PATCH_HEADER_BYTES + len);
  frame[0] = ORB_PATCH_MAGIC_0;
  frame[1] = ORB_PATCH_MAGIC_1;
  frame[2] = ORB_PATCH_MAGIC_2;
  frame[3] = ORB_PATCH_MAGIC_3;
  frame[4] = (schema >>> 8) & 0xff;
  frame[5] = schema & 0xff;
  frame[6] = (len >>> 8) & 0xff;
  frame[7] = len & 0xff;
  frame.set(payload, ORB_PATCH_HEADER_BYTES);
  return frame;
}

/**
 * Mirrors `OrbClient.Spec.parseOrbClientPatch` (`TotalSliceParserSpec`, `<= 65535` bytes).
 */
export function parseOrbClientPatch(raw: Uint8Array): Uint8Array | null {
  if (raw.byteLength < 9) return null;
  if (
    raw[0] !== ORB_PATCH_MAGIC_0 ||
    raw[1] !== ORB_PATCH_MAGIC_1 ||
    raw[2] !== ORB_PATCH_MAGIC_2 ||
    raw[3] !== ORB_PATCH_MAGIC_3
  ) {
    return null;
  }
  const schema = ((raw[4] << 8) | raw[5]) >>> 0;
  const payLen = ((raw[6] << 8) | raw[7]) >>> 0;
  if (
    schema >= 1 &&
    schema <= 255 &&
    payLen >= 1 &&
    payLen <= ORB_PATCH_MAX_PAYLOAD_BYTES &&
    ORB_PATCH_HEADER_BYTES + payLen === raw.byteLength
  ) {
    return raw.slice(ORB_PATCH_HEADER_BYTES, ORB_PATCH_HEADER_BYTES + payLen);
  }
  return null;
}
