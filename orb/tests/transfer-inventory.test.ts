import { expect, it } from "vitest";
import { formatBytes, inventoryGroups } from "../src/TransferInventory";
import { describeError } from "../src/ErrorNotice";

const file = (path: string, bytes: number) => ({ path, bytes, sha256: "", executable: false });
it("groups moved files by top-level folder, largest first, with Git history apart", () => {
  const groups = inventoryGroups({ bytes: 0, excluded: [], files: [file("notes.md", 10), file("repo/src/a.rs", 100), file("repo/src/b.rs", 50), file("repo/.transfer-git.bundle", 5000), file("data/x.bin", 3000), file(".transfer-git.bundle", 20)] });
  expect(groups.map(g => [g.name, g.files, g.bytes, g.history])).toEqual([["repo", 2, 5150, 5000], ["data", 1, 3000, 0], ["Workspace", 0, 20, 20], ["notes.md", 1, 10, 0]]);
  expect(groups[0].paths).toEqual(["src/a.rs", "src/b.rs"]);
  expect(groups[3].paths).toEqual([]);
});
it("lists a bounded number of paths for a large folder", () => {
  const groups = inventoryGroups({ bytes: 0, excluded: [], files: Array.from({ length: 500 }, (_, i) => file(`big/${i}`, 1)) });
  expect(groups[0].files).toBe(500);
  expect(groups[0].paths).toHaveLength(50);
});
it("formats sizes in binary units", () => {
  expect([0, 214, 2048, 3 * 1024 ** 2, 5.5 * 1024 ** 3].map(formatBytes)).toEqual(["0 B", "214 B", "2 KiB", "3.0 MiB", "5.5 GiB"]);
});
it("explains an oversized workspace with its largest folders", () => {
  const info = describeError("409 Workspace exceeds transfer limit (10 GiB / 50,000 files): 28.9 GiB in 408581 files. Largest: rvb (7.1 GiB, 126454 files), my, dir (4.5 GiB, 35607 files)");
  expect(info.title).toBe("Workspace too large to move");
  expect(info.message).toContain("It holds 28.9 GiB in 408,581 files.");
  expect(info.message).toContain("rvb  ·  7.1 GiB, 126,454 files\nmy, dir  ·  4.5 GiB, 35,607 files");
  expect(describeError("409 Workspace exceeds transfer limit (10 GiB / 50,000 files)").message).toBe("A move carries at most 10 GiB and 50,000 files.");
});
it("names the machine that cannot receive links", () => {
  expect(describeError("409 Update old-agent to receive a workspace containing links").title).toBe("old-agent needs an update");
});
