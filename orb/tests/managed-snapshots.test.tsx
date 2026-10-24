import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it } from "vitest";
import { ManagedSnapshots } from "../src/ManagedMachines";
import { isLive, isStopped, recentMachines, snapshotLine, stateLabel, type ManagedMachine, type ManagedSnapshot } from "../src/managedMachineModel";
afterEach(cleanup);

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
