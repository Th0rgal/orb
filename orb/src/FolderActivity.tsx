import { Show } from "solid-js";
import { normalizeMissionFolder, type Mission } from "./api";
import { localRunActive } from "./localAgents";
import { missionStatusPresentation } from "./MissionGlyph";
import { pendingMissionInteraction } from "./missionAttention";
import { missionActivity, presentedStatus } from "./missionStatus";
import * as Icon from "./sidebarIcons";

/** Index every ancestor once, so collapsed folders need no additional requests. */
export function folderActivity(missions: Mission[], running = (m: Mission) => {
  const effective = presentedStatus(m, missionActivity(m, [], { localRun: localRunActive(m.id) }));
  return missionStatusPresentation(effective, pendingMissionInteraction(m.id)).tone === "running";
}) {
  const counts = new Map<string, Map<string, number>>();
  const seen = new Set<string>();
  for (const mission of missions) {
    if (seen.has(mission.id)) continue;
    seen.add(mission.id);
    if (!mission.project || !running(mission)) continue;
    let project = counts.get(mission.project);
    if (!project) counts.set(mission.project, project = new Map());
    const path = normalizeMissionFolder(mission.folder);
    const parts = path.split("/").filter(Boolean);
    for (let depth = 0; depth <= parts.length; depth++) {
      const parent = parts.slice(0, depth).join("/");
      project.set(parent, (project.get(parent) ?? 0) + 1);
    }
  }
  return counts;
}

export function FolderActivityIcon(p: { expanded?: boolean; color?: string; count: number; scheduled?: number }) {
  const label = () => `${p.count} ${p.count === 1 ? "agent" : "agents"} running inside`;
  return <span class="row-ico folder-activity-icon" style={{ color: p.color ?? "var(--fg-3)" }}>
    <Show when={p.expanded} fallback={<Icon.Folder />}><Icon.FolderOpen /></Show>
    <Show when={p.count > 0}><span class="folder-activity-mark" role="img" aria-label={label()} title={label()}>
      <Icon.LoaderCircle size={10} class="mission-status-spin" />
    </span></Show>
    <Show when={!p.count && p.scheduled}><span class="folder-activity-mark" role="img" aria-label={`${p.scheduled} scheduled wake-ups inside`} title={`${p.scheduled} scheduled wake-ups inside`}><Icon.WakeClock size={10} /></span></Show>
  </span>;
}
