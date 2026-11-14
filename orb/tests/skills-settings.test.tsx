import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SkillsSettings, knownSkillNames } from "../src/SkillsSettings";
import { clearConnection, setConnection } from "../src/api";
import { rememberKnownSkillNames } from "../src/skillsApi";
import { cachedSkillsReport, rememberSkillsReport } from "../src/skillCache";
import { syncConnectedLibraryToLocalHarnesses } from "../src/localLibrarySync";
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
        global_rel: "~/.gemini/config/skills",
        global_path: "/Users/thomas/.gemini/config/skills",
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
  it("opens a skill as its own page and previews delivery under Advanced", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string) => Promise<unknown> } } }).__TAURI__ = { core: { invoke: async () => null } };
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "spark-lean-offload", path: "skill/spark-lean-offload", audience: ["mission", "local"] }]);
      if (url.endsWith("/api/projects")) return ok({ projects: [{ slug: "erdos-647", title: "Erdos 647 Proof", status: "active", updated_at: "2026-10-08T12:00:00Z" }] });
      if (url.includes("/api/projects/erdos-647/skills")) return new Response("", { status: 404 });
      if (url.includes("/api/library/skill-delivery")) return ok({ skills: [{ name: "spark-lean-offload", reasons: ["base", "project"] }], missing: [] });
      return ok({});
    });
    const opened: string[] = [];
    render(() => <SkillsSettings onOpenPage={(id) => opened.push(id)} />);
    fireEvent.click(await screen.findByText("spark-lean-offload"));
    expect(opened).toEqual(["sk:spark-lean-offload"]);
    expect(screen.queryByRole("dialog")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Actions for spark-lean-offload" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "History" }));
    expect(opened.at(-1)).toBe("sk:spark-lean-offload#history");

    const advanced = document.querySelector<HTMLDetailsElement>("details.skills-advanced")!;
    advanced.open = true;
    fireEvent(advanced, new Event("toggle"));
    const select = (await screen.findByLabelText("Preview project")) as HTMLSelectElement;
    // Rows show before projects load; wait for the project to be offered.
    await waitFor(() => expect(Array.from(select.options).some((o) => o.value === "erdos-647")).toBe(true));
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

  it("auto-mints a local coordinator MCP session and wires sandboxed-mcp when skills sync", async () => {
    setConnection("https://agent-backend.thomas.md", "test-jwt");
    let mcpReady = false;
    const syncCalls: any[] = [];
    const extSessionPosts: any[] = [];

    const buildMcpReport = (): LocalSkillsReport => ({
      ...sampleLocalReport(true),
      mcp: mcpReady
        ? {
            ready: true,
            needs_token: false,
            binary_ready: true,
            binary_path: "/Applications/Orb.app/Contents/MacOS/sandboxed-mcp",
            credential_path: "/Users/thomas/.orb/mcp/credential",
            api_url: "https://agent-backend.thomas.md",
            session_id: "sess-local-1",
            role: "coordinator",
            hard_expires_at: Math.floor(Date.now() / 1000) + 86400 * 30,
            synced_harnesses: ["claudecode", "codex", "antigravity", "opencode"],
            missing_harnesses: [],
          }
        : {
            ready: false,
            needs_token: true,
            binary_ready: true,
            binary_path: "/Applications/Orb.app/Contents/MacOS/sandboxed-mcp",
            credential_path: "/Users/thomas/.orb/mcp/credential",
            api_url: "https://agent-backend.thomas.md",
            session_id: null,
            role: "coordinator",
            hard_expires_at: null,
            synced_harnesses: [],
            missing_harnesses: ["claudecode", "codex", "antigravity", "opencode"],
          },
    });

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") return buildMcpReport();
          if (cmd === "approval_key_status") return { available: false, public_key: null };
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            if (args.request?.mcp_session?.token) mcpReady = true;
            return {
              synced_skills: 1,
              harnesses_updated: 0,
              skipped_unmanaged: [],
              pruned: [],
              mcp_synced_harnesses: mcpReady ? ["claudecode", "codex", "antigravity", "opencode"] : [],
              mcp_error: null,
              report: buildMcpReport(),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "paloma-backends", path: "skill/paloma-backends" }]);
      if (url.endsWith("/api/library/skill/paloma-backends")) return ok({ name: "paloma-backends", path: "skill/paloma-backends", content: "---\nname: paloma-backends\n---\n", files: [], references: [] });
      if (url.endsWith("/api/mcp/external-sessions") && init?.method === "POST") {
        extSessionPosts.push(JSON.parse(String(init.body ?? "{}")));
        return ok({
          token: "mcp1.local-test-token",
          session_id: "sess-local-1",
          role: "coordinator",
          expires_at: Math.floor(Date.now() / 1000) + 3600,
          hard_expires_at: Math.floor(Date.now() / 1000) + 86400 * 30,
        });
      }
      return ok({});
    });

    const { container } = render(() => <SkillsSettings />);
    await waitFor(() => expect(syncCalls).toHaveLength(1));
    expect(extSessionPosts).toEqual([
      {
        role: "coordinator",
        client_kind: "local_mcp",
        client_label: "Local Harnesses",
        ttl_days: 30,
      },
    ]);
    expect(syncCalls[0]).toMatchObject({
      api_url: "https://agent-backend.thomas.md",
      mcp_session: {
        api_url: "https://agent-backend.thomas.md",
        token: "mcp1.local-test-token",
        session_id: "sess-local-1",
        role: "coordinator",
      },
    });

    const advanced = container.querySelector<HTMLDetailsElement>("details.skills-advanced")!;
    advanced.open = true;
    fireEvent(advanced, new Event("toggle"));
    expect(await screen.findByText("Synced · 4 harnesses")).toBeTruthy();
  });

  it("still syncs SKILL.md files cleanly and offers Connect MCP if external session minting fails", async () => {
    setConnection("https://mx-fail.thomas.md", "test-jwt");
    const syncCalls: any[] = [];
    let allowMint = false;
    let mcpReady = false;

    const buildDriftedMcpReport = (skillsSynced: boolean): LocalSkillsReport => ({
      ...sampleLocalReport(skillsSynced),
      mcp: mcpReady
        ? {
            ready: true,
            needs_token: false,
            binary_ready: true,
            binary_path: "/Applications/Orb.app/Contents/MacOS/sandboxed-mcp",
            credential_path: "/Users/thomas/.orb/mcp/credential",
            api_url: "https://mx-fail.thomas.md",
            session_id: "sess-retry-2",
            role: "coordinator",
            hard_expires_at: Math.floor(Date.now() / 1000) + 86400 * 30,
            synced_harnesses: ["claudecode", "codex", "antigravity", "opencode"],
            missing_harnesses: [],
          }
        : {
            ready: false,
            needs_token: true,
            binary_ready: true,
            binary_path: "/Applications/Orb.app/Contents/MacOS/sandboxed-mcp",
            credential_path: "/Users/thomas/.orb/mcp/credential",
            api_url: "https://mx-fail.thomas.md",
            session_id: null,
            role: "coordinator",
            hard_expires_at: null,
            synced_harnesses: [],
            missing_harnesses: ["antigravity"],
          },
    });

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") return buildDriftedMcpReport(syncCalls.length > 0);
          if (cmd === "approval_key_status") return { available: false, public_key: null };
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            if (args.request?.mcp_session?.token) mcpReady = true;
            return {
              synced_skills: 1,
              harnesses_updated: 2,
              skipped_unmanaged: [],
              pruned: [],
              mcp_synced_harnesses: mcpReady ? ["claudecode", "codex", "antigravity", "opencode"] : [],
              mcp_error: null,
              report: buildDriftedMcpReport(true),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill")) return ok([{ name: "paloma-backends", path: "skill/paloma-backends" }]);
      if (url.endsWith("/api/library/skill/paloma-backends")) return ok({ name: "paloma-backends", path: "skill/paloma-backends", content: "---\nname: paloma-backends\n---\n", files: [], references: [] });
      if (url.endsWith("/api/mcp/external-sessions") && init?.method === "POST") {
        if (!allowMint) return new Response(JSON.stringify({ error: "device_approval_required" }), { status: 403 });
        return ok({
          token: "mcp1.retry-token",
          session_id: "sess-retry-2",
          role: "coordinator",
          expires_at: Math.floor(Date.now() / 1000) + 3600,
          hard_expires_at: Math.floor(Date.now() / 1000) + 86400 * 30,
        });
      }
      return ok({});
    });

    const { container } = render(() => <SkillsSettings />);
    await waitFor(() => expect(syncCalls).toHaveLength(1));
    expect(syncCalls[0].mcp_session).toBeUndefined();

    const advanced = container.querySelector<HTMLDetailsElement>("details.skills-advanced")!;
    advanced.open = true;
    fireEvent(advanced, new Event("toggle"));
    const connectBtn = await screen.findByRole("button", { name: "Connect MCP" });
    allowMint = true;
    fireEvent.click(connectBtn);
    expect(await screen.findByText("Synced · 4 harnesses")).toBeTruthy();
  });

  it("background startup sync uses ?include=bundle in 1 request and syncs drifted harnesses without opening Settings", async () => {
    setConnection("https://orbcore.thomas.md", "test-jwt");
    let synced = false;
    const syncCalls: any[] = [];
    const fetchedUrls: string[] = [];

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") return sampleLocalReport(synced);
          if (cmd === "local_skills_sync") {
            synced = true;
            syncCalls.push(args.request);
            return {
              synced_skills: 1,
              harnesses_updated: 2,
              skipped_unmanaged: [],
              pruned: [],
              report: sampleLocalReport(true),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      fetchedUrls.push(url);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill?include=bundle")) {
        return ok([
          {
            name: "orb-basics",
            path: "skill/orb-basics",
            audience: ["mission", "local"],
            scope: "global",
            content: "---\nname: orb-basics\n---\n# Basics\n",
            files: [{ name: "guide.md", path: "references/guide.md", content: "# Guide\n" }],
            references: [],
          },
        ]);
      }
      return ok({});
    });

    const res1 = await syncConnectedLibraryToLocalHarnesses({
      onlyIfNeeded: true,
      pruneRemoved: true,
      skipMcpMint: true,
    });
    expect(res1?.harnesses_updated).toBe(2);
    expect(fetchedUrls).toEqual(["https://orbcore.thomas.md/api/library/skill?include=bundle"]);
    expect(syncCalls).toHaveLength(1);
    expect(syncCalls[0]).toMatchObject({
      library_loaded: true,
      prune_removed: true,
      library_skills: [
        {
          name: "orb-basics",
          audience: ["mission", "local"],
          scope: "global",
          files: [{ rel: "references/guide.md", content: "# Guide\n" }],
        },
      ],
    });

    // Second check when already synced performs zero disk sync calls.
    const res2 = await syncConnectedLibraryToLocalHarnesses({
      onlyIfNeeded: true,
      pruneRemoved: true,
      skipMcpMint: true,
    });
    expect(res2).toBeNull();
    expect(syncCalls).toHaveLength(1);
  });

  it("disables pruning and marks snapshot incomplete when any skill or companion file fetch fails", async () => {
    setConnection("https://orbcore.thomas.md", "test-jwt");
    const statusCalls: any[] = [];
    const syncCalls: any[] = [];

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") {
            statusCalls.push(args.request);
            return sampleLocalReport(false);
          }
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            return {
              synced_skills: 1,
              harnesses_updated: 2,
              skipped_unmanaged: [],
              pruned: [],
              report: sampleLocalReport(true),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill?include=bundle") || url.endsWith("/api/library/skill")) {
        return ok([
          { name: "orb-basics", path: "skill/orb-basics" },
          { name: "ops", path: "skill/ops" },
        ]);
      }
      if (url.endsWith("/api/library/skill/orb-basics")) {
        return ok({
          name: "orb-basics",
          path: "skill/orb-basics",
          audience: ["mission", "local"],
          scope: "global",
          content: "---\nname: orb-basics\n---\n# Basics\n",
          files: [],
          references: [],
        });
      }
      if (url.endsWith("/api/library/skill/ops")) {
        return new Response("upstream timeout", { status: 502 });
      }
      return ok({});
    });

    const res = await syncConnectedLibraryToLocalHarnesses({
      onlyIfNeeded: true,
      pruneRemoved: true,
      skipMcpMint: true,
    });
    expect(res?.harnesses_updated).toBe(2);
    expect(statusCalls).toHaveLength(1);
    expect(statusCalls[0]).toMatchObject({
      library_loaded: false,
      library_skills: [{ name: "orb-basics" }],
    });
    expect(syncCalls).toHaveLength(1);
    expect(syncCalls[0]).toMatchObject({
      library_loaded: false,
      prune_removed: false,
      library_skills: [{ name: "orb-basics" }],
    });
  });

  it("transfers binary companion files as base64 without UTF-8 corruption and keeps out-of-line references in status payloads", async () => {
    setConnection("https://orbcore.thomas.md", "test-jwt");
    const statusCalls: any[] = [];
    const syncCalls: any[] = [];
    const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff]);

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") {
            statusCalls.push(args.request);
            return sampleLocalReport(false);
          }
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            return {
              synced_skills: 1,
              harnesses_updated: 2,
              skipped_unmanaged: [],
              pruned: [],
              report: sampleLocalReport(true),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
      if (url.endsWith("/api/library/skill?include=bundle")) {
        return ok([
          {
            name: "visual-skill",
            path: "skill/visual-skill",
            audience: ["mission", "local"],
            scope: "on-demand",
            content: "---\nname: visual-skill\n---\n# Visual\n",
            files: [],
            references: ["assets/logo.png", "references/large-guide.md"],
          },
        ]);
      }
      if (url.endsWith("/api/library/skill/visual-skill/files/assets/logo.png")) {
        return new Response(pngBytes, { status: 200, headers: { "Content-Type": "application/octet-stream" } });
      }
      if (url.endsWith("/api/library/skill/visual-skill/files/references/large-guide.md")) {
        return new Response("# Large Guide\n", { status: 200, headers: { "Content-Type": "text/plain" } });
      }
      return ok({});
    });

    const res = await syncConnectedLibraryToLocalHarnesses({
      onlyIfNeeded: true,
      pruneRemoved: true,
      skipMcpMint: true,
    });
    expect(res?.harnesses_updated).toBe(2);
    const expectedBase64 = btoa(String.fromCharCode(...pngBytes));
    expect(statusCalls[0].library_skills[0].files).toEqual([
      { rel: "assets/logo.png", content: "", content_base64: expectedBase64 },
      { rel: "references/large-guide.md", content: "# Large Guide\n" },
    ]);
    expect(syncCalls[0].library_skills[0].files).toEqual([
      { rel: "assets/logo.png", content: "", content_base64: expectedBase64 },
      { rel: "references/large-guide.md", content: "# Large Guide\n" },
    ]);
  });

  it("aborts in-flight local skill sync when backend connection switches mid-sync", async () => {
    setConnection("https://old-core.example", "jwt-old");
    const syncCalls: any[] = [];

    (window as unknown as { __TAURI__: { core: { invoke: (cmd: string, args?: any) => Promise<unknown> } } }).__TAURI__ = {
      core: {
        invoke: async (cmd: string, args?: any) => {
          if (cmd === "local_skills_status") {
            // Simulate user switching to another backend while `local_skills_status` is pending.
            setConnection("https://new-core.example", "jwt-new");
            return sampleLocalReport(false);
          }
          if (cmd === "local_skills_sync") {
            syncCalls.push(args.request);
            return {
              synced_skills: 1,
              harnesses_updated: 1,
              skipped_unmanaged: [],
              pruned: [],
              report: sampleLocalReport(true),
            };
          }
          return null;
        },
      },
    };

    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/library/skill?include=bundle")) {
        return new Response(
          JSON.stringify([
            {
              name: "old-backend-skill",
              path: "skill/old-backend-skill",
              audience: ["mission", "local"],
              scope: "on-demand",
              content: "---\nname: old-backend-skill\n---\n# Old\n",
              files: [],
              references: [],
            },
          ]),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }
      return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
    });

    const res = await syncConnectedLibraryToLocalHarnesses({
      onlyIfNeeded: true,
      pruneRemoved: true,
      skipMcpMint: true,
    });
    expect(res).toBeNull();
    expect(syncCalls).toHaveLength(0);
  });
});


describe("Library account isolation", () => {
  it("drops skill names and report bodies when the signed-in account changes", () => {
    setConnection("https://library.invalid", "fixture-owner-session");
    rememberKnownSkillNames(["owner-private-skill"]);
    rememberSkillsReport(sampleLocalReport());
    expect(knownSkillNames()).toContain("owner-private-skill");
    expect(cachedSkillsReport()).not.toBeNull();
    setConnection("https://library.invalid", "fixture-member-session");
    expect(knownSkillNames()).toEqual([]);
    expect(cachedSkillsReport()).toBeNull();
    rememberKnownSkillNames(["member-private-skill"]);
    expect(knownSkillNames()).toEqual(["member-private-skill"]);
    clearConnection();
  });
});
