import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SkillPage, middleTruncate } from "../src/SkillPage";
import { clearConnection, setConnection } from "../src/api";
import { rememberSkillsReport } from "../src/skillCache";
import { setMdSource } from "../src/Markdown";

let content: string;
let commitFails: boolean;
let requests: string[];

beforeEach(() => {
  content = "---\nname: agent-browser\ndescription: Drive a browser.\n---\n\n# Agent browser\n\nOpen pages.\n";
  commitFails = false;
  requests = [];
  setConnection("https://core.test", "test-jwt");
  setMdSource(false);
  (window as unknown as { __TAURI__: { core: { invoke: () => Promise<unknown> } } }).__TAURI__ = { core: { invoke: async () => ({ synced_skills: 1, harnesses_updated: 0, skipped_unmanaged: [], report: { skills: [], harnesses: [], sources: [] } }) } };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input).replace("https://core.test", ""), method = init?.method ?? "GET";
    requests.push(`${method} ${url}${url.endsWith("/commit") ? ` ${JSON.parse(String(init?.body)).message}` : ""}`);
    const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
    if (url === "/api/library/skill/agent-browser") {
      if (method === "PUT") { content = JSON.parse(String(init?.body)).content; return new Response("Skill saved successfully"); }
      return ok({ name: "agent-browser", path: "skill/agent-browser", content, files: [], references: ["references/selectors.md"] });
    }
    if (url === "/api/library/commit") return commitFails ? new Response("git commit failed: gpg failed to sign the data", { status: 500 }) : new Response("Committed successfully");
    if (url === "/api/library/push") return new Response("Pushed successfully");
    if (url === "/api/projects") return ok({ projects: [] });
    return ok({});
  });
});
afterEach(() => { clearConnection(); vi.restoreAllMocks(); });

describe("skill page", () => {
  it("opens SKILL.md as a document with a breadcrumb and its files as a tree", async () => {
    const back = vi.fn();
    render(() => <SkillPage name="agent-browser" onBack={back} />);
    expect(await screen.findByText("Agent browser")).toBeTruthy();
    // The rendered view hides the frontmatter; the settings sit in the strip.
    expect(screen.queryByText(/description: Drive a browser/)).toBeNull();
    expect(screen.getByRole("group", { name: "Who uses it" })).toBeTruthy();
    expect(screen.getByRole("tree", { name: "agent-browser files" }).textContent).toContain("selectors.md");
    expect(screen.queryByRole("dialog")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Skills" }));
    expect(back).toHaveBeenCalled();
  });

  it("saves with ⌘S: commits, pushes and says so; a failure shows Retry", async () => {
    render(() => <SkillPage name="agent-browser" onBack={() => {}} />);
    await screen.findByText("Agent browser");
    fireEvent.click(screen.getByRole("radio", { name: "Always" }));
    commitFails = true;
    fireEvent.keyDown(window, { key: "s", metaKey: true });
    expect(await screen.findByRole("alert")).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toContain("gpg failed");
    commitFails = false;
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(await screen.findByText("Saved to repo")).toBeTruthy();
    expect(content).toContain("scope: global");
    expect(requests).toContain("POST /api/library/commit skill: update agent-browser");
    expect(requests).toContain("POST /api/library/push");
  });

  it("keeps History, Discard local edits and Delete in the … menu", async () => {
    rememberSkillsReport({ checked_at: 0, home_dir: "/h", preflight: {} as never, sources: [], harnesses: [], skills: [
      { name: "agent-browser", origin: "Library", harnesses: ["claudecode"], managed: false, in_library: true, edited_copy: { harness: "Claude Code", path: "/h/.claude/skills/agent-browser", content: "# mine" } },
    ] });
    render(() => <SkillPage name="agent-browser" onBack={() => {}} />);
    await screen.findByText("Agent browser");
    fireEvent.click(screen.getByRole("button", { name: "Actions for agent-browser" }));
    expect(screen.getByRole("menuitem", { name: "History" })).toBeTruthy();
    expect(screen.getByRole("menuitem", { name: "Discard local edits" })).toBeTruthy();
    expect(screen.getByRole("menuitem", { name: /Delete/ })).toBeTruthy();
  });
});

describe("middleTruncate", () => {
  it("keeps both ends of a long path", () => {
    expect(middleTruncate("short/path.md")).toBe("short/path.md");
    const out = middleTruncate("/Users/thomas/work/paloma/skills/agent-browser/references/selectors.md", 32);
    expect(out).toHaveLength(32);
    expect(out.endsWith("selectors.md")).toBe(true);
  });
});
