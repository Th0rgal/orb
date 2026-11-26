import { render, fireEvent, waitFor, cleanup } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FilePanelProvider } from "../src/FilePanel";

const mockInvoke = vi.fn();

vi.mock("../src/clientRuns", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/clientRuns")>()),
  nativeInvoke: () => mockInvoke,
}));

vi.mock("../src/native", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/native")>()),
  nativeInvoke: () => mockInvoke,
}));

vi.mock("../src/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/api")>()),
  getProjectController: vi.fn(async () => ({ settings: {} })),
  getProjectCron: vi.fn(async () => ({ settings: {} })),
  api: vi.fn(async (_path: string, init?: RequestInit) => {
    const q = init?.body ? JSON.parse(String(init.body)) : {};
    if (q.action === "roots")
      return {
        sources: [
          { id: "workspace", label: "Workspace", path: "/repo", available: true },
        ],
      };
    if (q.action === "list") {
      if (!q.path)
        return {
          entries: [
            { name: "docs", path: "docs", kind: "dir" },
            { name: "README.md", path: "README.md", kind: "file" },
          ],
        };
      if (q.path === "docs")
        return {
          entries: [{ name: "guide.md", path: "docs/guide.md", kind: "file" }],
        };
      return { entries: [] };
    }
    if (q.action === "read") {
      if (q.path === "docs/guide.md")
        return { content: "# Guide", size: 7, binary: false, truncated: false };
      if (q.path === "README.md")
        return { content: "# Repo", size: 6, binary: false, truncated: false };
      throw new Error("File not found");
    }
    return { entries: [] };
  }),
}));

afterEach(() => {
  cleanup();
  sessionStorage.clear();
  mockInvoke.mockReset();
});

describe("FilePanel Cmd+G go to path", () => {
  it("opens Go to path with Cmd+G inside Cmd+J panel and closes on Escape", async () => {
    const { container, getByLabelText, queryByRole } = render(() => (
      <div class="app">
        <FilePanelProvider scope={{ project: "demo" }}>
          <div class="chat" />
        </FilePanelProvider>
      </div>
    ));

    fireEvent.keyDown(window, { key: "j", code: "KeyJ", metaKey: true });
    await waitFor(() => expect(container.querySelector(".file-panel")).not.toBeNull());

    fireEvent.keyDown(window, { key: "g", code: "KeyG", metaKey: true });
    const input = await waitFor(() => getByLabelText("Go to file or folder path"));
    expect(input).toBeTruthy();

    fireEvent.keyDown(input, { key: "Escape" });
    await waitFor(() => expect(queryByRole("dialog", { name: "Go to path" })).toBeNull());
    expect(container.querySelector(".file-panel")).not.toBeNull();
  });

  it("opens an arbitrary local file path in the viewer", async () => {
    const brainDir = "/home/thomas/.gemini/antigravity-cli/brain/5aea7a88-f1a4-494c-9fba-ea16c6bc2c1b";
    const filePath = `${brainDir}/paloma_agent_plan.md`;

    mockInvoke.mockImplementation(async (cmd: string, args: Record<string, unknown>) => {
      if (cmd === "local_agents_directory") {
        if (args.path === brainDir) return brainDir;
        throw new Error("Selected path is not a folder.");
      }
      if (cmd === "browse_local_files") {
        const req = args.request as { action: string; path?: string };
        if (args.root === brainDir && req.action === "list")
          return {
            entries: [
              { name: "paloma_agent_plan.md", path: "paloma_agent_plan.md", kind: "file" },
            ],
          };
        if (args.root === brainDir && req.action === "read" && req.path === "paloma_agent_plan.md")
          return {
            content: "# Paloma Agent Plan\n\nReady.",
            size: 28,
            binary: false,
            truncated: false,
          };
      }
      throw new Error(`Unexpected command: ${cmd}`);
    });

    const { getByLabelText, getByText } = render(() => (
      <div class="app">
        <FilePanelProvider scope={{ project: "demo" }}>
          <div class="chat" />
        </FilePanelProvider>
      </div>
    ));

    fireEvent.keyDown(window, { key: "j", code: "KeyJ", metaKey: true });
    fireEvent.keyDown(window, { key: "g", code: "KeyG", metaKey: true });
    const input = (await waitFor(() => getByLabelText("Go to file or folder path"))) as HTMLInputElement;
    fireEvent.input(input, { target: { value: filePath } });
    fireEvent.keyDown(input, { key: "Enter" });

    await waitFor(() => expect(getByText("Paloma Agent Plan")).toBeTruthy());
  });

  it("switches to and expands an arbitrary local folder path in the file explorer", async () => {
    const brainDir = "/home/thomas/.gemini/antigravity-cli/brain/5aea7a88-f1a4-494c-9fba-ea16c6bc2c1b";

    mockInvoke.mockImplementation(async (cmd: string, args: Record<string, unknown>) => {
      if (cmd === "local_agents_directory" && args.path === brainDir) return brainDir;
      if (cmd === "browse_local_files" && args.root === brainDir) {
        const req = args.request as { action: string };
        if (req.action === "list")
          return {
            entries: [
              { name: "paloma_agent_plan.md", path: "paloma_agent_plan.md", kind: "file" },
            ],
          };
      }
      throw new Error(`Unexpected command: ${cmd}`);
    });

    const { getByLabelText, getByText, queryByRole } = render(() => (
      <div class="app">
        <FilePanelProvider scope={{ project: "demo" }}>
          <div class="chat" />
        </FilePanelProvider>
      </div>
    ));

    fireEvent.keyDown(window, { key: "j", code: "KeyJ", metaKey: true });
    fireEvent.keyDown(window, { key: "g", code: "KeyG", metaKey: true });
    const input = (await waitFor(() => getByLabelText("Go to file or folder path"))) as HTMLInputElement;
    fireEvent.input(input, { target: { value: brainDir } });
    fireEvent.keyDown(input, { key: "Enter" });

    await waitFor(() => expect(queryByRole("dialog", { name: "Go to path" })).toBeNull());
    await waitFor(() => expect(getByText("paloma_agent_plan.md")).toBeTruthy());
  });

  it("navigates to workspace-relative folders and files, and shows an inline error on missing paths", async () => {
    mockInvoke.mockRejectedValue(new Error("Selected local folder does not exist."));

    const { getByLabelText, getByText, getByRole } = render(() => (
      <div class="app">
        <FilePanelProvider scope={{ project: "demo" }}>
          <div class="chat" />
        </FilePanelProvider>
      </div>
    ));

    fireEvent.keyDown(window, { key: "j", code: "KeyJ", metaKey: true });
    fireEvent.keyDown(window, { key: "g", code: "KeyG", metaKey: true });
    let input = (await waitFor(() => getByLabelText("Go to file or folder path"))) as HTMLInputElement;
    fireEvent.input(input, { target: { value: "docs" } });
    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(getByText("guide.md")).toBeTruthy());

    fireEvent.keyDown(window, { key: "g", code: "KeyG", metaKey: true });
    input = (await waitFor(() => getByLabelText("Go to file or folder path"))) as HTMLInputElement;
    fireEvent.input(input, { target: { value: "/does/not/exist.md" } });
    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(getByRole("alert").textContent).toContain("does not exist"));
  });
});
