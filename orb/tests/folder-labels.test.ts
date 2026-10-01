import { afterEach, expect, it, vi } from "vitest";
import { setApiUrl } from "../src/api";
import { folderLabel, setFolderLabel } from "../src/folderLabels";

afterEach(() => { localStorage.clear(); vi.restoreAllMocks(); });
it("persists a folder label while keeping path, project, account and server identities separate", () => {
  setApiUrl("https://first.example");
  expect(folderLabel("project", "notes/reference")).toBe("reference");
  setFolderLabel("project", "notes/reference", "  Research  ");
  expect(folderLabel("project", "notes/reference")).toBe("Research");
  expect(folderLabel("other", "notes/reference")).toBe("reference");
  expect(folderLabel("project", "other/reference")).toBe("reference");
  localStorage.setItem("orb.jwt", `header.${btoa(JSON.stringify({ sub: "another-user" }))}.signature`);
  expect(folderLabel("project", "notes/reference")).toBe("reference");
  localStorage.removeItem("orb.jwt");
  setApiUrl("https://second.example");
  expect(folderLabel("project", "notes/reference")).toBe("reference");
  setApiUrl("https://first.example");
  expect(folderLabel("project", "notes/reference")).toBe("Research");
  setFolderLabel("project", "notes/reference", "reference");
  expect(folderLabel("project", "notes/reference")).toBe("reference");
});
it("rejects empty names and surfaces persistence failures without changing the label", () => {
  expect(() => setFolderLabel("project", "notes", "  ")).toThrow("Enter a folder name");
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("Storage is full"); });
  expect(() => setFolderLabel("project", "notes", "Research")).toThrow("Storage is full");
  expect(folderLabel("project", "notes")).toBe("notes");
});
