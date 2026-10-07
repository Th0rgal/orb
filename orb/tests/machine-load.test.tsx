import { afterEach, expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { MachineLoadBadge, byLeastLoaded, firstAvailableNodeId, machineLoad, machineLoadTitle, recordFleet, recordLocalMemory, recordMissions } from "../src/machineLoad";

const GiB = 1024 ** 3;
const mission = (id: string, status: string, extra: Record<string, unknown> = {}) => ({ id, status, history: [], created_at: "", updated_at: "", backend: "claudecode", ...extra }) as any;
const node = (id: string, free: number | null) => ({ id, status: "online", mem_available_bytes: free, mem_total_bytes: 128 * GiB }) as any;
afterEach(() => { recordMissions([]); recordFleet([]); recordLocalMemory(undefined); });

it("counts running agents on the machine that runs them", () => {
  recordMissions([
    mission("a", "active", { remote_job: { job_id: "j", node_id: "ashur", phase: "running" } }),
    mission("b", "running", { remote_node_id: "ashur" }),
    mission("c", "awaiting_user", { remote_node_id: "ashur" }),
    mission("d", "active"),
    mission("e", "active", { tags: ["placement:client"] }),
    mission("f", "active", { backend: "cloud_chatgpt" }),
    mission("g", "completed", { remote_node_id: "babylon" }),
    // Waiting for a runner: no agent process yet.
    mission("h", "pending", { remote_node_id: "babylon" }),
    mission("i", "queued", { remote_node_id: "babylon" }),
    mission("j", "resuming", { remote_node_id: "babylon" }),
  ]);
  expect(machineLoad("ashur").sessions).toBe(2);
  expect(machineLoad("core").sessions).toBe(1);
  expect(machineLoad("client").sessions).toBe(1);
  expect(machineLoad("local").sessions).toBe(1);
  expect(machineLoad("babylon").sessions).toBe(0);
});

it("puts idle machines first, then the one with most free memory", () => {
  recordFleet([node("ashur", 30 * GiB), node("babylon", 60 * GiB), node("nippur", 8 * GiB), node("sepolia", null), node("old-agent", 90 * GiB)]);
  recordMissions([
    mission("a", "active", { remote_node_id: "old-agent" }),
    mission("b", "active", { remote_node_id: "old-agent" }),
    mission("c", "active", { remote_node_id: "nippur" }),
  ]);
  expect(byLeastLoaded(["ashur", "old-agent", "sepolia", "nippur", "babylon"], id => id)).toEqual(["babylon", "ashur", "sepolia", "nippur", "old-agent"]);
});

it("counts the administration entry with the machine it administers", () => {
  recordFleet([node("dgx-spark", 100 * GiB)]);
  recordMissions([mission("a", "active", { remote_node_id: "dgx-spark" })]);
  expect(machineLoad("dgx-spark-admin")).toEqual({ sessions: 1, freeMemory: 100 * GiB });
});

it("shows a quiet count with the agent icon, and nothing for an idle machine", () => {
  recordFleet([node("ashur", 30 * GiB)]);
  recordMissions([mission("a", "active", { remote_node_id: "ashur" }), mission("b", "active", { remote_node_id: "ashur" })]);
  const busy = render(() => <MachineLoadBadge machine="ashur" />);
  expect(busy.container.querySelector(".machine-load")?.textContent).toBe("2×");
  expect(busy.container.querySelector(".machine-load svg")).not.toBeNull();
  expect(machineLoadTitle("ashur")).toBe("2 agents running · 30 GiB of memory free");
  const idle = render(() => <MachineLoadBadge machine="babylon" />);
  expect(idle.container.querySelector(".machine-load")).toBeNull();
  expect(machineLoadTitle("babylon")).toBe("No agent running");
});

it("selects the first online uncordoned non-manual node from the sorted list", () => {
  const nodes = [
    { id: "dgx-spark-admin", status: "online", cordoned: false, labels: ["manual-only"] },
    { id: "babylon", status: "online", cordoned: false, labels: [] },
    { id: "ashur", status: "online", cordoned: false, labels: [] },
    { id: "sepolia", status: "offline", cordoned: false, labels: [] },
  ];
  expect(firstAvailableNodeId(nodes)).toBe("babylon");
  expect(firstAvailableNodeId([nodes[0], nodes[3]])).toBeUndefined();
});
