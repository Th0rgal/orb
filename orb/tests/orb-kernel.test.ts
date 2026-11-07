import { describe, expect, it } from "vitest";
import { kernelAbi } from "../src/orbKernelAbi";
import { ensureKernelLinearScratch, kernelScratchBaseOffset } from "../src/orbKernelRuntime";
import {
  ORB_WIRE_SCHEMA_SCROLL_SLICE, ORB_WIRE_SCHEMA_STREAM_SLICE, ORB_WIRE_SCHEMA_TRANSCRIPT_SLICE,
  leansysGfmPipeRowAdmitted, leansysRichTagAdmitted, leansysVerifyFdBounds,
  orbAuthToctouExecuteStep, orbHierarchyMergeStep, orbOutboxCrashReconcileStep,
  orbProviderAttemptStep, orbRelativeTimeString, orbResourceLedgerStep,
  orbScrollPolicyClampTop, orbScrollPolicyCorrect, orbScrollPolicyGap,
  orbScrollPolicyMaxTop, orbScrollPolicyStep,
  orbSidebarDragStep, orbSidebarMoveTargetAdmit,
  orbStreamBoundedCommitStep, orbTranscriptFoldStep, orbTranscriptPatchStep,
  orbUsageLimitBadge, orbWireApplyPatchStep, orbWireDecodeSlice,
  orbWireEncodeSliceInto, orbWireMachineStep, orbWireScrollSliceStep,
  orbWireStreamSliceStep, orbWireTranscriptSliceStep, orbWireVerifySliceIo,
  orbConnectionIssueClassify, orbFileRefLineSpan, orbMachineActionAdmitted,
  orbMissionFlags, orbMissionInboxSection, orbMissionSortRank, orbMissionStateClassify,
  orbNumericCellScan, orbSendFlowStep, orbTurnOutcomeStep, orbUtf8Utf16WindowStep,
  orbWorkedDurationBucket,
} from "../src/orbKernel";
import { mergeMission, reparentMission, resetMissionHierarchy } from "../src/missionHierarchy";
import { normalizeLoosePipeTables } from "../src/pipeTables";
import { RICH_TAG, parseRichTag, richTagSpan } from "../src/richTags";
import { advanceStreamBoundedCommit } from "../src/stream";
import { buildTranscript } from "../src/transcriptModel";

describe("orb kernel gates mirror lean-sys", () => {
  it("rejects a negative row offset", () => {
    expect(leansysGfmPipeRowAdmitted(0, 12, 12, 3, 3, false)).toBe(true);
    expect(leansysGfmPipeRowAdmitted(-1, 12, 12, 3, 3, false)).toBe(false);
    expect(leansysGfmPipeRowAdmitted(4, 12, 12, 3, 3, false)).toBe(false);
  });

  it("caps tables at 64 columns", () => {
    expect(leansysGfmPipeRowAdmitted(0, 200, 200, 64, 64, false)).toBe(true);
    expect(leansysGfmPipeRowAdmitted(0, 200, 200, 65, 65, false)).toBe(false);
    const wide = (n: number) => Array.from({ length: n }, (_, i) => `c${i}`).join(" | ");
    expect(normalizeLoosePipeTables(`${wide(65)}\n${wide(65)}`)).toBe(`${wide(65)}\n${wide(65)}`);
    expect(normalizeLoosePipeTables(`${wide(64)}\n${wide(64)}`)).toContain("| --- |");
  });

  it("only admits tag kinds 1..3", () => {
    expect(leansysRichTagAdmitted(0, 24, 5, 14, 24, 3)).toBe(true);
    expect(leansysRichTagAdmitted(0, 24, 5, 14, 24, 4)).toBe(false);
    expect(leansysRichTagAdmitted(0, 24, 5, 14, 24, 0)).toBe(false);
  });

  it("checks rich tags at their real offsets", () => {
    const text = 'see <image path="./a.png" alt="A" /> ok';
    const m = [...text.matchAll(RICH_TAG)][0];
    const span = richTagSpan(m[0], m[1], m[2], m.index!, text.length);
    expect(span.tagOff).toBe(4);
    expect(text.slice(span.attrOff, span.attrOff + m[2].length)).toBe(m[2]);
    expect(parseRichTag(m[1], m[2], m[3], span)).toMatchObject({ path: "./a.png" });
    expect(parseRichTag(m[1], m[2], m[3], { ...span, bufLen: span.tagOff + span.tagLen - 1 })).toBeNull();
  });

  it("hides the percentage when utilization exceeds 100", () => {
    expect(orbUsageLimitBadge("allowed_warning", "five_hour", true, 100.1, false, NaN)).toEqual({ tone: "warning", label: "Approaching limit · 5h" });
    expect(orbUsageLimitBadge("allowed_warning", "five_hour", true, 150, false, 0)).toEqual({ tone: "warning", label: "Approaching limit · 5h" });
    expect(orbUsageLimitBadge("allowed_warning", "five_hour", true, 100, false, 0)).toEqual({ tone: "warning", label: "Approaching limit · 5h 100%" });
  });

  it("encodes absent or unrepresentable optional reset values without throwing", () => {
    for (const reset of [NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1]) {
      expect(orbUsageLimitBadge("rejected", "five_hour", false, 0, false, reset)).toEqual({ tone: "error", label: "Limit reached" });
      expect(orbUsageLimitBadge("allowed", "five_hour", false, 0, false, reset)).toBeNull();
    }
    expect(() => orbRelativeTimeString(-Infinity)).toThrow("finite");
    expect(orbRelativeTimeString(-1)).toBe("now");
  });

  it("saturates a wrapping delta instead of wrapping", () => {
    expect(orbTranscriptPatchStep({ len: 0xffff_fff0, seq: 7 }, 0, 0x20)).toEqual({ len: 0xffff_ffff, seq: 8 });
    expect(orbTranscriptPatchStep({ len: 5, seq: 0xffff_ffff }, 0, 1)).toEqual({ len: 6, seq: 0xffff_ffff });
  });

  it("leaves the state unchanged on an unknown event kind", () => {
    const state = { len: 42, seq: 9 };
    expect(orbTranscriptPatchStep(state, 3, 100)).toEqual(state);
    expect(orbTranscriptPatchStep(state, -1, 100)).toEqual(state);
    expect(orbTranscriptPatchStep(state, 0.5, 100)).toEqual(state);
    expect(orbTranscriptPatchStep(state, 2, 100)).toEqual({ len: 0, seq: 10 });
    expect(orbTranscriptPatchStep(state, -1, NaN)).toEqual(state);
    expect(orbTranscriptPatchStep(state, 1, -1)).toEqual({ len: 42, seq: 10 });
    expect(orbTranscriptPatchStep(state, 0, 2 ** 32)).toEqual({ len: 0xffff_ffff, seq: 10 });
    expect(orbTranscriptPatchStep(state, 1, 0)).toEqual({ len: 42, seq: 10 });
  });

  it("enforces OrbWire patch presence and machine capacity/replay fences", () => {
    expect(orbWireApplyPatchStep(5n, 6n, 42, 0, 0)).toEqual({ actionCode: 3, admitted: true, nextVal: 42 });
    expect(orbWireApplyPatchStep(5n, 6n, 42, 1, 99)).toEqual({ actionCode: 1, admitted: true, nextVal: 99 });
    expect(orbWireApplyPatchStep(5n, 6n, 42, 2, 0)).toEqual({ actionCode: 4, admitted: true, nextVal: null });
    expect(orbWireApplyPatchStep(6n, 6n, 42, 1, 99)).toEqual({ actionCode: 2, admitted: false, nextVal: 42 });

    expect(orbWireMachineStep(2, 10n, 11n, 1, true, 16, 32)).toEqual({
      actionCode: 5, admitted: false, emitEffect: false, nextRev32: 10,
    });
    expect(orbWireMachineStep(2, 10n, 11n, 1, true, 64, 32)).toEqual({
      actionCode: 1, admitted: true, emitEffect: true, nextRev32: 11,
    });
  });

  it("enforces Wave 12 stateful families 1..7 across WASM", () => {
    // Family 1: Partial patch preserves omitted parent; sticky supersede blocks unarchive
    expect(orbHierarchyMergeStep({
      currentEpoch: 10n, incomingEpoch: 11n, archiveEpoch: 0n,
      curArchived: false, curSuperseded: false, isPartialPatch: true,
      parentPresence: 0, curParentOrd: 42, incParentOrd: 0,
      incArchive: false, incUnarchive: false, incSupersede: false,
    })).toMatchObject({ admitted: true, nextParentOrd: 42 });
    expect(orbHierarchyMergeStep({
      currentEpoch: 11n, incomingEpoch: 12n, archiveEpoch: 5n,
      curArchived: true, curSuperseded: true, isPartialPatch: true,
      parentPresence: 0, curParentOrd: 42, incParentOrd: 0,
      incArchive: false, incUnarchive: true, incSupersede: false,
    })).toMatchObject({ admitted: false, nextSuperseded: true, nextArchived: true });

    // Family 2: Contiguous seq progression & live/replay equivalence
    const live = orbTranscriptFoldStep(10n, 11n, 3, true, 5, false);
    const replay = orbTranscriptFoldStep(10n, 11n, 3, true, 5, true);
    expect(live).toEqual(replay);
    expect(live).toMatchObject({ admitted: true, closedPreviousThinking: true, nextEntryCount: 4 });
    expect(orbTranscriptFoldStep(10n, 13n, 3, false, 5, false)).toMatchObject({
      admitted: false, gapBuffered: true, nextEntryCount: 3,
    });

    // Family 3: Outbox crash reconciles volatile lease and preserves unacked WAL items
    expect(orbOutboxCrashReconcileStep(9, 4, 5, 100n, 101n, 77, 88)).toEqual({
      actionCode: 1, admitted: true, crashReconciled: true, hasSingleWriter: true, unackedDepth: 5,
    });

    // Family 4: Provider attempt locks after first byte
    expect(orbProviderAttemptStep({
      pinnedAccountId: 7, candidateAccountId: 7, attemptsUsed: 1, retryBudget: 3,
      firstByteCommitted: true, failureKind: 1, upstreamNowEpoch: 50n,
      cooldownUntilEpoch: 0n, upstreamDeadline: 100n, authValid: true,
    })).toEqual({
      actionCode: 3, admitted: false, firstByteLockedNext: true, nextAttemptsUsed: 1,
    });

    // Family 5: TOCTOU authorization fails closed on digest drift
    const authBase = {
      principalKind: 2, bunkerState: 0, observedTargetId: 9, execTargetId: 9,
      observedLeaseEpoch: 44n, liveLeaseEpoch: 44n, nowTick: 100n, expiryTick: 200n,
      observedDigest: 0xdead_beefn, execDigest: 0xdead_beefn,
    };
    expect(orbAuthToctouExecuteStep(authBase)).toEqual({ admitted: true, failClosed: false, reasonCode: 1 });
    expect(orbAuthToctouExecuteStep({ ...authBase, execDigest: 0xdead_bee0n })).toEqual({
      admitted: false, failClosed: true, reasonCode: 6,
    });

    // Family 6: Resource ledger blocks overspend/wrap without overflowing
    expect(orbResourceLedgerStep({
      opKind: 0, reservedSlots: 1, activeSlots: 2, maxSlots: 4,
      spentCents: 600n, costDeltaCents: 400n, budgetCents: 1000n,
      nowTick: 10n, ttlExpiryTick: 50n,
    })).toEqual({ stateValid: true, admitted: true, nextReservedSlots: 2, nextActiveSlots: 2 });
    expect(orbResourceLedgerStep({
      opKind: 0, reservedSlots: 1, activeSlots: 2, maxSlots: 4,
      spentCents: 600n, costDeltaCents: 0xffff_ffff_ffff_ffffn, budgetCents: 1000n,
      nowTick: 10n, ttlExpiryTick: 50n,
    })).toEqual({ stateValid: true, admitted: false, nextReservedSlots: 1, nextActiveSlots: 2 });

    // Family 7: Bounded-tail stream commit forces checkpoint within maxOpenTailBytes
    const sb = orbStreamBoundedCommitStep(1000, 200, 200, 20_000, 200, 4096);
    expect(sb).toEqual({ admitted: true, checkpointForced: true, nextCheckpoint: 20_000 - 4096 });
  });

  it("verifies leansysVerifyFdBounds and wired host helpers (hierarchy, transcript, stream)", () => {
    expect(leansysVerifyFdBounds(70_000n, 70_000)).toBe(true);
    expect(leansysVerifyFdBounds(70_000n, 4464)).toBe(false);
    expect(leansysVerifyFdBounds(0x8000_0000n, 0x8000_0000)).toBe(false);
    expect(leansysVerifyFdBounds(7n, -1)).toBe(false);

    resetMissionHierarchy();
    const m0 = mergeMission(undefined, { id: "m1", parent_mission_id: "p1", status: "active", tags: [] });
    const m1 = mergeMission(m0, { id: "m1", status: "running" }, "partial");
    expect(m1.parent_mission_id).toBe("p1");
    reparentMission("m1", { parent_mission_id: null });
    expect(mergeMission(undefined, { id: "m1", status: "running" }).parent_mission_id).toBeUndefined();

    const liveItems = buildTranscript([
      { type: "thinking", sequence: 1, data: { content: "plan", done: false } },
      { type: "text_delta", sequence: 2, data: { content: "answer", mode: "delta" } },
    ]);
    const replayItems = buildTranscript([
      { type: "thinking", sequence: 1, storedId: 1, data: { content: "plan", done: false } },
      { type: "text_delta", sequence: 2, storedId: 2, data: { content: "answer", mode: "delta" } },
    ]);
    expect(liveItems.map(i => i.kind)).toEqual(replayItems.map(i => i.kind));

    const tail0 = { totalBytes: 0, committedBytes: 0, checkpointBytes: 0 };
    const tail1 = advanceStreamBoundedCommit(tail0, 20_000, 200, 4096);
    expect(tail1).toEqual({
      totalBytes: 20_000,
      committedBytes: 200,
      checkpointBytes: 20_000 - 4096,
      admitted: true,
      checkpointForced: true,
    });
  });

  it("encodes and decodes OrbWire slices zero-copy without touching WASM static data and enforces no-partial-mutation", () => {
    // Regression test (B1): leansys_select_isa / leansys_verify_isa_selection read WASM static rodata at 65536.
    // Encoding arbitrary caller arenas must never overwrite WASM linear-memory static data.
    expect(kernelAbi.leansys_select_isa(0xffff_ffffn, 895n, 3, 4)).toBe(3);
    expect(kernelAbi.leansys_verify_isa_selection(0xffff_ffffn, 895n, 3, 4)).toBe(1);
    expect(kernelAbi.leansys_select_isa(1n, 1n, 3, 4)).toBe(0);
    expect(kernelAbi.leansys_verify_isa_selection(1n, 1n, 3, 4)).toBe(0);

    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    const arena = encoder.encode("wasm_slice");
    const records = [
      { tag: 2, flags: 1, len16: 4, payload32: 0 },
      { tag: 9, flags: 0, len16: 6, payload32: 4 },
    ];
    const outBuf = new Uint8Array(64).fill(0xee);
    const enc = orbWireEncodeSliceInto({ schemaId: 12, flags: 0x77, records, arena, outBuf });
    expect(enc).toEqual({ status: 0, written: 24 + 16 + 10 });
    expect(Array.from(outBuf.subarray(enc.written))).toEqual(new Array(64 - enc.written).fill(0xee));

    // Adversarial 18-byte arena attempt that previously forged ISA rodata at 65536
    const adversarialArena = new Uint8Array(18).fill(0x01);
    const advOut = new Uint8Array(64).fill(0xcc);
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records: [{ tag: 1, flags: 0, len16: 18, payload32: 0 }],
      arena: adversarialArena,
      outBuf: advOut,
    })).toEqual({ status: 0, written: 24 + 8 + 18 });
    expect(kernelAbi.leansys_select_isa(0xffff_ffffn, 895n, 3, 4)).toBe(3);
    expect(kernelAbi.leansys_verify_isa_selection(0xffff_ffffn, 895n, 3, 4)).toBe(1);
    expect(kernelAbi.leansys_select_isa(1n, 1n, 3, 4)).toBe(0);
    expect(kernelAbi.leansys_verify_isa_selection(1n, 1n, 3, 4)).toBe(0);

    // Reserved static-data pointer overrides (< scratchBase 131072) are rejected fail-closed (9)
    const reservedOut = new Uint8Array(64).fill(0xbb);
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records,
      arena,
      outBuf: reservedOut,
      inArenaPtr: 65_536,
    })).toEqual({ status: 9, written: 0 });
    expect(Array.from(reservedOut)).toEqual(new Array(64).fill(0xbb));

    // Shared ArrayBuffer aliasing between arena and outBuf is automatically detected and rejected (9)
    const sharedBacking = new ArrayBuffer(96);
    const sharedArena = new Uint8Array(sharedBacking, 16, 10);
    sharedArena.set(arena);
    const overlappingOut = new Uint8Array(sharedBacking, 8, 64);
    overlappingOut.fill(0xdd);
    sharedArena.set(arena);
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records,
      arena: sharedArena,
      outBuf: overlappingOut,
    })).toEqual({ status: 9, written: 0 });

    // Record field overflow (len16 > 0xFFFF) rejected fail-closed (3), sentinel untouched
    const badRecOut = new Uint8Array(64).fill(0x99);
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records: [{ tag: 1, flags: 0, len16: 70_000, payload32: 0 }],
      arena,
      outBuf: badRecOut,
    })).toEqual({ status: 3, written: 0 });
    expect(Array.from(badRecOut)).toEqual(new Array(64).fill(0x99));

    const framed = outBuf.subarray(0, enc.written);
    const dec = orbWireDecodeSlice(framed, 12);
    expect(dec.status).toBe(0);
    expect(dec.view).not.toBeNull();
    const view = dec.view!;
    expect(view.schemaId).toBe(12);
    expect(view.flags).toBe(0x77);
    expect(view.recordCount).toBe(2);
    expect(view.recordAt(0)).toEqual(records[0]);
    expect(view.recordAt(1)).toEqual(records[1]);
    expect(view.recordAt(2)).toBeNull();
    // Zero-copy subarray shares caller buffer
    expect(view.arenaBytes.buffer).toBe(outBuf.buffer);
    expect(decoder.decode(view.arenaSlice(0, 4)!)).toBe("wasm");
    expect(decoder.decode(view.arenaSlice(4, 6)!)).toBe("_slice");

    // Output too small -> OutputTooSmall (5), sentinel untouched
    const smallOut = new Uint8Array(16).fill(0xaa);
    expect(orbWireEncodeSliceInto({ schemaId: 12, records, arena, outBuf: smallOut })).toEqual({
      status: 5,
      written: 0,
    });
    expect(Array.from(smallOut)).toEqual(new Array(16).fill(0xaa));

    // Overlapping linear-memory spans -> SliceAliasOverlap (9), sentinel untouched
    const aliasOut = new Uint8Array(64).fill(0x55);
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records,
      arena,
      outBuf: aliasOut,
      inArenaPtr: 131_072,
      outPtr: 131_064,
    })).toEqual({ status: 9, written: 0 });
    expect(Array.from(aliasOut)).toEqual(new Array(64).fill(0x55));

    // Null pointer with non-zero span -> NullSlicePtr (7)
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records,
      arena,
      outBuf: aliasOut,
      inArenaPtr: 0,
      outPtr: 262_144,
    })).toEqual({ status: 7, written: 0 });
    expect(Array.from(aliasOut)).toEqual(new Array(64).fill(0x55));

    // 32-bit wasm32 span overflow vs 64-bit LP64 admission
    expect(orbWireVerifySliceIo({
      inPtr: 0xffff_fff0n, inLen: 32n, outPtr: 0x20000n, outCap: 64n, writtenLen: 32n, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: 0xffff_fff0n, inLen: 32n, outPtr: 0x20000n, outCap: 64n, writtenLen: 32n, is32Bit: false,
    })).toBe(0);
    expect(orbWireVerifySliceIo({
      inPtr: 0x20000n, inLen: 16n, outPtr: 0x30000n, outCap: 64n, writtenLen: 16n, is32Bit: 2,
    })).toBe(6);

    // Round 2 strict integer & non-throwing bounds regression checks:
    // 1. Negative / fractional / NaN / Infinity / >=2^64 pointers never clamp, wrap modulo 2^64, or throw
    expect(orbWireVerifySliceIo({
      inPtr: -16, inLen: 0, outPtr: 0x20000, outCap: 64, writtenLen: 16, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: 131_072.7, inLen: 8, outPtr: 0x30000, outCap: 64, writtenLen: 16, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: Number.NaN, inLen: 0, outPtr: 0x20000, outCap: 64, writtenLen: 0, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: 2 ** 53, inLen: 0, outPtr: 0x20000, outCap: 64, writtenLen: 0, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: 0x1_0000_0000_0002_0000n, inLen: 16n, outPtr: 0x30000n, outCap: 64n, writtenLen: 16n, is32Bit: true,
    })).toBe(8);
    expect(orbWireVerifySliceIo({
      inPtr: -0xffff_ffff_fffd_0000n, inLen: 16n, outPtr: 0x30000n, outCap: 64n, writtenLen: 16n, is32Bit: true,
    })).toBe(8);

    // 2. Fractional/out-of-range schemaId, expectedSchemaId, flags, and maxBudgetBytes fail closed with 0 written
    const guardOut = new Uint8Array(64).fill(0x7a);
    expect(orbWireEncodeSliceInto({ schemaId: 12.9, records, arena, outBuf: guardOut })).toEqual({
      status: 2, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 0x1_0001, records, arena, outBuf: guardOut })).toEqual({
      status: 2, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 12, flags: -1, records, arena, outBuf: guardOut })).toEqual({
      status: 3, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 12, flags: 2 ** 40, records, arena, outBuf: guardOut })).toEqual({
      status: 3, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 12, maxBudgetBytes: -5, records, arena, outBuf: guardOut })).toEqual({
      status: 4, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 12, inArenaPtr: -4096, records: [], arena: new Uint8Array(0), outBuf: guardOut })).toEqual({
      status: 8, written: 0,
    });
    expect(orbWireEncodeSliceInto({ schemaId: 12, outPtr: Number.POSITIVE_INFINITY, records, arena, outBuf: guardOut })).toEqual({
      status: 8, written: 0,
    });
    expect(Array.from(guardOut)).toEqual(new Array(64).fill(0x7a));

    // 3. Explicit non-overlapping pointer overrides cannot bypass actual shared-ArrayBuffer overlap
    expect(orbWireEncodeSliceInto({
      schemaId: 12,
      records,
      arena: sharedArena,
      outBuf: overlappingOut,
      inArenaPtr: 131_072,
      outPtr: 262_144,
    })).toEqual({ status: 9, written: 0 });

    // 4. Decode rejects fractional/invalid expectedSchemaId, maxBudgetBytes, and pointer overrides
    expect(orbWireDecodeSlice(framed, 12.9)).toEqual({ status: 2, view: null });
    expect(orbWireDecodeSlice(framed, 0x1_0001)).toEqual({ status: 2, view: null });
    expect(orbWireDecodeSlice(framed, 12, -1)).toEqual({ status: 4, view: null });
    expect(orbWireDecodeSlice(framed, 12, 65_536, -1)).toEqual({ status: 8, view: null });
    expect(orbWireDecodeSlice(framed, 12, 65_536, 0x1_0000_0000_0002_0000n)).toEqual({ status: 8, view: null });

    // 5. Resizable ArrayBuffer shrink after decode fails closed (null) instead of throwing RangeError
    const rab = new ArrayBuffer(framed.byteLength, { maxByteLength: 128 });
    const rabBytes = new Uint8Array(rab);
    rabBytes.set(framed);
    const rabDec = orbWireDecodeSlice(rabBytes, 12);
    expect(rabDec.status).toBe(0);
    rab.resize(24);
    expect(rabDec.view!.recordAt(0)).toBeNull();
    expect(rabDec.view!.arenaSlice(0, 4)).toBeNull();
  });

  it("verifies Phase R4 Scroll policy and zero-copy Stream/Scroll/Transcript slice steppers over WASM", () => {
    expect(orbScrollPolicyGap(1000, 400, 580)).toBe(20);
    expect(orbScrollPolicyGap(300, 400, 0)).toBe(-100);
    expect(orbScrollPolicyMaxTop(1000, 400)).toBe(600);
    expect(orbScrollPolicyClampTop(1000, 400, 999)).toBe(600);
    expect(orbScrollPolicyClampTop(1000, 400, -50)).toBe(0);
    expect(orbScrollPolicyMaxTop(0x4000_0000, 400)).toBeNull();
    expect(orbScrollPolicyClampTop(1000, 400, -0x4000_0001)).toBeNull();
    expect(orbScrollPolicyGap(0x4000_0000, 400, 0)).toBeNull();
    expect(orbScrollPolicyCorrect(0x4000_0000, 400, 0, 100, 20)).toBeNull();
    const c1 = orbScrollPolicyCorrect(2000, 500, 300, 820, 40)!;
    expect(c1).toBe(780);
    expect(orbScrollPolicyCorrect(2000, 500, c1, 820, 40)).toBe(c1);

    // Passive resize never flips pinned
    expect(orbScrollPolicyStep({
      opKind: 2, pinned: false, intent: false, resized: true,
      curTop: 400, height: 1200, client: 500, arg: 695,
    })).toEqual({ status: 1, admitted: true, pinned: false, top: 695 });

    // 1. Scroll slice step writes 32-byte OrbWire verdict frame and preserves sentinels on rejection
    const scrollOut = new Uint8Array(40).fill(0xa5);
    const scrollRes = orbWireScrollSliceStep({
      inSlice: new Uint8Array(8),
      outBuf: scrollOut,
      opKind: 1,
      pinned: true,
      intent: true,
      resized: false,
      curTop: 600,
      height: 1200,
      client: 500,
      arg: 350,
    });
    expect(scrollRes).toEqual({
      status: 0,
      written: 32,
      verdict: { status: 1, admitted: true, pinned: false, top: 350 },
    });
    expect(Array.from(scrollOut.subarray(32))).toEqual(new Array(8).fill(0xa5));
    const scrollDec = orbWireDecodeSlice(scrollOut.subarray(0, 32), ORB_WIRE_SCHEMA_SCROLL_SLICE);
    expect(scrollDec.status).toBe(0);
    expect(scrollDec.view!.recordAt(0)).toEqual({ tag: 1, flags: 0, len16: 0, payload32: 350 });

    const scrollSmall = new Uint8Array(24).fill(0x5a);
    expect(orbWireScrollSliceStep({
      inSlice: new Uint8Array(4),
      outBuf: scrollSmall,
      opKind: 0,
      pinned: true,
      intent: false,
      resized: false,
      curTop: 0,
      height: 1000,
      client: 400,
      arg: 0,
    })).toEqual({ status: 5, written: 0, verdict: null });
    expect(Array.from(scrollSmall)).toEqual(new Array(24).fill(0x5a));

    // 2. Stream bounded-tail slice step forces checkpoint and preserves sentinels on alias/bad state
    const streamOut = new Uint8Array(32).fill(0x3c);
    const streamRes = orbWireStreamSliceStep({
      inTail: new TextEncoder().encode("```rust\nlet x = 1;\n"),
      outBuf: streamOut,
      prevLen: 1000,
      prevCommit: 200,
      prevCheckpoint: 200,
      newLen: 20_000,
      rawCommit: 200,
      maxOpenTailBytes: 4096,
    });
    expect(streamRes).toEqual({
      status: 0,
      written: 32,
      verdict: { admitted: true, checkpointForced: true, nextCheckpoint: 15_904 },
    });
    const streamDec = orbWireDecodeSlice(streamOut, ORB_WIRE_SCHEMA_STREAM_SLICE);
    expect(streamDec.status).toBe(0);
    expect(streamDec.view!.recordAt(0)).toEqual({ tag: 1, flags: 1, len16: 19, payload32: 15_904 });

    const streamBad = new Uint8Array(32).fill(0xc3);
    expect(orbWireStreamSliceStep({
      inTail: new Uint8Array(8),
      outBuf: streamBad,
      prevLen: 500,
      prevCommit: 200,
      prevCheckpoint: 200,
      newLen: 400,
      rawCommit: 200,
      maxOpenTailBytes: 4096,
    })).toEqual({ status: 3, written: 0, verdict: null });
    expect(Array.from(streamBad)).toEqual(new Array(32).fill(0xc3));

    // 3. Transcript fold slice step preserves live == replay determinism and rejects sequence gaps without mutating outBuf
    const liveBuf = new Uint8Array(32).fill(0x11);
    const replayBuf = new Uint8Array(32).fill(0x22);
    const liveFold = orbWireTranscriptSliceStep({
      inEvent: new TextEncoder().encode("delta"),
      outBuf: liveBuf,
      lastAppliedSeq: 10n,
      incomingSeq: 11n,
      entryCount: 3,
      thinkingOpen: true,
      normalizedAction: 5,
      isReplayFromLog: false,
    });
    const replayFold = orbWireTranscriptSliceStep({
      inEvent: new TextEncoder().encode("delta"),
      outBuf: replayBuf,
      lastAppliedSeq: 10n,
      incomingSeq: 11n,
      entryCount: 3,
      thinkingOpen: true,
      normalizedAction: 5,
      isReplayFromLog: true,
    });
    expect(liveFold.verdict).toEqual(replayFold.verdict);
    expect(Array.from(liveBuf)).toEqual(Array.from(replayBuf));
    const txDec = orbWireDecodeSlice(liveBuf, ORB_WIRE_SCHEMA_TRANSCRIPT_SLICE);
    expect(txDec.status).toBe(0);
    expect(txDec.view!.recordAt(0)).toEqual({ tag: 1, flags: 2, len16: 5, payload32: 4 });

    const gapBuf = new Uint8Array(32).fill(0x77);
    const gapRes = orbWireTranscriptSliceStep({
      inEvent: new Uint8Array(4),
      outBuf: gapBuf,
      lastAppliedSeq: 10n,
      incomingSeq: 13n,
      entryCount: 3,
      thinkingOpen: false,
      normalizedAction: 5,
      isReplayFromLog: false,
    });
    expect(gapRes.written).toBe(0);
    expect(gapRes.verdict).toMatchObject({ admitted: false, gapBuffered: true, nextEntryCount: 3 });
    expect(Array.from(gapBuf)).toEqual(new Array(32).fill(0x77));

    // Invalid normalizedAction (actionCode = 4) is distinguished from OutputTooSmall (status = 5)
    const badActBuf = new Uint8Array(32).fill(0x88);
    const badActRes = orbWireTranscriptSliceStep({
      inEvent: new Uint8Array(4),
      outBuf: badActBuf,
      lastAppliedSeq: 10n,
      incomingSeq: 11n,
      entryCount: 3,
      thinkingOpen: true,
      normalizedAction: 99,
      isReplayFromLog: false,
    });
    expect(badActRes.status).toBe(3);
    expect(badActRes.written).toBe(0);
    expect(badActRes.verdict).toMatchObject({
      actionCode: 4,
      admitted: false,
      thinkingOpenNext: true,
      nextEntryCount: 3,
    });
    expect(Array.from(badActBuf)).toEqual(new Array(32).fill(0x88));

    const smallTxBuf = new Uint8Array(16).fill(0x99);
    const smallTxRes = orbWireTranscriptSliceStep({
      inEvent: new Uint8Array(4),
      outBuf: smallTxBuf,
      lastAppliedSeq: 10n,
      incomingSeq: 11n,
      entryCount: 3,
      thinkingOpen: true,
      normalizedAction: 99,
      isReplayFromLog: false,
    });
    expect(smallTxRes).toEqual({ status: 5, written: 0, verdict: null });
    expect(Array.from(smallTxBuf)).toEqual(new Array(16).fill(0x99));

    // advanceStreamBoundedCommit rejects invalid/negative inputs fail-closed via kernel gate
    const baseTail = { totalBytes: 1000, committedBytes: 200, checkpointBytes: 200 };
    expect(advanceStreamBoundedCommit(baseTail, -5, 200, 4096)).toEqual({
      ...baseTail,
      admitted: false,
      checkpointForced: false,
    });
    expect(advanceStreamBoundedCommit(baseTail, 100, 200, 0)).toEqual({
      ...baseTail,
      admitted: false,
      checkpointForced: false,
    });

    // Zero-copy length-only stream slice step handles >1 MiB open tails without copying or growing WASM linear memory past 1 MiB scratch
    const scratchBefore = ensureKernelLinearScratch(0).memory.buffer.byteLength;
    const cappedScratch = ensureKernelLinearScratch(8 * 1024 * 1024);
    const maxExpectedBytes = Math.ceil((kernelScratchBaseOffset() + 32 + 1_048_576) / 65_536) * 65_536;
    expect(cappedScratch.memory.buffer.byteLength).toBeLessThanOrEqual(maxExpectedBytes);
    expect(cappedScratch.memory.buffer.byteLength).toBeGreaterThanOrEqual(scratchBefore);

    const largeTailStep = advanceStreamBoundedCommit(
      { totalBytes: 2_000_000, committedBytes: 0, checkpointBytes: 1_983_616 },
      4096,
      0,
      16_384,
      20_480,
    );
    expect(largeTailStep).toEqual({
      totalBytes: 2_004_096,
      committedBytes: 0,
      checkpointBytes: 2_004_096 - 16_384,
      admitted: true,
      checkpointForced: true,
    });

    const lengthOnlyOut = new Uint8Array(32).fill(0x55);
    const lengthOnlyRes = orbWireStreamSliceStep({
      inTail: new Uint8Array(0),
      inTailBytesLen: 2_097_152,
      outBuf: lengthOnlyOut,
      prevLen: 2_097_152,
      prevCommit: 0,
      prevCheckpoint: 2_080_768,
      newLen: 2_101_248,
      rawCommit: 0,
      maxOpenTailBytes: 16_384,
    });
    expect(lengthOnlyRes.status).toBe(0);
    expect(lengthOnlyRes.written).toBe(32);
    expect(lengthOnlyRes.verdict).toEqual({
      admitted: true,
      checkpointForced: true,
      nextCheckpoint: 2_101_248 - 16_384,
    });
    expect(cappedScratch.memory.buffer.byteLength).toBeLessThanOrEqual(maxExpectedBytes);
  });

  it("evaluates cross-client projection and UTF-8/UTF-16 window steppers via WASM", () => {
    expect(orbMissionStateClassify(0)).toBeGreaterThanOrEqual(0);
    expect(orbMissionSortRank(0)).toBeGreaterThanOrEqual(0);
    expect(typeof orbMissionFlags(1).isActive).toBe("boolean");
    expect(orbMissionInboxSection(0)).toBeGreaterThanOrEqual(0);
    expect(
      orbConnectionIssueClassify({
        isUnreachable: true,
        isUsingDefault: false,
        isPrivateAddr: true,
        defaultReachable: true,
        hasExternalProxy: false,
      }),
    ).toBeGreaterThan(0);
    expect(orbWorkedDurationBucket(125).unit).toBeGreaterThanOrEqual(0);
    expect(
      orbTurnOutcomeStep({
        prevOutcome: 0,
        prevFailed: false,
        eventKind: 1,
        isNarration: false,
        isSuccessFalse: false,
        isTextNonEmpty: true,
      }).failed,
    ).toBe(false);
    expect(
      orbNumericCellScan({
        nonEmpty: true,
        hasLeadingDigitOrSign: true,
        hasDigit: true,
        allAllowedChars: true,
      }),
    ).toBe(true);
    expect(orbFileRefLineSpan(5, 12, 100)).toEqual({ valid: true, count: 8 });
    expect(orbMachineActionAdmitted(1, false, false)).toBeGreaterThanOrEqual(0);
    expect(
      orbSendFlowStep({
        isBusy: false,
        hasNonEmptyText: true,
        canQueue: true,
        awaitingAck: false,
        isDraining: false,
        pendingCount: 0,
        httpStatus: 200,
      }).tapAction,
    ).toBeGreaterThanOrEqual(0);
    expect(orbUtf8Utf16WindowStep(0, 10, 0xf0, 5, 6).admitted).toBe(false);
    expect(orbUtf8Utf16WindowStep(0, 10, 0xf0, 5, 7)).toEqual({
      admitted: true,
      seqBytes: 4,
      utf16Cost: 2,
      nextUtf16Units: 7,
    });
  });

  it("enforces sidebar move target admission and long-press drag state machine invariants", () => {
    // Folder cycle / self-subtree rejected even when parent ordinal differs
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 1, dstIsSelfOrSubtree: true,
      srcProjectOrd: 1, srcPathOrd: 2, srcParentOrd: 0,
      dstProjectOrd: 1, dstPathOrd: 3,
    })).toBe(false);

    // Same-container no-op rejected for mission (0), folder (1), file (2), cron (3)
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 0, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 4, srcParentOrd: 0,
      dstProjectOrd: 1, dstPathOrd: 4,
    })).toBe(false);
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 1, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 5, srcParentOrd: 4,
      dstProjectOrd: 1, dstPathOrd: 4,
    })).toBe(false);
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 2, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 6, srcParentOrd: 4,
      dstProjectOrd: 1, dstPathOrd: 4,
    })).toBe(false);
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 3, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 4, srcParentOrd: 0,
      dstProjectOrd: 1, dstPathOrd: 4,
    })).toBe(false);

    // Cross-project folder & mission moves admitted even when relative path ordinal matches
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 1, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 5, srcParentOrd: 4,
      dstProjectOrd: 2, dstPathOrd: 4,
    })).toBe(true);
    expect(orbSidebarMoveTargetAdmit({
      itemKind: 0, dstIsSelfOrSubtree: false,
      srcProjectOrd: 1, srcPathOrd: 0, srcParentOrd: 0,
      dstProjectOrd: 2, dstPathOrd: 0,
    })).toBe(true);

    // Quick click (< 260ms, < 6px): pointerDown -> pointerUp preserves normal click (eatClick: false)
    const down = orbSidebarDragStep({
      phase: 0, eventKind: 0, rowMovable: true,
      targetCollapsed: false, targetAdmitted: false,
      distSq: 0, elapsedMs: 0, springElapsedMs: 0,
      hoverTargetOrd: 0, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    expect(down.nextPhase).toBe(1);
    const quickUp = orbSidebarDragStep({
      phase: down.nextPhase, eventKind: 4, rowMovable: true,
      targetCollapsed: false, targetAdmitted: false,
      distSq: 4, elapsedMs: 120, springElapsedMs: 0,
      hoverTargetOrd: 0, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    expect(quickUp).toMatchObject({ nextPhase: 0, effectCode: 0, eatClick: false });

    // Hold >= 260ms within 6px slop -> armLift (effect 1) -> pointerUp opens Move picker (effect 5, eatClick: true)
    const armed = orbSidebarDragStep({
      phase: 1, eventKind: 1, rowMovable: true,
      targetCollapsed: false, targetAdmitted: false,
      distSq: 25, elapsedMs: 260, springElapsedMs: 0,
      hoverTargetOrd: 0, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    expect(armed).toMatchObject({ nextPhase: 2, effectCode: 1 });
    const holdRelease = orbSidebarDragStep({
      phase: armed.nextPhase, eventKind: 4, rowMovable: true,
      targetCollapsed: false, targetAdmitted: false,
      distSq: 25, elapsedMs: 310, springElapsedMs: 0,
      hoverTargetOrd: 0, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    expect(holdRelease).toMatchObject({ nextPhase: 0, effectCode: 5, eatClick: true });

    // Pointer move >= 6px (distSq >= 36) enters dragging, arms spring-load, auto-scrolls, expands once at 450ms, and commits drop
    const dragMove = orbSidebarDragStep({
      phase: 1, eventKind: 2, rowMovable: true,
      targetCollapsed: true, targetAdmitted: true,
      distSq: 36, elapsedMs: 80, springElapsedMs: 0,
      hoverTargetOrd: 7, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 0,
    });
    expect(dragMove).toMatchObject({
      nextPhase: 3, effectCode: 2, nextSpringTargetOrd: 7, scrollDir: 1, scrollStepPx: 10,
    });

    const springFired = orbSidebarDragStep({
      phase: 3, eventKind: 3, rowMovable: true,
      targetCollapsed: true, targetAdmitted: true,
      distSq: 100, elapsedMs: 530, springElapsedMs: 450,
      hoverTargetOrd: 7, springTargetOrd: 7, edgeTopDistPx: 10, edgeBottomDistPx: 999,
    });
    expect(springFired).toMatchObject({
      nextPhase: 3, effectCode: 3, nextSpringTargetOrd: 0,
    });

    const topScrollMove = orbSidebarDragStep({
      phase: 3, eventKind: 2, rowMovable: true,
      targetCollapsed: false, targetAdmitted: true,
      distSq: 100, elapsedMs: 550, springElapsedMs: 0,
      hoverTargetOrd: 7, springTargetOrd: 0, edgeTopDistPx: 10, edgeBottomDistPx: 999,
    });
    expect(topScrollMove.scrollDir).toBe(-1);
    expect(topScrollMove.scrollStepPx).toBeGreaterThanOrEqual(1);
    expect(topScrollMove.scrollStepPx).toBeLessThanOrEqual(10);

    // Escape / cancel from dragging resets without committing
    const cancelled = orbSidebarDragStep({
      phase: 3, eventKind: 5, rowMovable: true,
      targetCollapsed: false, targetAdmitted: true,
      distSq: 100, elapsedMs: 600, springElapsedMs: 0,
      hoverTargetOrd: 7, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    expect(cancelled).toMatchObject({ nextPhase: 0, effectCode: 6, eatClick: false });
  });
});
