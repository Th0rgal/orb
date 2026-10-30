import { batch, createMemo, createSignal } from "solid-js";
import { visibleTree, type TreeRow } from "../treeModel";
import { missionIdFromTreeId, type Node, type RowData } from "./TreeView";

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

export function isSelectableAnchorId(id: string | null | undefined): id is string {
  return !!id && (id.startsWith("m:") || id.startsWith("mp:") || id.startsWith("pc:") || id.startsWith("pf:"));
}

/**
 * Multi-selection state of the projects sidebar tree. Tree ids are `m:<id>`
 * (missions), `mp:<slug>:<id>` (cross-project placeholder parents),
 * `pf:<slug>:<path>` (files/folders) and `pc:<slug>:<id>` (crons).
 * `visibleNodes` returns the nodes currently rendered, in order, for range selection.
 */
export function createTreeSelection(deps: {
  visibleNodes: () => Node[];
  selected?: () => string | null;
  contextTreeId?: () => string | null;
}) {
  const [selectedTreeIds, setSelectedTreeIds] = createSignal<string[]>([]);
  const selectedAgents = createMemo(() => [...new Set(selectedTreeIds().map(missionIdFromTreeId).filter((id): id is string => !!id))]);
  const setSelectedAgents = (next: string[] | ((prev: string[]) => string[])) => {
    setSelectedTreeIds(prev => {
      const currentMissions = [...new Set(prev.map(missionIdFromTreeId).filter((id): id is string => !!id))];
      const updated = typeof next === "function" ? next(currentMissions) : next;
      return updated.map(id => `m:${id}`);
    });
  };
  const [selectionActive, setSelectionActive] = createSignal(false);
  const selectedTreeSet = createMemo(() => new Set(selectedTreeIds()));
  const contextId = () => deps.contextTreeId?.() ?? null;
  const selectedRowIds = createMemo<ReadonlySet<string> | undefined>(() => {
    if (selectionActive()) return selectedTreeSet();
    const ctx = contextId();
    return ctx ? new Set([ctx]) : undefined;
  });
  const isRowActive = (treeId: string): boolean => {
    const rows = selectedRowIds();
    return rows ? rows.has(treeId) : (deps.selected?.() ?? null) === treeId;
  };
  let anchor: string | null = null;
  const selectionAnchor = () => anchor;
  const setSelectionAnchor = (id: string | null) => { anchor = id; };
  const syncToCommitted = (committed: string | null = deps.selected?.() ?? null) => batch(() => {
    setSelectionActive(false);
    if (isSelectableAnchorId(committed)) {
      anchor = committed;
      setSelectedTreeIds([committed]);
    } else {
      anchor = null;
      setSelectedTreeIds([]);
    }
  });
  const isDeletingTreeId = (treeId: string, deleting: ReadonlySet<string>) => {
    const mid = missionIdFromTreeId(treeId);
    return !!mid && deleting.has(mid);
  };
  const clickSelectableRow = (e: { shiftKey?: boolean; metaKey?: boolean; ctrlKey?: boolean }, treeId: string, onPlainClick: () => void) => batch(() => {
    if (isDeletingTreeId(treeId, deletingIds())) return;
    const deleting = deletingIds();
    const anchorValid = anchor && !isDeletingTreeId(anchor, deleting);
    if (e.shiftKey && anchorValid) {
      const visible = visibleTree(deps.visibleNodes())
        .filter(row => isSelectableRow(row, deleting))
        .map(row => row.id);
      const a = visible.indexOf(anchor!), b = visible.indexOf(treeId);
      if (a >= 0 && b >= 0) {
        setSelectionActive(true);
        const range = visible.slice(Math.min(a, b), Math.max(a, b) + 1);
        const kept = selectedTreeIds().filter(x => !isDeletingTreeId(x, deleting));
        setSelectedTreeIds(e.metaKey || e.ctrlKey ? [...new Set([...kept, ...range])] : range);
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      setSelectionActive(true);
      setSelectedTreeIds(ids => ids.includes(treeId) ? ids.filter(x => x !== treeId) : [...ids, treeId]);
      anchor = treeId;
    } else {
      setSelectionActive(false);
      setSelectedTreeIds([treeId]); anchor = treeId; onPlainClick();
    }
  });
  /** Prepare selection for a right-click on `treeId`: preserve an active multi-selection
   * containing `treeId`, otherwise reset transient multi-selection to the committed row
   * so closing the context menu restores the open row's highlight. */
  const contextSelectRow = (treeId: string): string[] => {
    const deleting = deletingIds();
    if (isDeletingTreeId(treeId, deleting)) return [];
    if (selectionActive() && selectedTreeSet().has(treeId)) {
      return selectedTreeIds().filter(x => !isDeletingTreeId(x, deleting));
    }
    syncToCommitted();
    return [treeId];
  };
  /** Mission ids an action on `id` applies to: the active selection if it holds `id`, else just `id`. */
  const selectedFor = (id: string) => {
    const deleting = deletingIds();
    if (!selectionActive()) return deleting.has(id) ? [] : [id];
    const current = selectedAgents().filter(x => !deleting.has(x));
    return current.includes(id) ? current : (deleting.has(id) ? [] : [id]);
  };
  const selectedTreeFor = (treeId: string) => {
    const deleting = deletingIds();
    if (!selectionActive()) return isDeletingTreeId(treeId, deleting) ? [] : [treeId];
    const current = selectedTreeIds().filter(x => !isDeletingTreeId(x, deleting));
    return current.includes(treeId) ? current : (isDeletingTreeId(treeId, deleting) ? [] : [treeId]);
  };
  return {
    selectedTreeIds, setSelectedTreeIds, selectedAgents, setSelectedAgents,
    selectionActive, setSelectionActive, selectedTreeSet, selectedRowIds, isRowActive,
    selectionAnchor, setSelectionAnchor, syncToCommitted, clickSelectableRow, contextSelectRow,
    selectedFor, selectedTreeFor,
  };
}
