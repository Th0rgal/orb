import { createSignal } from "solid-js";
import { bumpProjects, connectionVersion, getApiUrl, type Mission } from "../api";
import { cutMission, moveMissions, planMissionMoves, readCutMission } from "../missionMove";

/**
 * Cut/paste of conversations between projects and folders in the sidebar.
 * A multi-selection move uses `pendingMoves`; a single one goes through the
 * clipboard (`cutMission`) so it also works across windows.
 */
export function createMissionMoves(deps: {
  allKnownMissions: () => Mission[];
  /**
   * Drop `id` from the loaded listing of every project except `keep`. A moved
   * mission is not deleted: this never hides it from later listings.
   */
  leaveProjects: (id: string, keep: string) => void;
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
      // No long grayed "cut" state: the rows are at their destination now
      // (moves.ts overlay) and only failures come back.
      setPendingMoves([]); setCutId(null); deps.setActionError(null);
      deps.revealDestination(slug, path);
      void run(ids, slug, path, version, failed => {
        setPendingMoves(failed); setCutId(failed[0] ?? null);
      }).finally(() => { moving = false; });
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
      consumedCut = clipboard; cutClipboard = "";
      setCutId(null); deps.setActionError(null);
      deps.revealDestination(slug, path);
      await run([missionId], slug, path, version, failed => { if (failed.length) { cutClipboard = clipboard; consumedCut = ""; setCutId(missionId); } });
    })().catch(e => deps.setActionError(`Couldn’t move conversation: ${String(e)}`)).finally(() => { moving = false; });
  };
  /** Move `ids` (and the missions they launched) in parallel; `done` gets the failed selection ids. */
  async function run(ids: string[], slug: string, path: string, version: number, done: (failed: string[]) => void) {
    const plan = planMissionMoves(ids, slug, path, deps.allKnownMissions());
    const failures = await moveMissions(plan, slug);
    if (version !== connectionVersion()) return;
    const failedIds = new Set(failures.map(f => f.id));
    // Load the destination before leaving the source, so no row blinks out.
    await deps.loadMissions(slug);
    if (version !== connectionVersion()) return;
    for (const step of plan) if (!failedIds.has(step.id)) deps.leaveProjects(step.id, slug);
    done(ids.filter(id => failedIds.has(id)));
    // Each failure already returned its row and showed an inline toast
    // (moves.ts); the failed rows stay cut so the user can retry.
    bumpProjects();
  }
  return {
    cutId, setCutId, pendingMoves, setPendingMoves, beginMove, pasteMission,
    isMoving: () => moving, hasCutClipboard: () => !!cutClipboard,
  };
}
