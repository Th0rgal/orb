import { beforeAll, describe, expect, it, vi } from "vitest";
import { render, waitFor } from "@solidjs/testing-library";
import katex from "katex";
import { highlightCode } from "../src/codeHighlight";
import { cachedHighlight, rememberHighlight } from "../src/codeHighlightClient";
import { hydrateMarkdownAst, parseMarkdownRaw } from "../src/markdownAst";
import { loadKatex, MdView, seedParsedMarkdown } from "../src/Markdown";
import { FileReferenceContext } from "../src/fileReferenceContext";

beforeAll(async () => {
  await loadKatex();
});

const COMPLEX_MARKDOWN = [
  "# Phase A.3 Worker Parity",
  "",
  "Currency stays plain: $15 and $20, while inline math $\\alpha + \\beta = \\gamma$ and display math render:",
  "",
  "$$",
  "E = mc^2 + \\sum_{i=1}^{n} x_i",
  "$$",
  "",
  "Glued fence prose```typescript",
  "export function greet(name: string): string {",
  "  return `Hello, ${name}!`;",
  "}",
  "```",
  "",
  "| Metric | Cold | Warm |",
  "| :--- | ---: | :---: |",
  "| Latency | **1.4 ms** | `0.2 ms` |",
  "| Link | [Example](https://example.com/docs) | [Evil](javascript:alert(1)) |",
  "",
  "> Quoted **summary** with nested list:",
  ">",
  "> - First item with :codex-file-citation{path=\"orb/src/Markdown.tsx\"}",
  ">   - Nested sub-item with `inline.ts`",
  "> - Unavailable attachment <file path=\"/tmp/gone.csv\" name=\"gone.csv\" unavailable=\"true\" />",
  "",
  "<file path=\"orb/src/App.tsx\" name=\"App.tsx\" /> and bare URL https://example.com/path_(1).",
].join("\n");

describe("off-main-thread Markdown AST + KaTeX + Prism parity", () => {
  it("produces 100% identical DOM between synchronous MdView and worker-hydrated AST + Prism + KaTeX", () => {
    const syncText = `${COMPLEX_MARKDOWN}\n\nSync marker.`;
    const workerText = `${COMPLEX_MARKDOWN}\n\nWorker marker.`;

    // Pre-populate Prism highlight so synchronous CodeBlock also paints highlighted tokens on frame 0
    const tsCode = 'export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}';
    const tsHtml = highlightCode(tsCode, "typescript");
    expect(tsHtml).toBeTruthy();
    rememberHighlight(tsCode, "typescript", tsHtml!);

    const resolver = {
      resolve: async (raw: string) => [{ source: "workspace", path: raw, name: raw.split("/").pop() || raw }],
      open: () => {},
      search: () => {},
    };

    const syncRender = render(() => (
      <FileReferenceContext.Provider value={resolver}>
        <MdView text={syncText} compact searchable />
      </FileReferenceContext.Provider>
    ));

    // Simulate codeHighlight.worker.ts `parse_markdown` execution and structured-clone round-trip
    const rawBlocks = parseMarkdownRaw(workerText);
    const work = hydrateMarkdownAst(rawBlocks);
    expect(work.codes).toEqual([{ text: tsCode, lang: "typescript" }]);
    expect(work.formulas).toEqual([
      { text: "\\alpha + \\beta = \\gamma", display: false },
      { text: "E = mc^2 + \\sum_{i=1}^{n} x_i", display: true },
    ]);

    const clonedBlocks = JSON.parse(JSON.stringify(rawBlocks));
    const workerFormulas = work.formulas.map((f) => ({
      key: `${f.display ? "D" : "I"}${f.text}`,
      html: katex.renderToString(f.text, {
        displayMode: f.display,
        throwOnError: false,
        trust: false,
        strict: "ignore",
        maxExpand: 1000,
      }),
    }));
    seedParsedMarkdown(workerText, clonedBlocks, workerFormulas);

    const workerRender = render(() => (
      <FileReferenceContext.Provider value={resolver}>
        <MdView text={workerText} compact searchable />
      </FileReferenceContext.Provider>
    ));

    const normalizeMarker = (html: string) => html.replace(/Worker marker\./g, "Sync marker.");
    expect(normalizeMarker(workerRender.container.innerHTML)).toBe(syncRender.container.innerHTML);

    // Neutralized javascript: link becomes a FileReference span, never an <a href="javascript:...">
    const hrefs = Array.from(workerRender.container.querySelectorAll("a")).map((a) => a.getAttribute("href"));
    expect(hrefs).toEqual(["https://example.com/docs", "https://example.com/path_(1)"]);
    expect(cachedHighlight(tsCode, "typescript")).toBe(tsHtml);
  });

  it("preserves exact block/table/code geometry on frame 0 for cold >= 4096-char turns while deferring inline AST to Worker, and falls back cleanly on worker error", async () => {
    const originalWorker = globalThis.Worker;
    let createdWorkers = 0;
    class FailingMockWorker {
      onmessage: ((ev: MessageEvent) => void) | null = null;
      onerror: ((ev: ErrorEvent) => void) | null = null;
      constructor() {
        createdWorkers++;
      }
      postMessage() {
        queueMicrotask(() => {
          this.onerror?.(new Event("error") as ErrorEvent);
        });
      }
      terminate = vi.fn();
    }
    (globalThis as unknown as { Worker: unknown }).Worker = FailingMockWorker;
    try {
      const huge = [
        "# Large Turn",
        "",
        "| Col A | Col B |",
        "| --- | --- |",
        "| **val** | `code` |",
        "",
        "```ts",
        `const longLine = "${"x".repeat(300)}";`,
        "```",
        "",
        "Paragraph body with **bold** text and `code` span. ".repeat(110),
      ].join("\n");
      expect(huge.length).toBeGreaterThanOrEqual(4096);

      const { container } = render(() => <MdView text={huge} compact />);
      // Frame 0 already renders the real <h1>, <table>, and .md-code-block (<pre>) geometry
      // while deferring expensive inline regex/AST parsing to the worker!
      expect(container.querySelector("h1")?.textContent).toBe("Large Turn");
      expect(container.querySelectorAll("table")).toHaveLength(1);
      expect(container.querySelectorAll(".md-code-block")).toHaveLength(1);
      expect(container.querySelectorAll("strong")).toHaveLength(0);
      expect(createdWorkers).toBe(1);

      // Worker error triggers synchronous inline AST fallback so inline formatting still resolves
      await waitFor(() => {
        expect(container.querySelectorAll("strong").length).toBeGreaterThan(10);
      });
    } finally {
      (globalThis as unknown as { Worker: unknown }).Worker = originalWorker;
    }
  });
});
