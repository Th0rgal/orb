import { batch, createMemo, createSignal } from "solid-js";
import { visibleTree, type TreeRow } from "../treeModel";
import type { Node, RowData } from "./TreeView";

/** Missions whose deletion is in flight, shared with the rest of the app. */
const [deletingIds, setDeletingIds] = createSignal<ReadonlySet<string>>(new Set());
export { deletingIds, setDeletingIds };
export const isMissionDeleting = (id: string): boolean => deletingIds().has(id);

/** Rows that take part in click / shift-click / cmd-click selection. */
export function isSelectableRow(row: TreeRow<RowData>, deleting: ReadonlySet<string> = deletingIds()): boolean {
  const d = row.data;
  if (d.kind === "mission") return !!d.mission && !deleting.has(d.mission.id);
  if (d.kind === "cron") return !d.controller && !!d.job?.id;
  return d.kind === "file" || d.kind === "folder";
}

/**
 * Multi-selection state of the projects sidebar tree. Tree ids are `m:<id>`
 * (missions), `pf:<slug>:<path>` (files/folders) and `pc:<slug>:<id>` (crons).
 * `visibleNodes` returns the nodes currently rendered, in order, for range selection.
 */
export function createTreeSelection(deps: { visibleNodes: () => Node[] }) {
  const [selectedTreeIds, setSelectedTreeIds] = createSignal<string[]>([]);
  const selectedAgents = createMemo(() => selectedTreeIds().filter(id => id.startsWith("m:")).map(id => id.slice(2)));
  const setSelectedAgents = (next: string[] | ((prev: string[]) => string[])) => {
    setSelectedTreeIds(prev => {
      const currentMissions = prev.filter(id => id.startsWith("m:")).map(id => id.slice(2));
      const updated = typeof next === "function" ? next(currentMissions) : next;
      return updated.map(id => `m:${id}`);
    });
  };
  const [selectionActive, setSelectionActive] = createSignal(false);
  const selectedTreeSet = createMemo(() => new Set(selectedTreeIds()));
  const selectedRowIds = createMemo(() => selectionActive() ? selectedTreeSet() : undefined);
  let anchor: string | null = null;
  const selectionAnchor = () => anchor;
  const setSelectionAnchor = (id: string | null) => { anchor = id; };
  const clickSelectableRow = (e: MouseEvent, treeId: string, onPlainClick: () => void) => batch(() => {
    if (treeId.startsWith("m:") && deletingIds().has(treeId.slice(2))) return;
    setSelectionActive(true);
    const deleting = deletingIds();
    const anchorValid = anchor && (!anchor.startsWith("m:") || !deleting.has(anchor.slice(2)));
    if (e.shiftKey && anchorValid) {
      const visible = visibleTree(deps.visibleNodes())
        .filter(row => isSelectableRow(row, deleting))
        .map(row => row.id);
      const a = visible.indexOf(anchor!), b = visible.indexOf(treeId);
      if (a >= 0 && b >= 0) {
        const range = visible.slice(Math.min(a, b), Math.max(a, b) + 1);
        const kept = selectedTreeIds().filter(x => !x.startsWith("m:") || !deleting.has(x.slice(2)));
        setSelectedTreeIds(e.metaKey || e.ctrlKey ? [...new Set([...kept, ...range])] : range);
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      setSelectedTreeIds(ids => ids.includes(treeId) ? ids.filter(x => x !== treeId) : [...ids, treeId]);
      anchor = treeId;
    } else {
      setSelectedTreeIds([treeId]); anchor = treeId; onPlainClick();
    }
  });
  /** Mission ids an action on `id` applies to: the selection if it holds `id`, else just `id`. */
  const selectedFor = (id: string) => {
    const deleting = deletingIds();
    const current = selectedAgents().filter(x => !deleting.has(x));
    return current.includes(id) ? current : (deleting.has(id) ? [] : [id]);
  };
  const selectedTreeFor = (treeId: string) => {
    const deleting = deletingIds();
    const current = selectedTreeIds().filter(x => !x.startsWith("m:") || !deleting.has(x.slice(2)));
    return current.includes(treeId) ? current : (treeId.startsWith("m:") && deleting.has(treeId.slice(2)) ? [] : [treeId]);
  };
  return {
    selectedTreeIds, setSelectedTreeIds, selectedAgents, setSelectedAgents,
    selectionActive, setSelectionActive, selectedTreeSet, selectedRowIds,
    selectionAnchor, setSelectionAnchor, clickSelectableRow, selectedFor, selectedTreeFor,
  };
}
