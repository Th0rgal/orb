import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SkillsSettings, knownSkillNames } from "../src/SkillsSettings";
import { clearConnection, setConnection } from "../src/api";
import type { LocalSkillsReport } from "../src/localAgents";

function sampleLocalReport(syncedAntigravity = false): LocalSkillsReport {
  const allHarnesses = syncedAntigravity
    ? ["claudecode", "codex", "antigravity", "opencode", "grok", "vibe"]
    : ["claudecode", "codex", "grok", "vibe"];
  return {
    checked_at: Math.floor(Date.now() / 1000),
    home_dir: "/Users/thomas",
    preflight: {
      python3_ready: true,
      python3_version: "3.12.4",
      pyyaml_ready: true,
      preflight_error: null,
      identity_ready: true,
      identity_fingerprint: "9A1E3D2F4C8811A0",
      identity_updated_at: 1728000000,
    },
    sources: [
      {
        id: "agent-skills-repo",
        label: "Agent Skills Repo",
        path: "/Users/thomas/work/skills/skills",
        exists: true,
        skill_count: 37,
      },
      {
        id: "paloma-skills",
        label: "Paloma Skills",
        path: "/Users/thomas/work/paloma/skills",
        exists: true,
        skill_count: 2,
      },
    ],
    harnesses: [
      {
        id: "claudecode",
        name: "Claude Code",
        global_rel: "~/.claude/skills",
        global_path: "/Users/thomas/.claude/skills",
        project_rel: ".claude/skills",
        exists: true,
        skill_count: 37,
        synced_count: 37,
        canonical_total: 37,
        missing_skills: [],
      },
      {
        id: "codex",
        name: "Codex",
        global_rel: "~/.codex/skills",
        global_path: "/Users/thomas/.codex/skills",
        project_rel: ".agents/skills",
        exists: true,
        skill_count: 37,
        synced_count: 37,
        canonical_total: 37,
        missing_skills: [],
      },
      {
        id: "antigravity",
        name: "Antigravity",
        global_rel: "~/.agents/skills",
        global_path: "/Users/thomas/.agents/skills",
        project_rel: ".agents/skills",
        exists: true,
        skill_count: syncedAntigravity ? 37 : 2,
        synced_count: syncedAntigravity ? 37 : 2,
        canonical_total: 37,
        missing_skills: syncedAntigravity ? [] : ["paloma-backends", "paloma-ssh-servers"],
      },
      {
        id: "opencode",
        name: "OpenCode",
        global_rel: "~/.config/opencode/skills",
        global_path: "/Users/thomas/.config/opencode/skills",
        project_rel: ".opencode/skills",
        exists: syncedAntigravity,
        skill_count: syncedAntigravity ? 37 : 0,
        synced_count: syncedAntigravity ? 37 : 0,
        canonical_total: 37,
        missing_skills: syncedAntigravity ? [] : ["paloma-backends", "paloma-ssh-servers"],
      },
      {
        id: "grok",
        name: "Grok",
        global_rel: "~/.grok/skills",
        global_path: "/Users/thomas/.grok/skills",
        project_rel: ".grok/skills",
        exists: true,
        skill_count: 37,
        synced_count: 37,
        canonical_total: 37,
        missing_skills: [],
      },
      {
        id: "vibe",
        name: "Mistral Vibe",
        global_rel: "~/.vibe/skills",
        global_path: "/Users/thomas/.vibe/skills",
        project_rel: ".vibe/skills",
        exists: true,
        skill_count: 37,
        synced_count: 37,
        canonical_total: 37,
        missing_skills: [],
      },
    ],
    skills: [
      {
        name: "paloma-backends",
        description: "Inspect and manage Paloma VPS and fleet backends.",
        origin: "Paloma Skills",
        source_path: "/Users/thomas/work/paloma/skills/paloma-backends",
        harnesses: allHarnesses,
        managed: true,
        content_preview: "---\nname: paloma-backends\n---\n# Paloma Backends\n",
      },
      {
        name: "development-identity",
        description: "Use the shared Paloma development identity for GitHub and SSH.",
        origin: "Development Identity",
        source_path: "/Users/thomas/.config/sandboxed-sh/development-identity/current/skill",
        harnesses: allHarnesses,
        managed: true,
        content_preview: "---\nname: development-identity\n---\n# Identity\n",
      },
    ],
  };
}

describe("SkillsSettings", () => {
  beforeEach(() => {
    clearConnection();
    vi.restoreAllMocks();
  });

  it("shows harness drift under Advanced without a manual sync button", async () => {
    let synced = false;
    const invokeMock = vi.fn(async (cmd: string) => {
      if (cmd === "local_skills_status") return sampleLocalReport(synced);
      if (cmd === "local_skills_sync") {
        synced = true;
        return {
          synced_skills: 37,
          harnesses_updated: 2,
          skipped_unmanaged: [],
          report: sampleLocalReport(true),
        };
      }
      if (cmd === "local_agents_scan") {
        return [
          { id: "claudecode", bin: "claude", path: "/usr/local/bin/claude", version: "2.1.10", installed: true },
          { id: "codex", bin: "codex", path: "/usr/local/bin/codex", version: "0.118.0", installed: true },
          { id: "antigravity", bin: "agy", path: "/usr/local/bin/agy", version: "0.2.1", installed: true },
          { id: "opencode", bin: "opencode", path: "/opt/homebrew/bin/opencode", version: "1.3.0", installed: true },
          { id: "grok", bin: "grok", path: "/usr/local/bin/grok", version: "0.4.2", installed: true },
        ];
      }
      if (cmd === "software_inventory") {
        return {
          checked_at: Math.floor(Date.now() / 1000),
          runtime: { name: "Orb runner", version: "0.1.0", build: "test", path: null, restart_required: false },
          jobs: [],
          components: [],
        };
      }
      return null;
    });

    (window as unknown as { __TAURI__: { core: { invoke: typeof invokeMock } } }).__TAURI__ = {
      core: { invoke: invokeMock },
    };

    const { container } = render(() => <SkillsSettings />);
    await waitFor(() => expect(knownSkillNames()).toContain("paloma-backends"));
    expect(screen.queryByRole("button", { name: /Sync all harnesses/ })).toBeNull();
    const advanced = container.querySelector<HTMLDetailsElement>("details.skills-advanced")!;
    advanced.open = true;
    fireEvent(advanced, new Event("toggle"));
    await waitFor(() => {
      expect(screen.getByText("Out of sync · 2/37")).toBeTruthy();
      expect(screen.getByText("Out of sync · 0/37")).toBeTruthy();
    });
    expect(screen.getByText("Ready · Python 3.12.4 + PyYAML")).toBeTruthy();
    expect(screen.getByText("Active · 4C8811A0")).toBeTruthy();
  });

  it("shows rows from the Library index first, then syncs drifted harnesses on its own", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    const syncCalls: unknown[] = [];
    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") return sampleLocalReport(false);
          if (cmd === "local_skills_sync") { syncCalls.push(args.request); return { synced_skills: 1, harnesses_updated: 2, skipped_unmanaged: [], pruned: [], report: sampleLocalReport(true) }; }
          return null;
        },
      },
    };
    let releaseBody!: () => void;
    const bodyGate = new Promise<void>((resolve) => (releaseBody = resolve));
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "paloma-backends", description: "Inspect Paloma backends.", path: "skill/paloma-backends" }]);
      if (url.endsWith("/api/library/skill/paloma-backends")) { await bodyGate; return ok({ name: "paloma-backends", path: "skill/paloma-backends", content: "---\nname: paloma-backends\n---\n", files: [], references: [] }); }
      if (url.endsWith("/api/library/status")) return ok({ remote: "git@github.com:Th0rgal/sandboxed-library.git", branch: "main", clean: true, ahead: 0, behind: 0, modified_files: [], last_synced_at: Math.floor(Date.now() / 1000) - 120 });
      return ok({});
    });
    render(() => <SkillsSettings />);
    // The row is there while every skill body is still loading.
    expect(await screen.findByText("paloma-backends")).toBeTruthy();
    expect(await screen.findByText(/Th0rgal\/sandboxed-library/)).toBeTruthy();
    expect(screen.getByText(/synced 2m ago/)).toBeTruthy();
    expect(syncCalls).toHaveLength(0);
    releaseBody();
    await waitFor(() => expect(syncCalls).toHaveLength(1));
    // Auto-sync also prunes: only copies carrying Orb's marker are ever removed.
    expect(syncCalls[0]).toMatchObject({ prune_removed: true });
  });

  it("loads Core Library skills and project skills when connected", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string) => {
          if (cmd === "local_skills_status") return sampleLocalReport(true);
          if (cmd === "local_agents_scan") return [];
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/library/skill")) {
        return new Response(
          JSON.stringify([
            {
              name: "spark-lean-offload",
              description: "Offload Lean 4 builds to DGX Spark arbiter.",
              path: "skill/spark-lean-offload",
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.endsWith("/api/projects")) {
        return new Response(
          JSON.stringify({
            projects: [
              {
                slug: "erdos-647",
                title: "Erdos 647 Proof",
                status: "active",
                updated_at: "2026-10-08T12:00:00Z",
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.includes("/api/projects/erdos-647/files?path=skills")) {
        return new Response(
          JSON.stringify({
            entries: [{ name: "aristotle-tactics", kind: "dir" }],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.includes("/api/projects/erdos-647/file?path=skills")) {
        return new Response(
          JSON.stringify({
            content: "---\nname: aristotle-tactics\ndescription: Custom tactics for Erdos 647\n---\n# Tactics\n",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      if (url.includes("/api/remote-nodes")) {
        return new Response(JSON.stringify({ enabled: true, nodes: [] }), { status: 200 });
      }
      return new Response("{}", { status: 200 });
    });

    const opened: string[] = [];
    render(() => <SkillsSettings onOpenPage={(id) => opened.push(id)} />);

    await waitFor(() => {
      expect(screen.getByText("spark-lean-offload")).toBeTruthy();
      expect(screen.getByText("aristotle-tactics")).toBeTruthy();
    });

    fireEvent.click(screen.getByText("aristotle-tactics"));
    expect(opened).toEqual(["pf:erdos-647:skills/aristotle-tactics/SKILL.md"]);
  });
  it("edits, deletes and previews delivery against the Library", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    const syncCalls: Array<{ library_skills: Array<{ name: string }>; prune_removed: boolean }> = [];
    const statusCalls: unknown[] = [];
    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") { statusCalls.push(args); return sampleLocalReport(true); }
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            return { synced_skills: 1, harnesses_updated: 6, skipped_unmanaged: [], pruned: [], report: sampleLocalReport(true) };
          }
          if (cmd === "local_agents_scan") return [];
          return null;
        },
      },
    };
    let content = "---\nname: spark-lean-offload\ndescription: Offload Lean 4 builds to the DGX Spark arbiter safely.\n---\n# Spark\n";
    const requests: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input), method = init?.method ?? "GET";
      requests.push(`${method} ${url.replace("https://agent-backend.thomas.md", "")}${url.endsWith("/commit") ? ` ${JSON.parse(String(init?.body)).message}` : ""}`);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "spark-lean-offload", path: "skill/spark-lean-offload", audience: ["mission", "local"] }]);
      if (url.endsWith("/api/library/skill/spark-lean-offload")) {
        if (method === "PUT") { content = JSON.parse(String(init?.body)).content; return new Response("Skill saved successfully", { status: 200 }); }
        if (method === "DELETE") return new Response("Skill deleted successfully", { status: 200 });
        return ok({ name: "spark-lean-offload", path: "skill/spark-lean-offload", content, files: [], references: [] });
      }
      if (url.endsWith("/api/projects")) return ok({ projects: [{ slug: "erdos-647", title: "Erdos 647 Proof", status: "active", updated_at: "2026-10-08T12:00:00Z" }] });
      if (url.includes("/api/projects/erdos-647/skills")) return new Response("", { status: 404 });
      if (url.endsWith("/api/library/commit")) return new Response("Committed successfully", { status: 200 });
      if (url.endsWith("/api/library/push")) return new Response("Pushed successfully", { status: 200 });
      if (url.includes("/api/library/skill-delivery")) return ok({ skills: [{ name: "spark-lean-offload", reasons: ["base", "project"] }], missing: [] });
      return ok({});
    });

    render(() => <SkillsSettings />);
    await waitFor(() => expect(statusCalls.some((c: any) => c?.request?.library_skills?.length === 1)).toBe(true));
    fireEvent.click(await screen.findByText("spark-lean-offload"));
    const dialog = await screen.findByRole("dialog");
    // Lint: missing metadata.sandboxed.
    expect(dialog.textContent).toContain("No metadata.sandboxed block");
    // The Assistant also uses it, and it is always loaded; Save commits and pushes to the repo.
    const before = syncCalls.length;
    fireEvent.click(screen.getByRole("checkbox", { name: "Assistant" }));
    fireEvent.click(screen.getByRole("radio", { name: "Always" }));
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(screen.getByText("Saved to repo")).toBeTruthy());
    expect(content).toContain("audience: [mission, coordinator, local]");
    expect(content).toContain("scope: global");
    expect(requests).toContain("POST /api/library/commit skill: update spark-lean-offload");
    expect(requests).toContain("POST /api/library/push");
    await waitFor(() => expect(syncCalls.length).toBe(before + 1));
    expect(syncCalls.at(-1)!.prune_removed).toBe(false);
    expect(syncCalls.at(-1)!.library_skills.map((s) => s.name)).toEqual(["spark-lean-offload"]);

    // Delete through the in-app confirmation; sync prunes.
    await waitFor(() => expect((screen.getByRole("button", { name: "Delete…" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(screen.getByRole("button", { name: "Delete…" }));
    // Confirms inside the panel: no second dialog.
    expect(screen.getAllByRole("dialog")).toHaveLength(1);
    fireEvent.click(await screen.findByRole("button", { name: "Delete" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(screen.queryByText("spark-lean-offload")).toBeNull();
    await waitFor(() => expect(syncCalls.at(-1)).toMatchObject({ prune_removed: true, library_skills: [] }));
    expect(requests).toContain("DELETE /api/library/skill/spark-lean-offload");
    expect(requests).toContain("POST /api/library/commit skill: delete spark-lean-offload");

    // Delivery preview (under Advanced) degrades when project skills are unsupported.
    const advanced = document.querySelector<HTMLDetailsElement>("details.skills-advanced")!;
    advanced.open = true;
    fireEvent(advanced, new Event("toggle"));
    const select = (await screen.findByLabelText("Preview project")) as HTMLSelectElement;
    fireEvent.change(select, { target: { value: "erdos-647" } });
    await waitFor(() => {
      expect(screen.getByText("This backend does not support project skill selection yet.")).toBeTruthy();
      expect(screen.getByText("Resolved delivery (1)")).toBeTruthy();
    });
  });

  it("keeps a failed delete in the confirm with Retry and the row back in the list", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string) => Promise<unknown> } } }).__TAURI__ = { core: { invoke: async () => null } };
    let commitFails = true;
    let deleted = false;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input), method = init?.method ?? "GET";
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok(deleted && !commitFails ? [] : [{ name: "agent-browser", description: "Drive a browser.", path: "skill/agent-browser" }]);
      if (url.endsWith("/api/library/skill/agent-browser")) {
        if (method === "DELETE") { if (deleted) return new Response("Skill not found: agent-browser", { status: 404 }); deleted = true; return new Response("Skill deleted successfully", { status: 200 }); }
        return ok({ name: "agent-browser", path: "skill/agent-browser", content: "---\nname: agent-browser\n---\n# Browser\n", files: [], references: [] });
      }
      if (url.endsWith("/api/library/commit")) return commitFails ? new Response("git commit failed: gpg failed to sign the data", { status: 500 }) : new Response("Committed successfully", { status: 200 });
      if (url.endsWith("/api/library/push")) return new Response("Pushed successfully", { status: 200 });
      return ok({});
    });
    render(() => <SkillsSettings />);
    fireEvent.click(await screen.findByRole("button", { name: "Actions for agent-browser" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: /Delete/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Delete" }));
    // The row is back, the dialog stays open with plain words and Retry.
    expect(await screen.findByText(/Core couldn’t sign the Library commit, so agent-browser is still there/)).toBeTruthy();
    expect(screen.getByText("agent-browser")).toBeTruthy();
    commitFails = false;
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    // Retry only commits: the file is already gone, so the 404 is fine.
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(screen.queryByText("agent-browser")).toBeNull();
  });

  it("separates removed skills, real local edits and old copies", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    const report = sampleLocalReport(true);
    report.skills = [
      { name: "agent-browser", origin: "User global", harnesses: ["claudecode"], managed: true, removed_from_library: true, legacy_only: false, divergent: true, sources: [{ id: "agent-skills-repo", label: "Agent Skills Repo", path: "/Users/thomas/work/skills/skills/agent-browser", legacy: true, hash: "a", lines: 3, content: "---\nname: agent-browser\n---\n" }] },
      { name: "spark-lean-offload", origin: "Library", harnesses: ["claudecode"], managed: false, in_library: true, edited_copy: { harness: "Claude Code", path: "/Users/thomas/.claude/skills/spark-lean-offload", content: "# mine" } },
      { name: "backblaze-b2-backups", origin: "Agent Skills Repo", harnesses: [], managed: false, legacy_only: true, sources: [{ id: "agent-skills-repo", label: "Agent Skills Repo", path: "/Users/thomas/work/skills/skills/backblaze-b2-backups", legacy: true, hash: "b", lines: 3, content: "---\nname: backblaze-b2-backups\n---\n" }] },
    ];
    const syncCalls: any[] = [];
    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: { invoke: async (cmd: string, args?: any) => {
        if (cmd === "local_skills_status") return report;
        if (cmd === "local_skills_sync") { syncCalls.push(args.request); return { synced_skills: 1, harnesses_updated: 1, skipped_unmanaged: [], pruned: ["~/.claude/skills/agent-browser"], report }; }
        return null;
      } },
    };
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "spark-lean-offload", path: "skill/spark-lean-offload" }]);
      if (url.endsWith("/api/library/skill/spark-lean-offload")) return ok({ name: "spark-lean-offload", path: "skill/spark-lean-offload", content: "---\nname: spark-lean-offload\n---\n# Library\n", files: [], references: [] });
      return ok({});
    });
    const { container } = render(() => <SkillsSettings />);
    const removed = await waitFor(() => { const el = container.querySelector('.skills-catalog-card [data-skill="agent-browser"]'); expect(el?.textContent).toContain("Removed"); return el!; });
    expect(removed.textContent).toContain("Removed from Library");
    expect(container.querySelector('[data-skill="spark-lean-offload"]')!.textContent).toContain("Edited on this Mac");
    // Old copies are not in the main list nor in "Needs attention".
    const main = container.querySelectorAll(".skills-catalog-card")[0];
    expect(main.querySelector('[data-skill="backblaze-b2-backups"]')).toBeNull();
    expect(container.querySelector(".skills-oldcopies")!.textContent).toContain("Old copies (1)");
    expect(screen.getByRole("button", { name: /Needs attention/ }).textContent).toContain("2");
    // Resolve is one menu item, and Remove copies prunes.
    fireEvent.click(screen.getByRole("button", { name: "Actions for spark-lean-offload" }));
    expect(screen.getByRole("menuitem", { name: "Resolve…" })).toBeTruthy();
    expect(screen.queryByRole("menuitem", { name: /Keep|Discard/ })).toBeNull();
    fireEvent.keyDown(document.activeElement ?? document.body, { key: "Escape" });
    fireEvent.click(screen.getByRole("button", { name: "Actions for agent-browser" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Remove copies" }));
    await waitFor(() => expect(syncCalls.some((c) => c.prune_removed)).toBe(true));
  });
});
