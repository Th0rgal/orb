import { describe, it, expect } from "vitest";
import { dropsSandboxedMetadata } from "../src/SkillDetail";
import { hermesRuntimeLine } from "../src/HermesSettings";
import { latestChecklist } from "../src/workModel";
import { buildTranscript } from "../src/transcriptModel";
import type { StreamEvent } from "../src/stream";

describe("ux quick wins", () => {
  it("flags an import that would drop sandboxed delivery metadata", () => {
    const lib = "---\nname: x\nmetadata:\n  sandboxed:\n    scope: global\n---\nbody";
    expect(dropsSandboxedMetadata(lib, "---\nname: x\n---\nbody")).toBe(true);
    expect(dropsSandboxedMetadata(lib, lib)).toBe(false);
    expect(dropsSandboxedMetadata("---\nname: x\n---\n", "---\nname: x\n---\n")).toBe(false);
  });
  it("reads the runtime fields Core actually returns", () => {
    expect(hermesRuntimeLine({ service_active: true, uses_sandboxed_proxy: true, token_present: true })).toBe("Service: active · Via Core proxy");
    expect(hermesRuntimeLine({ service_active: false, token_present: false })).toBe("Service: stopped · Token missing");
    expect(hermesRuntimeLine({ service_state: "running", api_server_healthy: true })).toBe("Service: running · API: Healthy");
  });
  it("does not fall back to an older all-pending checklist behind a finished unreadable one", () => {
    const call = (id: string, args: unknown): StreamEvent => ({ type: "tool_call", data: { tool_call_id: id, name: "todowrite", args } });
    const done = (id: string): StreamEvent => ({ type: "tool_result", data: { tool_call_id: id, name: "todowrite", result: "ok" } });
    const items = buildTranscript([call("a", { todos: [{ content: "x", status: "pending" }] }), done("a"), call("b", { todos: [{ content: "x", status: "???" }] }), done("b")]);
    expect(latestChecklist(items)).toBeNull();
  });
});
