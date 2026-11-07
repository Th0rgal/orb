// Host input encoding and presentation over generated scalar ABI adapters.
import { kernelAbi as kernel } from "./orbKernelAbi";
import { ensureKernelLinearScratch, kernelScratchBaseOffset } from "./orbKernelRuntime";

export type WorkfoldVerdict = { foldItem: boolean; foldHasToolNext: boolean };
export type TranscriptPatchState = { len: number; seq: number };
const b8 = (value: boolean) => value ? 1 : 0;
const enum8 = (value: number) => Number.isInteger(value) && value >= 0 && value <= 255 ? value : 255;
const sat8 = (value: number) => Math.max(0, Math.min(255, Number.isFinite(value) ? Math.round(value) : 255));
const sat32 = (value: number) => Number.isFinite(value) ? Math.max(0, Math.min(0xffff_ffff, Math.floor(value))) : 0;
function seconds(value: number): bigint {
  if (!Number.isFinite(value)) throw new RangeError("Time must be finite");
  const whole = Math.max(0, Math.floor(value));
  if (!Number.isSafeInteger(whole)) throw new RangeError("Time is outside the exact integer range");
  return BigInt(whole);
}
const byte = (raw: bigint, shift: bigint) => Number((raw >> shift) & 255n);

export function orbWorkfoldStep(itemKind: number, isCumulative: boolean, isNonEmpty: boolean, toolAhead: boolean,
  nextIsTool: boolean, foldHasTool: boolean): WorkfoldVerdict {
  const raw = kernel.orb_workfold_step(enum8(itemKind), b8(isCumulative), b8(isNonEmpty), b8(toolAhead), b8(nextIsTool), b8(foldHasTool));
  return { foldItem: (raw & 1) !== 0, foldHasToolNext: ((raw >> 8) & 1) !== 0 };
}

export function orbTaskcardStep(turnEnded: boolean, allClosed: boolean, turnOutcomeFinished: boolean): "live" | "done" | "stale" | "stopped" {
  const code = kernel.orb_taskcard_step(b8(turnEnded), b8(allClosed), b8(turnOutcomeFinished));
  return (["live", "done", "stale", "stopped"] as const)[code];
}

export function orbRelativeTimeString(elapsedSecs: number): string {
  const raw = kernel.orb_relative_time_bucket(seconds(elapsedSecs));
  const unit = byte(raw, 0n), value = Number((raw >> 8n) & 0xffff_ffffn);
  return unit === 0 ? "now" : `${value}${["", "m", "h", "d", "w"][unit]}`;
}

export function orbUsageLimitBadge(status: string, claim: string, hasUtilization: boolean, utilizationPct: number,
  hasReset: boolean, resetRemSecs: number): { tone: "warning" | "error"; label: string } | null {
  const statusKind = !status || status === "allowed" || status === "ok" ? 0 : status === "allowed_warning" ? 1 : status === "rejected" ? 2 : 3;
  const claimKind = ["", "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].indexOf(claim);
  const resetPresent = hasReset && Number.isFinite(resetRemSecs) && Number.isSafeInteger(Math.floor(resetRemSecs));
  const raw = kernel.orb_usage_limit_status(statusKind, Math.max(0, claimKind),
    b8(hasUtilization && Number.isFinite(utilizationPct) && utilizationPct >= 0 && utilizationPct <= 100), sat8(utilizationPct),
    b8(resetPresent), seconds(resetPresent ? resetRemSecs : 0));
  const tone = byte(raw, 0n);
  if (tone === 0) return null;
  if (tone === 1) {
    const label = ["", "5h", "weekly", "weekly Opus", "weekly Sonnet"][byte(raw, 8n)];
    const pct = byte(raw, 16n) ? ` ${byte(raw, 24n)}%` : "";
    return { tone: "warning", label: label ? `Approaching limit · ${label}${pct}` : "Approaching limit" };
  }
  if (tone === 2) {
    const unit = byte(raw, 32n), value = Number((raw >> 40n) & 0xff_ffffn);
    return { tone: "error", label: unit ? `Limit reached · resets in ${value}${["", "m", "h", "d"][unit]}` : "Limit reached" };
  }
  return { tone: "warning", label: "Limit status unknown" };
}

export function orbTranscriptPatchStep(state: TranscriptPatchState, eventKind: number, deltaLen: number): TranscriptPatchState {
  const raw = kernel.orb_transcript_patch_step(state.len, state.seq, enum8(eventKind), sat32(deltaLen));
  return { len: Number(raw & 0xffff_ffffn), seq: Number(raw >> 32n) };
}

// Coordinates must be exactly representable before crossing the UInt64 boundary.
const coordinates = (...values: number[]) => values.every(value => Number.isSafeInteger(value) && value >= 0);
export function leansysGfmPipeRowAdmitted(rowOff: number, rowLen: number, bufLen: number, colCount: number,
  sepCols: number, unterminatedEscape: boolean): boolean {
  if (!coordinates(rowOff, rowLen, bufLen, colCount, sepCols) || colCount > 0xffff_ffff || sepCols > 0xffff_ffff) return false;
  return kernel.leansys_gfm_pipe_scan(BigInt(rowOff), BigInt(rowLen), BigInt(bufLen), colCount, sepCols, b8(unterminatedEscape)) !== 0;
}

export function leansysRichTagAdmitted(tagOff: number, tagLen: number, attrOff: number, attrLen: number,
  bufLen: number, tagKind: number): boolean {
  if (!coordinates(tagOff, tagLen, attrOff, attrLen, bufLen, tagKind) || tagKind > 255) return false;
  return kernel.leansys_tag_scan(BigInt(tagOff), BigInt(tagLen), BigInt(attrOff), BigInt(attrLen), BigInt(bufLen), tagKind) !== 0;
}

export function leansysVerifyFdBounds(rawWord: bigint, fdOut: number): boolean {
  if (!Number.isInteger(fdOut) || fdOut < 0 || fdOut > 0xffff_ffff) return false;
  return kernel.leansys_verify_fd_bounds(BigInt.asUintN(64, rawWord), fdOut) !== 0;
}

const u64 = (value: bigint | number): bigint =>
  typeof value === "bigint" ? BigInt.asUintN(64, value) : seconds(value);

export type FieldPresence = 0 | 1 | 2;

export function orbWireApplyPatchStep(currentRev: bigint | number, incomingRev: bigint | number,
  currentVal: number | null, presence: number, incomingVal: number): {
  actionCode: number; admitted: boolean; nextVal: number | null;
} {
  const raw = kernel.orb_wire_apply_patch_step(u64(currentRev), u64(incomingRev), b8(currentVal !== null),
    sat32(currentVal ?? 0), enum8(presence), sat32(incomingVal));
  const lo32 = Number(raw & 0xffff_ffffn), hi32 = Number((raw >> 32n) & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    nextVal: ((lo32 >> 9) & 1) !== 0 ? hi32 : null,
  };
}

export function orbWireMachineStep(schemaId: number, stateRev: bigint | number, eventSeq: bigint | number,
  effectKind: number, effectAdmitted: boolean, outCap: number, requiredOutBytes: number): {
  actionCode: number; admitted: boolean; emitEffect: boolean; nextRev32: number;
} {
  const raw = kernel.orb_wire_machine_step(sat32(schemaId), u64(stateRev), u64(eventSeq),
    enum8(effectKind), b8(effectAdmitted), sat32(outCap), sat32(requiredOutBytes));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    emitEffect: ((lo32 >> 9) & 1) !== 0,
    nextRev32: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbHierarchyMergeStep(input: {
  currentEpoch: bigint | number; incomingEpoch: bigint | number; archiveEpoch: bigint | number;
  curArchived: boolean; curSuperseded: boolean; isPartialPatch: boolean;
  parentPresence: number; curParentOrd: number; incParentOrd: number;
  incArchive: boolean; incUnarchive: boolean; incSupersede: boolean;
}): {
  actionCode: number; admitted: boolean; nextArchived: boolean;
  nextSuperseded: boolean; unarchived: boolean; nextParentOrd: number;
} {
  const raw = kernel.orb_hierarchy_merge_step(
    u64(input.currentEpoch), u64(input.incomingEpoch), u64(input.archiveEpoch),
    b8(input.curArchived), b8(input.curSuperseded), b8(input.isPartialPatch),
    enum8(input.parentPresence), sat32(input.curParentOrd), sat32(input.incParentOrd),
    b8(input.incArchive), b8(input.incUnarchive), b8(input.incSupersede));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    nextArchived: ((lo32 >> 9) & 1) !== 0,
    nextSuperseded: ((lo32 >> 10) & 1) !== 0,
    unarchived: ((lo32 >> 11) & 1) !== 0,
    nextParentOrd: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbTranscriptFoldStep(lastAppliedSeq: bigint | number, incomingSeq: bigint | number,
  entryCount: number, thinkingOpen: boolean, normalizedAction: number, isReplayFromLog: boolean): {
  actionCode: number; admitted: boolean; thinkingOpenNext: boolean;
  closedPreviousThinking: boolean; gapBuffered: boolean; nextEntryCount: number;
} {
  const raw = kernel.orb_transcript_fold_step(u64(lastAppliedSeq), u64(incomingSeq), sat32(entryCount),
    b8(thinkingOpen), enum8(normalizedAction), b8(isReplayFromLog));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    thinkingOpenNext: ((lo32 >> 9) & 1) !== 0,
    closedPreviousThinking: ((lo32 >> 10) & 1) !== 0,
    gapBuffered: ((lo32 >> 11) & 1) !== 0,
    nextEntryCount: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbOutboxCrashReconcileStep(durableQueued: number, durableAcked: number,
  volatileInFlight: number, leaseBootEpoch: bigint | number, nodeBootEpoch: bigint | number,
  volatileLeaseOwner: number, reqOwner: number): {
  actionCode: number; admitted: boolean; crashReconciled: boolean;
  hasSingleWriter: boolean; unackedDepth: number;
} {
  const raw = kernel.orb_outbox_crash_reconcile_step(sat32(durableQueued), sat32(durableAcked),
    sat32(volatileInFlight), u64(leaseBootEpoch), u64(nodeBootEpoch),
    sat32(volatileLeaseOwner), sat32(reqOwner));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    crashReconciled: ((lo32 >> 9) & 1) !== 0,
    hasSingleWriter: ((lo32 >> 10) & 1) !== 0,
    unackedDepth: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbProviderAttemptStep(input: {
  pinnedAccountId: number; candidateAccountId: number; attemptsUsed: number; retryBudget: number;
  firstByteCommitted: boolean; failureKind: number; upstreamNowEpoch: bigint | number;
  cooldownUntilEpoch: bigint | number; upstreamDeadline: bigint | number; authValid: boolean;
}): {
  actionCode: number; admitted: boolean; firstByteLockedNext: boolean; nextAttemptsUsed: number;
} {
  const raw = kernel.orb_provider_attempt_step(
    sat32(input.pinnedAccountId), sat32(input.candidateAccountId),
    sat32(input.attemptsUsed), sat32(input.retryBudget),
    b8(input.firstByteCommitted), enum8(input.failureKind),
    u64(input.upstreamNowEpoch), u64(input.cooldownUntilEpoch), u64(input.upstreamDeadline),
    b8(input.authValid));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    actionCode: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    firstByteLockedNext: ((lo32 >> 9) & 1) !== 0,
    nextAttemptsUsed: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbAuthToctouExecuteStep(input: {
  principalKind: number; bunkerState: number; observedTargetId: number; execTargetId: number;
  observedLeaseEpoch: bigint | number; liveLeaseEpoch: bigint | number;
  nowTick: bigint | number; expiryTick: bigint | number;
  observedDigest: bigint | number; execDigest: bigint | number;
}): { admitted: boolean; failClosed: boolean; reasonCode: number } {
  const raw = kernel.orb_auth_toctou_execute_step(
    enum8(input.principalKind), enum8(input.bunkerState),
    sat32(input.observedTargetId), sat32(input.execTargetId),
    u64(input.observedLeaseEpoch), u64(input.liveLeaseEpoch),
    u64(input.nowTick), u64(input.expiryTick),
    u64(input.observedDigest), u64(input.execDigest));
  return {
    admitted: ((raw >>> 8) & 1) !== 0,
    failClosed: ((raw >>> 9) & 1) !== 0,
    reasonCode: raw & 0xff,
  };
}

export function orbResourceLedgerStep(input: {
  opKind: number; reservedSlots: number; activeSlots: number; maxSlots: number;
  spentCents: bigint | number; costDeltaCents: bigint | number; budgetCents: bigint | number;
  nowTick: bigint | number; ttlExpiryTick: bigint | number;
}): { stateValid: boolean; admitted: boolean; nextReservedSlots: number; nextActiveSlots: number } {
  const raw = kernel.orb_resource_ledger_step(
    enum8(input.opKind), sat32(input.reservedSlots), sat32(input.activeSlots), sat32(input.maxSlots),
    u64(input.spentCents), u64(input.costDeltaCents), u64(input.budgetCents),
    u64(input.nowTick), u64(input.ttlExpiryTick));
  const lo32 = Number(raw & 0xffff_ffffn), hi32 = Number((raw >> 32n) & 0xffff_ffffn);
  return {
    stateValid: lo32 !== 0,
    admitted: ((lo32 >> 8) & 1) !== 0,
    nextReservedSlots: hi32 & 0xffff,
    nextActiveSlots: (hi32 >>> 16) & 0xffff,
  };
}

export function orbStreamBoundedCommitStep(prevLen: number, prevCommit: number, prevCheckpoint: number,
  newLen: number, rawCommit: number, maxOpenTailBytes: number): {
  admitted: boolean; checkpointForced: boolean; nextCheckpoint: number;
} {
  const raw = kernel.orb_stream_bounded_commit_step(sat32(prevLen), sat32(prevCommit),
    sat32(prevCheckpoint), sat32(newLen), sat32(rawCommit), sat32(maxOpenTailBytes));
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    admitted: ((lo32 >> 8) & 1) !== 0,
    checkpointForced: ((lo32 >> 9) & 1) !== 0,
    nextCheckpoint: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export const ORB_WIRE_MAGIC = 0x4f52_4257;
export const ORB_WIRE_ABI_VERSION = 1;
export const ORB_WIRE_HEADER_BYTES = 24;
export const ORB_WIRE_DEFAULT_MAX_BUDGET = 65_536;

export type OrbWireStatusCode = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9;

export type OrbWireRecord = {
  tag: number;
  flags: number;
  len16: number;
  payload32: number;
};

export type OrbWireSliceView = {
  schemaId: number;
  flags: number;
  totalLen: number;
  payloadLen: number;
  arenaOff: number;
  arenaLen: number;
  recordsBytes: Uint8Array;
  arenaBytes: Uint8Array;
  recordCount: number;
  recordAt(index: number): OrbWireRecord | null;
  arenaSlice(offset: number, len: number): Uint8Array | null;
};

function clampWireStatus(code: number): OrbWireStatusCode {
  return (code >= 0 && code <= 9 ? code : 3) as OrbWireStatusCode;
}

function exactU64(value: bigint | number): bigint | null {
  if (typeof value === "bigint") {
    return value >= 0n && value <= 0xffff_ffff_ffff_ffffn ? value : null;
  }
  return Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null;
}

function exactU32(value: number): number | null {
  return Number.isInteger(value) && value >= 0 && value <= 0xffff_ffff ? value : null;
}

function exactSchemaId(value: number): number | null {
  return Number.isInteger(value) && value >= 1 && value <= 0xffff ? value : null;
}

function spansOverlap(aStart: number, aLen: number, bStart: number, bLen: number): boolean {
  return aLen > 0 && bLen > 0 && aStart < bStart + bLen && bStart < aStart + aLen;
}

export function orbWireVerifySliceIo(input: {
  inPtr: bigint | number;
  inLen: bigint | number;
  outPtr: bigint | number;
  outCap: bigint | number;
  writtenLen: bigint | number;
  is32Bit: boolean | number;
}): OrbWireStatusCode {
  const widthFlag = typeof input.is32Bit === "boolean" ? b8(input.is32Bit) : enum8(input.is32Bit);
  if (widthFlag > 1) return 6;
  const inPtr = exactU64(input.inPtr);
  const inLen = exactU64(input.inLen);
  const outPtr = exactU64(input.outPtr);
  const outCap = exactU64(input.outCap);
  const writtenLen = exactU64(input.writtenLen);
  if (inPtr === null || inLen === null || outPtr === null || outCap === null || writtenLen === null) {
    return 8;
  }
  const raw = kernel.orb_wire_verify_slice_io(
    inPtr, inLen, outPtr,
    outCap, writtenLen, widthFlag,
  );
  return clampWireStatus(raw);
}

export function orbWireEncodeSliceInto(input: {
  schemaId: number;
  flags?: number;
  records: readonly OrbWireRecord[];
  arena: Uint8Array;
  outBuf: Uint8Array;
  maxBudgetBytes?: number;
  inArenaPtr?: bigint | number;
  outPtr?: bigint | number;
}): { status: OrbWireStatusCode; written: number } {
  const scratchBase = BigInt(kernelScratchBaseOffset());
  const schemaId = exactSchemaId(input.schemaId);
  if (schemaId === null) {
    return { status: 2, written: 0 };
  }
  const flags = exactU32(input.flags ?? 0);
  if (flags === null) {
    return { status: 3, written: 0 };
  }
  const maxBudget = exactU32(input.maxBudgetBytes ?? ORB_WIRE_DEFAULT_MAX_BUDGET);
  if (maxBudget === null) {
    return { status: 4, written: 0 };
  }
  const recordsCount = exactU32(input.records.length);
  const arenaBytes = input.arena.byteLength;
  const arenaLen = exactU32(arenaBytes);
  if (recordsCount === null || arenaLen === null) {
    return { status: 3, written: 0 };
  }
  const outCapNum = input.outBuf.byteLength;
  const outCap = exactU64(outCapNum);
  if (outCap === null) {
    return { status: 8, written: 0 };
  }
  const sharesBackingBuffer =
    arenaBytes > 0 && outCapNum > 0 && input.arena.buffer === input.outBuf.buffer;
  if (sharesBackingBuffer &&
      spansOverlap(input.arena.byteOffset, arenaBytes, input.outBuf.byteOffset, outCapNum)) {
    return { status: 9, written: 0 };
  }
  const defaultInPtr = sharesBackingBuffer
    ? scratchBase + BigInt(input.arena.byteOffset)
    : (arenaBytes === 0 ? 0n : scratchBase);
  const defaultOutPtr = sharesBackingBuffer
    ? scratchBase + BigInt(input.outBuf.byteOffset)
    : (outCapNum === 0 ? 0n : (defaultInPtr === 0n ? scratchBase : defaultInPtr + BigInt(Math.max(arenaBytes, 8))));
  const inPtr = input.inArenaPtr === undefined ? defaultInPtr : exactU64(input.inArenaPtr);
  const outPtr = input.outPtr === undefined ? defaultOutPtr : exactU64(input.outPtr);
  if (inPtr === null || outPtr === null) {
    return { status: 8, written: 0 };
  }
  if ((arenaBytes > 0 && inPtr > 0n && inPtr < scratchBase) ||
      (outCapNum > 0 && outPtr > 0n && outPtr < scratchBase)) {
    return { status: 9, written: 0 };
  }
  for (let i = 0; i < input.records.length; i++) {
    const rec = input.records[i];
    if (!Number.isInteger(rec.tag) || rec.tag < 0 || rec.tag > 0xff ||
        !Number.isInteger(rec.flags) || rec.flags < 0 || rec.flags > 0xff ||
        !Number.isInteger(rec.len16) || rec.len16 < 0 || rec.len16 > 0xffff ||
        !Number.isInteger(rec.payload32) || rec.payload32 < 0 || rec.payload32 > 0xffff_ffff) {
      return { status: 3, written: 0 };
    }
  }
  const status = clampWireStatus(kernel.orb_wire_encode_slice_step(
    inPtr,
    outPtr,
    outCap,
    schemaId,
    recordsCount,
    arenaLen,
    maxBudget,
    1,
  ));
  if (status !== 0) {
    return { status, written: 0 };
  }
  const recordsBytes = recordsCount * 8;
  const payloadLen = recordsBytes + arenaBytes;
  const totalLen = ORB_WIRE_HEADER_BYTES + payloadLen;
  if (input.outBuf.byteLength < totalLen ||
      (arenaBytes > 0 && input.arena.byteLength < arenaBytes)) {
    return { status: 5, written: 0 };
  }
  const hdrView = new DataView(input.outBuf.buffer, input.outBuf.byteOffset, ORB_WIRE_HEADER_BYTES);
  hdrView.setUint32(0, ORB_WIRE_MAGIC, true);
  hdrView.setUint16(4, ORB_WIRE_ABI_VERSION, true);
  hdrView.setUint16(6, schemaId, true);
  hdrView.setUint32(8, flags, true);
  hdrView.setUint32(12, totalLen >>> 0, true);
  hdrView.setUint32(16, payloadLen >>> 0, true);
  hdrView.setUint16(20, recordsBytes, true);
  hdrView.setUint16(22, arenaLen, true);

  const recView = new DataView(
    input.outBuf.buffer,
    input.outBuf.byteOffset + ORB_WIRE_HEADER_BYTES,
    recordsBytes,
  );
  for (let i = 0; i < recordsCount; i++) {
    const rec = input.records[i];
    const packed = kernel.orb_wire_pack_record(
      rec.tag, rec.flags, rec.len16, rec.payload32,
    );
    recView.setBigUint64(i * 8, packed, true);
  }
  if (arenaBytes > 0) {
    input.outBuf.set(input.arena.subarray(0, arenaBytes), ORB_WIRE_HEADER_BYTES + recordsBytes);
  }
  return { status: 0, written: totalLen };
}

export function orbWireDecodeSlice(
  bytes: Uint8Array,
  expectedSchemaId: number,
  maxBudgetBytes = ORB_WIRE_DEFAULT_MAX_BUDGET,
  inPtr?: bigint | number,
): { status: OrbWireStatusCode; view: OrbWireSliceView | null } {
  const scratchBase = BigInt(kernelScratchBaseOffset());
  const effectiveInPtr = inPtr === undefined ? scratchBase : exactU64(inPtr);
  const inLen = exactU64(bytes.byteLength);
  if (effectiveInPtr === null || inLen === null) {
    return { status: 8, view: null };
  }
  if (bytes.byteLength > 0 && effectiveInPtr > 0n && effectiveInPtr < scratchBase) {
    return { status: 9, view: null };
  }
  const expectedSchema = exactSchemaId(expectedSchemaId);
  if (expectedSchema === null) {
    return { status: 2, view: null };
  }
  const maxBudget = exactU32(maxBudgetBytes);
  if (maxBudget === null) {
    return { status: 4, view: null };
  }
  if (bytes.byteLength < ORB_WIRE_HEADER_BYTES) {
    return { status: 3, view: null };
  }
  const hdr = new DataView(bytes.buffer, bytes.byteOffset, ORB_WIRE_HEADER_BYTES);
  const magic = hdr.getUint32(0, true);
  const abiVersion = hdr.getUint16(4, true);
  const schemaId = hdr.getUint16(6, true);
  const flags = hdr.getUint32(8, true);
  const totalLen = hdr.getUint32(12, true);
  const payloadLen = hdr.getUint32(16, true);
  const arenaOff = hdr.getUint16(20, true);
  const arenaLen = hdr.getUint16(22, true);

  const status = clampWireStatus(kernel.orb_wire_decode_slice_step(
    effectiveInPtr,
    inLen,
    1,
    magic,
    abiVersion,
    schemaId,
    expectedSchema,
    totalLen,
    payloadLen,
    arenaOff,
    arenaLen,
    maxBudget,
  ));
  if (status !== 0) {
    return { status, view: null };
  }
  if (arenaOff + arenaLen !== payloadLen) {
    return { status: 3, view: null };
  }
  // Zero-copy subarray views directly over caller's Uint8Array backing store.
  const payload = bytes.subarray(ORB_WIRE_HEADER_BYTES, ORB_WIRE_HEADER_BYTES + payloadLen);
  const recordsBytes = payload.subarray(0, arenaOff);
  const arenaBytes = payload.subarray(arenaOff, arenaOff + arenaLen);
  const recordCount = recordsBytes.byteLength >>> 3;

  return {
    status: 0,
    view: {
      schemaId,
      flags,
      totalLen,
      payloadLen,
      arenaOff,
      arenaLen,
      recordsBytes,
      arenaBytes,
      recordCount,
      recordAt(index: number): OrbWireRecord | null {
        if (!Number.isInteger(index) || index < 0 || index >= recordCount) return null;
        const byteOff = index * 8;
        if (recordsBytes.byteLength < byteOff + 8) return null;
        const recView = new DataView(recordsBytes.buffer, recordsBytes.byteOffset + byteOff, 8);
        const word = recView.getBigUint64(0, true);
        return {
          tag: Number(word & 0xffn),
          flags: Number((word >> 8n) & 0xffn),
          len16: Number((word >> 16n) & 0xffffn),
          payload32: Number((word >> 32n) & 0xffff_ffffn),
        };
      },
      arenaSlice(offset: number, len: number): Uint8Array | null {
        if (!coordinates(offset, len) || offset + len > arenaLen) return null;
        if (arenaBytes.byteLength < offset + len) return null;
        if (arenaBytes.buffer.byteLength === 0) return null;
        return arenaBytes.subarray(offset, offset + len);
      },
    },
  };
}

export const ORB_WIRE_SCHEMA_SCROLL_SLICE = 10;
export const ORB_WIRE_SCHEMA_STREAM_SLICE = 12;
export const ORB_WIRE_SCHEMA_TRANSCRIPT_SLICE = 13;
export const ORB_WIRE_FIXED_SLICE_FRAME_BYTES = 32;

const I64_MIN = -(1n << 63n);
const I64_MAX = (1n << 63n) - 1n;
export const SCROLL_DOMAIN_MIN = -0x4000_0000;
export const SCROLL_DOMAIN_MAX = 0x3fff_ffff;

export function inScrollDomain(value: number): boolean {
  return Number.isSafeInteger(value) && value >= SCROLL_DOMAIN_MIN && value <= SCROLL_DOMAIN_MAX;
}

function exactI64Bits(value: bigint | number): bigint | null {
  if (typeof value === "bigint") {
    return value >= I64_MIN && value <= I64_MAX ? BigInt.asUintN(64, value) : null;
  }
  if (!Number.isSafeInteger(value)) return null;
  return BigInt.asUintN(64, BigInt(value));
}

function writeFixedSliceVerdictFrame(outBuf: Uint8Array, schemaId: number, record: OrbWireRecord): number {
  const hdrView = new DataView(outBuf.buffer, outBuf.byteOffset, ORB_WIRE_HEADER_BYTES);
  hdrView.setUint32(0, ORB_WIRE_MAGIC, true);
  hdrView.setUint16(4, ORB_WIRE_ABI_VERSION, true);
  hdrView.setUint16(6, schemaId, true);
  hdrView.setUint32(8, 0, true);
  hdrView.setUint32(12, ORB_WIRE_FIXED_SLICE_FRAME_BYTES, true);
  hdrView.setUint32(16, 8, true);
  hdrView.setUint16(20, 8, true);
  hdrView.setUint16(22, 0, true);
  const recView = new DataView(outBuf.buffer, outBuf.byteOffset + ORB_WIRE_HEADER_BYTES, 8);
  const packed = kernel.orb_wire_pack_record(record.tag, record.flags, record.len16, record.payload32);
  recView.setBigUint64(0, packed, true);
  return ORB_WIRE_FIXED_SLICE_FRAME_BYTES;
}

function resolveSliceStepPointers(
  inSlice: Uint8Array,
  outBuf: Uint8Array,
  inPtrOverride?: bigint | number,
  outPtrOverride?: bigint | number,
  inLenOverride?: bigint | number,
): { status: OrbWireStatusCode; inPtr: bigint; inLen: bigint; outPtr: bigint; outCap: bigint } | null {
  const scratchBase = BigInt(kernelScratchBaseOffset());
  const inBytes = inSlice.byteLength;
  const outBytes = outBuf.byteLength;
  const inLen = inLenOverride === undefined ? exactU64(inBytes) : exactU64(inLenOverride);
  const outCap = exactU64(outBytes);
  if (inLen === null || outCap === null) {
    return { status: 8, inPtr: 0n, inLen: 0n, outPtr: 0n, outCap: 0n };
  }
  const sharesBackingBuffer = inBytes > 0 && outBytes > 0 && inSlice.buffer === outBuf.buffer;
  if (sharesBackingBuffer && spansOverlap(inSlice.byteOffset, inBytes, outBuf.byteOffset, outBytes)) {
    return { status: 9, inPtr: 0n, inLen, outPtr: 0n, outCap };
  }
  const defaultOutPtr = outBytes === 0 ? 0n : scratchBase;
  const defaultInPtr = inLen === 0n ? 0n : scratchBase + BigInt(Math.max(outBytes, ORB_WIRE_FIXED_SLICE_FRAME_BYTES));
  const inPtr = inPtrOverride === undefined ? defaultInPtr : exactU64(inPtrOverride);
  const outPtr = outPtrOverride === undefined ? defaultOutPtr : exactU64(outPtrOverride);
  if (inPtr === null || outPtr === null) {
    return { status: 8, inPtr: 0n, inLen, outPtr: 0n, outCap };
  }
  if ((inLen > 0n && inPtr > 0n && inPtr < scratchBase) ||
      (outBytes > 0 && outPtr > 0n && outPtr < scratchBase)) {
    return { status: 9, inPtr: 0n, inLen, outPtr: 0n, outCap };
  }
  return { status: 0, inPtr, inLen, outPtr, outCap };
}

export type ScrollPolicyVerdict = {
  status: number;
  admitted: boolean;
  pinned: boolean;
  top: number;
};

export function orbScrollPolicyGap(height: number, client: number, top: number): number | null {
  if (!inScrollDomain(height) || !inScrollDomain(client) || !inScrollDomain(top)) return null;
  const h = exactI64Bits(height), c = exactI64Bits(client), t = exactI64Bits(top);
  if (h === null || c === null || t === null) return null;
  const raw = kernel.orb_scroll_policy_gap(h, c, t);
  return Number(BigInt.asIntN(64, raw));
}

export function orbScrollPolicyCorrect(
  height: number, client: number, top: number, anchorDoc: number, y0: number,
): number | null {
  if (!inScrollDomain(height) || !inScrollDomain(client) || !inScrollDomain(top) ||
      !inScrollDomain(anchorDoc) || !inScrollDomain(y0)) {
    return null;
  }
  const h = exactI64Bits(height), c = exactI64Bits(client), t = exactI64Bits(top);
  const a = exactI64Bits(anchorDoc), y = exactI64Bits(y0);
  if (h === null || c === null || t === null || a === null || y === null) return null;
  const raw = kernel.orb_scroll_policy_correct(h, c, t, a, y);
  return Number(BigInt.asIntN(64, raw));
}

export function orbScrollPolicyStep(input: {
  opKind: number;
  pinned: boolean;
  intent: boolean;
  resized: boolean;
  curTop: number;
  height: number;
  client: number;
  arg: number;
}): ScrollPolicyVerdict | null {
  const curTop = exactI64Bits(input.curTop);
  const height = exactI64Bits(input.height);
  const client = exactI64Bits(input.client);
  const arg = exactI64Bits(input.arg);
  if (curTop === null || height === null || client === null || arg === null) return null;
  const raw = kernel.orb_scroll_policy_step(
    enum8(input.opKind), b8(input.pinned), b8(input.intent), b8(input.resized),
    curTop, height, client, arg,
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    status: lo32 & 0xff,
    admitted: ((lo32 >> 8) & 1) !== 0,
    pinned: ((lo32 >> 9) & 1) !== 0,
    top: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbScrollPolicyMaxTop(height: number, client: number): number | null {
  const v = orbScrollPolicyStep({
    opKind: 3, pinned: true, intent: false, resized: false, curTop: 0, height, client, arg: 0,
  });
  return v && v.admitted ? v.top : null;
}

export function orbScrollPolicyClampTop(height: number, client: number, target: number): number | null {
  const v = orbScrollPolicyStep({
    opKind: 1, pinned: false, intent: false, resized: false, curTop: 0, height, client, arg: target,
  });
  return v && v.admitted ? v.top : null;
}

export function orbWireScrollSliceStep(input: {
  inSlice: Uint8Array;
  outBuf: Uint8Array;
  opKind: number;
  pinned: boolean;
  intent: boolean;
  resized: boolean;
  curTop: bigint | number;
  height: bigint | number;
  client: bigint | number;
  arg: bigint | number;
  inPtr?: bigint | number;
  outPtr?: bigint | number;
}): { status: OrbWireStatusCode; written: number; verdict: ScrollPolicyVerdict | null } {
  const ptrs = resolveSliceStepPointers(input.inSlice, input.outBuf, input.inPtr, input.outPtr);
  if (!ptrs || ptrs.status !== 0) {
    return { status: ptrs ? ptrs.status : 8, written: 0, verdict: null };
  }
  const curTop = exactI64Bits(input.curTop);
  const height = exactI64Bits(input.height);
  const client = exactI64Bits(input.client);
  const arg = exactI64Bits(input.arg);
  if (curTop === null || height === null || client === null || arg === null) {
    return { status: 3, written: 0, verdict: null };
  }
  const raw = kernel.orb_wire_scroll_slice_step(
    ptrs.inPtr, ptrs.inLen, ptrs.outPtr, ptrs.outCap, 1,
    enum8(input.opKind), b8(input.pinned), b8(input.intent), b8(input.resized),
    curTop, height, client, arg,
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const admitted = ((lo32 >> 8) & 1) !== 0;
  const statusByte = lo32 & 0xff;
  if (!admitted) {
    return { status: clampWireStatus(statusByte), written: 0, verdict: null };
  }
  const verdict: ScrollPolicyVerdict = {
    status: statusByte,
    admitted: true,
    pinned: ((lo32 >> 9) & 1) !== 0,
    top: Number((raw >> 32n) & 0xffff_ffffn),
  };
  const written = writeFixedSliceVerdictFrame(input.outBuf, ORB_WIRE_SCHEMA_SCROLL_SLICE, {
    tag: enum8(input.opKind),
    flags: b8(verdict.pinned),
    len16: 0,
    payload32: verdict.top,
  });
  return { status: 0, written, verdict };
}

export function orbWireStreamSliceStep(input: {
  inTail: Uint8Array;
  outBuf: Uint8Array;
  prevLen: number;
  prevCommit: number;
  prevCheckpoint: number;
  newLen: number;
  rawCommit: number;
  maxOpenTailBytes: number;
  inPtr?: bigint | number;
  outPtr?: bigint | number;
  inTailBytesLen?: bigint | number;
}): {
  status: OrbWireStatusCode;
  written: number;
  verdict: { admitted: boolean; checkpointForced: boolean; nextCheckpoint: number } | null;
} {
  const ptrs = resolveSliceStepPointers(
    input.inTail,
    input.outBuf,
    input.inPtr,
    input.outPtr,
    input.inTailBytesLen,
  );
  if (!ptrs || ptrs.status !== 0) {
    return { status: ptrs ? ptrs.status : 8, written: 0, verdict: null };
  }
  const prevLen = exactU32(input.prevLen);
  const prevCommit = exactU32(input.prevCommit);
  const prevCheckpoint = exactU32(input.prevCheckpoint);
  const newLen = exactU32(input.newLen);
  const rawCommit = exactU32(input.rawCommit);
  const maxOpenTailBytes = exactU32(input.maxOpenTailBytes);
  if (prevLen === null || prevCommit === null || prevCheckpoint === null ||
      newLen === null || rawCommit === null || maxOpenTailBytes === null) {
    return { status: 3, written: 0, verdict: null };
  }
  const raw = kernel.orb_wire_stream_slice_step(
    ptrs.inPtr, ptrs.inLen, ptrs.outPtr, ptrs.outCap, 1,
    prevLen, prevCommit, prevCheckpoint, newLen, rawCommit, maxOpenTailBytes,
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const admitted = ((lo32 >> 8) & 1) !== 0;
  const statusByte = lo32 & 0xff;
  if (!admitted) {
    return { status: clampWireStatus(statusByte), written: 0, verdict: null };
  }
  const checkpointForced = ((lo32 >> 9) & 1) !== 0;
  const nextCheckpoint = Number((raw >> 32n) & 0xffff_ffffn);
  const written = writeFixedSliceVerdictFrame(input.outBuf, ORB_WIRE_SCHEMA_STREAM_SLICE, {
    tag: 1,
    flags: b8(checkpointForced),
    len16: ptrs.inLen > 0xffffn ? 0xffff : Number(ptrs.inLen),
    payload32: nextCheckpoint,
  });
  return {
    status: 0,
    written,
    verdict: { admitted: true, checkpointForced, nextCheckpoint },
  };
}

export function orbWireTranscriptSliceStep(input: {
  inEvent: Uint8Array;
  outBuf: Uint8Array;
  lastAppliedSeq: bigint | number;
  incomingSeq: bigint | number;
  entryCount: number;
  thinkingOpen: boolean;
  normalizedAction: number;
  isReplayFromLog: boolean;
  inPtr?: bigint | number;
  outPtr?: bigint | number;
}): {
  status: OrbWireStatusCode;
  written: number;
  verdict: {
    actionCode: number;
    admitted: boolean;
    thinkingOpenNext: boolean;
    closedPreviousThinking: boolean;
    gapBuffered: boolean;
    nextEntryCount: number;
  } | null;
} {
  const ptrs = resolveSliceStepPointers(input.inEvent, input.outBuf, input.inPtr, input.outPtr);
  if (!ptrs || ptrs.status !== 0) {
    return { status: ptrs ? ptrs.status : 8, written: 0, verdict: null };
  }
  const lastSeq = exactU64(input.lastAppliedSeq);
  const incSeq = exactU64(input.incomingSeq);
  const entryCount = exactU32(input.entryCount);
  if (lastSeq === null || incSeq === null || entryCount === null) {
    return { status: 3, written: 0, verdict: null };
  }
  const raw = kernel.orb_wire_transcript_slice_step(
    ptrs.inPtr, ptrs.inLen, ptrs.outPtr, ptrs.outCap, 1,
    lastSeq, incSeq, entryCount,
    b8(input.thinkingOpen), enum8(input.normalizedAction), b8(input.isReplayFromLog),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const admitted = ((lo32 >> 8) & 1) !== 0;
  const actionCode = lo32 & 0xff;
  const thinkingOpenNext = ((lo32 >> 9) & 1) !== 0;
  const closedPreviousThinking = ((lo32 >> 10) & 1) !== 0;
  const gapBuffered = ((lo32 >> 11) & 1) !== 0;
  const nextEntryCount = Number((raw >> 32n) & 0xffff_ffffn);
  if (!admitted) {
    return {
      status: actionCode >= 5 ? clampWireStatus(actionCode) : 3,
      written: 0,
      verdict: actionCode >= 5 ? null : {
        actionCode,
        admitted: false,
        thinkingOpenNext,
        closedPreviousThinking,
        gapBuffered,
        nextEntryCount,
      },
    };
  }
  const flags = b8(thinkingOpenNext) | (b8(closedPreviousThinking) << 1) | (b8(gapBuffered) << 2);
  const written = writeFixedSliceVerdictFrame(input.outBuf, ORB_WIRE_SCHEMA_TRANSCRIPT_SLICE, {
    tag: actionCode,
    flags,
    len16: Math.min(0xffff, input.inEvent.byteLength),
    payload32: nextEntryCount,
  });
  return {
    status: 0,
    written,
    verdict: {
      actionCode,
      admitted: true,
      thinkingOpenNext,
      closedPreviousThinking,
      gapBuffered,
      nextEntryCount,
    },
  };
}

export type PlacementSourceKind = 0 | 1 | 2 | 3;
export type PlacementStatusCode = 1 | 2 | 3 | 4 | 5 | 6;

export type PlacementMergeInput = {
  curRev: bigint | number;
  incRev: bigint | number;
  pendingOpId: number;
  ackOpId: number;
  sourceKind: PlacementSourceKind;
  hasPlacement: boolean;
};

export type PlacementMergeVerdict = {
  status: PlacementStatusCode;
  admitted: boolean;
  clearPending: boolean;
  evictOtherProjects: boolean;
  nextRev32: number;
};

export function orbPlacementMergeStep(input: PlacementMergeInput): PlacementMergeVerdict {
  const raw = kernel.orb_placement_merge_step(
    u64(input.curRev),
    u64(input.incRev),
    sat32(input.pendingOpId),
    sat32(input.ackOpId),
    enum8(input.sourceKind),
    b8(input.hasPlacement),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const status = (lo32 & 0xff) as PlacementStatusCode;
  return {
    status,
    admitted: ((lo32 >> 8) & 1) !== 0,
    clearPending: ((lo32 >> 9) & 1) !== 0,
    evictOtherProjects: ((lo32 >> 10) & 1) !== 0,
    nextRev32: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbKernelScratchSliceStep(inBytes = 0): {
  inView: Uint8Array;
  outView: Uint8Array;
  inOffset: number;
  outOffset: number;
} {
  const safeInBytes = Math.max(0, Math.floor(inBytes));
  const { memory, inOffset, outOffset } = ensureKernelLinearScratch(safeInBytes);
  const availInBytes = Math.max(0, Math.min(safeInBytes, memory.buffer.byteLength - inOffset));
  return {
    inView: new Uint8Array(memory.buffer, inOffset, availInBytes),
    outView: new Uint8Array(memory.buffer, outOffset, ORB_WIRE_FIXED_SLICE_FRAME_BYTES),
    inOffset,
    outOffset,
  };
}

// Cross-client projection & Wave 4 scanner steppers backed by orb_kernel.wasm.

export function orbMissionStateClassify(stateId: number): number {
  return kernel.orb_mission_state_classify(enum8(stateId));
}

export function orbMissionSortRank(stateId: number): number {
  return kernel.orb_mission_sort_rank(enum8(stateId));
}

export function orbMissionFlags(stateId: number): {
  isActive: boolean;
  needsAttention: boolean;
  isTerminal: boolean;
  raw: number;
} {
  const raw = kernel.orb_mission_flags(enum8(stateId));
  return {
    isActive: (raw & 1) !== 0,
    needsAttention: (raw & 2) !== 0,
    isTerminal: (raw & 4) !== 0,
    raw,
  };
}

export function orbMissionInboxSection(stateId: number): number {
  return kernel.orb_mission_inbox_section(enum8(stateId));
}

export function orbConnectionIssueClassify(input: {
  isUnreachable: boolean;
  isUsingDefault: boolean;
  isPrivateAddr: boolean;
  defaultReachable: boolean;
  hasExternalProxy: boolean;
}): number {
  return kernel.orb_connection_issue_classify(
    b8(input.isUnreachable),
    b8(input.isUsingDefault),
    b8(input.isPrivateAddr),
    b8(input.defaultReachable),
    b8(input.hasExternalProxy),
  );
}

export function orbWorkedDurationBucket(elapsedSecs: number): {
  unit: number;
  primary: number;
  secondary: number;
} {
  const raw = kernel.orb_worked_duration_bucket(seconds(elapsedSecs));
  return {
    unit: byte(raw, 0n),
    primary: Number((raw >> 8n) & 0xff_ffffn),
    secondary: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbTurnOutcomeStep(input: {
  prevOutcome: number;
  prevFailed: boolean;
  eventKind: number;
  isNarration: boolean;
  isSuccessFalse: boolean;
  isTextNonEmpty: boolean;
}): { outcome: number; failed: boolean } {
  const raw = kernel.orb_turn_outcome_step(
    enum8(input.prevOutcome),
    b8(input.prevFailed),
    enum8(input.eventKind),
    b8(input.isNarration),
    b8(input.isSuccessFalse),
    b8(input.isTextNonEmpty),
  );
  return {
    outcome: raw & 0x7f,
    failed: (raw & 0x80) !== 0,
  };
}

export function orbNumericCellScan(input: {
  nonEmpty: boolean;
  hasLeadingDigitOrSign: boolean;
  hasDigit: boolean;
  allAllowedChars: boolean;
}): boolean {
  return kernel.orb_numeric_cell_scan(
    b8(input.nonEmpty),
    b8(input.hasLeadingDigitOrSign),
    b8(input.hasDigit),
    b8(input.allAllowedChars),
  ) !== 0;
}

export function orbFileRefLineSpan(startLine: number, endLine: number, totalLines: number): {
  valid: boolean;
  count: number;
} {
  const raw = kernel.orb_file_ref_line_span(sat32(startLine), sat32(endLine), sat32(totalLines));
  return {
    valid: (raw & 1n) !== 0n,
    count: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbMachineActionAdmitted(stateKind: number, isBusy: boolean, isMuted: boolean): number {
  return kernel.orb_machine_action_admitted(enum8(stateKind), b8(isBusy), b8(isMuted));
}

export function orbSendFlowStep(input: {
  isBusy: boolean;
  hasNonEmptyText: boolean;
  canQueue: boolean;
  awaitingAck: boolean;
  isDraining: boolean;
  pendingCount: number;
  httpStatus: number;
}): { tapAction: number; canDrain: boolean; editOutcome: number } {
  const raw = kernel.orb_send_flow_step(
    b8(input.isBusy),
    b8(input.hasNonEmptyText),
    b8(input.canQueue),
    b8(input.awaitingAck),
    b8(input.isDraining),
    sat8(input.pendingCount),
    sat32(input.httpStatus),
  );
  return {
    tapAction: raw & 0xff,
    canDrain: (raw & 256) !== 0,
    editOutcome: (raw >>> 16) & 0xff,
  };
}

export function orbUtf8Utf16WindowStep(
  byteIdx: number,
  byteLen: number,
  leadByte: number,
  utf16Units: number,
  maxUtf16Units: number,
): { admitted: boolean; seqBytes: number; utf16Cost: number; nextUtf16Units: number } {
  const raw = kernel.orb_utf8_utf16_window_step(
    sat32(byteIdx),
    sat32(byteLen),
    sat8(leadByte),
    sat32(utf16Units),
    sat32(maxUtf16Units),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    admitted: (lo32 & 256) !== 0,
    seqBytes: lo32 & 0xff,
    utf16Cost: lo32 >>> 16,
    nextUtf16Units: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export type ComposerDefaultDecision =
  | "keep_explicit"
  | "default_paloma_hermes"
  | "default_workspace_harness"
  | "await_selection";

export function orbComposerDefaultStep(input: {
  hasExplicitChoice: boolean;
  hasPinnedContext: boolean;
  hermesAvailable: boolean;
  hasNativeHarness: boolean;
}): ComposerDefaultDecision {
  const code = kernel.orb_composer_default_step(
    b8(input.hasExplicitChoice),
    b8(input.hasPinnedContext),
    b8(input.hermesAvailable),
    b8(input.hasNativeHarness),
  );
  if (code === 0) return "keep_explicit";
  if (code === 1) return "default_paloma_hermes";
  if (code === 2) return "default_workspace_harness";
  return "await_selection";
}

export function orbCloudHandoffStep(input: {
  sourceIsCloud: boolean;
  isSideQuestion: boolean;
  targetIsNative: boolean;
  hasHistoryTurns: boolean;
  targetPlacementValid: boolean;
}): {
  admit: boolean;
  useCloudTurns: boolean;
  shareSourceWorkspace: boolean;
  freshWorkspace: boolean;
} {
  const raw = kernel.orb_cloud_handoff_step(
    b8(input.sourceIsCloud),
    b8(input.isSideQuestion),
    b8(input.targetIsNative),
    b8(input.hasHistoryTurns),
    b8(input.targetPlacementValid),
  );
  return {
    admit: (raw & 1) !== 0,
    useCloudTurns: ((raw >>> 8) & 1) !== 0,
    shareSourceWorkspace: ((raw >>> 16) & 1) !== 0,
    freshWorkspace: ((raw >>> 24) & 1) !== 0,
  };
}

export function orbCodexGoalLaunchStep(input: {
  isGoalRequest: boolean;
  hasNonEmptyObjective: boolean;
  hasImages: boolean;
  hasExplicitCyber: boolean;
  hasChatGptAuth: boolean;
  modelCompatible: boolean;
  accountSupportsProgram: boolean;
  resumedGoalActive: boolean;
  hasRetiredAlias: boolean;
}): { admitted: boolean; goalMode: boolean; rejectCode: number } {
  const raw = kernel.orb_codex_goal_launch_step(
    b8(input.isGoalRequest),
    b8(input.hasNonEmptyObjective),
    b8(input.hasImages),
    b8(input.hasExplicitCyber),
    b8(input.hasChatGptAuth),
    b8(input.modelCompatible),
    b8(input.accountSupportsProgram),
    b8(input.resumedGoalActive),
    b8(input.hasRetiredAlias),
  );
  const admitted = (raw & 256) !== 0;
  return {
    admitted,
    goalMode: (raw & 512) !== 0,
    rejectCode: admitted ? 0 : raw & 0xff,
  };
}

export function orbSkillSlashStep(input: {
  harnessKind: number;
  isDelivered: boolean;
  alreadySelected: boolean;
  nameCharsValid: boolean;
  nameLen: number;
  maxNameLen: number;
  selectedCount: number;
  maxSelected: number;
}): { admitted: boolean; strategy: number; rejectCode: number; nextSelectedCount: number } {
  const raw = kernel.orb_skill_slash_step(
    enum8(input.harnessKind),
    b8(input.isDelivered),
    b8(input.alreadySelected),
    b8(input.nameCharsValid),
    sat32(input.nameLen),
    sat32(input.maxNameLen),
    sat32(input.selectedCount),
    sat32(input.maxSelected),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const admitted = (lo32 & 256) !== 0;
  return {
    admitted,
    strategy: (lo32 >>> 16) & 0xff,
    rejectCode: admitted ? 0 : lo32 & 0xff,
    nextSelectedCount: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbWorktreeDecisionStep(input: {
  opKind: number;
  isOccupied: boolean;
  isGitRepo: boolean;
  branchCharsValid: boolean;
  targetPathExists: boolean;
  parentDirValid: boolean;
  slugLen: number;
  maxSlugLen: number;
  activeWorktrees: number;
  maxWorktrees: number;
}): { admitted: boolean; offerWorktree: boolean; actionOrRejectCode: number } {
  const raw = kernel.orb_worktree_decision_step(
    enum8(input.opKind),
    b8(input.isOccupied),
    b8(input.isGitRepo),
    b8(input.branchCharsValid),
    b8(input.targetPathExists),
    b8(input.parentDirValid),
    sat32(input.slugLen),
    sat32(input.maxSlugLen),
    sat32(input.activeWorktrees),
    sat32(input.maxWorktrees),
  );
  return {
    admitted: (raw & 256) !== 0,
    offerWorktree: (raw & 512) !== 0,
    actionOrRejectCode: raw & 0xff,
  };
}

export function orbRepoDiffBudgetStep(input: {
  isGitRepo: boolean;
  pathSafe: boolean;
  hasUntracked: boolean;
  modifiedCount: number;
  stagedCount: number;
  aheadCount: number;
  behindCount: number;
  diffBytes: number;
  maxFiles: number;
  maxBytes: number;
}): {
  admitted: boolean;
  dirty: boolean;
  truncatedFiles: boolean;
  truncatedBytes: boolean;
  syncState: number;
  rejectCode: number;
  clampedBytes: number;
} {
  const raw = kernel.orb_repo_diff_budget_step(
    b8(input.isGitRepo),
    b8(input.pathSafe),
    b8(input.hasUntracked),
    sat32(input.modifiedCount),
    sat32(input.stagedCount),
    sat32(input.aheadCount),
    sat32(input.behindCount),
    sat32(input.diffBytes),
    sat32(input.maxFiles),
    sat32(input.maxBytes),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const admitted = (lo32 & 256) !== 0;
  return {
    admitted,
    dirty: (lo32 & 512) !== 0,
    truncatedFiles: (lo32 & 1024) !== 0,
    truncatedBytes: (lo32 & 2048) !== 0,
    syncState: (lo32 >>> 16) & 0xff,
    rejectCode: admitted ? 0 : lo32 & 0xff,
    clampedBytes: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export type SidebarMoveItemKind = 0 | 1 | 2 | 3; // 0=mission, 1=folder, 2=file, 3=cron
export type SidebarDragPhase = 0 | 1 | 2 | 3;    // 0=idle, 1=pressing, 2=armed, 3=dragging
export type SidebarDragEffect = 0 | 1 | 2 | 3 | 4 | 5 | 6;

export function orbSidebarMoveTargetAdmit(input: {
  itemKind: SidebarMoveItemKind;
  dstIsSelfOrSubtree: boolean;
  srcProjectOrd: number;
  srcPathOrd: number;
  srcParentOrd: number;
  dstProjectOrd: number;
  dstPathOrd: number;
}): boolean {
  return kernel.orb_sidebar_move_target_admit(
    enum8(input.itemKind),
    b8(input.dstIsSelfOrSubtree),
    sat32(input.srcProjectOrd),
    sat32(input.srcPathOrd),
    sat32(input.srcParentOrd),
    sat32(input.dstProjectOrd),
    sat32(input.dstPathOrd),
  ) === 1;
}

export function orbSidebarDragStep(input: {
  phase: SidebarDragPhase;
  eventKind: 0 | 1 | 2 | 3 | 4 | 5;
  rowMovable: boolean;
  targetCollapsed: boolean;
  targetAdmitted: boolean;
  distSq: number;
  elapsedMs: number;
  springElapsedMs: number;
  hoverTargetOrd: number;
  springTargetOrd: number;
  edgeTopDistPx: number;
  edgeBottomDistPx: number;
}): {
  nextPhase: SidebarDragPhase;
  effectCode: SidebarDragEffect;
  eatClick: boolean;
  scrollDir: -1 | 0 | 1;
  scrollStepPx: number;
  nextSpringTargetOrd: number;
} {
  const raw = kernel.orb_sidebar_drag_step(
    enum8(input.phase),
    enum8(input.eventKind),
    b8(input.rowMovable),
    b8(input.targetCollapsed),
    b8(input.targetAdmitted),
    sat32(input.distSq),
    sat32(input.elapsedMs),
    sat32(input.springElapsedMs),
    sat32(input.hoverTargetOrd),
    sat32(input.springTargetOrd),
    sat32(input.edgeTopDistPx),
    sat32(input.edgeBottomDistPx),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  const up = ((lo32 >>> 17) & 1) !== 0;
  const down = ((lo32 >>> 18) & 1) !== 0;
  return {
    nextPhase: (lo32 & 0xff) as SidebarDragPhase,
    effectCode: ((lo32 >>> 8) & 0xff) as SidebarDragEffect,
    eatClick: ((lo32 >>> 16) & 1) !== 0,
    scrollDir: up ? -1 : down ? 1 : 0,
    scrollStepPx: (lo32 >>> 24) & 0xff,
    nextSpringTargetOrd: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

const rawU32 = (value: bigint | number): number => {
  if (typeof value === "bigint") return Number(BigInt.asUintN(32, value));
  if (!Number.isFinite(value)) throw new RangeError("Expected finite UInt32 number");
  return Math.trunc(value) >>> 0;
};

const rawU64 = (value: bigint | number): bigint => {
  if (typeof value === "bigint") return BigInt.asUintN(64, value);
  if (!Number.isFinite(value)) throw new RangeError("Expected finite UInt64 number");
  const whole = Math.trunc(value);
  if (!Number.isSafeInteger(whole)) throw new RangeError("UInt64 number is outside the exact safe integer range");
  return BigInt.asUintN(64, BigInt(whole));
};

export function orbFollowupQueueStep(input: {
  op: number;
  serverRev: bigint | number;
  incomingServerRev: bigint | number;
  expectedServerRev: bigint | number;
  clientMsgId: bigint | number;
  trackedMsgId: bigint | number;
  deliveredMsgId: bigint | number;
  postedAfterSeq: bigint | number;
  turnSeq: bigint | number;
  optimisticSending: boolean;
  serverListed: boolean;
  contentMatched: boolean;
  alreadyDelivered: boolean;
}): {
  reasonCode: number;
  admitted: boolean;
  optimisticLiveNext: boolean;
  retiredNow: boolean;
  nextServerRev: number;
} {
  const raw = kernel.orb_followup_queue_step(
    enum8(input.op),
    rawU32(input.serverRev),
    rawU32(input.incomingServerRev),
    rawU32(input.expectedServerRev),
    rawU64(input.clientMsgId),
    rawU64(input.trackedMsgId),
    rawU64(input.deliveredMsgId),
    rawU64(input.postedAfterSeq),
    rawU64(input.turnSeq),
    b8(input.optimisticSending),
    b8(input.serverListed),
    b8(input.contentMatched),
    b8(input.alreadyDelivered),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    reasonCode: lo32 & 0xff,
    admitted: ((lo32 >>> 8) & 1) !== 0,
    optimisticLiveNext: ((lo32 >>> 9) & 1) !== 0,
    retiredNow: ((lo32 >>> 10) & 1) !== 0,
    nextServerRev: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbTransportEpochStep(input: {
  mode: number;
  eventKind: number;
  everReady: boolean;
  stickyUnsupported: boolean;
  endpointClass: number;
  prevEndpointClass: number;
  hasSinceSeq: boolean;
  failureStreak: bigint | number;
  failThreshold: bigint | number;
  httpStatus: bigint | number;
  sinceSeq32: bigint | number;
  nowMs: bigint | number;
  cooldownUntilMs: bigint | number;
}): {
  nextMode: number;
  admitted: boolean;
  stickyUnsupportedNext: boolean;
  fallbackActiveNext: boolean;
  reprobeTriggered: boolean;
  hasPreservedSinceSeq: boolean;
  nextFailureStreak: number;
  preservedSinceSeq32: number;
} {
  const raw = kernel.orb_transport_epoch_step(
    enum8(input.mode),
    enum8(input.eventKind),
    b8(input.everReady),
    b8(input.stickyUnsupported),
    enum8(input.endpointClass),
    enum8(input.prevEndpointClass),
    b8(input.hasSinceSeq),
    rawU32(input.failureStreak),
    rawU32(input.failThreshold),
    rawU32(input.httpStatus),
    rawU32(input.sinceSeq32),
    rawU64(input.nowMs),
    rawU64(input.cooldownUntilMs),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    nextMode: lo32 & 0xff,
    admitted: ((lo32 >>> 8) & 1) !== 0,
    stickyUnsupportedNext: ((lo32 >>> 9) & 1) !== 0,
    fallbackActiveNext: ((lo32 >>> 10) & 1) !== 0,
    reprobeTriggered: ((lo32 >>> 11) & 1) !== 0,
    hasPreservedSinceSeq: ((lo32 >>> 12) & 1) !== 0,
    nextFailureStreak: (lo32 >>> 16) & 0xff,
    preservedSinceSeq32: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

export function orbStreamOpenTailCapStep(
  prevLen: bigint | number,
  prevCommit: bigint | number,
  prevCheckpoint: bigint | number,
  newLen: bigint | number,
  rawCommit: bigint | number,
  maxOpenTailBytes: bigint | number,
  openFenceActive: boolean,
): {
  admitted: boolean;
  checkpointForced: boolean;
  openFenceCapped: boolean;
  nextCheckpoint: number;
} {
  const raw = kernel.orb_stream_open_tail_cap_step(
    rawU32(prevLen),
    rawU32(prevCommit),
    rawU32(prevCheckpoint),
    rawU32(newLen),
    rawU32(rawCommit),
    rawU32(maxOpenTailBytes),
    b8(openFenceActive),
  );
  const lo32 = Number(raw & 0xffff_ffffn);
  return {
    admitted: ((lo32 >>> 8) & 1) !== 0,
    checkpointForced: ((lo32 >>> 9) & 1) !== 0,
    openFenceCapped: ((lo32 >>> 10) & 1) !== 0,
    nextCheckpoint: Number((raw >> 32n) & 0xffff_ffffn),
  };
}

