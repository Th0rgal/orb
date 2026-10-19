import { Show } from "solid-js";
import { missionNode, nodeLabel } from "../machines/nodes";
import * as SidebarIcon from "../sidebarIcons";
import type { TreeRow } from "../treeModel";
import type { RowData } from "./TreeView";

/** Known placement only: remote node, then workspace. Never invented. */
export function missionMachine(m: { backend?: string; remote_job?: { node_id?: string } | null; remote_node_id?: string | null; workspace_name?: string | null }): string | undefined {
  if (m.backend?.startsWith("cloud_")) return ({cloud_chatgpt:"ChatGPT",cloud_grok_bot:"Grok Bot",cloud_cursor:"Cursor Cloud",cloud_hermes:"Paloma"} as Record<string,string>)[m.backend];
  const id = missionNode(m) ?? m.workspace_name;
  return id ? nodeLabel(id) : undefined;
}

export type RowTipContent = { title: string; meta: string[] };
export const ROW_TIP_ID = "orb-row-tip";

/** Full title plus known repo/branch/machine lines. Never invented. */
export function rowDetail(title: string, extra: Array<string | undefined | null> = []): RowTipContent {
  return { title, meta: extra.map((part) => part?.trim()).filter((part): part is string => !!part) };
}

/**
 * The id to put on the clipboard for a sidebar agent row: the sandboxed mission
 * UUID exactly as the core stores it. Never the `m:` sidebar routing prefix,
 * never the durable remote job id (`remote_job.job_id`), and never a harness
 * session id — those identify an execution attempt, not the mission the
 * `/api/control/missions/:id` endpoints take.
 */
export function missionCopyId(mission: { id: string }): string {
  return mission.id;
}

/** Where an agent runs: the workspace/machine name behind a server glyph.
 * Per agent, not per project — one project can run on several machines. */
export function MachineBadge(p: { name?: string | null }) {
  return (
    <Show when={p.name}>
      <span class="row-machine" aria-hidden="true">
        <SidebarIcon.Server size={16} />
      </span>
    </Show>
  );
}

export const versionsText = (n: number) => `${n} earlier version${n === 1 ? "" : "s"}`;

/** Count + chevron after a row that launched missions or has earlier versions. */
export function launchedToggle(row: TreeRow<RowData>, d: RowData, deps: { deleting: (id: string) => boolean; setExpanded: (id: string, open: boolean) => void }) {
  return <Show when={d.launched || d.versions}><button class={`launched-toggle ${d.launchedLive ? "live" : ""}`} tabindex={-1} aria-expanded={row.expanded}
    disabled={d.mission ? deps.deleting(d.mission.id) : false}
    aria-label={d.launched ? `${row.expanded ? "Hide" : "Show"} the ${d.launched} mission${d.launched === 1 ? "" : "s"} launched by ${d.label}` : `${row.expanded ? "Hide" : "Show"} ${versionsText(d.versions!)} of ${d.label}`}
    title={[d.launched ? `${d.launched} launched mission${d.launched === 1 ? "" : "s"}${d.launchedLive ? ` · ${d.launchedLive} running` : ""}` : "", d.versions ? versionsText(d.versions) : ""].filter(Boolean).join(" · ")}
    onClick={e => { e.stopPropagation(); deps.setExpanded(row.id, !row.expanded); }}>
    <Show when={d.launched} fallback={<SidebarIcon.Clock size={12} class="launched-history" />}><span class="launched-count">{d.launchedLive ? `${d.launchedLive}/${d.launched}` : d.launched}</span></Show>
    <SidebarIcon.ChevronRight size={12} class={`launched-chevron ${row.expanded ? "open" : ""}`} />
  </button></Show>;
}
