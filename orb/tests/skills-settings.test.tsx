import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SkillsSettings, knownSkillNames } from "../src/SkillsSettings";
import { clearConnection, setConnection } from "../src/api";
import type { LocalSkillsReport } from "../src/localAgents";

function sampleLocalReport(syncedAntigravity = false): LocalSkillsReport {
  const allHarnesses = syncedAntigravity
    ? ["claudecode", "codex", "antigravity", "opencode", "grok"]
    : ["claudecode", "codex", "grok"];
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

  it("renders harness compatibility matrix, detects drift, and syncs all harnesses", async () => {
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

    render(() => <SkillsSettings />);

    await waitFor(() => {
      expect(screen.getByText("Out of sync · 2/37")).toBeTruthy();
      expect(screen.getByText("Out of sync · 0/37")).toBeTruthy();
    });

    expect(screen.getByText("Ready · Python 3.12.4 + PyYAML")).toBeTruthy();
    expect(screen.getByText("Active · 4C8811A0")).toBeTruthy();
    expect(knownSkillNames()).toContain("paloma-backends");

    const syncBtn = screen.getByRole("button", { name: /Sync all harnesses \(2 drifted\)/i });
    fireEvent.click(syncBtn);

    await waitFor(() => {
      expect(screen.getByRole("status").textContent).toContain(
        "Synchronized 37 skills across all 5 local harness directories",
      );
    });

    expect(screen.queryByText("Out of sync · 2/37")).toBeNull();
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
      expect(screen.getByText("Erdos 647 Proof")).toBeTruthy();
      expect(screen.getByText("aristotle-tactics")).toBeTruthy();
    });

    fireEvent.click(screen.getByText("aristotle-tactics"));
    expect(opened).toEqual(["pf:erdos-647:skills/aristotle-tactics/SKILL.md"]);
  });
});
