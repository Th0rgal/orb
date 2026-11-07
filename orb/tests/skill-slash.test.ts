import { describe, expect, test } from "vitest";
import { filterSkills, insertSkill, removeSkill, selectedSkillNames, skillDisplayText, skillQuery, validateSkillSelection } from "../src/skillSlash";

describe("skill slash selection", () => {
  const available = new Set(["review", "plan-work"]);

  test("finds a slash query without taking a path or skill token", () => {
    expect(skillQuery("see /rev", 8)).toMatchObject({ open: true, query: "rev", start: 4 });
    expect(skillQuery("/usr/bin", 8).open).toBe(false);
    expect(skillQuery(" /skill:review", 14).open).toBe(false);
  });

  test("inserts, displays, and removes a selected skill", () => {
    const inserted = insertSkill("fix /re", 7, "review");
    expect(inserted).toEqual({ text: "fix /skill:review ", caret: 18 });
    expect(skillDisplayText(inserted.text, available)).toBe("fix /review ");
    expect(removeSkill(`  ${inserted.text} now`, "review")).toBe("fix now");
    expect(selectedSkillNames("/skill:review /skill:review /skill:missing", available)).toEqual(["review"]);
  });

  test("filters delivered skills and validates the kernel limit", () => {
    expect(filterSkills([{ name: "review", description: "Read changes" }, { name: "other", description: null }], "read", [])).toEqual([{ name: "review", description: "Read changes" }]);
    const tooMany = Array.from({ length: 9 }, (_, index) => `/skill:skill-${index}`).join(" ");
    const names = new Set(Array.from({ length: 9 }, (_, index) => `skill-${index}`));
    expect(validateSkillSelection(tooMany, "codex", names)).toBe("Select at most 8 distinct skills");
    expect(validateSkillSelection("/goal fix /skill:missing", "opencode", available)).toContain("not delivered");
    expect(validateSkillSelection("/goal fix /skill:review", "opencode", available)).toBeNull();
  });
});
