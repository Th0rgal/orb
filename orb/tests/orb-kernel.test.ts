import { describe, expect, it } from "vitest";
import {
  leansysGfmPipeRowAdmitted, leansysRichTagAdmitted,
  orbAuthToctouExecuteStep, orbHierarchyMergeStep, orbOutboxCrashReconcileStep,
  orbProviderAttemptStep, orbRelativeTimeString, orbResourceLedgerStep,
  orbStreamBoundedCommitStep, orbTranscriptFoldStep, orbTranscriptPatchStep,
  orbUsageLimitBadge, orbWireApplyPatchStep, orbWireMachineStep,
} from "../src/orbKernel";
import { normalizeLoosePipeTables } from "../src/pipeTables";
import { RICH_TAG, parseRichTag, richTagSpan } from "../src/richTags";

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
});
