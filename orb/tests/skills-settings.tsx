import { render } from "solid-js/web";
import { SkillsSettings } from "../src/SkillsSettings";
import { setConnection } from "../src/api";
import type { LocalSkillsReport } from "../src/localAgents";
import "../src/styles.css";

document.documentElement.dataset.theme = new URLSearchParams(location.search).get("theme") ?? "dark";
setConnection(location.origin, "fixture-jwt");

let synced = false;

function buildReport(): LocalSkillsReport {
  const fullHarnesses = ["claudecode", "codex", "antigravity", "opencode", "grok"];
  const preSyncHarnesses = ["claudecode", "codex", "grok"];
  const activeHarnesses = synced ? fullHarnesses : preSyncHarnesses;

  return {
    checked_at: Math.floor(Date.now() / 1000),
    home_dir: "/Users/thomas",
    preflight: {
      python3_ready: true,
      python3_version: "3.12.4",
      pyyaml_ready: true,
      preflight_error: null,
      identity_ready: true,
      identity_fingerprint: "8F91C4A02D73E110",
      identity_updated_at: 1728300000,
    },
    sources: [
      {
        id: "agent-skills-repo",
        label: "Agent Skills Repo",
        path: "~/work/skills/skills",
        exists: true,
        skill_count: 37,
      },
      {
        id: "paloma-skills",
        label: "Paloma Skills",
        path: "~/work/paloma/skills",
        exists: true,
        skill_count: 2,
      },
      {
        id: "workspace-library",
        label: "Workspace Library Checkout",
        path: "~/work/paloma/sandboxed_sh/context/sandboxed-library/skill",
        exists: true,
        skill_count: 6,
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
        skill_count: synced ? 37 : 2,
        synced_count: synced ? 37 : 2,
        canonical_total: 37,
        missing_skills: synced
          ? []
          : [
              "paloma-backends",
              "paloma-ssh-servers",
              "controllers-policy",
              "project-manager",
              "sandboxed-sh-missions",
            ],
      },
      {
        id: "opencode",
        name: "OpenCode",
        global_rel: "~/.config/opencode/skills",
        global_path: "/Users/thomas/.config/opencode/skills",
        project_rel: ".opencode/skills",
        exists: synced,
        skill_count: synced ? 37 : 0,
        synced_count: synced ? 37 : 0,
        canonical_total: 37,
        missing_skills: synced ? [] : ["paloma-backends", "paloma-ssh-servers"],
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
        name: "controllers-policy",
        description: "Autonomous controller loop discipline, state signature trailers, and mission delegation rules.",
        origin: "Paloma Skills",
        source_path: "~/work/paloma/skills/controllers-policy",
        harnesses: activeHarnesses,
        managed: true,
        content_preview:
          "---\nname: controllers-policy\ndescription: Autonomous controller loop discipline.\n---\n\n# Controllers Policy\n\nAlways emit [STATE_SIGNATURE: ...] at the end of a controller tick.",
      },
      {
        name: "development-identity",
        description: "Use the shared Paloma development identity for GitHub, signed commits, and fleet SSH.",
        origin: "Development Identity",
        source_path: "~/.config/sandboxed-sh/development-identity/current/skill",
        harnesses: fullHarnesses,
        managed: true,
        content_preview:
          "---\nname: development-identity\ndescription: Shared Paloma git/SSH identity.\n---\n\n# Development Identity\n",
      },
      {
        name: "paloma-backends",
        description: "Architecture map of agent-core, sandboxed.sh harnesses, and isolated workspace execution.",
        origin: "Paloma Skills",
        source_path: "~/work/paloma/skills/paloma-backends",
        harnesses: activeHarnesses,
        managed: true,
        content_preview:
          "---\nname: paloma-backends\ndescription: Architecture map of agent-core.\n---\n\n# Paloma Backends\n",
      },
      {
        name: "paloma-ssh-servers",
        description: "Inventory of Tailscale and public SSH fleet nodes (Ashur, Babylon, Nippur, DGX Spark).",
        origin: "Paloma Skills",
        source_path: "~/work/paloma/skills/paloma-ssh-servers",
        harnesses: activeHarnesses,
        managed: true,
        content_preview:
          "---\nname: paloma-ssh-servers\ndescription: Fleet SSH inventory.\n---\n\n# Fleet Servers\n",
      },
      {
        name: "spark-lean-offload",
        description: "Offload heavy Lean 4 and Mathlib builds to the 128 GB DGX Spark arbiter.",
        origin: "Agent Skills Repo",
        source_path: "~/work/skills/skills/spark-lean-offload",
        harnesses: activeHarnesses,
        managed: true,
        content_preview:
          "---\nname: spark-lean-offload\ndescription: Offload Lean 4 builds.\n---\n\n# Spark Build Offload\n",
      },
    ],
  };
}

const origFetch = window.fetch.bind(window);
window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input);
  if (url.endsWith("/api/library/skill")) {
    return new Response(
      JSON.stringify([
        {
          name: "controllers-policy",
          description: "Autonomous controller loop discipline, state signature trailers, and mission delegation rules.",
          path: "skill/controllers-policy",
        },
        {
          name: "sandboxed-sh-missions",
          description: "Dispatch, monitor, and steer isolated coding missions over MCP.",
          path: "skill/sandboxed-sh-missions",
        },
      ]),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/library/skill/")) {
    const name = decodeURIComponent(url.split("/api/library/skill/")[1]);
    return new Response(
      JSON.stringify({
        name,
        description: `Library skill ${name}`,
        path: `skill/${name}`,
        content: `---\nname: ${name}\n---\n# ${name}\n`,
        files: [],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.endsWith("/api/projects")) {
    return new Response(
      JSON.stringify({
        projects: [
          {
            slug: "erdos-647",
            title: "Erdos 647 Formalization",
            status: "active",
            updated_at: "2026-10-08T14:00:00Z",
          },
          {
            slug: "paloma-core",
            title: "Paloma Control Plane",
            status: "active",
            updated_at: "2026-10-08T14:30:00Z",
          },
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/projects/erdos-647/files?path=skills")) {
    return new Response(
      JSON.stringify({
        entries: [
          { name: "aristotle-lean", kind: "dir" },
          { name: "Blueprint-check", kind: "dir" },
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/projects/paloma-core/files?path=skills")) {
    return new Response(
      JSON.stringify({
        entries: [{ name: "nspawn-isolation", kind: "dir" }],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/projects/") && url.includes("/file?path=skills")) {
    return new Response(
      JSON.stringify({
        content: "---\nname: project-skill\ndescription: Project specific skill\n---\n# Skill\n",
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/remote-nodes")) {
    return new Response(
      JSON.stringify({
        enabled: true,
        nodes: [
          { id: "dgx-spark", base_url: "http://100.77.4.93:3088", token_env: "SPARK", status: "online", labels: [], version: "0.1.0", capacity_total: 4, capacity_available: 3, active_jobs: 1, queued_jobs: 0, last_seen: null, error: null, cordoned: false },
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  if (url.includes("/api/software")) {
    return new Response(
      JSON.stringify({
        checked_at: Math.floor(Date.now() / 1000),
        runtime: { name: "sandboxed-sh", version: "0.1.0", build: "prod", path: "/usr/local/bin/sandboxed-sh-prod", restart_required: false },
        jobs: [],
        components: [
          { id: "claudecode", name: "Claude Code", version: "2.1.10", path: "/usr/local/bin/claude", installed: true, owner: "npm", update_supported: true, latest: "2.1.10", release_error: null, running: [], instructions: "" },
          { id: "codex", name: "Codex", version: "0.118.0", path: "/usr/local/bin/codex", installed: true, owner: "npm", update_supported: true, latest: "0.118.0", release_error: null, running: [], instructions: "" },
          { id: "opencode", name: "OpenCode", version: "1.3.0", path: "/usr/local/bin/opencode", installed: true, owner: "npm", update_supported: true, latest: "1.3.0", release_error: null, running: [], instructions: "" },
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
  return origFetch(input, init);
};

(window as any).__TAURI__ = {
  core: {
    invoke: async (name: string) => {
      if (name === "local_skills_status") return buildReport();
      if (name === "local_skills_sync") {
        synced = true;
        return {
          synced_skills: 37,
          harnesses_updated: 2,
          skipped_unmanaged: [],
          report: buildReport(),
        };
      }
      if (name === "local_agents_scan") {
        return [
          { id: "claudecode", bin: "claude", path: "/usr/local/bin/claude", version: "2.1.10", installed: true },
          { id: "codex", bin: "codex", path: "/usr/local/bin/codex", version: "0.118.0", installed: true },
          { id: "antigravity", bin: "agy", path: "/usr/local/bin/agy", version: "0.2.1", installed: true },
          { id: "opencode", bin: "opencode", path: "/opt/homebrew/bin/opencode", version: "1.3.0", installed: true },
          { id: "grok", bin: "grok", path: "/usr/local/bin/grok", version: "0.4.2", installed: true },
        ];
      }
      if (name === "software_inventory") {
        return {
          checked_at: Math.floor(Date.now() / 1000),
          runtime: { name: "Orb runner", version: "0.1.0", build: "0.1.0", path: "/Applications/Orb.app", restart_required: false },
          jobs: [],
          components: [],
        };
      }
      return null;
    },
  },
};

render(
  () => (
    <div class="app settings-view" style={{ height: "100vh", display: "flex", "flex-direction": "column" }}>
      <SkillsSettings />
    </div>
  ),
  document.getElementById("root")!,
);
