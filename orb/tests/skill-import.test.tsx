import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi } from "vitest";
import { SkillDetail, middleTruncate } from "../src/SkillDetail";
import type { SkillRow } from "../src/skillRows";

const row: SkillRow = {
  name: "old-skill",
  description: "Legacy skill",
  audience: ["mission", "local"],
  scope: null,
  sourceKinds: ["legacy"],
  sources: [{
    id: "paloma-skills", label: "Paloma Skills", path: "~/work/paloma/skills/old-skill", legacy: true, hash: "h", lines: 3,
    content: "---\nname: old-skill\n---\n",
    files: [{ rel: "references/a.md", size: 10 }, { rel: "scripts/run.sh", size: 2048 }],
  }],
  inLibrary: false,
  legacyOnly: true,
  divergent: false,
  desired: false,
  harnessCount: 0,
  staleCount: 0,
  lines: 3,
  content: "---\nname: old-skill\n---\n",
  lint: [],
};

describe("legacy import", () => {
  it("shows one quiet old-copy line that imports SKILL.md and its allowlisted files in one click", async () => {
    const onImport = vi.fn(async () => {});
    const onClose = vi.fn();
    render(() => (
      <SkillDetail row={row} connected harnessTotal={6} onClose={onClose} onSave={async () => {}} onImport={onImport}
        onDelete={async () => {}} onFilesChanged={async () => {}} />
    ));
    const line = document.querySelector(".skills-oldcopy")!;
    expect(line.textContent).toContain("Old copy in Paloma Skills");
    expect(line.getAttribute("title")).toBe("~/work/paloma/skills/old-skill");
    // No copies panel, no Compare.
    expect(screen.queryByRole("button", { name: "Compare" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Import" }));
    await waitFor(() => expect(onImport).toHaveBeenCalledWith("old-skill", row.sources[0], ["references/a.md", "scripts/run.sh"]));
    expect(onClose).toHaveBeenCalled();
  });
});

describe("middleTruncate", () => {
  it("keeps both ends of a long path", () => {
    expect(middleTruncate("short/path.md")).toBe("short/path.md");
    const out = middleTruncate("/Users/thomas/work/paloma/skills/agent-browser/references/selectors.md", 32);
    expect(out).toHaveLength(32);
    expect(out.startsWith("/Users/thomas/wo")).toBe(true);
    expect(out.endsWith("selectors.md")).toBe(true);
    expect(out).toContain("…");
  });
});
