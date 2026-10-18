import { describe, expect, it } from "vitest";
import { compactDiff, effectiveAudience, lineDiff, lintSkill, newSkillTemplate, parseSkillMeta, setSandboxedMeta } from "../src/skillModel";
import { buildSkillRows, filterSkillRows } from "../src/skillRows";

const GOOD_DESC = "Inspect and manage Paloma VPS hosts and fleet backends safely.";

describe("frontmatter metadata", () => {
  it("parses inline and block audiences and defaults when absent", () => {
    const inline = parseSkillMeta("---\nname: a\nmetadata:\n  sandboxed:\n    audience: [coordinator, 'local']\n    scope: global\n---\n# A\n");
    expect(inline).toMatchObject({ name: "a", audience: ["coordinator", "local"], scope: "global", hasSandboxedMeta: true });
    const block = parseSkillMeta("---\nname: b\nmetadata:\n  owner: me\n  sandboxed:\n    audience:\n      - mission\n---\n");
    expect(block.audience).toEqual(["mission"]);
    const none = parseSkillMeta("---\nname: c\ndescription: |\n  Multi\n  line\n---\n");
    expect(none).toMatchObject({ description: "Multi line", hasSandboxedMeta: false });
    expect(none.audience).toBeUndefined();
    expect(effectiveAudience(none)).toEqual(["mission", "local"]);
  });

  it("adds metadata.sandboxed while keeping other keys and the body", () => {
    const src = "---\nname: a\ndescription: x\nallowed-tools: [Bash]\n---\n# Body\n\ntext\n";
    const out = setSandboxedMeta(src, ["local", "coordinator"], "global");
    expect(out).toBe("---\nname: a\ndescription: x\nallowed-tools: [Bash]\nmetadata:\n  sandboxed:\n    audience: [coordinator, local]\n    scope: global\n---\n# Body\n\ntext\n");
    expect(parseSkillMeta(out)).toMatchObject({ audience: ["coordinator", "local"], scope: "global" });
  });

  it("rewrites an existing sandboxed block, preserving sibling metadata", () => {
    const src = "---\nname: a\nmetadata:\n  owner: me\n  sandboxed:\n    audience:\n      - mission\n    scope: global\n    tier: 2\n  other: y\n---\nBody\n";
    const out = setSandboxedMeta(src, ["mission", "local"], null);
    expect(out).toBe("---\nname: a\nmetadata:\n  owner: me\n  sandboxed:\n    audience: [mission, local]\n    tier: 2\n  other: y\n---\nBody\n");
    // Idempotent.
    expect(setSandboxedMeta(out, ["mission", "local"], null)).toBe(out);
  });

  it("creates frontmatter when missing", () => {
    const out = setSandboxedMeta("# Just body\n", ["local"], null, "solo");
    expect(parseSkillMeta(out)).toMatchObject({ name: "solo", audience: ["local"], hasFrontmatter: true });
    expect(out.endsWith("# Just body\n")).toBe(true);
  });

  it("template passes lint except for a short description", () => {
    expect(lintSkill("new-one", newSkillTemplate("new-one", GOOD_DESC))).toEqual([]);
    expect(lintSkill("new-one", newSkillTemplate("new-one", "A new skill")).map((l) => l.id)).toEqual(["description"]);
  });
});

describe("lint", () => {
  const ok = (body = "") => `---\nname: s\ndescription: ${GOOD_DESC}\nmetadata:\n  sandboxed:\n    audience: [local]\n---\n${body}`;
  it("flags missing or weak descriptions, name mismatch and missing metadata", () => {
    const ids = lintSkill("folder", "---\nname: other\n---\n").map((l) => l.id);
    expect(ids).toEqual(["description", "name", "metadata"]);
    expect(lintSkill("s", ok()).length).toBe(0);
  });
  it("flags long files and raw IPv4 except in paloma-infra", () => {
    expect(lintSkill("s", ok("x\n".repeat(520))).map((l) => l.id)).toEqual(["length"]);
    expect(lintSkill("s", ok("ssh root@65.109.98.246\n")).map((l) => l.id)).toEqual(["ipv4"]);
    expect(lintSkill("s", ok("version 1.2.3.4.5 and 127.0.0.1\n"))).toEqual([]);
    const infra = ok("ssh root@65.109.98.246\n").replace("name: s", "name: paloma-infra");
    expect(lintSkill("paloma-infra", infra)).toEqual([]);
  });
});

describe("line diff", () => {
  it("produces minimal adds and deletes with context compaction", () => {
    const a = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"].join("\n");
    const b = ["a", "b", "c", "D", "e", "f", "g", "h", "i", "j", "k"].join("\n");
    const d = lineDiff(a, b);
    expect(d.filter((l) => l.op === "-").map((l) => l.text)).toEqual(["d"]);
    expect(d.filter((l) => l.op === "+").map((l) => l.text)).toEqual(["D", "k"]);
    expect(d.filter((l) => l.op === " ").length).toBe(9);
    const c = compactDiff(lineDiff(["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "x"].join("\n"), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "y"].join("\n")), 1);
    expect(c[0]).toEqual({ op: "…", text: "9 unchanged lines" });
  });
  it("treats CRLF as equal and falls back on huge inputs", () => {
    expect(lineDiff("a\r\nb", "a\nb").every((l) => l.op === " ")).toBe(true);
    const big = lineDiff("a\nb\nc", "x\ny\nz", 1);
    expect(big.map((l) => l.op).join("")).toBe("---+++");
  });
});

describe("skill rows", () => {
  it("merges Library, legacy, identity and project sources with problem filters", () => {
    const rows = buildSkillRows({
      summaries: [{ name: "lib-skill", path: "skill/lib-skill", audience: ["coordinator"] }],
      library: { "lib-skill": { name: "lib-skill", path: "skill/lib-skill", content: `---\nname: lib-skill\ndescription: ${GOOD_DESC}\n---\n` } },
      report: {
        checked_at: 0, home_dir: "/h", library_known: true,
        preflight: { python3_ready: true, pyyaml_ready: true, identity_ready: false },
        sources: [], harnesses: [],
        skills: [
          { name: "old", origin: "Paloma Skills", harnesses: ["claudecode"], managed: true, legacy_only: true, audience: ["mission", "local"], lines: 3,
            sources: [{ id: "paloma-skills", label: "Paloma Skills", legacy: true, hash: "1", lines: 3, content: "---\nname: old\n---\n" }] },
          { name: "lib-skill", origin: "Library", harnesses: [], managed: false, divergent: true, in_library: true,
            sources: [{ id: "library", label: "Library", legacy: false, hash: "a", lines: 4 }, { id: "agent-skills-repo", label: "Agent Skills Repo", legacy: true, hash: "b", lines: 4, content: "x" }] },
        ],
      },
      projectSkills: [{ slug: "p1", name: "proj-only", path: "skills/proj-only/SKILL.md" }],
      localHarnessIds: ["claudecode", "codex"],
    });
    expect(rows.map((r) => r.name)).toEqual(["lib-skill", "old", "proj-only"]);
    const lib = rows[0];
    expect(lib.sourceKinds).toEqual(["Library", "legacy"]);
    expect(lib.audience).toEqual(["coordinator"]);
    expect(lib.divergent).toBe(true);
    expect(rows[1]).toMatchObject({ legacyOnly: true, harnessCount: 1, sourceKinds: ["legacy"] });
    const f = (problem: Parameters<typeof filterSkillRows>[1]["problem"], audience = "all") =>
      filterSkillRows(rows, { query: "", audience, scope: "all", problem, harnessTotal: 2 }).map((r) => r.name);
    expect(f("divergent")).toEqual(["lib-skill"]);
    expect(f("legacy")).toEqual(["old"]);
    expect(f("all", "coordinator")).toEqual(["lib-skill"]);
    expect(f("lint")).toEqual(["lib-skill", "old"]);
  });
});
