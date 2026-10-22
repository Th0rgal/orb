/**
 * Loose pipe tables: agents sometimes write tabular output as bare
 * `a | b | c` lines, with no outer pipes and no `| --- |` separator row.
 * Markdown does not see a table there, and soft line breaks collapse the
 * rows into one paragraph. `normalizeLoosePipeTables` rewrites such blocks
 * into GFM tables before parsing.
 *
 * Shared with iOS (OrbPipeTables.swift) and Android (OrbPipeTables.kt); the
 * rules and cases live in shared/orb-spec/fixtures/loose-pipe-tables.json.
 *
 * - Outside code fences, a candidate row has no `|` inside an inline code
 *   span, does not start with `|` (already GFM) or a block marker (`#`, `>`,
 *   list bullet), and every `|` has whitespace on both sides. Its cells are
 *   the text between those pipes; it needs at least 3 cells.
 * - A block is a run of at least 2 consecutive candidate rows with the same
 *   cell count. A block whose second row is a separator row is already a
 *   GFM table and is left alone.
 * - The first row is the header unless one of its cells is numeric; then the
 *   header row is empty (renderers hide an all-empty header).
 * - A column whose non-empty body cells are all numeric is right-aligned.
 * - While a reply streams, its last line (no newline yet) may be a row still
 *   arriving: directly after a block, with at least one pipe and fewer cells,
 *   it is padded and kept in the table so it does not jump in and out.
 * - The table is separated from surrounding text by blank lines.
 */

const NUMERIC = /^[+\-−]?[$€£]?\d[\d   ,.']*%?$/;
const SEPARATOR = /^:?-+:?$/;
const BLOCK_START = /^(?:#|>|[-*+]\s|\d+[.)]\s)/;

export function isNumericCell(cell: string): boolean {
  return NUMERIC.test(cell.trim());
}

/** The cells of a loose row, or null when the line is not one. */
export function loosePipeCells(line: string): string[] | null {
  if (/^ {4}|^\t/.test(line)) return null;
  const t = line.trim();
  if (!t.includes("|") || t.startsWith("|") || BLOCK_START.test(t)) return null;
  let inCode = false;
  let start = 0;
  const cells: string[] = [];
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (c === "`") inCode = !inCode;
    else if (c === "|") {
      if (inCode) return null;
      if (!/\s/.test(t[i - 1] ?? "") || !/\s/.test(t[i + 1] ?? "")) return null;
      cells.push(t.slice(start, i).trim());
      start = i + 1;
    }
  }
  cells.push(t.slice(start).trim());
  return cells.length >= 3 ? cells : null;
}

const row = (cells: string[]) => `| ${cells.join(" | ")} |`;

function gfmTable(rows: string[][]): string[] {
  const width = rows[0].length;
  const hasHeader = !rows[0].some((c) => c !== "" && isNumericCell(c));
  const head = hasHeader ? rows[0] : Array.from({length: width}, () => "");
  const body = hasHeader ? rows.slice(1) : rows;
  const aligns = head.map((_, col) => {
    const cells = body.map((r) => r[col] ?? "").filter((c) => c !== "");
    return cells.length > 0 && cells.every(isNumericCell) ? "---:" : "---";
  });
  return [row(head), row(aligns), ...body.map((r) => row([...r, ...Array(width - r.length).fill("")]))];
}

export function normalizeLoosePipeTables(src: string): string {
  if (!src.includes(" | ")) return src;
  const lines = src.split("\n");
  const out: string[] = [];
  let fence: string | null = null;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const marker = /^\s*(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence) {
      if (marker && marker[0] === fence[0] && marker.length >= fence.length) fence = null;
      out.push(line);
      i++;
      continue;
    }
    if (marker) {
      fence = marker;
      out.push(line);
      i++;
      continue;
    }
    const first = loosePipeCells(line);
    if (!first) {
      out.push(line);
      i++;
      continue;
    }
    const rows = [first];
    let j = i + 1;
    while (j < lines.length) {
      const cells = loosePipeCells(lines[j]);
      if (!cells || cells.length !== first.length) break;
      rows.push(cells);
      j++;
    }
    const isGfm = rows.length >= 2 && rows[1].every((c) => SEPARATOR.test(c.replace(/\s/g, "")));
    if (rows.length < 2 || isGfm) {
      out.push(...lines.slice(i, j));
      i = j;
      continue;
    }
    if (j === lines.length - 1 && lines[j].includes(" |")) {
      const t = lines[j].trim();
      const partial = t.split("|").map((c) => c.trim());
      if (partial.length < first.length && !t.startsWith("|")) {
        rows.push(partial);
        j++;
      }
    }
    if (out.length > 0 && out[out.length - 1].trim() !== "") out.push("");
    out.push(...gfmTable(rows));
    if (j < lines.length && lines[j].trim() !== "") out.push("");
    i = j;
  }
  return out.join("\n");
}
