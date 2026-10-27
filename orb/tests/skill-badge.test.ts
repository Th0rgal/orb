import { describe, expect, it } from "vitest";
import { isOldCopy, needsAttention, skillBadge } from "../src/skillRows";
import { repoLabel } from "../src/skillsApi";

type Row = Parameters<typeof needsAttention>[0];
const row = (o: Partial<Row> = {}): Row => ({ inLibrary: true, legacyOnly: false, scope: null, removed: false, editedCopy: null, lint: [], ...o });
const edit = { harness: "Claude Code", path: "/Users/t/.claude/skills/x", content: "# mine" };

describe("skill row badge", () => {
  it("shows nothing for a healthy row and at most one badge otherwise", () => {
    expect(skillBadge(row())).toBeNull();
    expect(skillBadge(row({ scope: "global" }))).toBe("always");
    expect(skillBadge(row({ inLibrary: false, legacyOnly: true }))).toBe("old-folder");
    expect(skillBadge(row({ inLibrary: false, removed: true, legacyOnly: true }))).toBe("removed");
    expect(skillBadge(row({ editedCopy: edit }))).toBe("edited");
  });
  it("calls a skill edited only when a Library skill's installed copy differs", () => {
    // A skill the Library dropped is never "Edited on this Mac", even with a stray copy.
    expect(skillBadge(row({ inLibrary: false, removed: true, editedCopy: edit }))).toBe("removed");
    expect(skillBadge(row({ inLibrary: false, editedCopy: edit }))).toBeNull();
  });
  it("needs attention for removed, edited and lint; old copies live in their own section", () => {
    expect(needsAttention(row({ scope: "global" }))).toBe(false);
    expect(needsAttention(row({ inLibrary: false, removed: true }))).toBe(true);
    expect(needsAttention(row({ editedCopy: edit }))).toBe(true);
    expect(needsAttention(row({ lint: [{ id: "x", message: "y" }] }))).toBe(true);
    const old = row({ inLibrary: false, legacyOnly: true, lint: [{ id: "x", message: "y" }] });
    expect(needsAttention(old)).toBe(false);
    expect(isOldCopy(old)).toBe(true);
  });
  it("names the repo from its remote", () => {
    expect(repoLabel("git@github.com:Th0rgal/sandboxed-library.git")).toBe("Th0rgal/sandboxed-library");
    expect(repoLabel(undefined)).toBe("Library");
  });
});
