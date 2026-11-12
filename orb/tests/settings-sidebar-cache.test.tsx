import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, waitFor } from "@solidjs/testing-library";
import "../src/SearchDialog";
import "../src/Settings";
import "../src/SettingsShell";
import "../src/Inbox";
import "../src/MachineCloudMenu";
import "../src/managedMachineModel";
import "../src/cloudAgentApi";
import "../src/deviceApproval";
import App from "../src/App";
import { clearConnection, setConnection, type Mission } from "../src/api";

class IdleSocket {
  static OPEN = 1;
  readyState = IdleSocket.OPEN;
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  send() {}
  close() {
    this.readyState = 3;
  }
}

describe("Settings navigation sidebar preservation and connection scoping", () => {
  let projectsCalls = 0;
  let projectMissionsCalls = 0;
  let serverLabel = "Verity";

  beforeEach(() => {
    projectsCalls = 0;
    projectMissionsCalls = 0;
    serverLabel = "Verity";
    localStorage.clear();
    Element.prototype.scrollIntoView = vi.fn();
    vi.stubGlobal(
      "matchMedia",
      vi.fn().mockImplementation((query: string) => ({
        matches: false,
        media: query,
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      })),
    );
    vi.stubGlobal("WebSocket", IdleSocket as unknown as typeof WebSocket);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const raw = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
        const url = new URL(raw, "http://sidebar.test");
        const path = url.pathname;
        if (path === "/api/projects") {
          projectsCalls += 1;
          const slug = serverLabel.toLowerCase();
          return Response.json({
            projects: [{ slug, title: serverLabel, status: "active", updated_at: "2026-11-09T15:00:00Z" }],
          });
        }
        if (path === "/api/control/missions" && url.searchParams.get("project")) {
          projectMissionsCalls += 1;
          const slug = url.searchParams.get("project")!;
          const rows: Mission[] = [
            {
              id: `m-${slug}-1`,
              title: `Open plan (${slug})`,
              project: slug,
              status: "paused",
              tags: [],
              history: [],
              created_at: "2026-11-09T15:00:00Z",
              updated_at: "2026-11-09T15:05:00Z",
            },
          ];
          return Response.json(rows);
        }
        if (path === "/api/control/missions") return Response.json([{
          id: "done-mission",
          title: "Finished audit",
          project: "verity",
          status: "completed",
          tags: [],
          history: [{ role: "assistant", content: "Audit complete." }],
          created_at: "2026-11-09T15:00:00Z",
          updated_at: "2026-11-09T15:05:00Z",
        }]);
        if (path === "/api/remote-nodes") return Response.json({ nodes: [] });
        if (path === "/api/cloud/accounts") return Response.json([]);
        if (path === "/api/backends") return Response.json([]);
        if (path === "/api/providers/backend-models") return Response.json({ backends: {} });
        if (path === "/api/model-routing/chains") return Response.json([]);
        if (path.endsWith("/events")) return Response.json({ events: [], has_more: false });
        if (path.endsWith("/files")) return Response.json({ entries: [] });
        if (path.endsWith("/controller")) return Response.json({ job: null, runs: [] });
        if (path.endsWith("/crons")) return Response.json({ jobs: [] });
        return Response.json({});
      }),
    );
    setConnection("http://sidebar.test", "fixture");
  });

  afterEach(() => {
    cleanup();
    clearConnection();
    vi.unstubAllGlobals();
  });

  it("keeps sidebar projects, expanded folders, and scrollTop intact across Settings round-trips without re-fetching", async () => {
    const view = render(() => <App />);
    const projectBtn = await view.findByRole("button", { name: "Verity", exact: true });
    fireEvent.click(projectBtn);

    const missionRow = await view.findByRole("button", { name: "Open plan (verity)", exact: true });
    expect(missionRow).toBeTruthy();
    expect(projectBtn.getAttribute("aria-expanded")).toBe("true");

    const sbScroll = view.container.querySelector<HTMLElement>(".sb-scroll")!;
    const sbMainNav = view.container.querySelector<HTMLElement>(".sb-main-nav")!;
    sbScroll.scrollTop = 180;

    const projectsBefore = projectsCalls;
    const missionsBefore = projectMissionsCalls;

    // Open Settings:
    fireEvent.click(view.getByRole("button", { name: "Settings" }));
    await waitFor(() => expect(sbMainNav.hidden).toBe(true));
    expect(sbScroll.scrollTop).toBe(0);
    const backBtn = await view.findByRole("button", { name: "Back" });

    // Return via Back:
    fireEvent.click(backBtn);
    await waitFor(() => expect(sbMainNav.hidden).toBe(false));

    // Expanded project, loaded mission row, and scrollTop are preserved with zero reload or empty-state flash:
    expect(projectBtn.isConnected).toBe(true);
    expect(projectBtn.getAttribute("aria-expanded")).toBe("true");
    expect(view.getByRole("button", { name: "Open plan (verity)", exact: true })).toBeTruthy();
    expect(sbScroll.textContent).not.toContain("No projects on the core backend.");
    await waitFor(() => expect(sbScroll.scrollTop).toBe(180));
    expect(projectsCalls).toBe(projectsBefore);
    expect(projectMissionsCalls).toBe(missionsBefore);

    // Switching backend connection cleanly remounts LiveProjectsSection for the new backend:
    serverLabel = "Secondary";
    setConnection("http://secondary.test", "fixture-2");
    const secondaryBtn = await view.findByRole("button", { name: "Secondary", exact: true });
    expect(secondaryBtn).toBeTruthy();
    expect(view.queryByRole("button", { name: "Verity", exact: true })).toBeNull();
  });

  it("opens a single-agent delete confirmation from Inbox Delete action", async () => {
    vi.stubGlobal("CSS", { escape: (s: string) => s });
    render(() => <App />);
    const { screen } = await import("@solidjs/testing-library");
    fireEvent.click(await screen.findByRole("button", { name: /^Inbox/ }));
    const peekBtn = await screen.findByRole("button", { name: /^Peek and reply/ });
    fireEvent.click(peekBtn);
    const deleteBtn = await screen.findByRole("button", { name: "Delete…", exact: true });
    fireEvent.click(deleteBtn);
    expect(await screen.findByRole("dialog", { name: "Delete 1 agent?" })).toBeTruthy();
  });
});
