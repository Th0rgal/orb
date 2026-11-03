/**
 * Glued opening code fences (shared/orb-spec/fixtures/glued-code-fences.json,
 * also replayed by the iOS and Android tests).
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, waitFor } from "@solidjs/testing-library";
import DOMPurify from "dompurify";
import { MdView, incrementalMarkdown, parseMarkdown } from "../src/Markdown";
import { normalizeGluedFences } from "../src/codeFences";
import { clearMermaidCache, setMermaidLoader } from "../src/mermaidRenderer";

const SPEC = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "glued-code-fences.json");
const cases = (JSON.parse(readFileSync(SPEC, "utf8")) as { cases: Array<{ name: string; input: string; output: string }> }).cases;
const byName = (name: string) => cases.find((c) => c.name.startsWith(name))!.input;

afterEach(() => {
  cleanup();
  setMermaidLoader(undefined);
  clearMermaidCache();
});

describe("shared/orb-spec/fixtures/glued-code-fences.json", () => {
  for (const c of cases) {
    it(c.name, () => {
      expect(normalizeGluedFences(c.input)).toBe(c.output);
      expect(normalizeGluedFences(c.output)).toBe(c.output);
    });
  }
});

describe("glued opening code fences in MdView and incrementalMarkdown", () => {
  it("parses and renders prod c7a89ff3 seq 219 with Mermaid block and trailing summary bullets intact", async () => {
    setMermaidLoader(async () => ({
      mermaid: {
        initialize: vi.fn(),
        parse: vi.fn(async () => true),
        render: vi.fn(async (id: string) => ({ svg: `<svg id="${id}" viewBox="0 0 120 40"><text>diagram</text></svg>` })),
      } as any,
      purify: DOMPurify,
    }));

    const input = byName("prod c7a89ff3 seq 219");
    const blocks = parseMarkdown(input);
    expect(blocks.map((b) => b.t)).toEqual(["ol", "p", "pre", "p", "ul"]);

    const intro = blocks[1] as Extract<(typeof blocks)[number], { t: "p" }>;
    expect(intro.text.endsWith("Let's present the updated diagram cleanly!")).toBe(true);
    expect(intro.text).not.toContain("```mermaid");

    const diagram = blocks[2] as Extract<(typeof blocks)[number], { t: "pre" }>;
    expect(diagram.lang).toBe("mermaid");
    expect(diagram.open).toBeUndefined();
    expect(diagram.text).toContain("flowchart TD");
    expect(diagram.text).toContain('Z["Final certificate"]');

    const summary = blocks[3] as Extract<(typeof blocks)[number], { t: "p" }>;
    expect(summary.text).toBe("Changes at `HEAD` (`fc02f3ccc`):");

    const bullets = blocks[4] as Extract<(typeof blocks)[number], { t: "ul" }>;
    expect(bullets.items).toHaveLength(3);

    const { container } = render(() => <MdView compact searchable text={input} />);
    await waitFor(() => expect(container.querySelector(".mermaid-block svg")).not.toBeNull());
    expect(container.textContent).toContain("Changes at HEAD (fc02f3ccc):");
    expect(container.textContent).toContain("Small leaves (fb_*)");
    expect(container.textContent).toContain("Stages 1–5");
    expect(container.textContent).toContain("Core specs (C00) & Memory rules");
    expect(container.querySelectorAll(".code-block")).toHaveLength(0);
  });

  it("keeps incremental streaming equivalent to full parsing across every prefix", () => {
    for (const c of cases) {
      const parse = incrementalMarkdown();
      for (let n = 0; n <= c.input.length; n++) {
        expect(parse(c.input.slice(0, n)), `${c.name} @ ${n}`).toEqual(parseMarkdown(c.input.slice(0, n)));
      }
    }
  });

  it("streams a large glued code fence in linear cost and matches full parsing", () => {
    const parse = incrementalMarkdown();
    let acc = "";
    for (let k = 0; k < 64; k++) {
      let chunk = k === 0 ? "Updated code cleanly!```rust\n" : "";
      let li = 0;
      while (chunk.length < 1024) {
        chunk += `pub fn step_${k}_${li}(x: u64) -> u64 { x ^ 0x55aa_${k} }\n`;
        li++;
      }
      acc += chunk.slice(0, 1024);
      expect(parse(acc)).toEqual(parseMarkdown(acc));
    }
    const openBytes = Buffer.byteLength(acc, "utf8");
    expect(parse.scannedBytes).toBeLessThanOrEqual(openBytes);
    expect(parse.parsedBytes).toBeLessThanOrEqual(openBytes * 2);

    acc += "\n```\n\nChanges at HEAD:\n- Done\n";
    expect(parse(acc)).toEqual(parseMarkdown(acc));
  });

  it("does not rewrite loose pipe lines inside a glued code fence", () => {
    const blocks = parseMarkdown(byName("pipes inside a glued code fence"));
    expect(blocks).toEqual([
      { t: "p", text: "Raw log:" },
      { t: "pre", lang: "text", text: "a | b | c\nd | e | f" },
      { t: "p", text: "Summary." },
    ]);
  });
});
