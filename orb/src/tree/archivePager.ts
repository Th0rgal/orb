import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import { connectionVersion, isBtwMission, listArchivedMissions, type Mission } from "../api";

/** Page size of `GET` archived missions; a full page means there may be more. */
export const ARCHIVE_PAGE_SIZE = 100;

/**
 * Paginated "Archived" section of the sidebar. `revision` is bumped by the
 * owner whenever local mission state changes, so a stale page is dropped;
 * `archiving` holds optimistic statuses; `deleted` ids are never shown again.
 */
export function createArchivePager(deps: {
  revision: () => number;
  archiving: ReadonlyMap<string, string>;
  deleted: ReadonlySet<string>;
  currentConnection: (version: number) => boolean;
}) {
  const [archivesOpen, setArchivesOpen] = createSignal(false);
  const [archiveExpanded, setArchiveExpanded] = createStore<Record<string, boolean>>({});
  const [archivedMissions, setArchivedMissions] = createSignal<Mission[]>([]);
  const [archivesLoading, setArchivesLoading] = createSignal(false);
  const [archivesError, setArchivesError] = createSignal<string | null>(null);
  const [archivesMore, setArchivesMore] = createSignal(false);
  let offset = 0;
  let loaded = false;
  let request: Promise<void> | null = null;
  const loadArchives = (more = false): Promise<void> => {
    if (archivesLoading()) return request ?? Promise.resolve();
    const version = connectionVersion(), revision = deps.revision();
    setArchivesLoading(true); setArchivesError(null);
    let run: Promise<void> | undefined;
    run = (async () => {
      try {
        const rows = await listArchivedMissions(more ? offset : 0);
        if (!deps.currentConnection(version) || revision !== deps.revision()) return;
        const projected = rows.filter(m => !isBtwMission(m) && !deps.deleted.has(m.id)).map(m => deps.archiving.has(m.id) ? {...m,status:deps.archiving.get(m.id)!} : m);
        setArchivedMissions(previous => { if (!more) return projected; const known = new Set(previous.map(old => old.id)); return [...previous, ...projected.filter(m => !known.has(m.id))]; });
        offset = (more ? offset : 0) + rows.length;
        loaded = true;
        setArchivesMore(rows.length === ARCHIVE_PAGE_SIZE);
      } catch (error) { if (deps.currentConnection(version)) setArchivesError(String(error)); }
      finally {
        if (request === run) request = null;
        if (deps.currentConnection(version)) setArchivesLoading(false);
      }
    })();
    request = run;
    return run;
  };
  /** Rows removed locally shift the next page's offset back. */
  const removeArchived = (removed: ReadonlySet<string>) => setArchivedMissions(rows => {
    if (!rows.some(m => removed.has(m.id))) return rows;
    const next = rows.filter(m => !removed.has(m.id));
    offset = Math.max(0, offset - (rows.length - next.length));
    return next;
  });
  const reset = () => {
    setArchiveExpanded({}); setArchivesOpen(false); setArchivedMissions([]); setArchivesLoading(false); setArchivesError(null); setArchivesMore(false);
    offset = 0; loaded = false; request = null;
  };
  return {
    archivesOpen, setArchivesOpen, archiveExpanded, setArchiveExpanded, archivedMissions, setArchivedMissions,
    archivesLoading, archivesError, archivesMore, archivesLoaded: () => loaded, archivesRequest: () => request,
    loadArchives, removeArchived, reset,
  };
}
