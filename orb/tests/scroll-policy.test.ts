import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { correct, gap, jump, layout, maxTop, clampTop, scrollEvent, userScroll, type ScrollState } from "../src/mission/scrollPolicy";

type Case = { op: string; state?: ScrollState; intent?: boolean; resized?: boolean; height: number; client: number; shift?: number; to?: number; top?: number; anchorDoc?: number; y0?: number; expected: unknown };
const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "scroll-policy.json"), "utf8")) as { cases: Case[] };

describe("shared/orb-spec/fixtures/scroll-policy.json (lean/Orb/Scroll.lean)", () => {
  it("has cases", () => expect(fixture.cases.length).toBeGreaterThan(1000));
  it("matches the Lean definitions", () => {
    for (const c of fixture.cases) {
      const got = c.op === "layout" ? layout(c.state!, c.height, c.client, c.shift!)
        : c.op === "userScroll" ? userScroll(c.state!, c.height, c.client, c.to!)
        : c.op === "scrollEvent" ? scrollEvent(c.state!, c.intent!, c.resized!, c.height, c.client, c.to!)
        : c.op === "jump" ? jump(c.state!, c.height, c.client)
        : correct(c.height, c.client, c.top!, c.anchorDoc!, c.y0!);
      expect(got, JSON.stringify(c)).toEqual(c.expected);
    }
  });
  it("preserves exact JS math when coordinates or scaled subpixels exceed kernel domain", () => {
    const huge = 2_000_000_000;
    expect(maxTop(huge, 500)).toBe(huge - 500);
    expect(clampTop(huge, 500, huge - 100)).toBe(huge - 500);
    expect(gap(huge, 500, huge - 520)).toBe(20);
    expect(correct(huge, 500, 1000, 1400, 120)).toBe(1280);
    expect(layout({ pinned: true, top: 0 }, huge, 500, 0)).toEqual({ pinned: true, top: huge - 500 });
    expect(maxTop(2_000_000.3, 400.1)).toBeCloseTo(2_000_000.3 - 400.1, 6);
  });
});
