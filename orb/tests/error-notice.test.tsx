import { render, screen, fireEvent, waitFor } from "@solidjs/testing-library";
import { describe, it, expect, vi } from "vitest";
import { ErrorNotice } from "../src/ErrorNotice";
describe("inline errors", () => {
  it("summarizes disk admission and preserves the backend details", () => {
    const raw="mission needs an estimated 64 GiB scratch plus a 64 GiB emergency floor (128 GiB required), but only 127 GiB is free at /root (filesystem statvfs:7321850625438636562); select a remote node or free space";
    const dismiss=vi.fn();
    render(()=><ErrorNotice error={raw} onDismiss={dismiss} />);
    expect(screen.getByRole("alert").textContent).toContain("Not enough disk space");
    expect(screen.getByText(/127 GiB available/)).toBeTruthy();
    expect(screen.getByText(raw).closest("details")?.open).toBe(false);
    fireEvent.click(screen.getByRole("button",{name:"Dismiss error"}));expect(dismiss).toHaveBeenCalledOnce();
  });
});

it("copies the complete raw error even when the details are folded", async () => {
  const writeText = vi.fn().mockResolvedValue(undefined);
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
  const raw = "Internal error: " + "long backend detail ".repeat(40);
  render(() => <ErrorNotice error={raw} />);
  fireEvent.click(screen.getByRole("button", { name: "Copy error" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Error copied" })).toBeTruthy());
  expect(writeText).toHaveBeenCalledWith(raw);
});
it("shows clipboard failures without claiming success", async () => {
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn().mockRejectedValue(new Error("Permission denied")) } });
  render(() => <ErrorNotice error="Original error" />);
  fireEvent.click(screen.getByRole("button", { name: "Copy error" }));
  await waitFor(() => expect(screen.getByRole("status").textContent).toContain("Permission denied"));
  expect(screen.queryByRole("button", { name: "Error copied" })).toBeNull();
});

describe("provider usage limits", () => {
  const codex = "Remote codex job 4a509fc2-a3a7-4a96-8e6c-04aed3e20cb3 on node 'old-agent' finished with state 'failed' (exit Some(1)); error: command exited with Some(1).\nCLI error: {'message': 'You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 3rd, 2026 6:58 PM.', 'codexErrorInfo': 'usageLimitExceeded', 'additionalDetails': None, 'misalignment': None}\n\ndiagnostics:\n2026-09-28T13:40:28.541097Z ERROR codex_app_server: Codex's Linux sandbox uses bubblewrap";
  it("names the provider, the reset time and links to the usage page instead of a generic failure", async () => {
    const open = vi.fn().mockResolvedValue(undefined);
    vi.doMock("../src/api", () => ({ openExternalUrl: open }));
    render(() => <ErrorNotice error={codex} title="Mission failed" />);
    const alert = screen.getByRole("alert");
    expect(alert.classList.contains("warning")).toBe(true);
    expect(alert.textContent).toContain("Codex usage limit reached");
    expect(alert.textContent).not.toContain("Mission failed");
    expect(alert.textContent).toContain("It resets on Oct 3, 2026 6:58 PM.");
    fireEvent.click(screen.getByRole("button", { name: "View usage" }));
    await waitFor(() => expect(open).toHaveBeenCalledWith("https://chatgpt.com/codex/settings/usage"));
    expect(alert.querySelector("details pre")?.textContent).toBe(codex);
    vi.doUnmock("../src/api");
  });
  it("reads Claude's reset formats and separates transient rate limits", async () => {
    const { describeError } = await import("../src/ErrorNotice");
    expect(describeError("You've hit your limit · resets 9pm")).toMatchObject({ title: "Usage limit reached", message: expect.stringContaining("It resets at 9pm.") });
    expect(describeError("Claude AI usage limit reached|1790600000").title).toBe("Claude usage limit reached");
    expect(describeError("Error: 429 Too Many Requests").title).toBe("The provider is rate-limiting requests");
    expect(describeError("Increased the rate of the limit checker loop.").tone).toBeUndefined();
  });
});
