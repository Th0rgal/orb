import { createRoot, createSignal } from "solid-js";
import { describe, expect, it } from "vitest";
import type { Mission } from "../src/api";
import { createTreeSelection, setDeletingIds } from "../src/tree/selection";
import type { Node } from "../src/tree/TreeView";

const mission = (id: string, title = id): Mission => ({
  id,
  title,
  status: "active",
  project: "one",
  tags: [],
  history: [],
  created_at: "",
  updated_at: "",
});

const nodes: Node[] = [
  {
    id: "project:one",
    expanded: true,
    data: { kind: "project", slug: "one", label: "One" },
    children: [
      { id: "m:a", data: { kind: "mission", slug: "one", label: "Mission A", mission: mission("a", "Mission A") } },
      { id: "m:b", data: { kind: "mission", slug: "one", label: "Mission B", mission: mission("b", "Mission B") } },
      { id: "m:c", data: { kind: "mission", slug: "one", label: "Mission C", mission: mission("c", "Mission C") } },
      { id: "pf:one:notes.md", data: { kind: "file", slug: "one", path: "notes.md", label: "notes.md" } },
      { id: "pc:one:cron-1", data: { kind: "cron", slug: "one", label: "Sweep", job: { id: "cron-1", name: "Sweep", schedule: "every 1h", enabled: true, failure_streak: 0 } } },
    ],
  },
];

describe("sidebar selection and transient context menu target", () => {
  it("highlights mission B only while its context menu is open and restores mission A on close", () => {
    createRoot(dispose => {
      setDeletingIds(new Set());
      const [selected, setSelected] = createSignal<string | null>("m:a");
      const [contextTreeId, setContextTreeId] = createSignal<string | null>(null);
      const sel = createTreeSelection({ visibleNodes: () => nodes, selected, contextTreeId });
      sel.syncToCommitted(selected());

      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(false);
      expect(sel.selectedRowIds()).toBeUndefined();

      // Right-click mission B while mission A is open.
      expect(sel.contextSelectRow("m:b")).toEqual(["m:b"]);
      setContextTreeId("m:b");

      expect(sel.selectionActive()).toBe(false);
      expect(sel.isRowActive("m:b")).toBe(true);
      expect(sel.isRowActive("m:a")).toBe(false);
      expect([...(sel.selectedRowIds() ?? [])]).toEqual(["m:b"]);
      expect(sel.selectedFor("b")).toEqual(["b"]);

      // Click "Copy mission ID" (or press Escape): menu closes without navigating.
      setContextTreeId(null);

      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(false);
      expect(sel.selectedRowIds()).toBeUndefined();

      // Switching between context targets B -> C -> close still restores A.
      sel.contextSelectRow("m:b");
      setContextTreeId("m:b");
      sel.contextSelectRow("m:c");
      setContextTreeId("m:c");
      expect(sel.isRowActive("m:c")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(false);
      setContextTreeId(null);
      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:c")).toBe(false);

      // Right-clicking a file or cron while in mission A also restores mission A on close.
      for (const target of ["pf:one:notes.md", "pc:one:cron-1"]) {
        expect(sel.contextSelectRow(target)).toEqual([target]);
        setContextTreeId(target);
        expect(sel.isRowActive(target)).toBe(true);
        expect(sel.isRowActive("m:a")).toBe(false);
        setContextTreeId(null);
        expect(sel.isRowActive("m:a")).toBe(true);
        expect(sel.isRowActive(target)).toBe(false);
      }

      // On New Agent (selected === null), closing the context menu leaves no tree row active.
      setSelected(null);
      sel.syncToCommitted(null);
      sel.contextSelectRow("m:b");
      setContextTreeId("m:b");
      expect(sel.isRowActive("m:b")).toBe(true);
      setContextTreeId(null);
      expect(sel.isRowActive("m:b")).toBe(false);
      expect(sel.selectedRowIds()).toBeUndefined();

      dispose();
    });
  });

  it("preserves an active multi-selection when right-clicking inside it, and exits when right-clicking outside it", () => {
    createRoot(dispose => {
      setDeletingIds(new Set());
      const [selected] = createSignal<string | null>("m:a");
      const [contextTreeId, setContextTreeId] = createSignal<string | null>(null);
      const sel = createTreeSelection({ visibleNodes: () => nodes, selected, contextTreeId });
      sel.syncToCommitted(selected());

      // Shift-click to select A..B while in A.
      sel.clickSelectableRow({ shiftKey: true }, "m:b", () => {});
      expect(sel.selectionActive()).toBe(true);
      expect(sel.selectedFor("b")).toEqual(["a", "b"]);

      // Right-clicking B (inside the multi-selection) preserves {m:a, m:b} even after menu dismissal.
      expect(sel.contextSelectRow("m:b")).toEqual(["m:a", "m:b"]);
      setContextTreeId("m:b");
      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(true);
      setContextTreeId(null);
      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(true);

      // Right-clicking C (outside {m:a, m:b}) exits multi-selection, highlights C during the menu, and restores A on close.
      expect(sel.contextSelectRow("m:c")).toEqual(["m:c"]);
      setContextTreeId("m:c");
      expect(sel.selectionActive()).toBe(false);
      expect(sel.selectedFor("c")).toEqual(["c"]);
      expect(sel.isRowActive("m:c")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(false);

      setContextTreeId(null);
      expect(sel.isRowActive("m:a")).toBe(true);
      expect(sel.isRowActive("m:b")).toBe(false);
      expect(sel.isRowActive("m:c")).toBe(false);

      dispose();
    });
  });
});
