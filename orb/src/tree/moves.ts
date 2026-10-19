import { createSignal } from "solid-js";
import { bumpProjects, connectionVersion, getApiUrl, type Mission } from "../api";
import { cutMission, moveMission, readCutMission } from "../missionMove";
import { missionMoveKey, previewMove, settleMove } from "../moves";

/**
 * Cut/paste of conversations between projects and folders in the sidebar.
 * A multi-selection move uses `pendingMoves`; a single one goes through the
 * clipboard (`cutMission`) so it also works across windows.
 */
export function createMissionMoves(deps: {
  allKnownMissions: () => Mission[];
  removeRow: (id: string) => void;
  /** Drop `id` from every loaded project listing. */
  dropFromProjects: (id: string) => void;
  revealDestination: (slug: string, path: string) => void;
  loadMissions: (slug: string) => Promise<void>;
  setActionError: (error: string | null) => void;
}) {
  const [cutId, setCutId] = createSignal<string | null>(null);
  const [pendingMoves, setPendingMoves] = createSignal<string[]>([]);
  let moving = false;
  let consumedCut = "";
  let cutClipboard = "";
  const beginMove = (id: string) => {
    if (moving) return;
    const version = connectionVersion();
    void cutMission(id).then(text => {
      if (version !== connectionVersion()) return;
      cutClipboard = text; setCutId(id); deps.setActionError(null);
    }).catch(e => deps.setActionError(String(e)));
  };
  /** `clipboardText` is what Cmd+V already read; without it the in-app cut is used. */
  const pasteMission = (slug: string, path: string, clipboardText?: string) => {
    if (moving) return;
    if (pendingMoves().length) {
      moving = true;
      const ids = [...pendingMoves()], version = connectionVersion();
      // The whole selection shows in its new place at once.
      const from = new Map(ids.map(id => [id, deps.allKnownMissions().find(m => m.id === id)?.project ?? null]));
      for (const id of ids) previewMove(missionMoveKey(id), { kind: "mission", fromProject: from.get(id) ?? null, toProject: slug, path });
      void (async () => {
        const failed: string[] = [];
        for (const id of ids) {
          if (version !== connectionVersion()) { settleMove(missionMoveKey(id)); continue; }
          try {
            await moveMission(id, slug, path, from.get(id) ?? null);
            if (version !== connectionVersion()) break;
            deps.removeRow(id);
          } catch (error) { failed.push(id); deps.setActionError(`Couldn’t move ${id.slice(0, 8)}: ${String(error)}`); }
        }
        if (version !== connectionVersion()) return;
        setPendingMoves(failed); setCutId(failed[0] ?? null);
        deps.revealDestination(slug, path);
        await deps.loadMissions(slug); bumpProjects();
      })().finally(() => { moving = false; });
      return;
    }
    moving = true;
    const version = connectionVersion();
    void (async () => {
      // A second clipboard read in the same gesture is refused by WebKit (NotAllowedError).
      let clipboard = clipboardText ?? cutClipboard;
      let missionId = clipboard === consumedCut ? null : readCutMission(clipboard, getApiUrl());
      if (!missionId && cutClipboard && clipboard !== cutClipboard) { clipboard = cutClipboard; missionId = readCutMission(clipboard, getApiUrl()); }
      if (!missionId || version !== connectionVersion()) return;
      await moveMission(missionId, slug, path, deps.allKnownMissions().find(m => m.id === missionId)?.project ?? null);
      if (version !== connectionVersion()) return;
      consumedCut = clipboard; cutClipboard = "";
      setCutId(null); deps.setActionError(null);
      deps.dropFromProjects(missionId);
      deps.revealDestination(slug, path);
      await deps.loadMissions(slug);
      bumpProjects();
    })().catch(e => deps.setActionError(`Couldn’t move conversation: ${String(e)}`)).finally(() => { moving = false; });
  };
  return {
    cutId, setCutId, pendingMoves, setPendingMoves, beginMove, pasteMission,
    isMoving: () => moving, hasCutClipboard: () => !!cutClipboard,
  };
}
