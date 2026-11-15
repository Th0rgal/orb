import { Show, createEffect, createSignal, on, onCleanup } from "solid-js";
import { connectionVersion, getMission, getProject, getProjectBoard, isClientPlacement, isConnected, setProjectControllerMission, type Mission, type ProjectBoard } from "./api";
import { displayTitle } from "./goal";
import { SettingsCard, SettingsRow } from "./SettingsCard";
import { SteerComposer } from "./SteerComposer";
import "./ProjectBoard.css";

export function ProjectBoardSection(p: { slug: string; selectedMission?: Mission | null; missionHint?: { id: string | null }; onOpenMission: (id: string) => void }) {
  const [supported, setSupported] = createSignal(false);
  const [loading, setLoading] = createSignal(true);
  const [board, setBoard] = createSignal<ProjectBoard | null>(null);
  const [controllerId, setControllerId] = createSignal<string | null>(null);
  const [controller, setController] = createSignal<Mission | null>(null);
  const [sending, setSending] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  let attemptedController: string | null = null;
  const [error, setError] = createSignal<string | null>(null);
  let generation = 0, boardRequest = 0, missionRequest = 0;
  const valid = (gen: number) => gen === generation;
  onCleanup(() => { generation++; });

  const refreshBoard = async (gen: number) => {
    const request = ++boardRequest;
    try {
      const next = await getProjectBoard(p.slug);
      if (!valid(gen) || request !== boardRequest) return;
      setBoard(next);
      const id = next?.controller_mission_id;
      if ((id === null || typeof id === "string") && id !== controllerId()) {
        setControllerId(id); setController(null);
        if (id) await refreshController(id, gen);
      }
    }
    catch { /* Background refresh preserves the last board without a toast. */ }
  };
  const refreshController = async (id: string, gen: number, refreshOnChange = false) => {
    const request = ++missionRequest;
    try {
      const next = await getMission(id, { fresh: true, includeHistory: false });
      if (!valid(gen) || request !== missionRequest || controllerId() !== id) return;
      const changed = controller()?.status !== next.status;
      setController(next);
      if (refreshOnChange && changed) await refreshBoard(gen);
    } catch { /* The mission may be unavailable to this viewer. */ }
  };
  createEffect(on(() => [p.slug, connectionVersion(), isConnected()] as const, async () => {
    const gen = ++generation;
    setBusy(false); setSupported(false); setLoading(true); setBoard(null); setControllerId(null); setController(null); setError(null);
    if (!isConnected()) { setLoading(false); return; }
    try {
      const project = await getProject(p.slug);
      if (!valid(gen) || !project) return;
      setSupported(true); setControllerId(project.controller_mission_id ?? null);
      await Promise.all([refreshBoard(gen), project.controller_mission_id ? refreshController(project.controller_mission_id, gen) : Promise.resolve()]);
    } catch { /* An older or unavailable Core leaves this optional section quiet. */ }
    finally { if (valid(gen)) setLoading(false); }
  }));
  // Reuse the app's foreground presentation stream; only a status transition refetches the board.
  createEffect(on(() => p.missionHint, hint => {
    const id = controllerId();
    if (hint?.id === null) {
      void refreshBoard(generation);
      if (id) void refreshController(id, generation);
    } else if (id && hint?.id === id) void refreshController(id, generation, true);
  }, { defer: true }));
  const candidate = () => p.selectedMission?.project === p.slug ? p.selectedMission : null;
  const assign = async (id: string | null, replacing?: string) => {
    if (busy() || (sending() && replacing !== controllerId())) return;
    if (replacing && replacing !== controllerId()) return;
    const gen = generation;
    attemptedController = id;
    // A board read started before this write cannot restore the previous controller.
    boardRequest++;
    setBusy(true); setError(null);
    try {
      if (!await setProjectControllerMission(p.slug, id)) { if (valid(gen)) setSupported(false); return; }
      if (!valid(gen)) return;
      setControllerId(id); setController(null);
      if (id) await refreshController(id, gen);
      await refreshBoard(gen);
    } catch (e) { if (valid(gen)) setError(e instanceof Error ? e.message : String(e)); }
    finally { if (valid(gen)) setBusy(false); }
  };
  return <Show when={loading() || supported()}>
    <SettingsCard title="Controller" class="project-controller">
      <SettingsRow stack title="Controller" desc={loading() ? "Loading controller…" : controllerId() ? controller()?.status.replaceAll("_", " ") : "No controller"}>
        <Show when={controllerId()}>{id => <button class="s-btn" onClick={() => p.onOpenMission(id())}>{displayTitle(controller()?.title) || id()}</button>}</Show>
        <button class="s-btn" disabled={loading() || busy() || sending() || isClientPlacement(candidate()) || !candidate() || candidate()?.id === controllerId()} onClick={() => void assign(candidate()!.id)}>Use selected mission</button>
        <button class="s-btn" disabled={loading() || busy() || sending() || !controllerId()} onClick={() => void assign(null)}>Clear</button>
      </SettingsRow>
      <p class="project-board-hint">{isClientPlacement(candidate()) ? "Choose a Core or remote mission as controller. Local missions run on their originating computer." : !candidate() && !loading() ? "Open a mission in this project, then return here to set it as controller." : "\u00a0"}</p>
      <Show when={error()}><p class="project-board-error" role="alert">{error()} <button class="s-btn" disabled={busy()} onClick={() => void assign(attemptedController)}>Retry</button></p></Show>
      <SteerComposer missionId={controllerId()} disabled={busy() || isClientPlacement(controller())}
        hint={isClientPlacement(controller()) ? "Open this mission on the computer that started it to send a message." : undefined}
        onBusyChange={setSending} onReplacement={(id, previousId) => assign(id, previousId)} />
    </SettingsCard>
    <Show when={loading() || board()}><SettingsCard title="Board">
      <div class="project-board" aria-busy={loading()}>
        <Show when={!loading()} fallback={<div class="project-board-skeleton" role="status" aria-label="Loading board"><span /><span /><span /></div>}>
          <Show when={board()}>{value => <><Show when={value().updated_at}><time dateTime={value().updated_at!}>{new Date(value().updated_at!).toLocaleString()}</time></Show><pre>{value().text}</pre></>}</Show>
        </Show>
      </div>
    </SettingsCard></Show>
  </Show>;
}
