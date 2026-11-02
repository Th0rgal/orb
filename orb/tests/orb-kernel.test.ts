import { describe, expect, it } from "vitest";
import { kernelAbi } from "../src/orbKernelAbi";
import {
  leansysGfmPipeRowAdmitted, leansysRichTagAdmitted, leansysVerifyFdBounds,
  orbAuthToctouExecuteStep, orbHierarchyMergeStep, orbOutboxCrashReconcileStep,
  orbProviderAttemptStep, orbRelativeTimeString, orbResourceLedgerStep,
  orbStreamBoundedCommitStep, orbTranscriptFoldStep, orbTranscriptPatchStep,
  orbUsageLimitBadge, orbWireApplyPatchStep, orbWireDecodeSlice,
  orbWireEncodeSliceInto, orbWireMachineStep, orbWireVerifySliceIo,
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
});
