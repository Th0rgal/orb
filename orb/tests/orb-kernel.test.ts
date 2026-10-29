import { describe, expect, it } from "vitest";
import { leansysGfmPipeRowAdmitted, leansysRichTagAdmitted, orbRelativeTimeString, orbTranscriptPatchStep, orbUsageLimitBadge } from "../src/orbKernel";
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
});
