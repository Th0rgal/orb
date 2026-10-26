import { describe, expect, it } from "vitest";
import { needsAttention, skillBadge } from "../src/skillRows";
import { repoLabel } from "../src/skillsApi";

const row = (o: Partial<{ divergent: boolean; legacyOnly: boolean; scope: string | null; lint: { id: string; message: string }[] }> = {}) =>
  ({ divergent: false, legacyOnly: false, scope: null, lint: [], ...o }) as Parameters<typeof needsAttention>[0];

describe("skill row badge", () => {
  it("shows nothing for a healthy row and at most one badge otherwise", () => {
    expect(skillBadge(row())).toBeNull();
    expect(skillBadge(row({ scope: "global" }))).toBe("always");
    expect(skillBadge(row({ legacyOnly: true, scope: "global" }))).toBe("old-folder");
    expect(skillBadge(row({ divergent: true, legacyOnly: true }))).toBe("edited");
  });
  it("needs attention for edits, old folders and lint, not for always-loaded", () => {
    expect(needsAttention(row({ scope: "global" }))).toBe(false);
    expect(needsAttention(row({ divergent: true }))).toBe(true);
    expect(needsAttention(row({ legacyOnly: true }))).toBe(true);
    expect(needsAttention(row({ lint: [{ id: "x", message: "y" }] }))).toBe(true);
  });
  it("names the repo from its remote", () => {
    expect(repoLabel("git@github.com:Th0rgal/sandboxed-library.git")).toBe("Th0rgal/sandboxed-library");
    expect(repoLabel("https://github.com/Th0rgal/sandboxed-library")).toBe("Th0rgal/sandboxed-library");
    expect(repoLabel(undefined)).toBe("Library");
  });
});
