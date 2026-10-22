/**
 * Loose pipe tables (shared/orb-spec/fixtures/loose-pipe-tables.json, also
 * replayed by the iOS and Android tests).
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { MdView, incrementalMarkdown, parseMarkdown } from "../src/Markdown";
import { normalizeLoosePipeTables } from "../src/pipeTables";

const SPEC = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "loose-pipe-tables.json");
const cases = (JSON.parse(readFileSync(SPEC, "utf8")) as { cases: Array<{ name: string; input: string; output: string }> }).cases;
const byName = (name: string) => cases.find((c) => c.name.startsWith(name))!.input;

describe("shared/orb-spec/fixtures/loose-pipe-tables.json", () => {
  for (const c of cases) {
    it(c.name, () => {
      expect(normalizeLoosePipeTables(c.input)).toBe(c.output);
      expect(normalizeLoosePipeTables(c.output)).toBe(c.output);
    });
  }
});

describe("loose pipe tables in MdView", () => {
  it("renders the prod usage reply as a table with right-aligned numbers", () => {
    const { container } = render(() => <MdView text={byName("prod 55518e2b")} />);
    expect(container.querySelectorAll("table")).toHaveLength(1);
    expect([...container.querySelectorAll("th")].map((th) => th.textContent)).toEqual(["modèle", "input", "output", "cache read", "cache write", "USD", "appels"]);
    expect(container.querySelectorAll("tbody tr")).toHaveLength(4);
    const first = [...container.querySelectorAll("tbody tr:first-child td")] as HTMLElement[];
    expect(first[0].style.textAlign).toBe("left");
    expect(first[1].textContent).toBe("3 915 038 024");
    expect(first.slice(1).every((td) => td.style.textAlign === "right")).toBe(true);
    expect(container.querySelector(".md-table-wrap table")).not.toBeNull();
    expect(container.querySelectorAll("p")).toHaveLength(1);
  });

  it("hides the empty header of a headerless block", () => {
    const { container } = render(() => <MdView text={byName("headerless")} />);
    expect(container.querySelector("thead")).toBeNull();
    expect(container.querySelectorAll("tbody tr")).toHaveLength(2);
  });

  it("leaves prose, code and real GFM tables as before", () => {
    for (const name of ["mixed column", "single line", "pipes inside code fences", "pipes inside inline code", "GFM table is unchanged", "GFM table without outer"]) {
      const input = byName(name);
      // Identity before parsing, so these parse exactly as before.
      expect(normalizeLoosePipeTables(input)).toBe(input);
    }
    expect(parseMarkdown("| a | b |\n|---|---:|\n| x | 1 |")).toEqual([{ t: "table", heads: ["a", "b"], rows: [["x", "1"]], aligns: ["left", "right"] }]);
  });

  it("streams without a table flickering in and out", () => {
    const text = byName("prod 55518e2b");
    const parse = incrementalMarkdown();
    const tableStart = text.indexOf("modèle");
    const secondRowEnd = text.indexOf("\n", text.indexOf("gpt-6.1-sol"));
    let seen = false;
    for (let n = 1; n <= text.length; n++) {
      const blocks = parse(text.slice(0, n));
      const tables = blocks.filter((b) => b.t === "table");
      if (n < secondRowEnd) {
        // Header plus one row still arriving: no table yet (it would need 2 complete rows).
        if (n > tableStart && text.slice(0, n).split("\n").at(-1)!.split(" | ").length < 7) expect(tables).toHaveLength(0);
      }
      if (seen) expect(tables, `prefix ${n}`).toHaveLength(1);
      if (tables.length) {
        seen = true;
        const t = tables[0] as Extract<(typeof blocks)[number], { t: "table" }>;
        expect(t.heads).toHaveLength(7);
        expect(t.rows.every((r) => r.length === 7)).toBe(true);
      }
    }
    expect(seen).toBe(true);
  });
});
