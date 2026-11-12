import {
  requestHighlight,
  requestMarkdownParse,
  warmHighlight,
  type WorkerMarkdownFormula,
  type WorkerMarkdownResult,
} from "./codeHighlightClient";
import { CodeBlock } from "./CodeBlock";
import { isMermaidLang, MermaidBlock } from "./MermaidBlock";
import { FileReference, FileReferenceText } from "./fileReferenceContext";
import { For, Index, Show, createEffect, onCleanup, createMemo, createSignal, type JSX } from "solid-js";
import { openExternalUrl } from "./api";
import { timed } from "./diagnostics";
import { swallow } from "./log";
import { WorkspaceImage } from "./WorkspaceImage";
import * as Ic from "./icons";
import {
  createIncrementalMarkdown,
  markdownText as markdownTextAst,
  parseInlineAst,
  parseMarkdownRaw,
  safeHref,
  type Block,
  type IncrementalMarkdownParser,
  type InlineNode,
  type ListItem,
} from "./markdownAst";

export { safeHref, type Block, type IncrementalMarkdownParser, type InlineNode, type ListItem };

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

// Rendered formulas by source: a transcript row that remounts while scrolling
// reuses the markup instead of running KaTeX again in that frame.
const formulas = new Map<string, string>();
const [formulaVersion, setFormulaVersion] = createSignal(0);

// KaTeX (~255 kB) loads on the first formula instead of at startup; until then
// a formula shows its source (or worker-precomputed KaTeX HTML once seeded).
type Katex = typeof import("./katexRender");
const [katex, setKatex] = createSignal<Katex>();
let katexLoad: Promise<void> | undefined;
export function loadKatex(): Promise<void> {
  return (katexLoad ??= import("./katexRender").then((m) => {
    setKatex(() => m);
  }, swallow("markdown.katex")));
}

export function seedRenderedFormulas(items: ReadonlyArray<WorkerMarkdownFormula>): void {
  if (!items.length) return;
  let added = false;
  for (const { key, html } of items) {
    if (!formulas.has(key)) added = true;
    formulas.delete(key);
    formulas.set(key, html);
    if (formulas.size > 1500) formulas.delete(formulas.keys().next().value!);
  }
  // Ensure KaTeX stylesheet + copy-tex copy handler are active on the document.
  void loadKatex();
  if (added) setFormulaVersion((v) => v + 1);
}

function renderFormula(text: string, display: boolean): string | undefined {
  formulaVersion();
  const key = `${display ? "D" : "I"}${text}`;
  let html = formulas.get(key);
  if (html !== undefined) {
    formulas.delete(key);
    formulas.set(key, html);
    return html;
  }
  const k = katex();
  if (!k) {
    void loadKatex();
    return undefined;
  }
  html = k.renderKatex(text, display);
  if (text.length < 4000) {
    formulas.set(key, html);
    if (formulas.size > 1500) formulas.delete(formulas.keys().next().value!);
  }
  return html;
}

function MathFormula(p: { text: string; display?: boolean }) {
  const html = createMemo(() => renderFormula(p.text, !!p.display));
  return (
    <Show
      when={html()}
      fallback={
        <span class={p.display ? "md-math-block md-math-pending" : "md-math-inline md-math-pending"}>{p.text}</span>
      }
    >
      {(markup) => <span class={p.display ? "md-math-block" : "md-math-inline"} innerHTML={markup()} />}
    </Show>
  );
}

/** A share Core could not copy (the agent's file was gone or refused). */
function UnavailableFile(p: { label: string; path: string }) {
  return (
    <span class="md-file-unavailable" title={p.path} role="note">
      <Ic.FileIcon size={14} />
      <span>{p.label}</span>
      <small>File no longer available</small>
    </span>
  );
}

export function renderInlineAst(nodes: InlineNode[]): JSX.Element[] {
  return nodes.map((n): JSX.Element => {
    switch (n.t) {
      case "text":
        return n.text;
      case "ref_text":
        return <FileReferenceText text={n.text} />;
      case "autolink": {
        const target = n.href;
        return (
          <a
            href={target}
            onClick={(event) => {
              event.preventDefault();
              void openExternalUrl(target);
            }}
          >
            {target}
          </a>
        );
      }
      case "strong":
        return <strong>{renderInlineAst(n.children)}</strong>;
      case "em":
        return <em>{renderInlineAst(n.children)}</em>;
      case "code":
        return n.linkRef ? (
          <FileReference raw={n.text}>
            <code>{n.text}</code>
          </FileReference>
        ) : (
          <code>{n.text}</code>
        );
      case "link": {
        const href = n.href;
        return (
          <a
            href={href}
            onClick={(e) => {
              e.preventDefault();
              void openExternalUrl(href);
            }}
          >
            {renderInlineAst(n.children)}
          </a>
        );
      }
      case "file_link":
        return <FileReference raw={n.raw}>{renderInlineAst(n.children)}</FileReference>;
      case "file_ref":
        return <FileReference raw={n.raw}>{n.label}</FileReference>;
      case "unavailable_file":
        return <UnavailableFile label={n.label} path={n.path} />;
      case "workspace_img":
        return <WorkspaceImage path={n.path} alt={n.alt} />;
      case "ext_img":
        return <img class="md-image" src={n.src} alt={n.alt} loading="lazy" referrerPolicy="no-referrer" />;
      case "math":
        return <MathFormula text={n.text} display={n.display} />;
    }
  });
}

function inline(text: string, preParsed?: InlineNode[]): JSX.Element[] {
  return renderInlineAst(preParsed ?? parseInlineAst(text, true));
}

export function parseMarkdown(src: string): Block[] {
  return timed("markdown", () => parseMarkdownRaw(src));
}

export function markdownText(source: string): string {
  return markdownTextAst(source, parseMarkdown);
}

export function incrementalMarkdown(): IncrementalMarkdownParser {
  return createIncrementalMarkdown(parseMarkdown);
}

function renderListItem(it: string | ListItem, preInl?: InlineNode[], compact?: boolean): JSX.Element {
  if (typeof it === "string") return <li>{inline(it, preInl)}</li>;
  return (
    <li>
      {inline(it.text, it.inl ?? preInl)}
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
    <h1>{inline(b.text, b.inl)}</h1>
  ) : b.t === "h" && b.n === 2 ? (
    <h2>{inline(b.text, b.inl)}</h2>
  ) : b.t === "h" ? (
    <h3>{inline(b.text, b.inl)}</h3>
  ) : b.t === "ol" ? (
    <ol start={b.start}>{b.items.map((item, idx) => renderListItem(item, b.inl?.[idx], compact))}</ol>
  ) : b.t === "ul" ? (
    <ul>{b.items.map((it, idx) => renderListItem(it, b.inl?.[idx], compact))}</ul>
  ) : b.t === "pre" ? (
    isMermaidLang(b.lang) ? (
      <MermaidBlock text={b.text} complete={!b.open} />
    ) : (
      <CodeBlock text={b.text} lang={b.lang} streaming={Boolean(b.open)} />
    )
  ) : b.t === "quote" ? (
    <blockquote>
      {b.sub ? (
        <div class={`md ${compact ? "md-compact" : ""}`}>
          <Index each={b.sub}>{(sub) => renderBlockSlot(sub, compact)}</Index>
        </div>
      ) : (
        <MdView text={b.text} compact={compact} />
      )}
    </blockquote>
  ) : b.t === "table" ? (
    <div class="md-table-wrap">
      <table>
        {/* A loose pipe table without a header row has an all-empty one. */}
        {b.heads.some((h) => h !== "") && (
          <thead>
            <tr>
              {b.heads.map((h, i) => (
                <th style={{ "text-align": b.aligns[i] ?? "left" }}>{inline(h, b.headInl?.[i])}</th>
              ))}
            </tr>
          </thead>
        )}
        <tbody>
          {b.rows.map((row, rIdx) => (
            <tr>
              {row.map((c, i) => (
                <td style={{ "text-align": b.aligns[i] ?? "left" }}>{inline(c, b.rowInl?.[rIdx]?.[i])}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  ) : (
    <p>{inline(b.text, b.inl)}</p>
  );
}

function renderBlockSlot(block: () => Block, compact?: boolean): JSX.Element {
  const kind = createMemo(() => {
    const b = block();
    if (b.t === "pre") return isMermaidLang(b.lang) ? "pre:mermaid" : "pre:code";
    if (b.t === "h") return `h:${b.n}`;
    return b.t;
  });
  return (
    <Show when={kind()} keyed>
      {(k) => {
        if (k === "pre:code") {
          const pre = () => block() as Extract<Block, { t: "pre" }>;
          return <CodeBlock text={pre().text} lang={pre().lang} streaming={Boolean(pre().open)} />;
        }
        if (k === "pre:mermaid") {
          const pre = () => block() as Extract<Block, { t: "pre" }>;
          return <MermaidBlock text={pre().text} complete={!pre().open} />;
        }
        if (k === "p") {
          const p = () => block() as Extract<Block, { t: "p" }>;
          return <p>{inline(p().text, p().inl)}</p>;
        }
        return <>{() => renderBlock(block(), compact)}</>;
      }}
    </Show>
  );
}

// Parsed blocks of recently shown messages: rows that remount while a long
// transcript scrolls skip re-parsing. Bounded by both entry count and source chars.
const parsedMessages = new Map<string, Block[]>();
let parsedMessageChars = 0;
const MAX_PARSED_MESSAGES = 500;
const MAX_PARSED_MESSAGE_CHARS = 4_000_000;
const WORKER_DEFER_THRESHOLD_CHARS = 4_096;

export function seedParsedMarkdown(text: string, blocks: Block[], renderedFormulas?: ReadonlyArray<WorkerMarkdownFormula>): void {
  if (renderedFormulas?.length) seedRenderedFormulas(renderedFormulas);
  rememberParsedMessage(text, blocks);
}

function rememberParsedMessage(text: string, blocks: Block[]) {
  if (!text || text.length >= 50_000) return;
  if (blocks.some((b) => b.t === "pre" && b.open)) return;
  if (parsedMessages.has(text)) {
    parsedMessages.delete(text);
  } else {
    parsedMessageChars += text.length;
  }
  parsedMessages.set(text, blocks);
  while (parsedMessages.size > MAX_PARSED_MESSAGES || (parsedMessages.size > 1 && parsedMessageChars > MAX_PARSED_MESSAGE_CHARS)) {
    const oldest = parsedMessages.keys().next().value!;
    parsedMessages.delete(oldest);
    parsedMessageChars = Math.max(0, parsedMessageChars - oldest.length);
  }
}

export function applyWorkerMarkdownResult(text: string, res: WorkerMarkdownResult): Block[] | null {
  if (res.formulas.length > 0) seedRenderedFormulas(res.formulas);
  if (res.blocks) {
    rememberParsedMessage(text, res.blocks);
    return res.blocks;
  }
  return null;
}

export function warmMarkdownText(text: string): void {
  if (!text || text.length >= 50_000) return;
  const hit = parsedMessages.get(text);
  if (hit) {
    parsedMessages.delete(text);
    parsedMessages.set(text, hit);
    for (const b of hit) {
      if (b.t === "pre" && !b.open && b.lang && !isMermaidLang(b.lang)) {
        warmHighlight(b.text, b.lang);
      }
    }
    return;
  }
  if (typeof Worker !== "undefined") {
    requestMarkdownParse(text, (res) => {
      applyWorkerMarkdownResult(text, res);
    });
    return;
  }
  const blocks = incrementalMarkdown()(text);
  rememberParsedMessage(text, blocks);
}

export function warmTranscriptMarkdown(items: ReadonlyArray<{ kind: string; text?: string; live?: boolean }>): void {
  if (!items.length || typeof window === "undefined") return;
  const texts: string[] = [];
  const seen = new Set<string>();
  const limit = typeof Worker !== "undefined" ? 30 : 6;
  for (let i = items.length - 1; i >= 0 && texts.length < limit; i--) {
    const item = items[i];
    if (item.kind === "text" && !item.live && item.text && item.text.length < 50_000 && !seen.has(item.text)) {
      seen.add(item.text);
      texts.push(item.text);
    }
  }
  if (!texts.length) return;
  if (typeof Worker !== "undefined") {
    // Dispatch immediately to the worker so AST, Prism, and KaTeX caches are warm before mount/scroll.
    for (const text of texts) warmMarkdownText(text);
    return;
  }
  const run = () => {
    for (const text of texts) warmMarkdownText(text);
  };
  const ric = (window as Window & { requestIdleCallback?: (cb: () => void, opts?: { timeout: number }) => number })
    .requestIdleCallback;
  if (typeof ric === "function") ric(run, { timeout: 120 });
  else setTimeout(run, 16);
}

export function MdView(p: { text: string; compact?: boolean; searchable?: boolean }) {
  const parse = incrementalMarkdown();
  let mountText: string | undefined;
  let sawMultipleTexts = false;
  const [workerParsed, setWorkerParsed] = createSignal<{ text: string; blocks: Block[] } | null>(null);

  const shouldDeferToWorker = (text: string): boolean => {
    if (typeof Worker === "undefined") return false;
    if (text.length < WORKER_DEFER_THRESHOLD_CHARS || text.length >= 50_000) return false;
    if (parsedMessages.has(text)) return false;
    if (workerParsed()?.text === text) return false;
    // Live streaming updates mutate `p.text` incrementally; keep the incremental O(tail) scanner for streams.
    if (sawMultipleTexts) return false;
    return true;
  };

  createEffect(() => {
    const text = p.text;
    if (!shouldDeferToWorker(text)) return;
    const cancel = requestMarkdownParse(text, (res) => {
      const resolved = applyWorkerMarkdownResult(text, res) ?? parse(text);
      rememberParsedMessage(text, resolved);
      setWorkerParsed({ text, blocks: resolved });
    });
    onCleanup(cancel);
  });

  const blocks = createMemo<Block[] | null>(() => {
    const text = p.text;
    if (mountText === undefined) mountText = text;
    else if (text !== mountText) sawMultipleTexts = true;

    const hit = parsedMessages.get(text);
    if (hit) {
      parsedMessages.delete(text);
      parsedMessages.set(text, hit);
      return hit;
    }
    const asyncHit = workerParsed();
    if (asyncHit && asyncHit.text === text) return asyncHit.blocks;
    if (shouldDeferToWorker(text)) return null;

    const out = parse(text);
    if (!sawMultipleTexts || !parsedMessages.has(text)) rememberParsedMessage(text, out);
    return out;
  });

  return (
    <div class={`md ${p.compact ? "md-compact" : ""}`} data-find-message={p.searchable ? "" : undefined}>
      <Show
        when={blocks()}
        fallback={
          <div class="md-pending" style={{ "white-space": "pre-wrap", "overflow-wrap": "anywhere" }}>
            {p.text}
          </div>
        }
      >
        {(resolved) => <Index each={resolved()}>{(b) => renderBlockSlot(b, p.compact)}</Index>}
      </Show>
    </div>
  );
}

function hlInline(text: string): JSX.Element[] {
  const out: JSX.Element[] = [];
  const re =
    /(\*\*)(.+?)(\*\*)|(\[)((?:`[^`\n]*`|[^\]`\n])+)(\]\()(<[^>\n]+>|(?:[^()\n]|\([^()\n]*\))+)(\))|(`)([^`]+)(`)/g;
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
        <span class="md-p">
          {h[1]}
          {h[2]}
        </span>
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
        autocapitalize="off"
        autocorrect="off"
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
  const [highlighted, setHighlighted] = createSignal<string[] | null>(null);
  createEffect(() => {
    const text = p.text,
      language = p.language;
    setHighlighted(null);
    if (!language || typeof Worker === "undefined") return;
    const cancel = requestHighlight(text, language, (html) => setHighlighted(html ? highlightedLines(html) : null));
    onCleanup(cancel);
  });
  return (
    <div class="file-source-code">
      <For each={p.text.split("\n")}>
        {(line, i) => (
          <div data-line={i() + 1} class={p.line === i() + 1 ? "highlight" : ""}>
            <span class="file-line-number">{i() + 1}</span>
            <Show when={highlighted()?.[i()]} fallback={<code>{p.language ? line || " " : hlLine(line) || " "}</code>}>
              {(html) => <code innerHTML={html()} />}
            </Show>
          </div>
        )}
      </For>
    </div>
  );
}

/** Reopen multiline token spans on each row without losing their lexical context. */
export function highlightedLines(html: string): string[] {
  const lines: string[] = [],
    stack: string[] = [];
  let current = "";
  for (const token of html.match(/<\/?span\b[^>]*>|\n|[^<\n]+|</g) ?? []) {
    if (token === "\n") {
      lines.push(current + "</span>".repeat(stack.length));
      current = stack.join("");
      continue;
    }
    if (token.startsWith("<span")) stack.push(token);
    else if (token === "</span>") stack.pop();
    current += token;
  }
  lines.push(current + "</span>".repeat(stack.length));
  return lines;
}
