import { describe, it, expect } from "vitest";
import { buildTranscript } from "../src/Transcript";
import type { StreamEvent } from "../src/stream";
import type { StreamItem } from "../src/transcriptModel";
import {
  collectFollowUps, isOrchestrationTool, isSubagentTool, machineLabel, machineRef, orchestrationKind, orchestrationOp, subagentRef, toolPayload,
} from "../src/orchestrationModel";
import fixture from "./fixtures/boat-subagent-3a510e9b.json";

type Tool = Extract<StreamItem, { kind: "tool" }>;
const items = buildTranscript(fixture as StreamEvent[]);
const tools = items.filter((i): i is Tool => i.kind === "tool");
const follow = collectFollowUps(items);

describe("orchestration tool classification", () => {
  it("recognises start_mission across harness and MCP prefixes", () => {
    for (const name of [
      "sandboxed_start_mission", "mcp__sandboxed__start_mission", "mcp__sandboxed-assistant__start_mission",
      "mcp_sandboxed_assistant_start_mission", "functions.sandboxed_start_mission", "sandboxed.start_mission", "start_mission",
    ]) {
      expect(orchestrationOp(name)).toBe("start_mission");
      expect(orchestrationKind(name)).toBe("subagent");
      expect(isSubagentTool(name)).toBe(true);
    }
    expect(orchestrationKind("mcp__sandboxed__spawn_managed_machine")).toBe("machine-spawn");
    expect(orchestrationKind("sandboxed_destroy_managed_machine")).toBe("machine-destroy");
  });
  it("keeps look-alikes and read-only calls in the fold", () => {
    for (const name of ["restart_mission", "sandboxed_get_mission", "sandboxed_get_action", "sandboxed_list_managed_machines", "bash", "read"]) {
      expect(isOrchestrationTool(name)).toBe(false);
    }
    expect(isSubagentTool("Task")).toBe(true);
    expect(isOrchestrationTool("Task")).toBe(false);
  });
  it("unwraps OpenCode, MCP content and error envelopes", () => {
    expect(toolPayload({ error: null, name: "x", output: "{\"accepted\":\"yes\",\"action_id\":\"a\"}" }).value).toMatchObject({ action_id: "a" });
    expect(toolPayload({ content: [{ type: "text", text: "{\"mission_id\":\"m\"}" }] }).value).toMatchObject({ mission_id: "m" });
    expect(toolPayload({ error: "{\"error\":{\"accepted\":\"no\",\"message\":\"Child mission project must match its parent\"}}", output: null }).error)
      .toBe("Child mission project must match its parent");
  });
});

describe("failed spawn action polling", () => {
  it.each([
    [{ error: "provider_at_capacity" }, "provider_at_capacity"],
    [{ error: "provider_at_capacity", message: "No engines available" }, "No engines available"],
    [{ message: "Provider disabled" }, "Provider disabled"],
    [{ reason: "quota_vcpus" }, "quota_vcpus"],
    [{ error: { message: "Pool exhausted" } }, "Pool exhausted"],
    [{}, "Outcome unconfirmed"],
  ])("uses result failure details before the envelope fallback: %j", (result, expected) => {
    const spawn: Tool = { kind: "tool", key: "spawn", name: "sandboxed_spawn_managed_machine", args: { size: "small" }, done: true, result: { action_id: "act" } };
    const poll: Tool = { kind: "tool", key: "poll", name: "sandboxed_get_action", args: { action_id: "act" }, done: true, result: { state: "failed", result, error: "Outcome unconfirmed" } };
    expect(machineRef(spawn, collectFollowUps([spawn, poll]))).toMatchObject({ state: "failed", error: expected });
  });

  it("settles failed actions without a supplied reason", () => {
    const poll: Tool = { kind: "tool", key: "poll", name: "get_action", args: { action_id: "act" }, done: true, result: { state: "failed", result: {} } };
    expect(collectFollowUps([poll]).actions.get("act")?.error).toBe("Failed");
    const envelopeOnly = { ...poll, result: { state: "failed", error: "provider_disabled" } };
    expect(collectFollowUps([envelopeOnly]).actions.get("act")?.error).toBe("provider_disabled");
  });
});

describe("real transcript of mission 3a510e9b (subagent on a boat machine)", () => {
  const subagents = tools.filter(t => orchestrationKind(t.name) === "subagent").map(t => subagentRef(t, follow)!);
  it("links the successful start to child 26e6bbcd with machine, backend and result", () => {
    const ok = subagents.find(s => s.missionId === "26e6bbcd-2e3e-4c61-8839-578dcb978211")!;
    expect(ok).toBeDefined();
    expect(ok).toMatchObject({ native: false, backend: "opencode", model: "builtin/smart", nodeId: "managed-mm4b8tgs9y", status: "done" });
    expect(ok.summary).toContain("Diagonal Sums");
    expect(machineLabel(ok.nodeId, follow)).toBe("xlarge · mm4b8tgs9y");
  });
  it("shows the failed attempts as failed with the Core reason", () => {
    const failed = subagents.filter(s => s.status === "failed");
    expect(failed.length).toBeGreaterThanOrEqual(4);
    expect(failed.map(f => f.error).join("\n")).toContain("REMOTE_MODEL_REQUIRED");
    expect(failed.map(f => f.error).join("\n")).toContain("Child mission project must match its parent");
  });
  it("lets the live mission list override the transcript's last known status", () => {
    const t = tools.find(t => orchestrationKind(t.name) === "subagent" && subagentRef(t, follow)?.missionId)!;
    expect(subagentRef(t, follow, () => ({ status: "failed", title: "Renamed" }))).toMatchObject({ status: "failed", title: "Renamed" });
  });
  it("tracks the machine from spawn to destroyed with its cost", () => {
    const spawns = tools.filter(t => orchestrationKind(t.name) === "machine-spawn").map(t => machineRef(t, follow)!);
    const last = spawns.find(m => m.machineId === "mm4b8tgs9y")!;
    expect(last).toMatchObject({ size: "xlarge", state: "destroyed", nodeId: "managed-mm4b8tgs9y", costUsd: 0.0106 });
    const destroy = machineRef(tools.find(t => orchestrationKind(t.name) === "machine-destroy")!, follow)!;
    expect(destroy).toMatchObject({ action: "destroy", state: "destroyed", machineId: "mm4b8tgs9y" });
  });
  it("resolves async auto-managed start_mission via get_action to running and concrete machine label", () => {
    const autoEvents = buildTranscript([
      {
        type: "tool_call",
        data: {
          tool_call_id: "c-start",
          name: "mcp__sandboxed__start_mission",
          args: {
            title: "R15-EvmEkFk: 7 ek_*/fk_frame_open",
            backend: "opencode",
            model_override: "google/gemini-4-carbon-eap",
            remote_node_id: "auto-managed:boat:xlarge",
            prompt: "prove contracts",
          },
        },
      },
      {
        type: "tool_result",
        data: {
          tool_call_id: "c-start",
          name: "mcp__sandboxed__start_mission",
          result: { content: [{ type: "text", text: JSON.stringify({ accepted: "yes", action_id: "act-1", state: "queued" }) }] },
        },
      },
      {
        type: "tool_call",
        data: { tool_call_id: "c-poll", name: "mcp__sandboxed__get_action", args: { action_id: "act-1" } },
      },
      {
        type: "tool_result",
        data: {
          tool_call_id: "c-poll",
          name: "mcp__sandboxed__get_action",
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({
                action_id: "act-1",
                state: "succeeded",
                result: {
                  mission: {
                    id: "005ca1ac-1111-2222-3333-444455556666",
                    status: "active",
                    title: "R15-EvmEkFk: 7 ek_*/fk_frame_open",
                    backend: "opencode",
                    model_override: "google/gemini-4-carbon-eap",
                    execution: { scope_unit: "remote-node:managed-mmf4ywkaxw" },
                  },
                  managed_machine: {
                    id: "mmf4ywkaxw",
                    node_id: "managed-mmf4ywkaxw",
                    size: "xlarge",
                    state: "online",
                  },
                },
              }),
            }],
          },
        },
      },
    ] as StreamEvent[]);
    const autoFollow = collectFollowUps(autoEvents);
    const startTool = autoEvents.find((i): i is Tool => i.kind === "tool" && orchestrationKind(i.name) === "subagent")!;
    const ref = subagentRef(startTool, autoFollow)!;
    expect(ref).toMatchObject({
      missionId: "005ca1ac-1111-2222-3333-444455556666",
      status: "running",
      nodeId: "managed-mmf4ywkaxw",
    });
    expect(machineLabel(ref.nodeId, autoFollow)).toBe("xlarge · mmf4ywkaxw");
  });
});
