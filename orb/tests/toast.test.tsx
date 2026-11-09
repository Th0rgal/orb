import { createSignal, For } from "solid-js";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection } from "../src/api";
import { CloudConversation } from "../src/CloudAgents";
import { CloudProviders } from "../src/CloudProviders";
import { ErrorToast, StatusToast, notify } from "../src/toast";

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

  it("merges simultaneous TimeoutError cascades across views, strips redundant prefixes, and runs all owners on Retry", async () => {
    const retryArchives = vi.fn();
    const dismissAction = vi.fn();
    const dismissRename = vi.fn();
    const timeoutMsg = "TimeoutError: The server is taking too long to answer. Please retry; nothing was lost.";
    const [errAction, setErrAction] = createSignal<string | null>("The server is taking too long to answer. Please retry; nothing was lost.");
    const [errRename, setErrRename] = createSignal<string | null>(timeoutMsg);
    const [errArchives, setErrArchives] = createSignal<string | null>(`Couldn’t load archives: ${timeoutMsg}`);

    render(() => (
      <>
        <ErrorToast error={errAction()} title="This action couldn’t be completed" onDismiss={() => { dismissAction(); setErrAction(null); }} />
        <ErrorToast error={errRename()} title="Couldn’t rename the project" onDismiss={() => { dismissRename(); setErrRename(null); }} />
        <ErrorToast error={errArchives()} title="Couldn’t load archives" background action={{ label: "Retry", run: retryArchives }} />
      </>
    ));

    const alerts = screen.getAllByRole("alert");
    expect(alerts).toHaveLength(1);
    expect(alerts[0].querySelector(".toast-title")?.textContent).toBe("The server is taking too long to answer");
    expect(alerts[0].querySelector(".toast-message")?.textContent).toBe("Please retry; nothing was lost.");

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(retryArchives).toHaveBeenCalledOnce();

    setErrAction(null);
    setErrRename(null);
    setErrArchives(null);
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  });

  it("strips duplicate caller title and Error prefixes from custom error messages", () => {
    render(() => (
      <ErrorToast
        error="Couldn't load archives: Error: Archive storage unavailable"
        title="Couldn’t load archives"
      />
    ));
    const alert = screen.getByRole("alert");
    expect(alert.querySelector(".toast-title")?.textContent).toBe("Couldn’t load archives");
    expect(alert.querySelector(".toast-message")?.textContent).toBe("Archive storage unavailable");
  });

  it("excludes the left sidebar: straddles open workspace panels at 580px in 2-panel mode and matches the centered column in 1-panel mode", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1440 });
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 900 });

    const sidebar = document.createElement("aside");
    sidebar.className = "sidebar";
    sidebar.getBoundingClientRect = () => rect(0, 0, 220, 900);

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

    document.body.append(sidebar, main, filePanel);
    try {
      notify({ key: "approval-queue", kind: "info", variant: "secret", title: "Touch ID required" });
      window.dispatchEvent(new Event("resize"));
      const toaster = document.querySelector<HTMLElement>(".toaster")!;
      // 2 panels open: workspace spans 220..1440 (excluding 0..220 sidebar) -> center 830px, straddle width 580px.
      expect(toaster.style.left).toBe("830px");
      expect(toaster.style.width).toBe("580px");
      // Overlaps the docked composer at top=818 -> lifts to 900 - 818 + 12 = 94px.
      expect(toaster.style.bottom).toBe("94px");

      // Close side panel -> 1 panel open: main spans 220..1440, centered 748px composer spans 456..1204 (center 830px).
      filePanel.remove();
      main.getBoundingClientRect = () => rect(220, 35, 1440, 900);
      composer.getBoundingClientRect = () => rect(456, 818, 1204, 884);
      window.dispatchEvent(new Event("resize"));
      expect(toaster.style.left).toBe("830px");
      expect(toaster.style.width).toBe("748px");
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

  it("renders StatusToast as role=status (never role=alert) with warning tone, action, and dismiss callback", async () => {
    const onDismiss = vi.fn();
    const onReattach = vi.fn();
    const [msg, setMsg] = createSignal<string | null>("File no longer available — re-attach: notes.pdf");
    render(() => (
      <StatusToast
        tone="warning"
        message={msg()}
        detail="Removed from the message; your text is kept."
        onDismiss={() => {
          onDismiss();
          setMsg(null);
        }}
        action={{ label: "Re-attach", primary: true, run: onReattach }}
      />
    ));

    expect(screen.queryByRole("alert")).toBeNull();
    const status = screen.getByRole("status");
    expect(status.classList.contains("warning")).toBe(true);
    expect(status.textContent).toContain("File no longer available — re-attach: notes.pdf");
    expect(status.textContent).toContain("Removed from the message; your text is kept.");

    fireEvent.click(screen.getByRole("button", { name: "Re-attach" }));
    expect(onReattach).toHaveBeenCalledOnce();
    expect(screen.queryByRole("status")).toBeNull();

    setMsg("Synced Library skills");
    expect(screen.getByRole("status").textContent).toContain("Synced Library skills");
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(onDismiss).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  });

  it("isolates concurrent StatusToast instances showing identical messages", async () => {
    const onDismissMain = vi.fn();
    const onDismissSide = vi.fn();
    const onReattachMain = vi.fn();
    const onReattachSide = vi.fn();
    const [mainMsg, setMainMsg] = createSignal<string | null>("File no longer available — re-attach: notes.pdf");
    const [sideMsg, setSideMsg] = createSignal<string | null>("File no longer available — re-attach: notes.pdf");

    render(() => (
      <>
        <StatusToast
          tone="warning"
          message={mainMsg()}
          onDismiss={() => {
            onDismissMain();
            setMainMsg(null);
          }}
          action={{
            label: "Re-attach",
            primary: true,
            run: () => {
              onReattachMain();
              setMainMsg(null);
            },
          }}
        />
        <StatusToast
          tone="warning"
          message={sideMsg()}
          onDismiss={() => {
            onDismissSide();
            setSideMsg(null);
          }}
          action={{
            label: "Re-attach",
            primary: true,
            run: () => {
              onReattachSide();
              setSideMsg(null);
            },
          }}
        />
      </>
    ));

    expect(screen.getAllByRole("status")).toHaveLength(2);
    const buttons = screen.getAllByRole("button", { name: "Re-attach" });
    expect(buttons).toHaveLength(2);

    fireEvent.click(buttons[0]!);
    expect(onReattachMain).toHaveBeenCalledOnce();
    expect(onReattachSide).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.getAllByRole("status")).toHaveLength(1));

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(onDismissSide).toHaveBeenCalledOnce();
    expect(onDismissMain).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  });

  it("stacks the Copy error button under the Dismiss button inside .toast-corner", () => {
    render(() => <ErrorToast error="HTTP 502: Upstream gateway error" title="Couldn’t load the conversation" />);
    const alert = screen.getByRole("alert");
    const corner = alert.querySelector(".toast-corner");
    expect(corner).not.toBeNull();
    const btns = Array.from(corner!.querySelectorAll("button"));
    expect(btns.map((b) => b.getAttribute("aria-label"))).toEqual(["Dismiss", "Copy error"]);
  });
});
