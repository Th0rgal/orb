import { expect, it, vi } from "vitest";
import { startApp } from "../src/startup";

it("does not load the app until the kernel resolves, and retries failure once", async () => {
  const root = document.createElement("div");
  let ready!: () => void;
  const initialize = vi.fn().mockRejectedValueOnce(new Error("network")).mockImplementationOnce(() => new Promise<void>(resolve => { ready = resolve; }));
  const mount = vi.fn(async () => { root.textContent = "Opened"; });
  startApp(root, initialize, mount);
  await vi.waitFor(() => expect(root.querySelector("button")?.textContent).toBe("Retry"));
  expect(mount).not.toHaveBeenCalled();
  root.querySelector("button")!.click();
  expect(root.textContent).toBe("Starting Orb…");
  expect(mount).not.toHaveBeenCalled();
  ready();
  await vi.waitFor(() => expect(mount).toHaveBeenCalledTimes(1));
  expect(initialize).toHaveBeenCalledTimes(2);
  expect(root.textContent).toBe("Opened");
});

it("offers Reload after a mount failure without recreating partial stores", async () => {
  const root = document.createElement("div");
  const initialize = vi.fn(async () => {});
  const mount = vi.fn(async () => { throw new Error("mount"); });
  startApp(root, initialize, mount);
  await vi.waitFor(() => expect(root.querySelector("button")?.textContent).toBe("Reload"));
  expect(root.textContent).toContain("could not open");
  expect(root.textContent).not.toContain("Retry");
  expect(initialize).toHaveBeenCalledTimes(1);
  expect(mount).toHaveBeenCalledTimes(1);
});
