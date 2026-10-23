import { Show, createContext, createMemo, useContext } from "solid-js";
import * as Ic from "./icons";
import { shallowEqual } from "./poll";
import type { StreamItem } from "./transcriptModel";
import {
  MissionLookupContext, collectFollowUps, machineLabel, machineRef, orchestrationKind, subagentRef, subagentStatusLabel,
  type FollowUps,
} from "./orchestrationModel";

type Tool = Extract<StreamItem, { kind: "tool" }>;

/** Follow-up facts (get_action, get_mission_health…) of the whole transcript, computed once per render. */
export const FollowUpsContext = createContext<() => FollowUps>(() => collectFollowUps([]));

const openMission = (id: string) => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: `m:${id}` }));
/** Refs are rebuilt from the whole transcript on every items update; keep the
 * previous object when nothing it shows changed so the card does not rewrite
 * its title/cost/machine attributes on each streamed token. */
const sameRef = <T extends object>(a: T | null | undefined, b: T | null | undefined) => a === b || (!!a && !!b && shallowEqual(a, b));
const usd = (v: number) => `$${v < 1 ? v.toFixed(4).replace(/0+$/, "").replace(/\.$/, ".00") : v.toFixed(2)}`;

export function SubagentCard(p: { item: Tool }) {
  const follow = useContext(FollowUpsContext);
  const lookup = useContext(MissionLookupContext);
  const ref = createMemo(() => subagentRef(p.item, follow(), lookup), undefined, { equals: sameRef });
  return (
    <Show when={ref()}>
      {r => {
        const machine = createMemo(() => machineLabel(r().nodeId, follow()));
        const meta = () => [r().backend, r().model].filter(Boolean).join(" · ");
        const live = () => r().status === "starting" || r().status === "queued" || r().status === "running";
        return (
          <div class="st-orch st-subagent" data-status={r().status}>
            <div class="st-orch-head">
              <span class="st-tool-glyph" data-kind="agent" aria-hidden="true"><Ic.BranchIcon size={13} /></span>
              <span class="st-orch-kind">Subagent</span>
              <span class="st-orch-title" title={r().title}>{r().title}</span>
              <span class={`st-orch-status ${live() ? "shimmer" : ""}`} data-status={r().status}>{subagentStatusLabel[r().status]}</span>
              <Show when={r().missionId}>
                {id => <button type="button" class="st-orch-open" title="Open subagent" aria-label="Open subagent" onClick={() => openMission(id())}><Ic.ExternalIcon size={12} /></button>}
              </Show>
            </div>
            <Show when={meta() || machine()}>
              <div class="st-orch-meta">
                <Show when={meta()}><span>{meta()}</span></Show>
                <Show when={machine()}><span class="st-orch-machine" title={r().nodeId}><Ic.ComputeNodeIcon size={11} />{machine()}</span></Show>
              </div>
            </Show>
            <Show when={r().error}><div class="st-orch-error">{r().error}</div></Show>
            <Show when={!r().error && r().summary}><div class="st-orch-summary">{r().summary}</div></Show>
          </div>
        );
      }}
    </Show>
  );
}

const machineStateLabel = { requested: "Requested", provisioning: "Provisioning", online: "Online", destroyed: "Destroyed", failed: "Failed" } as const;

export function MachineCard(p: { item: Tool }) {
  const follow = useContext(FollowUpsContext);
  const ref = createMemo(() => machineRef(p.item, follow()), undefined, { equals: sameRef });
  return (
    <Show when={ref()}>
      {r => {
        const name = () => r().name ?? machineLabel(r().nodeId ?? (r().machineId && `managed-${r().machineId}`), follow()) ?? "Machine";
        const lifecycle = () => r().action === "spawn" && r().state === "destroyed" ? "Online → Destroyed" : machineStateLabel[r().state];
        return (
          <div class="st-orch st-machine" data-state={r().state}>
            <div class="st-orch-head">
              <span class="st-tool-glyph" aria-hidden="true"><Ic.ComputeNodeIcon size={13} /></span>
              <span class="st-orch-kind">{r().action === "spawn" ? "Machine" : "Destroy machine"}</span>
              <span class="st-orch-title" title={r().nodeId}>{name()}</span>
              <Show when={r().size && !name().includes(r().size!)}><span class="st-tool-badge">{r().size}</span></Show>
              <span class={`st-orch-status ${r().state === "provisioning" || r().state === "requested" ? "shimmer" : ""}`} data-status={r().state}>{lifecycle()}</span>
              <Show when={r().costUsd !== undefined}><span class="st-orch-cost" title={r().usdPerHour ? `${usd(r().usdPerHour!)}/h` : undefined}>{usd(r().costUsd!)}</span></Show>
            </div>
            <Show when={r().error}><div class="st-orch-error">{r().error}</div></Show>
          </div>
        );
      }}
    </Show>
  );
}

export function OrchestrationCard(p: { item: Tool }) {
  return orchestrationKind(p.item.name) === "subagent" ? <SubagentCard item={p.item} /> : <MachineCard item={p.item} />;
}
