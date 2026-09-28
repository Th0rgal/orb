import { afterEach, expect, it, vi } from "vitest";
import { fileDestination, readFileReference, transferProjectFile } from "../src/fileActions";
import { setApiUrl } from "../src/api";
afterEach(() => vi.restoreAllMocks());
it("renames exactly and moves to the root without allowing traversal", () => {
  expect(fileDestination("notes/context.md", "README", true)).toBe("notes/README");
  expect(fileDestination("notes/context.md", "", false)).toBe("context.md");
  expect(fileDestination("notes/context.md", "archive/nested", false)).toBe("archive/nested/context.md");
  for (const value of ["../escape", "/absolute", "a//b", "a\\b"]) expect(() => fileDestination("notes/context.md", value, false)).toThrow();
  expect(() => fileDestination("notes/context.md", "notes", false)).toThrow();
});
it("accepts only file clipboard payloads from this backend", () => {
  setApiUrl("https://example.test");
  const payload = { slug: "test", path: "context.md", copy: false, backend: "https://example.test", account: "", nonce: "one" };
  expect(readFileReference("orb:file:" + JSON.stringify(payload))).toEqual(payload);
  expect(readFileReference("orb:file:" + JSON.stringify({...payload, backend: "https://other.test"}))).toBeNull();
  expect(readFileReference("some text")).toBeNull();
});
it("sends a transfer to the authoritative API and surfaces an old backend", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response('{}', {status:200}));
  await transferProjectFile("test", "context.md", "notes/context.md", true);
  expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({path:"context.md",destination:"notes/context.md",copy:true});
  fetch.mockResolvedValue(new Response('Not found', {status:404}));
  await expect(transferProjectFile("test", "context.md", "renamed.md")).rejects.toThrow("Update the backend");
});
