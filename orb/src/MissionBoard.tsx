import { For, Show, createEffect, createSignal, on, onCleanup } from "solid-js";
import { createStore, reconcile } from "solid-js/store";
import { Portal } from "solid-js/web";
import { Popover } from "./Popover";
import { connectionVersion, getMissionBoard, getProjectBoard, getProjectBoards, isConnected, type MissionBoard, type MissionBoardSummary, type ProjectBoard } from "./api";
import { boardPlacementSnapshot, staleBoardListing, visibleBoards } from "./missionBoard";
import { SettingsCard } from "./SettingsCard";
import "./ProjectBoard.css";

type Hint = { id: string | null };
export function BoardSkeleton() {
  return <div class="project-board-skeleton" role="status" aria-label="Loading board"><span /><span /><span /></div>;
}
export function MissionBoardSection(p: { id: string; project?: string | null; missionHint?: Hint; hash?: string; chrome?: boolean }) {
  const [board, setBoard] = createSignal<MissionBoard | ProjectBoard | null>(null);
  const [loading, setLoading] = createSignal(true);
  const [error, setError] = createSignal(false);
  const [open, setOpen] = createSignal(false);
  let trigger!: HTMLButtonElement;
  let request = 0;
  onCleanup(() => { request++; });
  async function refresh(reset = false) {
    const token = ++request;
    if (reset) { setBoard(null); setLoading(true); }
    try {
      let next: MissionBoard | ProjectBoard | null = await getMissionBoard(p.id);
      if (token !== request) return;
      if (next === null && p.project && !p.chrome) next = await getProjectBoard(p.project);
      if (token !== request) return;
      setBoard(next); setError(false);
    } catch { if (token === request) { setBoard(null); setError(true); } }
    finally { if (token === request) setLoading(false); }
  }
  createEffect(on(() => [p.id, p.project, connectionVersion(), isConnected()] as const, () => {
    request++; setOpen(false); setBoard(null); setError(false); setLoading(false);
    if (isConnected()) void refresh(true);
  }));
  createEffect(on(() => p.hash, () => { if (isConnected()) void refresh(); }, { defer: true }));
  createEffect(on(() => p.missionHint, hint => {
    if (!hint || hint.id === null || hint.id === p.id) void refresh();
  }, { defer: true }));
  const content = () => <SettingsCard title="Mission board"><div class="project-board" aria-busy={loading()} data-testid="mission-board" data-text-sha256={board() && "text_sha256" in board()! ? (board() as MissionBoard).text_sha256 : undefined}>
    <Show when={!loading()} fallback={<BoardSkeleton />}>
      <Show when={!error()} fallback={<p role="alert">Board unreadable. <button class="s-btn" onClick={() => void refresh()}>Retry</button></p>}>
        <Show when={board()?.updated_at}><time dateTime={board()!.updated_at!}>{new Date(board()!.updated_at!).toLocaleString()}</time></Show>
        <Show when={board()?.updated_by_mission_id}><p class="project-board-hint">Writer: {board()!.updated_by_mission_id}</p></Show>
        <Show when={board()?.text} fallback={<p>No board yet</p>}><pre>{board()?.text}</pre></Show>
      </Show>
    </Show>
  </div></SettingsCard>;
  return <Show when={p.chrome} fallback={content()}>
    <Show when={!loading() && !error() && board()?.text && document.getElementById("tb-tools")}>
      {mount => <Portal mount={mount() as HTMLElement}>
        <button ref={trigger} class="s-btn" aria-label="Mission board" aria-expanded={open()} onClick={() => setOpen(!open())}>Board</button>
        <Show when={open()}><Popover label="Mission board" anchor={trigger} width={480} onClose={() => setOpen(false)}>{content()}</Popover></Show>
      </Portal>}
    </Show>
  </Show>;
}

function BoardCard(p: { row: MissionBoardSummary; project: string; missionHint?: Hint; onOpenMission: (id: string) => void }) {
  const [shown, setShown] = createSignal(false);
  let container!: HTMLDivElement;
  createEffect(() => {
    const observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) { setShown(true); observer.disconnect(); } });
    observer.observe(container); onCleanup(() => observer.disconnect());
  });
  return <div ref={container} data-board-mission={p.row.mission_id}>
    <button class="s-btn" onClick={() => p.onOpenMission(p.row.mission_id)}>{p.row.title || p.row.mission_id}</button>
    <span class="project-board-hint">{p.row.status}</span>
    <Show when={shown()} fallback={<div class="project-board"><BoardSkeleton /></div>}>
      <MissionBoardSection id={p.row.mission_id} project={p.project} hash={p.row.text_sha256} missionHint={p.missionHint} />
    </Show>
  </div>;
}

export function ProjectMissionBoards(p: { slug: string; missionHint?: Hint; onOpenMission: (id: string) => void; legacy: () => unknown }) {
  const [rows, setRows] = createStore<{ boards: MissionBoardSummary[] }>({ boards: [] });
  const [loading, setLoading] = createSignal(true), [legacy, setLegacy] = createSignal(false), [error, setError] = createSignal(false);
  let request = 0;
  onCleanup(() => { request++; });
  async function refresh(reset = false) {
    const token = ++request, snapshot = boardPlacementSnapshot();
    if (reset) { setLoading(true); setRows("boards", []); setLegacy(false); }
    try {
      const next = await getProjectBoards(p.slug);
      if (token !== request) return;
      if (staleBoardListing(snapshot, next?.boards ?? [])) { void refresh(); return; }
      setLegacy(next === null); setError(false);
      setRows("boards", reconcile(visibleBoards(next?.boards ?? [], p.slug), { key: "mission_id" }));
    } catch { if (token === request) setError(true); }
    finally { if (token === request) setLoading(false); }
  }
  createEffect(on(() => [p.slug, connectionVersion(), isConnected()] as const, () => { if (isConnected()) void refresh(true); }));
  createEffect(on(() => p.missionHint, () => void refresh(), { defer: true }));
  return <Show when={!legacy()} fallback={p.legacy() as import("solid-js").JSX.Element}>
    <SettingsCard title="Mission boards">
      <Show when={!loading()} fallback={<div class="project-board"><BoardSkeleton /></div>}>
        <Show when={error()}><p role="alert">Boards unreadable. <button class="s-btn" onClick={() => void refresh()}>Retry</button></p></Show>
        <For each={rows.boards} fallback={<p class="project-board-hint">No boards yet</p>}>{row => <BoardCard row={row} project={p.slug} missionHint={p.missionHint} onOpenMission={p.onOpenMission} />}</For>
      </Show>
    </SettingsCard>
  </Show>;
}
