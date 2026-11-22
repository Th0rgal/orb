import { afterEach, expect, it, vi } from "vitest";
import { setConnection } from "../src/api";
import { listManagedMachines } from "../src/managedMachineModel";

afterEach(() => vi.unstubAllGlobals());

it("shares a pending inventory request and reads again once it settles", async () => {
  setConnection("https://core.example", "member");
  let release!: (response: Response) => void;
  const inventory = (enabled: boolean) => Response.json({ enabled, machines: [] });
  const fetch = vi.fn()
    .mockImplementationOnce(() => new Promise<Response>(resolve => { release = resolve; }))
    .mockResolvedValueOnce(inventory(true));
  vi.stubGlobal("fetch", fetch);
  const picker = listManagedMachines();
  const machines = listManagedMachines();
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  release(inventory(false));
  for (const result of await Promise.all([picker, machines])) expect(result?.enabled).toBe(false);
  expect((await listManagedMachines())?.enabled).toBe(true);
  expect(fetch).toHaveBeenCalledTimes(2);
});
