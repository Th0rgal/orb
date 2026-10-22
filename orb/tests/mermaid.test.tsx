import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@solidjs/testing-library";
import DOMPurify from "dompurify";
import { MdView, parseMarkdown } from "../src/Markdown";
import { neutralizeCss, stripDirectives, cachedMermaid, clearMermaidCache, hashSource, mermaidCacheSize, renderMermaid, sanitizeSvg, setMermaidLoader } from "../src/mermaidRenderer";

const theme = { primaryColor: "#123456" };
let parse: ReturnType<typeof vi.fn>, renderFn: ReturnType<typeof vi.fn>;
beforeEach(() => {
  clearMermaidCache();
  parse = vi.fn(async (src: string) => { if (src.includes("broken")) throw new Error("Parse error on line 2:\nExpecting 'NODE_STRING', got 'EOF'"); return true; });
  renderFn = vi.fn(async (id: string, src: string) => ({ svg: `<svg id="${id}" viewBox="0 0 120 40"><text>${src.length}</text><script>alert(1)</script></svg>` }));
  setMermaidLoader(async () => ({ mermaid: { initialize: vi.fn(), parse, render: renderFn } as any, purify: DOMPurify }));
});
afterEach(() => { cleanup(); setMermaidLoader(undefined); });

it("marks unterminated fences as still streaming", () => {
  expect(parseMarkdown("```mermaid\nflowchart LR\n  A-->B")).toEqual([{ t: "pre", lang: "mermaid", text: "flowchart LR\n  A-->B", open: true }]);
  expect(parseMarkdown("```mermaid\nflowchart LR\n```")).toEqual([{ t: "pre", lang: "mermaid", text: "flowchart LR" }]);
});

it("returns the parser message for invalid source without rendering", async () => {
  const result = await renderMermaid("flowchart LR\n  broken -->", theme);
  expect(result).toEqual({ ok: false, error: expect.stringContaining("Parse error on line 2") });
  expect(renderFn).not.toHaveBeenCalled();
});

it("caches by source and theme and shares concurrent renders", async () => {
  const [a, b] = await Promise.all([renderMermaid("graph TD\nA-->B", theme), renderMermaid("graph TD\nA-->B", theme)]);
  expect(a).toBe(b);
  expect(renderFn).toHaveBeenCalledTimes(1);
  expect(cachedMermaid("graph TD\nA-->B", theme)).toBe(a);
  await renderMermaid("graph TD\nA-->B", theme);
  expect(renderFn).toHaveBeenCalledTimes(1);
  await renderMermaid("graph TD\nA-->B", { primaryColor: "#ffffff" });
  expect(renderFn).toHaveBeenCalledTimes(2);
  expect(mermaidCacheSize()).toBe(2);
  expect(a.ok && a.width).toBe(120);
  expect(a.ok && a.svg).not.toContain("<script");
  expect(hashSource("ab")).not.toBe(hashSource("ba"));
});

it("strips scripts, handlers and links from rendered SVG", () => {
  const out = sanitizeSvg(DOMPurify, '<svg><g onclick="x()"><a href="javascript:alert(1)"><text>t</text></a></g><foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><span>label</span><img src=x onerror=alert(1)></div></foreignObject><script>1</script></svg>');
  expect(out).not.toMatch(/onclick|onerror|javascript:|<script|href/);
  expect(out).toContain("label");
});

it("falls back to the source with a note when a diagram is invalid", async () => {
  render(() => <MdView text={"```mermaid\nflowchart LR\n  broken -->\n```\n\nafter"} />);
  await waitFor(() => expect(screen.getByRole("note").textContent).toContain("Couldn't render diagram"), { timeout: 2000 });
  expect(screen.getByRole("note").textContent).toContain("Parse error on line 2");
  expect(screen.getByText(/broken -->/)).toBeTruthy();
  expect(screen.getByText("after")).toBeTruthy();
});

it("does not render while the fence is open", async () => {
  render(() => <MdView text={"```mermaid\nflowchart LR\n  A-->B"} />);
  await new Promise((r) => setTimeout(r, 300));
  expect(parse).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Diagram" }).hasAttribute("disabled")).toBe(true);
});

it("neutralises directives, external CSS and links", async () => {
  expect(stripDirectives('%%{init: {"themeCSS": "x"}}%%\nflowchart LR\nA-->B')).toBe("\nflowchart LR\nA-->B");
  expect(neutralizeCss('@import "https://e.x/a.css"; .n{background:url(https://e.x/p.png)} .m{marker-end:url(#arrow)}')).toBe(' .n{background:none} .m{marker-end:url(#arrow)}');
  const out = sanitizeSvg(DOMPurify, '<svg><style>@import url(https://e.x/a.css); .a{fill:url("https://e.x/t")}</style><rect style="fill:url(https://e.x/q)" filter="url(https://e.x/f)" marker-end="url(#m)"/><a xlink:href="https://e.x"><text>t</text></a></svg>');
  expect(out).not.toMatch(/e\.x|@import|href/);
  expect(out).toContain('marker-end="url(#m)"');
  await renderMermaid('%%{init: {"theme":"dark"}}%%\ngraph TD\nA-->B', theme);
  expect(parse).toHaveBeenCalledWith("\ngraph TD\nA-->B");
});
