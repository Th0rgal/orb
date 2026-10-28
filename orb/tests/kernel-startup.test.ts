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
