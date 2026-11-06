import { createSignal } from "solid-js";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi } from "vitest";
import { ErrorToast, notify } from "../src/toast";

const rect = (left: number, top: number, right: number, bottom: number): DOMRect => ({
  x: left,
  y: top,
  left,
  top,
  right,
  bottom,
  width: right - left,
  height: bottom - top,
  toJSON: () => ({}),
});

describe("unified workspace ErrorToast & Toaster", () => {
  it("merges duplicate backend reachability errors across views and runs all owners on Retry", async () => {
    const retrySidebar = vi.fn();
    const retryResources = vi.fn();
    const [errA, setErrA] = createSignal<string | null>("TypeError: Failed to fetch");
    const [errB, setErrB] = createSignal<string | null>("NetworkError when attempting to fetch resource.");

    render(() => (
      <>
        <ErrorToast error={errA()} title="Couldn’t load projects" background action={{ label: "Retry", run: retrySidebar }} />
        <ErrorToast error={errB()} title="Couldn’t load resources" background action={{ label: "Retry", run: retryResources }} />
      </>
    ));

    const alerts = screen.getAllByRole("alert");
    expect(alerts).toHaveLength(1);
    expect(alerts[0].textContent).toContain("Can’t reach the backend");

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(retrySidebar).toHaveBeenCalledOnce();
    expect(retryResources).toHaveBeenCalledOnce();

    // Auto-dismisses once both views recover.
    setErrA(null);
    setErrB(null);
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  });

  it("keeps repeated background poll ticks quiet after Dismiss until recovery or a distinct failure", async () => {
    const [pollErr, setPollErr] = createSignal<string | null>("Failed to fetch");
    render(() => <ErrorToast error={pollErr()} background />);

    expect(screen.getByRole("alert").textContent).toContain("Can’t reach the backend");
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByRole("alert")).toBeNull();

    // Another offline poll tick with the same classified error stays quiet.
    setPollErr("TypeError: Load failed");
    expect(screen.queryByRole("alert")).toBeNull();

    // A distinct failure still surfaces immediately.
    setPollErr("HTTP 500: Internal database fault");
    expect(screen.getByRole("alert").textContent).toContain("HTTP 500: Internal database fault");
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByRole("alert")).toBeNull();

    // Healthy poll clears the suppression latch so a later outage notifies again.
    setPollErr(null);
    setPollErr("Failed to fetch");
    expect(screen.getByRole("alert").textContent).toContain("Can’t reach the backend");
  });

  it("surfaces warning tone and external usage links without closing the toast", async () => {
    const open = vi.fn().mockResolvedValue(undefined);
    vi.doMock("../src/api", () => ({ openExternalUrl: open }));
    const codex = "CLI error: {'message': 'You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 3rd, 2026 6:58 PM.', 'codexErrorInfo': 'usageLimitExceeded'}";

    render(() => <ErrorToast error={codex} title="Mission failed" />);
    const alert = screen.getByRole("alert");
    expect(alert.classList.contains("warning")).toBe(true);
    expect(alert.textContent).toContain("Codex usage limit reached");
    expect(alert.querySelector("details pre")?.textContent).toBe(codex);

    fireEvent.click(screen.getByRole("button", { name: "View usage" }));
    await waitFor(() => expect(open).toHaveBeenCalledWith("https://chatgpt.com/codex/settings/usage"));
    // Opening the usage page keeps the toast visible until dismissed.
    expect(screen.getByRole("alert")).toBeTruthy();
    vi.doUnmock("../src/api");
  });

  it("centers across all open workspace panels and lifts above any overlapping bottom composer", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1440 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 900 });

    const main = document.createElement("main");
    main.className = "main";
    main.getBoundingClientRect = () => rect(220, 35, 820, 900);

    const dock = document.createElement("div");
    dock.className = "dock";
    const composer = document.createElement("div");
    composer.className = "composer";
    composer.getBoundingClientRect = () => rect(254, 818, 786, 884);
    dock.append(composer);
    main.append(dock);

    const filePanel = document.createElement("aside");
    filePanel.className = "file-panel";
    filePanel.getBoundingClientRect = () => rect(820, 35, 1440, 900);

    document.body.append(main, filePanel);
    try {
      notify({ key: "approval-queue", kind: "info", variant: "secret", title: "Touch ID required" });
      window.dispatchEvent(new Event("resize"));
      const toaster = document.querySelector<HTMLElement>(".toaster")!;
      // Workspace spans 220..1440 -> exact center is 830px (not just the left 220..820 column).
      expect(toaster.style.left).toBe("830px");
      // Overlaps the docked composer at top=818 -> lifts to 900 - 818 + 12 = 94px.
      expect(toaster.style.bottom).toBe("94px");
    } finally {
      main.remove();
      filePanel.remove();
    }
  });

  it("runs toast actions before dismissing so owner state like Inbox undoItem remains intact", () => {
    let undoItem: { id: string } | null = { id: "mission-1" };
    let reopened: string | null = null;
    const onDismiss = vi.fn(() => {
      undoItem = null;
    });
    notify({
      key: "inbox-undo",
      kind: "info",
      title: "Marked done",
      actions: [{
        label: "Undo",
        run: () => {
          if (!undoItem) return;
          reopened = undoItem.id;
          undoItem = null;
        },
      }],
      onDismiss,
    });

    fireEvent.click(screen.getByRole("button", { name: /Undo/ }));
    expect(reopened).toBe("mission-1");
    expect(onDismiss).not.toHaveBeenCalled();
    expect(screen.queryByRole("status")).toBeNull();
  });
});
