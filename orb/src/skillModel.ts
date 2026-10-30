// Pure helpers for the skills manager: frontmatter edits, lint rules and line diffs.

export const AUDIENCES = ["mission", "coordinator", "local"] as const;
export type Audience = (typeof AUDIENCES)[number];
export const DEFAULT_AUDIENCE: string[] = ["mission", "local"];

export interface SkillMeta {
  name?: string;
  description?: string;
  /** Explicit `metadata.sandboxed.audience`; `undefined` when absent. */
  audience?: string[];
  /** `metadata.sandboxed.scope`; `undefined` (on-demand) when absent. */
  scope?: string;
  hasSandboxedMeta: boolean;
  hasFrontmatter: boolean;
}

interface FrontmatterSplit {
  yaml: string[];
  body: string;
  newline: string;
}

function splitFrontmatter(markdown: string): FrontmatterSplit | null {
  const text = markdown.replace(/^﻿/, "");
  const newline = text.includes("\r\n") ? "\r\n" : "\n";
  const lines = text.split(/\r?\n/);
  if (lines[0] !== "---") return null;
  const end = lines.indexOf("---", 1);
  if (end < 0) return null;
  return { yaml: lines.slice(1, end), body: lines.slice(end + 1).join(newline), newline };
}

const indentOf = (line: string) => line.length - line.trimStart().length;

function unquote(value: string): string {
  const v = value.trim();
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
    return v.slice(1, -1).trim();
  }
  return v;
}

function inlineList(value: string): string[] {
  const v = value.trim();
  const inner = v.startsWith("[") && v.endsWith("]") ? v.slice(1, -1) : v;
  return inner.split(",").map(unquote).filter(Boolean);
}

/** Locate a nested mapping block (`key:`) under a parent range. Returns [start, end) line indexes. */
function findBlock(lines: string[], key: string, from: number, to: number, parentIndent: number): [number, number] | null {
  for (let i = from; i < to; i++) {
    const line = lines[i];
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const ind = indentOf(line);
    if (ind <= parentIndent) return null;
    if (t === `${key}:` || t.startsWith(`${key}: `) || t === `${key}: {}`) {
      let end = i + 1;
      while (end < to) {
        const next = lines[end];
        if (next.trim() && indentOf(next) <= ind) break;
        end++;
      }
      while (end > i + 1 && !lines[end - 1].trim()) end--;
      return [i, end];
    }
  }
  return null;
}

function topLevelBlock(lines: string[], key: string): [number, number] | null {
  return findBlock(lines, key, 0, lines.length, -1);
}

export function parseSkillMeta(markdown: string): SkillMeta {
  const fm = splitFrontmatter(markdown);
  if (!fm) return { hasSandboxedMeta: false, hasFrontmatter: false };
  const meta: SkillMeta = { hasSandboxedMeta: false, hasFrontmatter: true };
  const { yaml } = fm;
  for (let i = 0; i < yaml.length; i++) {
    const line = yaml[i];
    if (indentOf(line) !== 0) continue;
    const m = /^(name|description):\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if (["|", ">", "|-", ">-", ""].includes(value)) {
      const parts: string[] = [];
      while (i + 1 < yaml.length && (yaml[i + 1].startsWith(" ") || yaml[i + 1].startsWith("\t") || !yaml[i + 1].trim())) {
        i++;
        if (yaml[i].trim()) parts.push(yaml[i].trim());
      }
      value = parts.join(" ");
    } else value = unquote(value);
    if (m[1] === "name") meta.name = value || undefined;
    else meta.description = value || undefined;
  }
  const metadata = topLevelBlock(yaml, "metadata");
  if (metadata) {
    const sandboxed = findBlock(yaml, "sandboxed", metadata[0] + 1, metadata[1], indentOf(yaml[metadata[0]]));
    if (sandboxed) {
      meta.hasSandboxedMeta = true;
      const sInd = indentOf(yaml[sandboxed[0]]);
      for (let i = sandboxed[0] + 1; i < sandboxed[1]; i++) {
        const line = yaml[i];
        if (!line.trim() || indentOf(line) <= sInd) continue;
        const t = line.trim();
        if (t.startsWith("audience:")) {
          const rest = t.slice("audience:".length).trim();
          if (rest) meta.audience = inlineList(rest);
          else {
            const items: string[] = [];
            while (i + 1 < sandboxed[1] && /^\s*-/.test(yaml[i + 1])) {
              i++;
              const item = unquote(yaml[i].trim().replace(/^-\s*/, ""));
              if (item) items.push(item);
            }
            meta.audience = items;
          }
        } else if (t.startsWith("scope:")) {
          const v = unquote(t.slice("scope:".length));
          if (v) meta.scope = v;
        }
      }
    }
  }
  return meta;
}

export function effectiveAudience(meta: Pick<SkillMeta, "audience">): string[] {
  return (meta.audience ?? DEFAULT_AUDIENCE).map((a) => a.trim().toLowerCase()).filter(Boolean);
}

/**
 * Rewrite `metadata.sandboxed` with the given audience and scope, keeping every other
 * frontmatter key, sibling `metadata.*` keys and the body untouched.
 */
export function setSandboxedMeta(markdown: string, audience: string[], scope: string | null, fallbackName = "skill"): string {
  const known: string[] = [...AUDIENCES];
  const ordered = [...known.filter((a) => audience.includes(a)), ...audience.filter((a) => !known.includes(a))];
  const fm = splitFrontmatter(markdown);
  const nl = fm?.newline ?? "\n";
  const yaml = fm ? [...fm.yaml] : [`name: ${fallbackName}`, `description: ""`];
  const body = fm ? fm.body : markdown.replace(/^﻿/, "");
  const metadata = topLevelBlock(yaml, "metadata");
  const childIndent = (block: [number, number] | null, fallback: number) => {
    if (!block) return fallback;
    for (let i = block[0] + 1; i < block[1]; i++) if (yaml[i].trim()) return indentOf(yaml[i]);
    return fallback;
  };
  if (!metadata) {
    yaml.push("metadata:", ...sandboxedLines(2, 2, ordered, scope));
  } else {
    const mInd = indentOf(yaml[metadata[0]]);
    if (yaml[metadata[0]].trim() !== "metadata:") yaml[metadata[0]] = `${" ".repeat(mInd)}metadata:`;
    const sandboxed = findBlock(yaml, "sandboxed", metadata[0] + 1, metadata[1], mInd);
    const ind = childIndent(metadata, mInd + 2);
    if (sandboxed) {
      const sInd = indentOf(yaml[sandboxed[0]]);
      const step = Math.max(childIndent(sandboxed, sInd + 2) - sInd, 2);
      const kept: string[] = [];
      for (let i = sandboxed[0] + 1; i < sandboxed[1]; i++) {
        const t = yaml[i].trim();
        if (indentOf(yaml[i]) === sInd + step && (t.startsWith("audience:") || t.startsWith("scope:"))) {
          // Skip the key and any block list items that belong to it.
          while (i + 1 < sandboxed[1] && indentOf(yaml[i + 1]) > sInd + step) i++;
          continue;
        }
        kept.push(yaml[i]);
      }
      yaml.splice(sandboxed[0], sandboxed[1] - sandboxed[0], ...sandboxedLines(sInd, step, ordered, scope), ...kept);
    } else {
      yaml.splice(metadata[1], 0, ...sandboxedLines(ind, 2, ordered, scope));
    }
  }
  return ["---", ...yaml, "---"].join(nl) + nl + body.replace(/^(\r?\n)?/, "");
}

function sandboxedLines(indent: number, step: number, audience: string[], scope: string | null): string[] {
  const pad = " ".repeat(indent), inner = " ".repeat(indent + step);
  const lines = [`${pad}sandboxed:`, `${inner}audience: [${audience.join(", ")}]`];
  if (scope) lines.push(`${inner}scope: ${scope}`);
  return lines;
}

/** Template for a new Library skill. */
export function newSkillTemplate(name: string, description: string): string {
  const desc = description.trim() || `Describe when ${name} should be used.`;
  return `---\nname: ${name}\ndescription: ${JSON.stringify(desc)}\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n---\n\n# ${name}\n\n## When to use\n\n- \n\n## Instructions\n\n- \n`;
}

export function normalizeSkillName(raw: string): string {
  return raw.trim().toLowerCase().replace(/[^a-z0-9-_]+/g, "-").replace(/^-+|-+$/g, "");
}

// ── Lint ──────────────────────────────────────────────────────────────────

export interface SkillLint {
  id: "description" | "name" | "length" | "ipv4" | "metadata";
  message: string;
}

const IPV4 = /(?<![\d.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![\d.])/;
const IPV4_ALLOWED = new Set(["ops"]);
const BENIGN_IPS = new Set(["127.0.0.1", "0.0.0.0"]);

export function lintSkill(folder: string, content: string): SkillLint[] {
  const out: SkillLint[] = [];
  const meta = parseSkillMeta(content);
  const desc = meta.description?.trim() ?? "";
  if (!desc) out.push({ id: "description", message: "Missing description: harnesses use it to decide when to load the skill." });
  else if (desc.length < 40 || /^a new skill\.?$/i.test(desc)) out.push({ id: "description", message: `Weak description (${desc.length} chars): say what it does and when to use it.` });
  if (meta.name && meta.name !== folder) out.push({ id: "name", message: `Frontmatter name "${meta.name}" does not match folder "${folder}".` });
  else if (!meta.name) out.push({ id: "name", message: "Frontmatter has no name." });
  const lines = content.split("\n").length;
  if (lines > 500) out.push({ id: "length", message: `SKILL.md is ${lines} lines (> 500): move detail into reference files.` });
  if (!IPV4_ALLOWED.has(folder)) {
    const found = [...content.matchAll(new RegExp(IPV4.source, "g"))].map((m) => m[0]).filter((ip) => !BENIGN_IPS.has(ip));
    if (found.length) out.push({ id: "ipv4", message: `Raw IPv4 address ${found[0]}${found.length > 1 ? ` (+${found.length - 1})` : ""}: reference ops or a hostname instead.` });
  }
  if (!meta.hasSandboxedMeta) out.push({ id: "metadata", message: "No metadata.sandboxed block: audience defaults to mission + local, scope on-demand." });
  return out;
}

// ── Line diff ─────────────────────────────────────────────────────────────

export interface DiffLine {
  op: " " | "+" | "-";
  text: string;
}

/** Line diff (LCS). Large inputs fall back to a whole-block replace. */
export function lineDiff(before: string, after: string, maxCells = 4_000_000): DiffLine[] {
  const a = before.replace(/\r\n/g, "\n").split("\n");
  const b = after.replace(/\r\n/g, "\n").split("\n");
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  const head: DiffLine[] = a.slice(0, start).map((text) => ({ op: " ", text }));
  const tail: DiffLine[] = a.slice(endA).map((text) => ({ op: " ", text }));
  const midA = a.slice(start, endA), midB = b.slice(start, endB);
  const n = midA.length, m = midB.length;
  if (n * m > maxCells) {
    return [...head, ...midA.map((text) => ({ op: "-" as const, text })), ...midB.map((text) => ({ op: "+" as const, text })), ...tail];
  }
  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    dp[i][j] = midA[i] === midB[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  }
  const mid: DiffLine[] = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (midA[i] === midB[j]) { mid.push({ op: " ", text: midA[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) mid.push({ op: "-", text: midA[i++] });
    else mid.push({ op: "+", text: midB[j++] });
  }
  while (i < n) mid.push({ op: "-", text: midA[i++] });
  while (j < m) mid.push({ op: "+", text: midB[j++] });
  return [...head, ...mid, ...tail];
}

/** Keep `context` unchanged lines around each change; elide the rest. */
export function compactDiff(lines: DiffLine[], context = 3): Array<DiffLine | { op: "…"; text: string }> {
  const keep = new Array(lines.length).fill(false);
  lines.forEach((l, idx) => {
    if (l.op === " ") return;
    for (let k = Math.max(0, idx - context); k <= Math.min(lines.length - 1, idx + context); k++) keep[k] = true;
  });
  const out: Array<DiffLine | { op: "…"; text: string }> = [];
  let skipped = 0;
  lines.forEach((l, idx) => {
    if (keep[idx]) {
      if (skipped) out.push({ op: "…", text: `${skipped} unchanged line${skipped === 1 ? "" : "s"}` });
      skipped = 0;
      out.push(l);
    } else skipped++;
  });
  if (skipped) out.push({ op: "…", text: `${skipped} unchanged line${skipped === 1 ? "" : "s"}` });
  return out;
}

/** Where a skill applies, as three stackable choices (Cursor-style): this computer's harnesses,
 * every mission plus the coordinator, and an explicit list of projects. */
