import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createRoot, createMemo } from "solid-js";
import { RENAME_CONFIRM_MS, renamedTitle, renameOptimistically, resetRenames, withRenamedTitles } from "../src/renames";

beforeEach(() => resetRenames());
afterEach(() => { vi.useRealTimers(); resetRenames(); });

const deferred = () => { let resolve!: () => void, reject!: (e: unknown) => void; const promise = new Promise<void>((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

it("shows the new name in every view before the server answers", () => {
  const request = deferred();
  createRoot(dispose => {
    const sidebar = createMemo(() => renamedTitle("mission", "m1", "Old title"));
    const inbox = createMemo(() => withRenamedTitles("mission", [{ id: "m1", title: "Old title" }, { id: "m2", title: "Other" }], m => m.id).map(m => m.title));
    void renameOptimistically("mission", "m1", "New title", "Old title", () => request.promise);
    expect(sidebar()).toBe("New title");
    expect(inbox()).toEqual(["New title", "Other"]);
    expect(renamedTitle("project", "m1", "Project")).toBe("Project");
    dispose();
  });
  request.resolve();
});

it("restores the old name and shows an error toast when the request fails", async () => {
  const request = deferred();
  const done = renameOptimistically("project", "alpha", "Beta", "Alpha", () => request.promise);
  expect(renamedTitle("project", "alpha", "Alpha")).toBe("Beta");
  request.reject(new Error("409 conflict"));
  await expect(done).rejects.toThrow("409 conflict");
  expect(renamedTitle("project", "alpha", "Alpha")).toBe("Alpha");
  await Promise.resolve();
  expect(document.body.textContent).toContain("Couldn’t rename the project");
  expect(document.body.textContent).toContain("409 conflict");
});

it("ignores a stale poll that still carries the old name until the server confirms", async () => {
  vi.useFakeTimers();
  await renameOptimistically("mission", "m1", "New title", "Old title", async () => {});
  // A list fetched before the rename landed still says "Old title".
  expect(renamedTitle("mission", "m1", "Old title")).toBe("New title");
  expect(withRenamedTitles("mission", [{ id: "m1", title: "Old title" }], m => m.id)[0].title).toBe("New title");
  // The server reports the new title: the pending entry is cleared.
  expect(renamedTitle("mission", "m1", "New title")).toBe("New title");
  await Promise.resolve();
  expect(renamedTitle("mission", "m1", "Renamed elsewhere")).toBe("Renamed elsewhere");
});

it("stops overriding the server after the confirmation timeout", async () => {
  vi.useFakeTimers();
  await renameOptimistically("mission", "m1", "New title", "Old title", async () => {});
  vi.advanceTimersByTime(RENAME_CONFIRM_MS);
  expect(renamedTitle("mission", "m1", "Old title")).toBe("Old title");
});

it("keeps row identity when nothing is pending", () => {
  const rows = [{ id: "a", title: "A" }];
  expect(withRenamedTitles("mission", rows, r => r.id)).toBe(rows);
});
