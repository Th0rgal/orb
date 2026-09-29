import { expect, it } from "vitest";
import { formatBytes, inventoryGroups } from "../src/TransferInventory";
import { describeError } from "../src/ErrorNotice";

const file = (path: string, bytes: number) => ({ path, bytes, sha256: "", executable: false });
it("groups moved files by top-level folder, largest first, with Git history apart", () => {
  const groups = inventoryGroups({ bytes: 0, excluded: [], files: [file("notes.md", 10), file("todo.md", 7), file("repo/src/a.rs", 100), file("repo/src/b.rs", 50), file("repo/.transfer-git.bundle", 5000), file("data/x.bin", 3000), file(".transfer-git.bundle", 20)] });
  expect(groups.map(g => [g.name, g.files, g.bytes, g.history])).toEqual([["repo", 2, 5150, 5000], ["data", 1, 3000, 0], ["Workspace", 0, 20, 20], ["Top-level files", 2, 17, 0]]);
  expect(groups[0].paths).toEqual(["src/a.rs", "src/b.rs"]);
  expect(groups[3].paths).toEqual(["notes.md", "todo.md"]);
});
it("lists a bounded number of paths for a large folder and for the root", () => {
  for (const folder of ["big/", ""]) {
    const groups = inventoryGroups({ bytes: 0, excluded: [], files: Array.from({ length: 500 }, (_, i) => file(`${folder}${i}`, 1)) });
    expect(groups).toHaveLength(1);
    expect(groups[0].files).toBe(500);
    expect(groups[0].paths).toHaveLength(50);
  }
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

import { blocked, selectionRequest, selectionTotals } from "../src/TransferSelection";
import type { InventoryRow } from "../src/machineTransfer";
const row = (path: string, state: InventoryRow["state"], bytes: number, files: number, folder = true): InventoryRow => ({ path, folder, state, bytes, files });
const rows = [row("work", "moved", 100, 10), row("work/cache", "moved", 60, 6), row("work/cache/x/target", "rebuildable", 500, 50), row("work/run.log", "ignored", 5, 1, false), row(".cargo", "rebuildable", 1000, 100), row("top.txt", "moved", 1, 1, false), row("scratch/.lake", "rebuildable", 70, 7)];
it("moves everything but ignored and rebuildable paths by default", () => {
  expect(selectionTotals({ rows, bytes: 101, files: 11 }, {})).toEqual({ bytes: 101, files: 11 });
  expect(selectionRequest(rows, {})).toEqual({ omit: [], include: [] });
});
it("subtracts an unticked folder and adds a ticked left-behind path", () => {
  const choice = { "work/cache": false, ".cargo": true, "work/run.log": true, "scratch/.lake": true };
  expect(selectionTotals({ rows, bytes: 101, files: 11 }, choice)).toEqual({ bytes: 100 - 60 + 1000 + 5 + 70 + 1, files: 10 - 6 + 100 + 1 + 7 + 1 });
  expect(selectionRequest(rows, choice)).toEqual({ omit: ["work/cache"], include: ["work/run.log", ".cargo", "scratch/.lake"] });
});
it("lets an unticked folder decide for everything beneath it", () => {
  const choice = { work: false, "work/cache": false, "work/cache/x/target": true };
  expect(rows.filter(r => blocked(r, rows, choice)).map(r => r.path)).toEqual(["work/cache", "work/cache/x/target", "work/run.log"]);
  expect(selectionTotals({ rows, bytes: 101, files: 11 }, choice)).toEqual({ bytes: 1, files: 1 });
  expect(selectionRequest(rows, choice)).toEqual({ omit: ["work"], include: [] });
  expect(selectionRequest(rows, { "work/cache": false, "work/cache/x/target": true })).toEqual({ omit: ["work/cache"], include: [] });
});
it("counts moved entries a long listing left out", () => {
  expect(selectionTotals({ rows: rows.slice(0, 2), bytes: 900, files: 90 }, { "work/cache": false })).toEqual({ bytes: 840, files: 84 });
});
it("reserves room for Git history and the archived conversation", () => {
  expect(selectionTotals({ rows: [], bytes: 0, files: 0 }, {})).toEqual({ bytes: 0, files: 0 });
  expect(selectionTotals({ rows, bytes: 101, files: 11, reserved: { bytes: 40, files: 2 } }, { "work/cache": false })).toEqual({ bytes: 81, files: 7 });
});
