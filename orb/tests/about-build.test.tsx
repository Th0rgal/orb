import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { api, bumpConnectionVersion, isConnected } from "../src/api";
import { AboutCard, BUNDLE_BUILD, coreBuildInfo, debugSnapshot, diagnosticsText } from "../src/DebugInfo";

vi.mock("../src/api", async () => {
  const { createSignal } = await import("solid-js");
  const [connectionVersion, setVersion] = createSignal(0);
  return {
    api: vi.fn(), isConnected: vi.fn(() => true), getApiUrl: () => "https://core.example",
    connectionVersion, bumpConnectionVersion: () => setVersion(v => v + 1),
  };
});

beforeEach(() => {
  vi.mocked(isConnected).mockReturnValue(true);
  vi.mocked(api).mockResolvedValue({ version: "0.9.0", build: "1349b797f" });
});
afterEach(() => vi.clearAllMocks());

it("shows separate client and server commits using the health endpoint", async () => {
  const { container } = render(() => <AboutCard />);
  expect(screen.getByRole("heading", { name: "About" })).toBeTruthy();
  await screen.findByText("1349b797f");
  const rows = [...container.querySelectorAll(".s-row")];
  expect(rows.find(row => row.textContent?.includes("Client build commit"))?.textContent).toContain(BUNDLE_BUILD);
  expect(rows.find(row => row.textContent?.includes("Server build commit"))?.textContent).toContain("1349b797f");
  expect(api).toHaveBeenCalledWith("/api/health");
  vi.mocked(api).mockResolvedValue({ version: "0.9.0", build: "updated-commit" });
  fireEvent.click(screen.getByRole("button", { name: "Refresh build info" }));
  await screen.findByText("updated-commit");
});

it.each([{}, { build: null }, { build: 123 }, { build: "  " }])("does not substitute the client commit for missing server build %j", async health => {
  vi.mocked(api).mockResolvedValue(health);
  render(() => <AboutCard />);
  await screen.findByText("Unknown");
});

it("handles health failures and lets the user retry", async () => {
  vi.mocked(api).mockRejectedValue(new Error("offline"));
  render(() => <AboutCard />);
  await screen.findByText("Unknown");
  vi.mocked(api).mockResolvedValue({ build: "recovered-commit" });
  fireEvent.click(screen.getByRole("button", { name: "Refresh build info" }));
  await screen.findByText("recovered-commit");
});

it("keeps client build visible offline without requesting health", async () => {
  vi.mocked(isConnected).mockReturnValue(false);
  render(() => <AboutCard />);
  await waitFor(() => expect(screen.queryByLabelText("Loading server build")).toBeNull());
  expect(screen.getByText(BUNDLE_BUILD)).toBeTruthy();
  expect(screen.getByRole("button", { name: "Refresh build info" }).hasAttribute("disabled")).toBe(true);
  expect(api).not.toHaveBeenCalled();
  expect(await coreBuildInfo()).toEqual({ version: null, build: null });
});

it("hides the old server commit while a new connection is loading and ignores its late response", async () => {
  let resolveOld!: (value: unknown) => void;
  vi.mocked(api).mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve; }));
  render(() => <AboutCard />);
  bumpConnectionVersion();
  await screen.findByText("1349b797f");
  resolveOld({ build: "old-server" });
  await Promise.resolve();
  expect(screen.queryByText("old-server")).toBeNull();
  let resolveNew!: (value: unknown) => void;
  vi.mocked(api).mockImplementationOnce(() => new Promise(resolve => { resolveNew = resolve; }));
  bumpConnectionVersion();
  expect(screen.queryByText("1349b797f")).toBeNull();
  expect(screen.getByLabelText("Loading server build")).toBeTruthy();
  resolveNew({ build: "new-server" });
  await screen.findByText("new-server");
});

it("includes the server build in copied diagnostics independently of the client build", async () => {
  const snapshot = await debugSnapshot();
  expect(snapshot.coreBuild).toBe("1349b797f");
  expect(diagnosticsText(snapshot)).toContain("Core: 0.9.0 (build 1349b797f)");
  expect(diagnosticsText(snapshot)).toContain(`(build ${BUNDLE_BUILD})`);
});
