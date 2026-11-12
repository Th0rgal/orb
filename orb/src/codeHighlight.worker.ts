import { highlightCode } from "./codeHighlight";
import { hydrateMarkdownAst, parseMarkdownRaw, type Block } from "./markdownAst";
import { initializeKernel } from "./orbKernelAbi";

type WorkerRequest =
  | { kind?: "highlight"; id: number; text: string; lang: string }
  | { kind: "parse_markdown"; id: number; text: string };

export type WorkerMarkdownFormula = { key: string; html: string };
export type WorkerMarkdownHighlight = { text: string; lang: string; html: string };
export type WorkerResponse =
  | { kind?: "highlight"; id: number; html: string | null }
  | {
      kind: "parse_markdown";
      id: number;
      blocks: Block[] | null;
      highlights: WorkerMarkdownHighlight[];
      formulas: WorkerMarkdownFormula[];
    };

let kernelReady: Promise<void> | undefined;
let katexReady: Promise<{ renderToString: (tex: string, opts: Record<string, unknown>) => string }> | undefined;

function ensureWorkerKernel(): Promise<void> {
  return (kernelReady ??= initializeKernel().catch((err) => {
    kernelReady = undefined;
    throw err;
  }));
}

function ensureWorkerKatex() {
  return (katexReady ??= import("katex")
    .then((m) => (m.default ?? m) as { renderToString: (tex: string, opts: Record<string, unknown>) => string })
    .catch((err) => {
      katexReady = undefined;
      throw err;
    }));
}

self.onmessage = async (event: MessageEvent<WorkerRequest>) => {
  const data = event.data;
  if (data.kind === "parse_markdown") {
    try {
      await ensureWorkerKernel();
      const blocks = parseMarkdownRaw(data.text);
      const work = hydrateMarkdownAst(blocks);
      const highlights: WorkerMarkdownHighlight[] = [];
      for (const code of work.codes) {
        try {
          const html = highlightCode(code.text, code.lang);
          if (html !== null) highlights.push({ text: code.text, lang: code.lang, html });
        } catch {
          /* keep plaintext */
        }
      }
      const formulas: WorkerMarkdownFormula[] = [];
      if (work.formulas.length > 0) {
        try {
          const katex = await ensureWorkerKatex();
          for (const f of work.formulas) {
            try {
              const html = katex.renderToString(f.text, {
                displayMode: f.display,
                throwOnError: false,
                trust: false,
                strict: "ignore",
                maxExpand: 1000,
              });
              formulas.push({ key: `${f.display ? "D" : "I"}${f.text}`, html });
            } catch {
              /* fallback to source text */
            }
          }
        } catch {
          /* main thread will load katex if needed */
        }
      }
      self.postMessage({ kind: "parse_markdown", id: data.id, blocks, highlights, formulas } satisfies WorkerResponse);
    } catch {
      self.postMessage({ kind: "parse_markdown", id: data.id, blocks: null, highlights: [], formulas: [] } satisfies WorkerResponse);
    }
    return;
  }

  let html: string | null = null;
  try {
    html = highlightCode(data.text, data.lang);
  } catch {
    /* keep plaintext */
  }
  self.postMessage({ kind: "highlight", id: data.id, html } satisfies WorkerResponse);
};
