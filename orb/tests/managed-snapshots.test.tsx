import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { applyAuthMeResponse, setConnection } from "../src/api";
import { MachineProvidersCard, ManagedSnapshots } from "../src/ManagedMachines";
import { isLive, isStopped, recentMachines, snapshotLine, stateLabel, type ManagedMachine, type ManagedSnapshot } from "../src/managedMachineModel";
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it("keeps admin personal opt-in separate from the global provider switch", async () => {
  setConnection("https://orb.example", "test");
  applyAuthMeResponse({ auth_mode: "multi_user", user: { id: "admin", username: "admin", role: "admin" } });
  const provider = { provider: "leanci", display_name: "lean.ci", configured: true, enabled: true, supports_snapshots: true, supports_free_stop: false, sizes: [] };
  const calls: { path: string; enabled: boolean }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = String(input);
    if (init?.method === "PUT") calls.push({ path, enabled: JSON.parse(String(init.body)).enabled });
    const body = path.endsWith("/preference") ? { ok: true } : path.endsWith("/providers/leanci") ? { ...provider, enabled: false, user_enabled: true } : {};
    return new Response(JSON.stringify(body), { status: 200 });
  }));
  render(() => <MachineProvidersCard providers={[provider]} inSettings />);
  const personal = screen.getByRole("switch", { name: "Use lean.ci for my missions" });
  const global = screen.getByRole("switch", { name: "Enable lean.ci globally" });
  expect(personal.getAttribute("aria-checked")).toBe("false");
  expect(global.getAttribute("aria-checked")).toBe("true");
  fireEvent.click(personal);
  await waitFor(() => expect(calls).toHaveLength(1));
  expect(calls[0]).toMatchObject({ path: "https://orb.example/api/managed-machines/providers/leanci/preference", enabled: true });
  await waitFor(() => expect(personal.getAttribute("aria-checked")).toBe("true"));
  await waitFor(() => expect(global.hasAttribute("disabled")).toBe(false));
  fireEvent.click(global);
  await waitFor(() => expect(calls).toHaveLength(2));
  expect(calls[1]).toMatchObject({ path: "https://orb.example/api/managed-machines/providers/leanci", enabled: false });
  expect(personal.getAttribute("aria-checked")).toBe("true");
});

const snap = (over: Partial<ManagedSnapshot> = {}): ManagedSnapshot => ({
  name: "orb-snap-lean-warm-ab12", label: "warm", project: "lean", source_machine_id: "mm1", source_size: "large",
  created_at: new Date(Date.now() - 3 * 3600_000).toISOString(), status: "ready", size_bytes: 3.2e9, monthly_usd: 0, ...over,
});

it("treats stopped machines as neither live nor recent", () => {
  const m = { state: "stopped", destroyed_at: null, created_at: new Date().toISOString() } as unknown as ManagedMachine;
  expect(isLive(m)).toBe(false);
  expect(isStopped(m)).toBe(true);
  expect(stateLabel("stopped")).toBe("Stopped");
  expect(recentMachines([m])).toEqual([]);
});

it("describes a snapshot with project, size, age and cost", () => {
  expect(snapshotLine(snap())).toBe("lean · 3.2 GB · saved 3 h ago · included");
  expect(snapshotLine(snap({ monthly_usd: 1.7, last_used_at: new Date().toISOString() }))).toContain("$1.70/month");
});

it("deletes a snapshot optimistically and restores it on failure", async () => {
  let fail = true;
  render(() => <ManagedSnapshots load={async () => ({ snapshots: [snap(), snap({ name: "s2", label: "other", status: "saving" })] })}
    remove={async () => { if (fail) throw new Error("snapshot_in_use"); return { deleted: "x" }; }} />);
  const list = await screen.findByLabelText("Managed snapshots");
  expect(list.textContent).toContain("Saving…");
  fireEvent.click(screen.getByRole("button", { name: "Delete snapshot warm" }));
  fireEvent.click(await screen.findByRole("button", { name: "Delete snapshot" }));
  await waitFor(() => expect(screen.getByText(/Couldn’t delete warm/)).toBeTruthy());
  expect(screen.getByLabelText("Managed snapshots").textContent).toContain("warm");
  fail = false;
  fireEvent.click(screen.getByRole("button", { name: "Delete snapshot warm" }));
  fireEvent.click(await screen.findByRole("button", { name: "Delete snapshot" }));
  await waitFor(() => expect(screen.queryByRole("button", { name: "Delete snapshot warm" })).toBeNull());
});

it("restores the snapshot load error toast when Retry fails again with the same error", async () => {
  let attempts = 0;
  render(() => (
    <ManagedSnapshots
      load={async () => {
        attempts += 1;
        if (attempts < 3) throw new Error("Snapshot store offline");
        return { snapshots: [snap()] };
      }}
    />
  ));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Snapshot store offline"));
  expect(attempts).toBe(1);

  // First Retry fails with the identical error -> toast and Retry control return.
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(attempts).toBe(2));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Snapshot store offline"));

  // Second Retry succeeds -> snapshots render and the error toast clears.
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(attempts).toBe(3));
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  expect(screen.getByLabelText("Managed snapshots").textContent).toContain("warm");
});
