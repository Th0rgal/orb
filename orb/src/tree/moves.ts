import { createSignal } from "solid-js";
import { bumpProjects, connectionVersion, getApiUrl, type Mission } from "../api";
import { copyText } from "../clipboard";
import { makeCutMission, moveMissions, planMissionMoves, readCutMission } from "../missionMove";

/**
 * Cut/paste and drag-move of conversations between projects and folders in the sidebar.
 * A multi-selection move uses `pendingMoves`; a single one goes through the
 * clipboard (`makeCutMission`) so it also works across windows while keeping an
 * in-memory fallback when WebKit refuses async clipboard writes.
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
  const beginMove = (id: string, clipboardData?: DataTransfer | null) => {
    if (moving) return;
    const text = makeCutMission(id);
    cutClipboard = text; consumedCut = ""; setCutId(id); deps.setActionError(null);
    if (clipboardData) { clipboardData.setData("text/plain", text); return; }
    void copyText(text).catch(() => {});
  };
  const moveDirect = (ids: string[], slug: string, path: string) => {
    if (moving || !ids.length) return;
    moving = true;
    const version = connectionVersion();
    if (ids.some(id => id === cutId() || pendingMoves().includes(id))) {
      setPendingMoves([]); setCutId(null); cutClipboard = "";
    }
    deps.setActionError(null);
    deps.revealDestination(slug, path);
    void run(ids, slug, path, version, () => {}).finally(() => { moving = false; });
  };
  /** `clipboardText` is what Cmd+V / onPaste already read; without it the in-app cut is used. */
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
      let clipboard = clipboardText || cutClipboard;
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
    const sourceSlugs = new Set<string>();
    for (const step of plan) {
      if (!failedIds.has(step.id)) {
        deps.leaveProjects(step.id, slug);
        if (step.from && step.from !== slug) sourceSlugs.add(step.from);
      }
    }
    for (const src of sourceSlugs) void deps.loadMissions(src);
    done(ids.filter(id => failedIds.has(id)));
    // Each failure already returned its row and showed an inline toast
    // (moves.ts); the failed rows stay cut so the user can retry.
    bumpProjects();
  }
  return {
    cutId, setCutId, pendingMoves, setPendingMoves, beginMove, moveDirect, pasteMission,
    isMoving: () => moving, hasCutClipboard: () => !!cutClipboard,
  };
}
