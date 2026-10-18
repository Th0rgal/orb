import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi } from "vitest";
import { SkillDetail } from "../src/SkillDetail";
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
  it("lists allowed reference files checked by default and imports only the kept ones", async () => {
    const onImport = vi.fn(async () => {});
    render(() => (
      <SkillDetail row={row} connected harnessTotal={6} onClose={() => {}} onSave={async () => {}} onImport={onImport}
        onDelete={async () => {}} onFilesChanged={async () => {}} />
    ));
    fireEvent.click(screen.getByRole("button", { name: "Import to Library" }));
    const a = await screen.findByRole("checkbox", { name: /references\/a\.md/ }) as HTMLInputElement;
    const s = screen.getByRole("checkbox", { name: /scripts\/run\.sh/ }) as HTMLInputElement;
    expect(a.checked && s.checked).toBe(true);
    expect(screen.getByText("2.0 KB")).toBeTruthy();
    fireEvent.click(s);
    expect(s.checked).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Import" }));
    await waitFor(() => expect(onImport).toHaveBeenCalledTimes(1));
    expect(onImport).toHaveBeenCalledWith("old-skill", row.sources[0], ["references/a.md"]);
  });
});
