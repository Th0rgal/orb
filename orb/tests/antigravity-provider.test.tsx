import { render, fireEvent, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { AntigravityProvider } from "../src/AntigravityProvider";
import * as api from "../src/api";
import { codingPlanWindows, effectiveProviderStatus, quotaExhaustedLabel, usageWindows } from "../src/providerUsage";
afterEach(() => vi.restoreAllMocks());
const node = (id: string, extra: Partial<api.RemoteNodeView> = {}) => ({ id, status: "online", cordoned: false, ...extra }) as api.RemoteNodeView;

it("checks every machine with the one sign-in and lists where it runs", async () => {
  vi.spyOn(api, "getRemoteNodes").mockResolvedValue({ enabled: true, nodes: [node("ashur"), node("nippur"), node("off", { status: "offline" }), node("held", { cordoned: true })] });
  const discovery = vi.spyOn(api, "listNodeAntigravityModels").mockImplementation(async id => {
    if (id === "nippur") throw new Error("unavailable");
    return [["agy-demo", "Gemini 4 Argon"]];
  });
  const ui = render(() => <AntigravityProvider />);
  await waitFor(() => expect(ui.getByRole("status").textContent).toBe("Available on Core, ashur"));
  expect(ui.getByText("nippur unavailable")).toBeTruthy();
  expect(ui.queryByLabelText("Antigravity machine")).toBeNull();
  expect(discovery.mock.calls.map(c => c[0]).sort()).toEqual(["ashur", "core", "nippur"]);
  fireEvent.click(ui.getByRole("button", { name: /1 model available/ }));
  expect(ui.getByRole("list", { name: "Antigravity models" }).textContent).toContain("Gemini 4 Argon");
});

it("retries a single machine without rechecking the others", async () => {
  vi.spyOn(api, "getRemoteNodes").mockResolvedValue({ enabled: true, nodes: [node("nippur")] });
  const discovery = vi.spyOn(api, "listNodeAntigravityModels").mockImplementation(async id => {
    if (id === "nippur") throw new Error("unavailable");
    return [["agy-demo", "Gemini 4 Argon"]];
  });
  const ui = render(() => <AntigravityProvider />);
  await waitFor(() => expect(ui.getByText("nippur unavailable")).toBeTruthy());
  discovery.mockResolvedValueOnce([["agy-demo", "Gemini 4 Argon"]]);
  fireEvent.click(ui.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(ui.getByRole("status").textContent).toBe("Available on Core, nippur"));
  expect(discovery.mock.calls.filter(c => c[0] === "core")).toHaveLength(1);
});

it("keeps Core when the machine inventory fails and reloads on refresh", async () => {
  vi.spyOn(api, "getRemoteNodes").mockRejectedValueOnce(new Error("offline")).mockResolvedValue({ enabled: true, nodes: [node("new-node")] });
  vi.spyOn(api, "listNodeAntigravityModels").mockResolvedValue([["m", "Model"]]);
  const ui = render(() => <AntigravityProvider />);
  await waitFor(() => expect(ui.getByRole("status").textContent).toBe("Available on Core"));
  window.dispatchEvent(new Event("orb:providers-refresh"));
  await waitFor(() => expect(ui.getByRole("status").textContent).toBe("Available on Core, new-node"));
});

it("ignores late answers from a previous connection", async () => {
  let finish!: (rows: [string, string][]) => void;
  vi.spyOn(api, "getRemoteNodes").mockResolvedValue({ enabled: true, nodes: [] });
  const discovery = vi.spyOn(api, "listNodeAntigravityModels").mockReturnValueOnce(new Promise(resolve => { finish = resolve; }));
  const ui = render(() => <AntigravityProvider />);
  discovery.mockResolvedValue([]);
  api.bumpConnectionVersion(value => value + 1);
  await waitFor(() => expect(ui.getByRole("status").textContent).toBe("Not available on any machine"));
  finish([["late", "Late model"]]);
  await Promise.resolve();
  expect(ui.queryByText(/model available/)).toBeNull();
});

it("maps Google quota windows onto the plan bars", () => {
  const windows = codingPlanWindows({ provider_type: "antigravity", antigravity_windows: [{ label: "Claude", used_percent: 60, reset_at: 1_800_000_000 }, { label: "Gemini Pro", used_percent: 0 }] } as api.ProviderUsage);
  expect(windows).toEqual([{ label: "Claude", used: 0.6, reset: 1_800_000_000 }, { label: "Gemini Pro", used: 0, reset: undefined }]);
});

it("shows an exhausted Gemini group next to Claude & GPT", () => {
  const usage = { provider_type: "antigravity", antigravity_windows: [{ label: "Claude & GPT · 5h", used_percent: 0 }, { label: "Claude & GPT · Weekly", used_percent: 0 }, { label: "Gemini · 5h", used_percent: 100, reset_at: 1_792_835_511 }] } as api.ProviderUsage;
  expect(codingPlanWindows(usage).map(w => w.label)).toContain("Gemini · 5h");
  expect(quotaExhaustedLabel(usageWindows(usage))).toMatch(/Gemini/);
});

it("flags an account Google has not verified", () => {
  const account = { provider_type: "antigravity", enabled: true, status: { type: "connected" } } as unknown as api.AIProvider;
  expect(effectiveProviderStatus(account, { provider_type: "antigravity", status: "needs_verification" } as api.ProviderUsage)).toBe("needs_verification");
});
