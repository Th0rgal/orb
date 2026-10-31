import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { normalizeLoosePipeTables } from "../src/pipeTables";
import {
  admitMount,
  allocTurnKeys,
  ensureUniqueIds,
  hiddenTurnCount,
  latexSpanAdmitted,
  visibleTurnCount,
  type CandidateKey,
} from "../src/transcriptGates";

type TranscriptGateCase =
  | {
      op: "allocTurnKeys";
      candidates: CandidateKey[];
      expected: Array<{ tag: number; item: number; gen: number }>;
    }
  | {
      op: "latexSpanAdmitted";
      name: string;
      len: number;
      prevBlocked: boolean;
      nextDigit: boolean;
      leadSpace: boolean;
      trailSpace: boolean;
      hasNewline: boolean;
      firstDigit: boolean;
      internalSpace: boolean;
      hasMathOp: boolean;
      expected: boolean;
    }
  | {
      op: "windowBudget";
      total: number;
      baseLimit: number;
      expandedSteps: number;
      stepSize: number;
      expectedVisible: number;
      expectedHidden: number;
    }
  | {
      op: "admitMount";
      active: number;
      cap: number;
      expectedAdmitted: boolean;
      expectedNextActive: number;
    };

const fixturePath = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "shared",
  "orb-spec",
  "fixtures",
  "transcript-gates.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { cases: TranscriptGateCase[] };

describe("shared/orb-spec/fixtures/transcript-gates.json (lean/Orb/Transcript.lean)", () => {
  it("matches every Lean-generated transcript gate case", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(60);
    for (const c of fixture.cases) {
      if (c.op === "allocTurnKeys") {
        const got = allocTurnKeys(c.candidates);
        expect(got, JSON.stringify(c)).toEqual(c.expected);
        const serialized = got.map((k) => `${k.tag}:${k.item}:${k.gen}`);
        expect(new Set(serialized).size).toBe(serialized.length);
      } else if (c.op === "latexSpanAdmitted") {
        expect(latexSpanAdmitted(c), c.name).toBe(c.expected);
      } else if (c.op === "windowBudget") {
        expect(visibleTurnCount(c.total, c.baseLimit, c.expandedSteps, c.stepSize)).toBe(
          c.expectedVisible,
        );
        expect(hiddenTurnCount(c.total, c.baseLimit, c.expandedSteps, c.stepSize)).toBe(
          c.expectedHidden,
        );
      } else if (c.op === "admitMount") {
        expect(admitMount(c.active, c.cap)).toEqual({
          admitted: c.expectedAdmitted,
          nextActive: c.expectedNextActive,
        });
      }
    }
  });

  it("holds across 500 deterministic property-fuzz seeds", () => {
    let state = 0x9e3779b9;
    const nextInt = (mod: number) => {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state >>> 0) % mod;
    };
    const keyPool = ["", "turn-0-user", "turn-0-user#1", "cloud:u", "cloud:a", "optimistic-user", "seq-7"];
    const linePool = [
      "colA | colB | colC",
      "🔹 | 12 | 3.5%",
      "alpha | beta | 42",
      "```",
      "~~~",
      "| gfm | 1 |",
      "`a | b` | x | 9",
      "",
      "$15 and $20",
    ];

    for (let seed = 0; seed < 500; seed++) {
      const n = nextInt(32);
      const rawIds: string[] = [];
      const cands: CandidateKey[] = [];
      for (let i = 0; i < n; i++) {
        rawIds.push(keyPool[nextInt(keyPool.length)]);
        cands.push({ tag: nextInt(4), item: nextInt(6) });
      }
      const uniqueStrings = ensureUniqueIds(rawIds);
      expect(uniqueStrings.length).toBe(rawIds.length);
      expect(new Set(uniqueStrings).size).toBe(uniqueStrings.length);
      expect(uniqueStrings.every((s) => s.length > 0)).toBe(true);

      const uniqueKeys = allocTurnKeys(cands);
      expect(uniqueKeys.length).toBe(cands.length);
      expect(new Set(uniqueKeys.map((k) => `${k.tag}:${k.item}:${k.gen}`)).size).toBe(cands.length);

      const lines: string[] = [];
      const lineCount = nextInt(10);
      for (let i = 0; i < lineCount; i++) {
        lines.push(linePool[nextInt(linePool.length)]);
      }
      const sep = nextInt(2) === 0 ? "\n" : "\r\n";
      const once = normalizeLoosePipeTables(lines.join(sep));
      expect(normalizeLoosePipeTables(once)).toBe(once);

      const total = nextInt(600);
      const stepsA = nextInt(12);
      const stepsB = stepsA + nextInt(12);
      const visA = visibleTurnCount(total, 24, stepsA, 24);
      const visB = visibleTurnCount(total, 24, stepsB, 24);
      expect(visA + hiddenTurnCount(total, 24, stepsA, 24)).toBe(total);
      expect(visA).toBeLessThanOrEqual(visB);
    }
  });
});
