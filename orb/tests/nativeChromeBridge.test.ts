import { describe, expect, it } from "vitest";
import type { Mission } from "../src/api";
import { serializeNativeChromeMission } from "../src/nativeChromeBridge";

const base = { id: "m1", title: "T", status: "failed", created_at: "2026-11-19T00:00:00Z" } as Mission;

describe("serializeNativeChromeMission", () => {
  it("marks a mission tagged archived as acknowledged", () => {
    expect(serializeNativeChromeMission({ ...base, tags: ["pr-writer", "archived"] }).acknowledged).toBe(true);
  });
  it("keeps an untagged failed mission visible", () => {
    expect(serializeNativeChromeMission({ ...base, tags: ["pr-writer"] }).acknowledged).toBe(false);
  });
});
