import { createSignal, For } from "solid-js";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection } from "../src/api";
import { CloudConversation } from "../src/CloudAgents";
import { CloudProviders } from "../src/CloudProviders";
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

  it("centers across the full app window (including over the sidebar) and lifts above any overlapping bottom composer", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 900 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 900 });

    const sidebar = document.createElement("aside");
    sidebar.className = "sidebar";
    sidebar.getBoundingClientRect = () => rect(0, 0, 240, 900);

    const main = document.createElement("main");
    main.className = "main";
    main.getBoundingClientRect = () => rect(240, 35, 700, 900);

    const dock = document.createElement("div");
    dock.className = "dock";
    const composer = document.createElement("div");
    composer.className = "composer";
    composer.getBoundingClientRect = () => rect(274, 818, 666, 884);
    dock.append(composer);
    main.append(dock);

    const filePanel = document.createElement("aside");
    filePanel.className = "file-panel";
    filePanel.getBoundingClientRect = () => rect(700, 35, 900, 900);

    document.body.append(sidebar, main, filePanel);
    try {
      notify({ key: "approval-queue", kind: "info", variant: "secret", title: "Touch ID required" });
      window.dispatchEvent(new Event("resize"));
      const toaster = document.querySelector<HTMLElement>(".toaster")!;
      // Window spans 0..900 -> exact center is 450px (580px wide spans 160..740, overlapping sidebar 0..240).
      expect(toaster.style.left).toBe("450px");
      expect(toaster.style.width).toBe("580px");
      // Overlaps the docked composer at top=818 -> lifts to 900 - 818 + 12 = 94px.
      expect(toaster.style.bottom).toBe("94px");
    } finally {
      sidebar.remove();
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

  it("keeps keyed background ErrorToast owners suppressed across cloned error maps", () => {
    const [errors, setErrors] = createSignal<Record<string, string>>({ health: "503 Service Unavailable" });
    render(() => (
      <For each={Object.keys(errors())}>
        {key => <ErrorToast error={errors()[key] ? `${key}: ${errors()[key]}` : null} title="Couldn’t load routing settings" background />}
      </For>
    ));

    expect(screen.getByRole("alert").textContent).toContain("health: 503 Service Unavailable");
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByRole("alert")).toBeNull();

    // Next poll clones the errors object while keeping the same key and failure.
    setErrors(prev => ({ ...prev }));
    expect(screen.queryByRole("alert")).toBeNull();

    // Recovery deletes the key; a subsequent failure surfaces again.
    setErrors({});
    setErrors({ health: "503 Service Unavailable" });
    expect(screen.getByRole("alert").textContent).toContain("health: 503 Service Unavailable");
  });

  it("resets CloudProviders background suppression on manual orb:providers-refresh while keeping polls quiet", async () => {
    vi.useFakeTimers();
    setConnection("https://test.invalid", "tok");
    const fetcher = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      if (String(input).endsWith("/api/cloud/usage")) {
        return new Response(JSON.stringify({ accounts: {} }), { status: 200 });
      }
      throw new Error("Cloud registry offline");
    });
    try {
      render(() => <CloudProviders />);
      await vi.waitFor(() => expect(screen.getByText("Couldn’t load cloud accounts")).toBeTruthy());
      expect(screen.queryByText("No cloud accounts configured.")).toBeNull();

      fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
      expect(screen.queryByRole("alert")).toBeNull();
      expect(screen.queryByText("No cloud accounts configured.")).toBeNull();
      expect(screen.getByText("Cloud accounts could not be loaded.")).toBeTruthy();

      // Background 60s poll stays suppressed when the same failure persists.
      await vi.advanceTimersByTimeAsync(60_000);
      expect(screen.queryByRole("alert")).toBeNull();

      // Manual Refresh button on Inference dispatches orb:providers-refresh -> surfaces the error again.
      window.dispatchEvent(new Event("orb:providers-refresh"));
      await vi.waitFor(() => expect(screen.getByText("Couldn’t load cloud accounts")).toBeTruthy());
    } finally {
      fetcher.mockRestore();
      clearConnection();
      vi.useRealTimers();
    }
  });

  it("suppresses dismissed CloudConversation poll errors across 750ms/2.5s polls while surfacing explicit action failures", async () => {
    vi.useFakeTimers();
    setConnection("https://test.invalid", "tok");
    let failPoll = false;
    const fetcher = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith("/api/cloud/accounts")) {
        return new Response(JSON.stringify([]), { status: 200 });
      }
      if (url.includes("/cloud/artifact")) {
        throw new Error("Artifact storage offline");
      }
      if (failPoll) throw new Error("Gateway down");
      if (url.includes("/cloud")) {
        return new Response(
          JSON.stringify({
            mission_id: "cm-1",
            selection: { provider: "cursor_cloud", account: "acc-1" },
            turns: [{ key: "t1", prompt: "hello", phase: "completed", steps: [], branches: [], artifacts: [{ path: "report.txt" }] }],
          }),
          { status: 200 },
        );
      }
      return new Response(JSON.stringify({ id: "cm-1", title: "Cloud", history: [], created_at: "", updated_at: "" }), { status: 200 });
    });
    try {
      render(() => <CloudConversation id="cm-1" />);
      await vi.waitFor(() => expect(screen.getByRole("button", { name: "Download report.txt" })).toBeTruthy());

      failPoll = true;
      await vi.advanceTimersByTimeAsync(2_500);
      await vi.waitFor(() => expect(screen.getByText("Couldn’t load the conversation")).toBeTruthy());

      fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
      expect(screen.queryByRole("alert")).toBeNull();

      // Subsequent polls stay suppressed.
      await vi.advanceTimersByTimeAsync(5_000);
      expect(screen.queryByRole("alert")).toBeNull();

      // Explicit artifact download failure still surfaces its own toast.
      fireEvent.click(screen.getByRole("button", { name: "Download report.txt" }));
      await vi.waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Artifact storage offline"));
    } finally {
      fetcher.mockRestore();
      clearConnection();
      vi.useRealTimers();
    }
  });
});
