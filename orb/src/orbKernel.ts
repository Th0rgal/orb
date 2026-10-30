// Host input encoding and presentation over generated scalar ABI adapters.
import { kernelAbi as kernel } from "./orbKernelAbi";

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
