import { afterEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { diagnosticsText, debugSnapshot } from "../src/DebugInfo";
import { log, resetLogForTests } from "../src/log";
import { Settings, ShowLogsButton } from "../src/Settings";

type TauriWindow = { __TAURI__?: { core?: { invoke?: unknown } } };
afterEach(() => { delete (window as TauriWindow).__TAURI__; resetLogForTests(); vi.restoreAllMocks(); });

it("hides Show logs outside the desktop app", () => {
  render(() => <ShowLogsButton />);
  expect(screen.queryByRole("button", { name: "Show logs" })).toBeNull();
});

it("Show logs invokes the native reveal_logs command", async () => {
  const invoke = vi.fn(async () => undefined);
  (window as TauriWindow).__TAURI__ = { core: { invoke } };
  render(() => <ShowLogsButton />);
  fireEvent.click(screen.getByRole("button", { name: "Show logs" }));
  await waitFor(() => expect(invoke).toHaveBeenCalledWith("reveal_logs"));
});

it("diagnostics text lists versions, backend and recent log lines", async () => {
  log.error("queue.tick", "boom", { mission: "m1" });
  const snapshot = await debugSnapshot();
  expect(snapshot.logs.map(e => e.scope)).toContain("queue.tick");
  const text = diagnosticsText({ ...snapshot, version: "1.2.3", build: "abc123", backend: "https://core.example", coreVersion: "0.9.0" });
  expect(text).toContain("Orb 1.2.3 (build abc123)");
  expect(text).toContain("Backend: https://core.example");
  expect(text).toContain("Core: 0.9.0");
  expect(text).toMatch(/ERROR \[queue\.tick\] boom \{"mission":"m1"\}/);
});

it("Settings shows a Debug info panel with the recent log", async () => {
  log.warn("sidebar.load", "slow listing");
  const { container } = render(() => <Settings />);
  const details = [...container.querySelectorAll("details")].find(d => d.textContent?.includes("Debug info"))!;
  details.open = true;
  fireEvent(details, new Event("toggle"));
  await waitFor(() => expect(screen.getByLabelText("Recent log entries").textContent).toContain("[sidebar.load] slow listing"));
  expect(screen.getByRole("button", { name: "Copy diagnostics" })).toBeTruthy();
});
