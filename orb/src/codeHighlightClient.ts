import { batch } from "solid-js";
import type { WorkerMarkdownFormula, WorkerMarkdownHighlight, WorkerResponse } from "./codeHighlight.worker";
import type { Block } from "./markdownAst";

let worker: Worker | undefined;
let sequence = 0;

// Finished highlights by language and source, so a code block that scrolls
// back into a virtualized transcript paints coloured in its first frame
// instead of plain text for the 120 ms debounce plus the worker round trip.
// Bounded by characters (about 4 MB of strings) with LRU eviction.
const highlights = new Map<string, string>();
let highlightChars = 0;
const HIGHLIGHT_BUDGET = 2_000_000;
const MAX_SINGLE_HIGHLIGHT_CHARS = Math.floor(HIGHLIGHT_BUDGET / 4);

export function cachedHighlight(text: string, lang: string): string | null {
  const key = `${lang}\n${text}`,
    html = highlights.get(key);
  if (html === undefined) return null;
  highlights.delete(key);
  highlights.set(key, html);
  return html;
}

export function rememberHighlight(text: string, lang: string, html: string): void {
  const key = `${lang}\n${text}`;
  if (key.length + html.length >= MAX_SINGLE_HIGHLIGHT_CHARS) return;
  if (highlights.has(key)) {
    highlights.delete(key);
    highlights.set(key, html);
    return;
  }
  highlights.set(key, html);
  highlightChars += key.length + html.length;
  for (const [old, value] of highlights) {
    if (highlightChars <= HIGHLIGHT_BUDGET) break;
    highlights.delete(old);
    highlightChars -= old.length + value.length;
  }
}

export type WorkerMarkdownResult = {
  blocks: Block[] | null;
  formulas: WorkerMarkdownFormula[];
};

const pendingHighlights = new Map<number, (html: string | null) => void>();
const pendingMarkdown = new Map<number, (res: WorkerMarkdownResult) => void>();
const inFlightMarkdownByText = new Map<string, Set<(res: WorkerMarkdownResult) => void>>();

let flushQueue: WorkerResponse[] = [];
let flushScheduled = false;

function flushWorkerBatch() {
  flushScheduled = false;
  const ready = flushQueue;
  flushQueue = [];
  batch(() => {
    for (const msg of ready) {
      if (msg.kind === "parse_markdown") {
        for (const h of msg.highlights) {
          rememberHighlight(h.text, h.lang, h.html);
        }
        const cb = pendingMarkdown.get(msg.id);
        pendingMarkdown.delete(msg.id);
        cb?.({ blocks: msg.blocks, formulas: msg.formulas });
      } else {
        const cb = pendingHighlights.get(msg.id);
        pendingHighlights.delete(msg.id);
        cb?.(msg.html);
      }
    }
  });
}

function ensureWorker(): Worker {
  if (!worker) {
    worker = new Worker(new URL("./codeHighlight.worker.ts", import.meta.url), { type: "module" });
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      flushQueue.push(event.data);
      if (!flushScheduled) {
        flushScheduled = true;
        queueMicrotask(flushWorkerBatch);
      }
    };
    worker.onerror = () => {
      worker?.terminate();
      worker = undefined;
      flushQueue = [];
      flushScheduled = false;
      const hl = [...pendingHighlights.values()];
      const md = [...pendingMarkdown.values()];
      pendingHighlights.clear();
      pendingMarkdown.clear();
      inFlightMarkdownByText.clear();
      batch(() => {
        for (const cb of hl) cb(null);
        for (const cb of md) cb({ blocks: null, formulas: [] });
      });
    };
  }
  return worker;
}

/** One lazy worker shared by all blocks. Cancelled requests cannot update stale DOM. */
export function requestHighlight(text: string, lang: string, receive: (html: string | null) => void): () => void {
  const hit = cachedHighlight(text, lang);
  if (hit !== null) {
    receive(hit);
    return () => {};
  }
  if (typeof Worker === "undefined") {
    receive(null);
    return () => {};
  }
  const w = ensureWorker();
  const id = ++sequence;
  pendingHighlights.set(id, (html) => {
    if (html !== null) rememberHighlight(text, lang, html);
    receive(html);
  });
  w.postMessage({ kind: "highlight", id, text, lang });
  return () => {
    pendingHighlights.delete(id);
  };
}

/** Pre-warm worker syntax highlighting for settled code blocks off the critical path. */
export function warmHighlight(text: string, lang: string): void {
  if (!lang || !text || text.length > 100_000 || typeof Worker === "undefined") return;
  if (cachedHighlight(text, lang) !== null) return;
  requestHighlight(text, lang, () => {});
}

/** Off-main-thread Markdown block + inline AST + Prism + KaTeX worker parse, deduplicated per source string. */
export function requestMarkdownParse(text: string, receive: (res: WorkerMarkdownResult) => void): () => void {
  if (typeof Worker === "undefined") {
    receive({ blocks: null, formulas: [] });
    return () => {};
  }
  const existing = inFlightMarkdownByText.get(text);
  if (existing) {
    existing.add(receive);
    return () => {
      existing.delete(receive);
    };
  }
  const listeners = new Set<(res: WorkerMarkdownResult) => void>([receive]);
  inFlightMarkdownByText.set(text, listeners);
  const w = ensureWorker();
  const id = ++sequence;
  pendingMarkdown.set(id, (res) => {
    inFlightMarkdownByText.delete(text);
    for (const cb of listeners) cb(res);
  });
  w.postMessage({ kind: "parse_markdown", id, text });
  return () => {
    listeners.delete(receive);
    if (listeners.size === 0) {
      inFlightMarkdownByText.delete(text);
      pendingMarkdown.delete(id);
    }
  };
}

export type { WorkerMarkdownHighlight, WorkerMarkdownFormula };
