import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { correct, jump, layout, userScroll, type ScrollState } from "../src/mission/scrollPolicy";

type Case = { op: string; state?: ScrollState; height: number; client: number; shift?: number; to?: number; top?: number; anchorDoc?: number; y0?: number; expected: unknown };
const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "scroll-policy.json"), "utf8")) as { cases: Case[] };

describe("shared/orb-spec/fixtures/scroll-policy.json (lean/Orb/Scroll.lean)", () => {
  it("has cases", () => expect(fixture.cases.length).toBeGreaterThan(1000));
  it("matches the Lean definitions", () => {
    for (const c of fixture.cases) {
      const got = c.op === "layout" ? layout(c.state!, c.height, c.client, c.shift!)
        : c.op === "userScroll" ? userScroll(c.state!, c.height, c.client, c.to!)
        : c.op === "jump" ? jump(c.state!, c.height, c.client)
        : correct(c.height, c.client, c.top!, c.anchorDoc!, c.y0!);
      expect(got, JSON.stringify(c)).toEqual(c.expected);
    }
  });
});
