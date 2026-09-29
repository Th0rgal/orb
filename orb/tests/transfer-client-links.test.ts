import { afterEach, expect, it, vi } from "vitest";
const manifest = { bytes: 0, excluded: [], files: [], links: [{ path: "bin/cargo", target: "rustup" }] };
vi.mock("../src/clientRuns", () => ({ machineIdentity: async () => "computer", nativeInvoke: () => async () => manifest }));
vi.mock("../src/localAgents", () => ({ localBinding: () => ({ cwd: "/work" }), refreshLocalAgents: async () => [], rememberBinding: async () => {} }));
import { snapshotTransfer, type TransferAction } from "../src/machineTransfer";

const action: TransferAction = { id: "move", mission_id: "conversation", phase: "preparing", source: { kind: "client", id: "computer" }, destination: { kind: "core" }, backend: "codex", created_at: "now" };
afterEach(() => vi.restoreAllMocks());
const backend = (view: Record<string, unknown>) => {
  const posted: Record<string, unknown>[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (_url, init) => {
    if (!init?.body) return new Response(JSON.stringify({ version: 1, actions: [], destinations: [], ...view }), { status: 200 });
    posted.push(JSON.parse(String(init.body)));
    return new Response(JSON.stringify({ ...action, manifest, phase: "copying" }), { status: 200 });
  });
  return posted;
};
it("does not register a local snapshot with links on a backend that would drop them", async () => {
  const posted = backend({});
  await expect(snapshotTransfer(action)).rejects.toThrow("Update the connected backend to move a workspace containing links");
  expect(posted).toEqual([]);
});
it("registers a local snapshot with links on a backend that carries them", async () => {
  const posted = backend({ features: ["links"] });
  expect((await snapshotTransfer(action)).phase).toBe("copying");
  expect(posted).toMatchObject([{ op: "client_snapshot", manifest }]);
});
