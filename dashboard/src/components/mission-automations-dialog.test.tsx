import { describe, expect, it } from "vitest";

import { prepareVisibleAutomations } from "./mission-automations-dialog";

describe("prepareVisibleAutomations", () => {
  const make = (
    id: string,
    overrides: Partial<{
      active: boolean;
      created_at: string;
      last_triggered_at: string | null;
      stop_policy: { type: string };
      command_source: { type: string };
    }> = {},
  ) => ({
    id,
    active: overrides.active ?? true,
    created_at: overrides.created_at ?? "2026-05-21T00:00:00Z",
    last_triggered_at: overrides.last_triggered_at ?? null,
    stop_policy: overrides.stop_policy ?? { type: "never" },
    command_source: overrides.command_source ?? { type: "inline" },
  });

  it("drops inactive native_loop rows but keeps active ones", () => {
    const result = prepareVisibleAutomations([
      make("stale", { active: false, command_source: { type: "native_loop" } }),
      make("running", { active: true, command_source: { type: "native_loop" } }),
    ]);

    expect(result.live.map((a) => a.id)).toEqual(["running"]);
  });

  it("preserves inactive non-native_loop rows (user-paused automations stay visible)", () => {
    const result = prepareVisibleAutomations([
      make("paused-by-user", { active: false, command_source: { type: "inline" } }),
      make("paused-library", { active: false, command_source: { type: "library" } }),
    ]);

    expect(result.live.map((a) => a.id).sort()).toEqual(
      ["paused-by-user", "paused-library"].sort(),
    );
  });

  it("sorts active rows above inactive rows", () => {
    const result = prepareVisibleAutomations([
      make("paused", { active: false, created_at: "2026-05-22T00:00:00Z" }),
      make("active-old", { active: true, created_at: "2026-05-20T00:00:00Z" }),
    ]);

    expect(result.live.map((a) => a.id)).toEqual(["active-old", "paused"]);
  });

  it("within the same active state, sorts newest first", () => {
    const result = prepareVisibleAutomations([
      make("oldest", { active: true, created_at: "2026-05-20T00:00:00Z" }),
      make("newest", { active: true, created_at: "2026-05-22T00:00:00Z" }),
      make("middle", { active: true, created_at: "2026-05-21T00:00:00Z" }),
    ]);

    expect(result.live.map((a) => a.id)).toEqual(["newest", "middle", "oldest"]);
  });

  it("does not mutate the input array (sort + filter return a fresh list)", () => {
    const input = [
      make("a", { active: false, created_at: "2026-05-22T00:00:00Z" }),
      make("b", { active: true, created_at: "2026-05-20T00:00:00Z" }),
    ];
    const inputSnapshot = input.map((a) => a.id);

    prepareVisibleAutomations(input);

    expect(input.map((a) => a.id)).toEqual(inputSnapshot);
  });

  it("regression: an active interval driver does not get buried under newer inactive native_loop children", () => {
    // Mirrors the bug we just hunted on mission a81529aa: the active interval
    // was 14 rows down because 13 child native_loop rows were created later.
    const intervalDriver = make("interval-driver", {
      active: true,
      created_at: "2026-05-21T14:15:26Z",
      command_source: { type: "inline" },
    });
    const newerCompletedChildren = Array.from({ length: 13 }, (_, i) =>
      make(`child-${i}`, {
        active: false,
        created_at: `2026-05-22T0${(i % 9) + 1}:00:00Z`,
        command_source: { type: "native_loop" },
      }),
    );

    const result = prepareVisibleAutomations([
      ...newerCompletedChildren,
      intervalDriver,
    ]);

    expect(result.live.map((a) => a.id)).toEqual(["interval-driver"]);
  });

  it("routes fired one-shot wakeups (inactive + last_triggered_at) to spent", () => {
    const result = prepareVisibleAutomations([
      make("live-driver", { active: true }),
      make("paused-never-fired", { active: false, last_triggered_at: null }),
      make("spent-wakeup", {
        active: false,
        last_triggered_at: "2026-05-22T10:00:00Z",
        stop_policy: { type: "after_first_fire" },
      }),
      make("paused-recurring", {
        active: false,
        last_triggered_at: "2026-05-22T10:00:00Z",
        stop_policy: { type: "never" },
      }),
    ]);
    expect(result.live.map((a) => a.id).sort()).toEqual(
      ["live-driver", "paused-never-fired", "paused-recurring"].sort(),
    );
    expect(result.spent.map((a) => a.id)).toEqual(["spent-wakeup"]);
  });
});
