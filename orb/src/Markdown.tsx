import katex from "katex";
import "katex/dist/katex.min.css";
import {requestHighlight} from "./codeHighlightClient";
import { CodeBlock } from "./CodeBlock";
import { FileReference, FileReferenceText } from "./fileReferenceContext";
import { For, Show, createEffect, onCleanup, createMemo, createSignal, type JSX } from "solid-js";
import { openExternalUrl } from "./api";
import { timed } from "./diagnostics";

/**
 * Source-vs-preview for Markdown file views, shared by every one of them so ⌘/
 * works the same on a local demo file and on a core-hosted reference file. It
 * is module-level rather than per-view because the shortcut is handled once, at
 * the window, and the mode is a user preference that should survive switching
 * between files.
 */
const [mdSource, setMdSource] = createSignal(false);
export { mdSource, setMdSource };
export const toggleMdSource = () => setMdSource((on) => !on);

/** Only http(s)/mailto links are rendered as real links; anything else
 * (javascript:, data:, file:) is neutralised so markdown from a mission
 * transcript cannot run script in the webview. */
export function safeHref(raw: string): string | null {
  return /^(https?:|mailto:)/i.test(raw.trim()) ? raw.trim() : null;
}

import { normalizeFileUrl } from "./fileResources";

/** File URLs go through Orb's scoped file resolver, never webview navigation. */
function fileLinkTarget(raw: string): string {
  const unwrapped =
    raw.startsWith("<") && raw.endsWith(">") ? raw.slice(1, -1) : raw;
  return normalizeFileUrl(unwrapped);
}

function plainInline(text: string, links: boolean): JSX.Element[] {
  text = text.replace(/\\([\\`*_[\]{}()#+.!|>-])/g, "$1");
  if (!links) return [text];
  const result: JSX.Element[] = [];
  const pattern = /https?:\/\/[^\s<>"`]+/gi;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    let href = match[0].replace(/[.,;:!?\u2026'’»]+$/, "");
    for (const [open, close] of [["(", ")"], ["[", "]"], ["{", "}"]]) {
      while (href.endsWith(close) && href.split(close).length > href.split(open).length) href = href.slice(0, -1);
    }
    href = href.replace(/[.,;:!?\u2026'’»]+$/, "");
    try { if (!new URL(href).hostname) continue; } catch { continue; }
    const start = match.index!;
    if (start > last) result.push(<FileReferenceText text={text.slice(last, start)}/>);
    const target = href;
    result.push(<a href={target} onClick={event => {event.preventDefault();void openExternalUrl(target);}}>{target}</a>);
    last = start + href.length;
  }
  if (last < text.length) result.push(<FileReferenceText text={text.slice(last)}/>);
  return result;
}

function MathFormula(p: {text: string; display?: boolean}) {
  const html = createMemo(() => katex.renderToString(p.text, {displayMode: !!p.display, throwOnError: false, trust: false, strict: "ignore", maxExpand: 1000}));
  return <span class={p.display ? "md-math-block" : "md-math-inline"} innerHTML={html()} />;
}
function inline(text: string, links = true): JSX.Element[] {
  const out: JSX.Element[] = [];
  // Keep code spans opaque; currency such as "$15 and $20" is ordinary text.
  // Emphasis that wraps a code span is taken whole first, or the span would
  // split it and leave its asterisks as text. Links likewise stay whole so
  // code-formatted labels do not expose their brackets and destination.
  const pattern = /(?<![\\*])\*\*(?=\S)(?:\[(?:`[^`\n]*`|[^\]`\n])+\]\((?:<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)|`[^`\n]*`|[^`*\n]|\*(?!\*))*?(?<=\S)\*\*|(?<![\\*])\*(?!\*)(?=\S)(?:\[(?:`[^`\n]*`|[^\]`\n])+\]\((?:<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)|`[^`\n]*`|[^`*\n])+?(?<=\S)\*(?!\*)|!\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)|(?<![\\!])\[(?:`[^`\n]*`|[^\]`\n])+\]\((?:<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)|`[^`]*`|\\\((.+?)\\\)|(?<![\w\\])\$(?!\s|\d)([^$\n]+?)(?<!\s)\$(?!\w)/g;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index! > last) out.push(...inlineText(text.slice(last, match.index), links));
    if (match[0].startsWith('**')) out.push(<strong>{inline(match[0].slice(2, -2), links)}</strong>);
    else if (match[0].startsWith('*')) out.push(<em>{inline(match[0].slice(1, -1), links)}</em>);
    else if (match[0].startsWith('![')) out.push(<img class="md-image" src={match[2]} alt={match[1]} loading="lazy" referrerPolicy="no-referrer"/>);
    else if (match[0].startsWith('[')) out.push(...inlineText(match[0], links));
    else if (match[0].startsWith('`')) out.push(...inlineText(match[0], links));
    else out.push(<MathFormula text={match[3] ?? match[4]}/>);
    last = match.index! + match[0].length;
  }
  if (last < text.length) out.push(...inlineText(text.slice(last), links));
  return out;
}
function inlineText(text: string, links = true): JSX.Element[] {
  const out: JSX.Element[] = [];
  const re = /(?<!\\)(?:\*\*(.+?)\*\*|`([^`]+)`|\[((?:`[^`\n]*`|[^\]`\n])+)\]\((<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)|(:codex-file-citation\{(?:[^"{}]|"(?:\\.|[^"\\])*")*\})|\*([^*\n]+)\*)/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push(...plainInline(text.slice(last, m.index), links));
    if (m[5] !== undefined) {
      const attributes = [...m[5].matchAll(/([a-z_]+)\s*=\s*("(?:\\.|[^"\\])*")/g)];
      const quoted = attributes.find(attribute => attribute[1] === "path")?.[2];
      let path: string | undefined;
      try { path = quoted ? JSON.parse(quoted) : undefined; } catch { /* malformed citation remains readable */ }
      if (path) out.push(<FileReference raw={path}>{path.split("/").pop() || path}</FileReference>);
      else out.push(m[5]);
    }
    else if (m[6] !== undefined) out.push(<em>{inline(m[6], links)}</em>);
    else if (m[1] !== undefined) out.push(<strong>{inline(m[1], links)}</strong>);
    else if (m[2] !== undefined) out.push(links ? <FileReference raw={m[2]}><code>{m[2]}</code></FileReference> : <code>{m[2]}</code>);
    else if (!safeHref(m[4])) out.push(<FileReference raw={fileLinkTarget(m[4])}>{inline(m[3], false)}</FileReference>);
    else
      out.push(
        <a
          href={safeHref(m[4]) ?? "#"}
          onClick={(e) => {
            e.preventDefault();
            const href = safeHref(m[4]);
            if (href) void openExternalUrl(href);
          }}
        >
          {inline(m[3], false)}
        </a>,
      );
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(...plainInline(text.slice(last), links));
  return out;
}

type Align = "left" | "center" | "right";
export type ListItem = { text: string; sub?: Block[] };
type Block =
  | { t: "hr" }
  | { t: "math"; text: string }
  | { t: "h"; n: number; text: string }
  | { t: "p"; text: string }
  | { t: "ul"; items: (string | ListItem)[] }
  | { t: "ol"; items: (string | ListItem)[]; start: number }
  | { t: "pre"; lang: string; text: string }
  | { t: "quote"; text: string }
  | { t: "table"; heads: string[]; rows: string[][]; aligns: Align[] };

function tableCells(line: string): string[] {
  let t = line.trim();
  if (t.startsWith("|")) t = t.slice(1);
  if (t.endsWith("|")) t = t.slice(0, -1);
  return t.split("|").map((c) => c.trim());
}
function sepAlign(cell: string): Align | null {
  const n = cell.replace(/\s/g, "").replace(/[−–—]/g, "-");
  if (!/^:?-+:?$/.test(n)) return null;
  const left = n.startsWith(":");
  const right = n.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  return "left";
}
function isTableSep(line: string): boolean {
  const cells = tableCells(line);
  return cells.length > 0 && cells.every((c) => sepAlign(c) != null);
}
function isPipeRow(line: string): boolean {
  const t = line.trim();
  return t.startsWith("|") && tableCells(t).length >= 2;
}
function readTable(lines: string[], start: number): { block: Extract<Block, { t: "table" }>; next: number } | null {
  const header = lines[start];
  if (!isPipeRow(header) || start + 1 >= lines.length) return null;
  const sep = lines[start + 1];
  const hasSep = isTableSep(sep);
  if (!hasSep && !isPipeRow(sep)) return null;
  const heads = tableCells(header);
  const aligns = hasSep ? tableCells(sep).map((c) => sepAlign(c) ?? "left") : heads.map(() => "left" as Align);
  let i = start + (hasSep ? 2 : 1);
  const rows: string[][] = [];
  while (i < lines.length && isPipeRow(lines[i]) && !isTableSep(lines[i])) {
    rows.push(tableCells(lines[i++]));
  }
  if (!hasSep && rows.length === 0) return null;
  return { block: { t: "table", heads, rows, aligns }, next: i };
}

export function parseMarkdown(src: string): Block[] {
  return timed("markdown", () => parseBlocks(src));
}
function isHrLine(line: string): boolean {
  const t = line.trim();
  return /^(?:-[ \t]*){3,}$|^(?:\*[ \t]*){3,}$|^(?:_[ \t]*){3,}$/.test(t);
}
function listMarker(line: string): { kind: "ul" | "ol"; indent: number; start?: number; rest: string } | null {
  if (isHrLine(line)) return null;
  const ul = /^( *)[-*+]\s+(.*)$/.exec(line);
  if (ul) return { kind: "ul", indent: ul[1].length, rest: ul[2] };
  const ol = /^( *)(\d+)\.\s+(.*)$/.exec(line);
  if (ol) return { kind: "ol", indent: ol[1].length, start: Number(ol[2]), rest: ol[3] };
  return null;
}
function readList(lines: string[], startIdx: number, baseIndent: number, kind: "ul" | "ol"): { block: Extract<Block, { t: "ul" | "ol" }>; next: number } {
  const items: (string | ListItem)[] = [];
  let i = startIdx;
  let startNum = 1;
  const firstMarker = listMarker(lines[i]);
  if (firstMarker?.start !== undefined) startNum = firstMarker.start;
  while (i < lines.length) {
    const m = listMarker(lines[i]);
    if (!m || m.kind !== kind || m.indent !== baseIndent) break;
    const headLines: string[] = [m.rest];
    const subLines: string[] = [];
    i++;
    while (i < lines.length) {
      const nextLine = lines[i];
      if (!nextLine.trim()) {
        // A blank line ends the list unless the next non-empty line is indented
        // continuation/sub-list or another sibling item at the same indent.
        let look = i + 1;
        while (look < lines.length && !lines[look].trim()) look++;
        if (look >= lines.length) break;
        const afterBlank = lines[look];
        const nextM = listMarker(afterBlank);
        if (nextM && nextM.indent === baseIndent && nextM.kind === kind) {
          i = look;
          break;
        }
        const lead = /^ */.exec(afterBlank)?.[0].length ?? 0;
        if (lead > baseIndent) {
          subLines.push("");
          i++;
          continue;
        }
        break;
      }
      if (isHrLine(nextLine) || /^ {0,3}#{1,6}\s/.test(nextLine) || readTable(lines, i)) break;
      const nextM = listMarker(nextLine);
      if (nextM) {
        if (nextM.indent < baseIndent) break;
        if (nextM.indent === baseIndent) break;
        subLines.push(nextLine);
        i++;
        continue;
      }
      const lead = /^ */.exec(nextLine)?.[0].length ?? 0;
      if (subLines.length > 0) {
        if (lead <= baseIndent && (nextLine.trimStart().startsWith("```") || /^ {0,3}>/.test(nextLine))) break;
        subLines.push(nextLine);
        i++;
        continue;
      }
      if (nextLine.trimStart().startsWith("```") || /^ {0,3}>/.test(nextLine)) {
        if (lead > baseIndent) {
          subLines.push(nextLine);
          i++;
          continue;
        }
        break;
      }
      headLines.push(nextLine.trim());
      i++;
    }
    const text = headLines.join(" ");
    if (subLines.length > 0) {
      const nonEmptyIndents = subLines.filter((l) => l.trim()).map((l) => /^ */.exec(l)?.[0].length ?? 0);
      const strip = nonEmptyIndents.length ? Math.min(...nonEmptyIndents) : 0;
      const dedented = subLines.map((l) => (l.length >= strip ? l.slice(strip) : l.trimStart())).join("\n");
      const sub = parseBlocks(dedented);
      items.push(sub.length ? { text, sub } : text);
    } else {
      items.push(text);
    }
  }
  return {
    block: kind === "ol" ? { t: "ol", items, start: startNum } : { t: "ul", items },
    next: i,
  };
}
function parseBlocks(src: string): Block[] {
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  const out: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const singleLineMath = /^\s*(?:\$\$(.+?)\$\$|\\\[(.+?)\\\])\s*$/.exec(line);
    if (singleLineMath) {
      out.push({t: 'math', text: singleLineMath[1] ?? singleLineMath[2]});
      i++;
      continue;
    }
    if (line.trim() === '$$' || line.trim() === '\\[') {
      const end = line.trim() === '$$' ? '$$' : '\\]';
      const start = i++;
      const content: string[] = [];
      while (i < lines.length && lines[i].trim() !== end) content.push(lines[i++]);
      if (i < lines.length) { i++; out.push({t: 'math', text: content.join('\n')}); }
      else out.push({t: 'p', text: lines.slice(start).join('\n')});
      continue;
    }
    if (line.trimStart().startsWith("```")) {
      const fenceIndent = /^ */.exec(line)?.[0].length ?? 0;
      const lang = line.trimStart().slice(3).trim();
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trimStart().startsWith("```")) {
        const raw = lines[i++];
        buf.push(fenceIndent > 0 && raw.startsWith(" ".repeat(fenceIndent)) ? raw.slice(fenceIndent) : raw);
      }
      if (i < lines.length) i++;
      out.push({ t: "pre", lang, text: buf.join("\n") });
      continue;
    }
    if (isHrLine(line)) {
      out.push({ t: "hr" });
      i++;
      continue;
    }
    const hm = /^ {0,3}(#{1,6})\s+(.*)$/.exec(line);
    if (hm) {
      out.push({ t: "h", n: hm[1].length, text: hm[2] });
      i++;
      continue;
    }
    const marker = listMarker(line);
    if (marker) {
      const parsed = readList(lines, i, marker.indent, marker.kind);
      out.push(parsed.block);
      i = parsed.next;
      continue;
    }
    if (/^ {0,3}>/.test(line)) {
      const quoted: string[] = [];
      while (i < lines.length && /^ {0,3}>/.test(lines[i])) {
        quoted.push(lines[i++].replace(/^ {0,3}>[ \t]?/, ""));
      }
      out.push({ t: "quote", text: quoted.join("\n") });
      continue;
    }
    if (!line.trim()) {
      i++;
      continue;
    }
    const table = readTable(lines, i);
    if (table) {
      out.push(table.block);
      i = table.next;
      continue;
    }
    const buf = [line];
    i++;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !isHrLine(lines[i]) &&
      !/^ {0,3}#{1,6}\s/.test(lines[i]) &&
      !listMarker(lines[i]) &&
      !/^\s*(?:\$\$|\\\[)/.test(lines[i]) &&
      !lines[i].trimStart().startsWith("```") &&
      !/^ {0,3}>/.test(lines[i]) &&
      !readTable(lines, i)
    ) {
      buf.push(lines[i++]);
    }
    out.push({ t: "p", text: buf.join(" ") });
  }
  return out;
}

/** Freeze only completed blocks; fences keep blank lines inside the active tail. */
/** Search the same block content without mounting historical Markdown. */
export function markdownText(source:string):string{
 const plain=(text:string):string=>text.replace(/\*\*(.+?)\*\*|`([^`]+)`|\[((?:`[^`\n]*`|[^\]`\n])+)\]\((<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)\)/g,(_match,bold,code,label)=>bold!==undefined?plain(bold):code??plain(label));
 const blockText=(block:Block):string=>block.t==='hr'?'':block.t==='pre'?block.text:block.t==='quote'?markdownText(block.text):(block.t==='ul'||block.t==='ol')?block.items.map(it=>typeof it==='string'?plain(it):[plain(it.text),...(it.sub?.map(blockText)??[])].filter(Boolean).join('\n')).join('\n'):block.t==='table'?[block.heads,...block.rows].map(row=>row.map(plain).join('')).join('\n'):plain(block.text);
 return parseMarkdown(source).map(blockText).filter(Boolean).join('\n');
}

/** The same block again keeps its object, so the list keeps its DOM. */
function reuseBlocks(previous: Block[], next: Block[]): Block[] {
  return next.map((block, index) => {
    const old = previous[index];
    return old && JSON.stringify(old) === JSON.stringify(block) ? old : block;
  });
}

export function incrementalMarkdown() {
  let previous = "", boundary = 0, stable: Block[] = [], unstable: Block[] = [];
  return (text: string): Block[] => {
    if (!text.startsWith(previous)) { boundary = 0; stable = []; unstable = []; }
    previous = text;
    const tail = text.slice(boundary);
    let fenced = false, math = false, inList = false, end = 0, offset = 0;
    for (const line of tail.split("\n").slice(0, -1)) {
      offset += line.length + 1;
      if (line.trimStart().startsWith("```")) fenced = !fenced;
      if (!fenced && ["$$", "\\[", "\\]"].includes(line.trim())) math = !math;
      if (!fenced && !math) {
        if (listMarker(line)) inList = true;
        else if (!line.trim()) {
          if (!inList) end = offset;
          inList = false;
        } else if (!/^ /.test(line)) {
          inList = false;
        }
      }
    }
    if (end) {
      stable = [...stable, ...parseMarkdown(tail.slice(0, end))];
      boundary += end;
      unstable = [];
    }
    // The unstable tail is re-parsed each time; blocks that did not change
    // (everything but the last one, usually) keep their identity.
    unstable = reuseBlocks(unstable, parseMarkdown(text.slice(boundary)));
    return [...stable, ...unstable];
  };
}

function renderListItem(it: string | ListItem, compact?: boolean): JSX.Element {
  if (typeof it === "string") return <li>{inline(it)}</li>;
  return (
    <li>
      {inline(it.text)}
      <Show when={it.sub?.length}>
        <For each={it.sub}>{(sub) => renderBlock(sub, compact)}</For>
      </Show>
    </li>
  );
}

function renderBlock(b: Block, compact?: boolean): JSX.Element {
  return b.t === "hr" ? (
    <hr />
  ) : b.t === "math" ? (
    <MathFormula text={b.text} display />
  ) : b.t === "h" && b.n === 1 ? (
    <h1>{inline(b.text)}</h1>
  ) : b.t === "h" && b.n === 2 ? (
    <h2>{inline(b.text)}</h2>
  ) : b.t === "h" ? (
    <h3>{inline(b.text)}</h3>
  ) : b.t === "ol" ? (
    <ol start={b.start}>{b.items.map((item) => renderListItem(item, compact))}</ol>
  ) : b.t === "ul" ? (
    <ul>{b.items.map((it) => renderListItem(it, compact))}</ul>
  ) : b.t === "pre" ? (
    <CodeBlock text={b.text} lang={b.lang} />
  ) : b.t === "quote" ? (
    <blockquote>
      <MdView text={b.text} compact={compact} />
    </blockquote>
  ) : b.t === "table" ? (
    <div class="md-table-wrap">
      <table>
        <thead>
          <tr>
            {b.heads.map((h, i) => (
              <th style={{ "text-align": b.aligns[i] ?? "left" }}>{inline(h)}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {b.rows.map((row) => (
            <tr>
              {row.map((c, i) => (
                <td style={{ "text-align": b.aligns[i] ?? "left" }}>{inline(c)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  ) : (
    <p>{inline(b.text)}</p>
  );
}

export function MdView(p: { text: string; compact?: boolean }) {
  const parse = incrementalMarkdown();
  const blocks = createMemo(() => parse(p.text));
  return (
    <div class={`md ${p.compact ? "md-compact" : ""}`}>
      <For each={blocks()}>{(b) => renderBlock(b, p.compact)}</For>
    </div>
  );
}

function hlInline(text: string): JSX.Element[] {
  const out: JSX.Element[] = [];
  const re = /(\*\*)(.+?)(\*\*)|(\[)((?:`[^`\n]*`|[^\]`\n])+)(\]\()(<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)(\))|(`)([^`]+)(`)/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1])
      out.push(
        <>
          <span class="md-p">{m[1]}</span>
          <strong>{m[2]}</strong>
          <span class="md-p">{m[3]}</span>
        </>,
      );
    else if (m[9])
      out.push(
        <>
          <span class="md-p">{m[9]}</span>
          <span class="md-code">{m[10]}</span>
          <span class="md-p">{m[11]}</span>
        </>,
      );
    else
      out.push(
        <>
          <span class="md-p">{m[4]}</span>
          <span class="md-link">{m[5]}</span>
          <span class="md-p">{m[6]}</span>
          <span class="md-link">{m[7]}</span>
          <span class="md-p">{m[8]}</span>
        </>,
      );
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function hlLine(line: string): JSX.Element {
  const h = /^(#{1,6})(\s)(.*)$/.exec(line);
  if (h)
    return (
      <>
        <span class="md-p">{h[1]}{h[2]}</span>
        <span class="md-h">{h[3]}</span>
      </>
    );
  if (line.startsWith("```")) return <span class="md-fence">{line}</span>;
  if (/^ *[-*+]\s/.test(line)) {
    const m = /^( *[-*+]\s+)(.*)$/.exec(line)!;
    return (
      <>
        <span class="md-p">{m[1]}</span>
        {hlInline(m[2])}
      </>
    );
  }
  if (/^ *\d+\.\s/.test(line)) {
    const m = /^( *\d+\.\s+)(.*)$/.exec(line)!;
    return (
      <>
        <span class="md-p">{m[1]}</span>
        {hlInline(m[2])}
      </>
    );
  }
  if (line.startsWith("> "))
    return (
      <>
        <span class="md-p">{"> "}</span>
        {hlInline(line.slice(2))}
      </>
    );
  return <>{hlInline(line)}</>;
}

export function MdSource(p: { text: string; onInput: (t: string) => void; readOnly?: boolean }) {
  let pre!: HTMLPreElement;
  let ta!: HTMLTextAreaElement;
  const lines = createMemo(() => p.text.split("\n"));
  // The highlighted layer has no scrollbar of its own: it follows the textarea
  // on both axes. Horizontal matters even though both layers wrap, because a
  // single unbreakable run (a long URL, a wide table row) still overflows.
  const sync = () => {
    if (!pre || !ta) return;
    pre.scrollTop = ta.scrollTop;
    pre.scrollLeft = ta.scrollLeft;
  };
  return (
    <div class="md-src">
      <pre ref={pre} class="md-hl" aria-hidden>
        <For each={lines()}>
          {(ln, i) => (
            <>
              {hlLine(ln)}
              {i() < lines().length - 1 ? "\n" : p.text.endsWith("\n") ? "\n" : null}
            </>
          )}
        </For>
      </pre>
      <textarea
        ref={ta}
        class="md-ta"
        readOnly={p.readOnly}
        value={p.text}
        spellcheck={false}
        onScroll={sync}
        onInput={(e) => {
          p.onInput(e.currentTarget.value);
          // Typing at the bottom scrolls the textarea to keep the caret in
          // view; re-sync so the layer beneath follows even if that happened
          // without a scroll event.
          sync();
        }}
      />
    </div>
  );
}

/** The same syntax presentation as the editor, without a writable textarea. */
export function ReadOnlySource(p: { text: string; line?: number; language?: string }) {
  const [highlighted,setHighlighted]=createSignal<string[]|null>(null);
  createEffect(()=>{
    const text=p.text,language=p.language;setHighlighted(null);
    if(!language||typeof Worker==='undefined')return;
    const cancel=requestHighlight(text,language,html=>setHighlighted(html?highlightedLines(html):null));
    onCleanup(cancel);
  });
  return <div class="file-source-code"><For each={p.text.split("\n")}>{(line,i)=><div data-line={i()+1} class={p.line===i()+1?"highlight":""}><span class="file-line-number">{i()+1}</span><Show when={highlighted()?.[i()]} fallback={<code>{p.language?line||" ":hlLine(line)||" "}</code>}>{html=><code innerHTML={html()}/>}</Show></div>}</For></div>;
}

/** Reopen multiline token spans on each row without losing their lexical context. */
export function highlightedLines(html:string):string[]{
 const lines:string[]=[],stack:string[]=[];let current='';
 for(const token of html.match(/<\/?span\b[^>]*>|\n|[^<\n]+|</g)??[]){
  if(token==='\n'){lines.push(current+'</span>'.repeat(stack.length));current=stack.join('');continue;}
  if(token.startsWith('<span'))stack.push(token);else if(token==='</span>')stack.pop();
  current+=token;
 }
 lines.push(current+'</span>'.repeat(stack.length));return lines;
}
