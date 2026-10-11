import { afterEach, expect, it, vi } from "vitest";
import { copyTransfer, verifyTransfer, activateTransfer, type TransferAction } from "../src/machineTransfer";
import { missionDestination } from "../src/missionLaunch";
const action: TransferAction = { id: "move", mission_id: "conversation", phase: "copying", source: { kind: "core" }, destination: { kind: "node", id: "spark" }, backend: "codex", created_at: "now", manifest: { bytes: 3, excluded: [".env"], files: [{ path: "é.bin", bytes: 3, sha256: "hash", executable: true }] } };
afterEach(() => vi.restoreAllMocks());
it("copies exact blocks, verifies before activation, and retains the mission identity", async () => {
  const calls: Record<string, any>[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    calls.push(body);
    const op = body.operation?.op;
    const response = op === "read" ? { data: "AQID" } : op === "stage" ? { received: {} } : op === "verify" ? { ...action, phase: "verified" } : body.op === "activate" ? { ...action, phase: "activated" } : !init?.body ? { id: action.mission_id, machine_transfer: { ...action, phase: "activated" } } : {};
    return new Response(JSON.stringify(response), { status: 200 });
  });
  const progress = vi.fn();
  const copied = await copyTransfer(action, progress);
  expect(calls.map(c => c.operation.op)).toEqual(["stage", "read", "write"]);
  expect(calls[2].operation).toEqual({ op: "write", path: "é.bin", offset: 0, data: "AQID" });
  expect(progress).toHaveBeenLastCalledWith(3, 3);
  const verified = await verifyTransfer(copied);
  const moved = await activateTransfer(verified);
  expect(moved.id).toBe(action.mission_id);
  expect(calls.findIndex(c => c.operation?.op === "verify")).toBeLessThan(calls.findIndex(c => c.op === "activate"));
  expect(calls.some(c => c.op === "resume" || c.op === "begin")).toBe(false);
});
it("recovers a sealed destination without trying to overwrite it", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ sealed: true, received: {} })));
  await copyTransfer(action, vi.fn());
  expect(fetch).toHaveBeenCalledOnce();
});
it("resumes completed blocks and never activates after cancellation", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ sealed: false, received: {} })));
  await expect(copyTransfer(action, vi.fn(), () => true)).rejects.toThrow("cancelled");
  expect(fetch).toHaveBeenCalledOnce();
});
it("an authoritative move supersedes stale local launch receipts", () => {
  const mission = { id: "conversation", status: "awaiting_user", title: "t", history: [], created_at: "", updated_at: "", machine_transfer: { ...action, phase: "activated" } };
  expect(missionDestination(mission, { nodeId: "local", destination: "This computer", prompt: "hello" })).toBe("spark");
  expect(missionDestination({ ...mission, machine_transfer: { ...action, destination: { kind: "core" } } })).toBe("Core");
});
it("reports missing transfer capability without calling an export or fork endpoint", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("Not found", { status: 404 }));
  const { inspectTransfer } = await import("../src/machineTransfer");
  await expect(inspectTransfer("id")).rejects.toThrow("Update the connected backend");
  expect(fetch).toHaveBeenCalledOnce();
});
it("writes an empty file on resume even when stage reports 0 received bytes", async () => {
  const calls: Record<string, any>[] = [];
  const emptyAction: TransferAction = { ...action, manifest: { bytes: 0, excluded: [], files: [{ path: "empty.txt", bytes: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", executable: false }] } };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    calls.push(body);
    return new Response(JSON.stringify(body.operation?.op === "stage" ? { sealed: false, received: { "empty.txt": 0 } } : { ok: true }), { status: 200 });
  });
  await copyTransfer(emptyAction, vi.fn());
  expect(calls.map(c => c.operation.op)).toEqual(["stage", "write"]);
  expect(calls[1].operation).toEqual({ op: "write", path: "empty.txt", offset: 0, data: "" });
});
