import { render, screen, fireEvent, waitFor } from "@solidjs/testing-library";
import { afterEach, it, expect, vi } from "vitest";
import { WorkingDirectoryPicker } from "../src/WorkingDirectoryPicker";
import { invalidateReads } from "../src/sharedReads";

afterEach(() => {
  delete (window as any).__TAURI__;
  localStorage.clear();
  invalidateReads();
  vi.restoreAllMocks();
});

it("uses the native folder picker and keeps the selection on cancellation", async () => {
  const invoke = vi.fn().mockResolvedValueOnce("/Users/test/repo").mockResolvedValueOnce(null);
  (window as any).__TAURI__ = { core: { invoke } };
  const change = vi.fn();
  render(() => <WorkingDirectoryPicker machine="local" value="/Users/test/old" onChange={change} />);
  fireEvent.click(screen.getByRole("button", { name: "Choose working folder" }));
  await waitFor(() => expect(change).toHaveBeenCalledWith("/Users/test/repo"));
  fireEvent.click(screen.getByRole("button", { name: "Choose working folder" }));
  await waitFor(() => expect(invoke).toHaveBeenCalledTimes(2));
  expect(change).toHaveBeenCalledTimes(1);
});

it("edits remote paths without opening the local Finder", () => {
  const invoke = vi.fn();
  (window as any).__TAURI__ = { core: { invoke } };
  const change = vi.fn();
  render(() => <WorkingDirectoryPicker machine="spark" value="" onChange={change} />);
  fireEvent.click(screen.getByRole("button", { name: "Choose working folder" }));
  fireEvent.input(screen.getByLabelText("Folder path"), { target: { value: "/srv/project" } });
  expect(change).toHaveBeenCalledWith("/srv/project");
  expect(invoke).not.toHaveBeenCalled();
});

it("browses remote folders, navigates breadcrumbs, toggles hidden folders, and creates a new folder", async () => {
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input);
    if (init?.method === "POST" && url.endsWith("/api/fs/mkdir")) {
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }
    if (url.includes("path=%2Fsrv%2Fwork%2Fpaloma")) {
      return new Response(
        JSON.stringify([
          { name: "sandboxed_sh", path: "/srv/work/paloma/sandboxed_sh", kind: "dir" },
          { name: "hermes-agent", path: "/srv/work/paloma/hermes-agent", kind: "dir" },
          { name: "AGENTS.md", path: "/srv/work/paloma/AGENTS.md", kind: "file" },
        ]),
        { status: 200 },
      );
    }
    return new Response(
      JSON.stringify([
        { name: "paloma", path: "/srv/work/paloma", kind: "dir" },
        { name: ".git", path: "/srv/work/.git", kind: "dir" },
        { name: "README.md", path: "/srv/work/README.md", kind: "file" },
      ]),
      { status: 200 },
    );
  });

  let current = "";
  const change = vi.fn((next: string) => {
    current = next;
  });

  render(() => <WorkingDirectoryPicker machine="core" machineName="Core (agent-core)" value={current} onChange={change} />);
  fireEvent.click(screen.getByRole("button", { name: "Choose working folder" }));

  await waitFor(() => expect(screen.getByRole("option", { name: /paloma/ })).toBeTruthy());
  expect(screen.queryByRole("option", { name: /\.git/ })).toBeNull();

  // Show hidden folders toggle reveals .git
  fireEvent.click(screen.getByRole("button", { name: /Show 1 hidden folder/ }));
  expect(screen.getByRole("option", { name: /\.git/ })).toBeTruthy();

  // Clicking paloma selects it and drills into /srv/work/paloma
  fireEvent.click(screen.getByRole("option", { name: /paloma/ }));
  expect(change).toHaveBeenCalledWith("/srv/work/paloma");
  await waitFor(() => expect(screen.getByRole("option", { name: /sandboxed_sh/ })).toBeTruthy());

  // Creating a new folder inside /srv/work/paloma calls mkdir and selects the new folder
  fireEvent.click(screen.getByRole("button", { name: "New folder" }));
  const newInput = screen.getByLabelText("New folder name");
  fireEvent.input(newInput, { target: { value: "experiments" } });
  fireEvent.click(screen.getByRole("button", { name: "Create" }));
  await waitFor(() => expect(change).toHaveBeenCalledWith("/srv/work/paloma/experiments"));
  expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("/api/fs/mkdir"), expect.objectContaining({ method: "POST" }));
});
