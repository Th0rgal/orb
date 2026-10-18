import { describe, expect, it } from "vitest";
import { fitReplacementHistory } from "../src/api";

describe("remote replacement prompt budget", () => {
  it("keeps the newest history and stays under the native prompt limit", () => {
    const history = [
      { role: "user", content: "x".repeat(57_000) },
      ...Array.from({ length: 40 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: `turn ${i} ` + "é".repeat(2_000) })),
    ];
    const mission = { id: "m1", history, goal_objective: null } as never;
    const kept = fitReplacementHistory(mission, "Ok, du coup tout ça c'est en cours ?");
    expect(kept.length).toBeGreaterThan(0);
    expect(kept.at(-1)!.content).toContain("turn 39");
    expect(new TextEncoder().encode(JSON.stringify(kept)).length).toBeLessThan(60 * 1024);
  });
  it("leaves small histories untouched", () => {
    const history = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }];
    expect(fitReplacementHistory({ id: "m", history } as never, "next")).toEqual(history);
  });
});
