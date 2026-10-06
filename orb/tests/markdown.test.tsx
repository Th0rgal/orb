import { describe, expect, it } from "vitest";
import { render } from "@solidjs/testing-library";
import { parseMarkdown, MdView } from "../src/Markdown";

const HEX_ZEROS = `On this DGX Spark the generator runs at about **1.29 billion addresses/s** (mean of three 20 s GB10 runs: 1299 / 1287 / 1281 M addr/s).

This tool's \`--until-score S\` counts **leading zero bytes** (\`0x00…\`), not hex characters. **S bytes = 2S hex zeros.** Expected wait is geometric: \`16^n / 1.29e9\` seconds for **n hex zeros**, or \`256^S / 1.29e9\` for **S zero bytes**. Median is ~0.69× that; ~95% of runs finish by ~3×.

| Hex zeros \`n\` | Address looks like | Byte score \`S\` | Expected keys | Expected time | 95% time |
|---:|---|---:|---:|---|---|
| 4 | \`0x0000…\` | 2 | 6.6×10⁴ | **50 µs** | 0.2 ms |
| 6 | \`0x000000…\` | 3 | 1.7×10⁷ | **13 ms** | 40 ms |
| 8 | \`0x00000000…\` | 4 | 4.3×10⁹ | **3.3 s** | 10 s |
| 10 | \`0x0000000000…\` | 5 | 1.1×10¹² | **14 min** | 42 min |
| 12 | \`0x000000000000…\` | 6 | 2.8×10¹⁴ | **2.5 days** | 7.6 days |
| 14 | \`0x00000000000000…\` | 7 | 7.2×10¹⁶ | **1.8 years** | 5.3 years |
| 16 | \`0x0000000000000000…\` | 8 | 1.8×10¹⁹ | **450 years** | 1.4 millennia |
| 20 | 10 zero bytes | 10 | 1.2×10²⁴ | **3×10⁷ years** | — |

That matches what we already saw: score 3 (\`0x000000…\`) in the first kernel, score 4 (\`0x00000000…\`) in a few seconds.
`;

describe("parseMarkdown", () => {
  it("keeps GFM tables as tables instead of one mashed paragraph", () => {
    const src = [
      "## GB10 results",
      "| Item | Result |",
      "|---|---|",
      "| Device | NVIDIA GB10 |",
      "| Throughput | **1.29B** addr/s |",
      "",
      "After the table.",
    ].join("\n");
    const blocks = parseMarkdown(src);
    expect(blocks).toMatchObject([
      { t: "h", n: 2, text: "GB10 results" },
      { t: "table", heads: ["Item", "Result"], rows: [["Device", "NVIDIA GB10"], ["Throughput", "**1.29B** addr/s"]] },
      { t: "p", text: "After the table." },
    ]);
  });

  it("parses GFM alignment separators and inline code in headers", () => {
    const src = [
      "Median is ~0.69× that; ~95% of runs finish by ~3×.",
      "",
      "| Hex zeros `n` | Address looks like | Byte score `S` | Expected keys | Expected time | 95% time |",
      "|---:|---|---:|---:|---|---|",
      "| 4 | `0x0000…` | 2 | 6.6×10⁴ | **50 µs** | 0.2 ms |",
      "| 6 | `0x000000…` | 3 | 1.7×10⁷ | **13 ms** | 40 ms |",
      "",
      "That matches what we already saw.",
    ].join("\n");
    const blocks = parseMarkdown(src);
    expect(blocks.map((b) => b.t)).toEqual(["p", "table", "p"]);
    expect(blocks[1]).toMatchObject({
      t: "table",
      heads: ["Hex zeros `n`", "Address looks like", "Byte score `S`", "Expected keys", "Expected time", "95% time"],
      aligns: ["right", "left", "right", "right", "left", "left"],
    });
    expect((blocks[1] as { rows: string[][] }).rows).toHaveLength(2);
  });

  it("renders the vanity Hex zeros estimate as an HTML table", () => {
    const blocks = parseMarkdown(HEX_ZEROS);
    expect(blocks.some((b) => b.t === "table")).toBe(true);
    const { container } = render(() => <MdView text={HEX_ZEROS} compact />);
    expect(container.querySelectorAll("table")).toHaveLength(1);
    expect(container.querySelectorAll("th").length).toBe(6);
    expect(container.querySelectorAll("tr").length).toBe(9); // header + 8 data
    expect(container.textContent).not.toContain("|---|");
  });
});

it("keeps quote separators and paragraphs in one blockquote",()=>{
 const text="> Salut **équipe**.\n>\n> Le rapport est prêt.\n>\n> Merci.";
 const {container}=render(()=><MdView text={text}/>);
 expect(container.querySelectorAll('blockquote')).toHaveLength(1);
 expect(container.querySelectorAll('blockquote p')).toHaveLength(3);
 expect(container.textContent).not.toContain('>');
 expect(container.querySelector('blockquote strong')?.textContent).toBe('équipe');
});
it("renders nested quotes, lists and fenced code within a quote",()=>{
 const {container}=render(()=><MdView text={'> Outer\n>\n> > Inner\n>\n> - one\n> - two\n>\n> ```txt\n> code\n> ```\n\nOutside'}/>);
 expect(container.querySelectorAll('blockquote')).toHaveLength(2);
 expect(container.querySelectorAll('blockquote li')).toHaveLength(2);
 expect(container.querySelector('blockquote pre')?.textContent).toBe('code');
 expect(container.querySelector(':scope > .md > p')?.textContent).toBe('Outside');
});

it("links bare URLs without swallowing surrounding punctuation", () => {
 const {container}=render(()=><MdView text={'**Verity** : https://github.com/lfglabs-dev/verity/pull/2438, puis (https://example.com/page). https://example.com/a_(b).'}/>);
 expect(Array.from(container.querySelectorAll('a')).map(a=>a.getAttribute('href'))).toEqual(['https://github.com/lfglabs-dev/verity/pull/2438','https://example.com/page','https://example.com/a_(b)']);
 expect(container.textContent).toContain('2438, puis (https://example.com/page).');
});
it("does not autolink code or nest anchors inside Markdown links", () => {
 const {container}=render(()=><MdView text={'`https://example.com/code` [https://example.com/label](https://example.com/target)\n\n```\nhttps://example.com/fenced\n```'}/>);
 expect(container.querySelectorAll('a')).toHaveLength(1);
 expect(container.querySelector('a')?.getAttribute('href')).toBe('https://example.com/target');
 expect(container.querySelector('a a')).toBeNull();
});

import { fireEvent, waitFor } from "@solidjs/testing-library";
import { vi } from "vitest";
import { FileReferenceContext } from "../src/fileReferenceContext";

it("renders code-formatted file link labels and opens only the destination", async () => {
  const path = '/Users/thomas/.orb/project-context/server/account/verity-core/files/Context/Verity.md';
  const ref = {source: 'workspace', path, name: 'Verity.md'};
  const open = vi.fn(), resolve = vi.fn(async () => [ref]);
  const {container, getByRole} = render(() => <FileReferenceContext.Provider value={{resolve, open, search: () => {}}}>
    <MdView text={`- [\`Context/Verity.md\`](file://${path}): Covers Verity.`}/>
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getByRole('button', {name: 'Context/Verity.md'})).toBeTruthy());
  expect(container.textContent).toBe('Context/Verity.md: Covers Verity.');
  expect(container.querySelector('button code')?.textContent).toBe('Context/Verity.md');
  expect(container.querySelectorAll('button')).toHaveLength(1);
  expect(resolve).toHaveBeenCalledExactlyOnceWith(path);
  fireEvent.click(getByRole('button', {name: 'Context/Verity.md'}));
  expect(open).toHaveBeenCalledWith([ref]);
});

it("does not resolve a plain file label inside an already resolved link", async () => {
  const path = 'audit/IMPLEMENTATION-BRIEF.md';
  const ref = {source: 'workspace', path, name: 'IMPLEMENTATION-BRIEF.md'};
  const resolve = vi.fn(async () => [ref]);
  const {container, getByRole} = render(() => <FileReferenceContext.Provider value={{resolve, open: () => {}, search: () => {}}}>
    <MdView text={'[IMPLEMENTATION-BRIEF.md](audit/IMPLEMENTATION-BRIEF.md)'}/>
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getByRole('button', {name: 'IMPLEMENTATION-BRIEF.md'})).toBeTruthy());
  expect(container.querySelectorAll('button')).toHaveLength(1);
  expect(resolve).toHaveBeenCalledExactlyOnceWith(path);
});

it("resolves Windows file URLs without the URL-only leading slash", async () => {
  const path = 'C:/Users/Jane/project/readme.md';
  const ref = {source: 'workspace', path, name: 'readme.md'};
  const resolve = vi.fn(async () => [ref]);
  const {getByRole} = render(() => <FileReferenceContext.Provider value={{resolve, open: () => {}, search: () => {}}}>
    <MdView text={'[`readme.md`](file:///C:/Users/Jane/project/readme.md)'}/>
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getByRole('button', {name: 'readme.md'})).toBeTruthy());
  expect(resolve).toHaveBeenCalledExactlyOnceWith(path);
});

it("keeps brackets inside code-formatted file link labels", async () => {
  const path = '/tmp/array.ts';
  const ref = {source: 'workspace', path, name: 'array.ts'};
  const resolve = vi.fn(async () => [ref]);
  const {container, getByRole} = render(() => <FileReferenceContext.Provider value={{resolve, open: () => {}, search: () => {}}}>
    <MdView text={'[`array[i].ts`](file:///tmp/array.ts)'}/>
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getByRole('button', {name: 'array[i].ts'})).toBeTruthy());
  expect(container.querySelector('button code')?.textContent).toBe('array[i].ts');
  expect(container.textContent).toBe('array[i].ts');
  expect(resolve).toHaveBeenCalledExactlyOnceWith(path);
});

it("handles balanced parentheses and angle-bracketed destinations in file links", async () => {
  const path = '/tmp/My (draft).pdf';
  const ref = {source: 'workspace', path, name: 'My (draft).pdf'};
  const resolve = vi.fn(async () => [ref]);
  const {container, getAllByRole} = render(() => <FileReferenceContext.Provider value={{resolve, open: () => {}, search: () => {}}}>
    <MdView text={'**[details (`safe`)](file:///tmp/My (draft).pdf)** and [`other`](<file:///tmp/My (draft).pdf>)'}/>
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getAllByRole('button')).toHaveLength(2));
  expect(container.textContent).toBe('details (safe) and other');
  expect(resolve).toHaveBeenCalledWith(path);
});

it("renders formatted link labels even without a file resolver", () => {
  const {container} = render(() => <MdView text={'[\`files/Context/\`](file:///tmp/Context/) [**notes**](file:///tmp/notes.md) [\`docs\`](https://example.com/docs)'}/>);
  expect(container.textContent).toBe('files/Context/ notes docs');
  expect(container.querySelectorAll('code')).toHaveLength(2);
  expect(container.querySelector('strong')?.textContent).toBe('notes');
  expect(container.querySelector('a code')?.textContent).toBe('docs');
});

it("decodes local file URLs while keeping unsupported URLs out of the resolver", async () => {
  const ref = {source: 'workspace', path: '/tmp/My notes.md', name: 'My notes.md'};
  const resolve = vi.fn(async () => [ref]);
  const {getByRole, container} = render(() => <FileReferenceContext.Provider value={{resolve, open: () => {}, search: () => {}}}>
    <MdView text={'[`notes`](file://localhost/tmp/My%20notes.md#L12) [`remote`](file://other-host/tmp/notes.md) [`unsafe`](javascript:alert)'} />
  </FileReferenceContext.Provider>);
  await waitFor(() => expect(getByRole('button', {name: 'notes'})).toBeTruthy());
  expect(resolve).toHaveBeenCalledExactlyOnceWith('/tmp/My notes.md#L12');
  expect(container.querySelectorAll('button')).toHaveLength(1);
  expect(container.querySelector('a')).toBeNull();
});

it("keeps a complete Markdown file link inside a code span literal", () => {
  const text = '`[notes](file:///tmp/notes.md)`';
  const {container} = render(() => <MdView text={text}/>);
  expect(container.querySelector('code')?.textContent).toBe('[notes](file:///tmp/notes.md)');
  expect(container.querySelector('a, button')).toBeNull();
});

it("renders Codex output citations through the file resolver and opens the original path", async () => {
  const path='/Users/thomas/.orb/local-workspaces/default/output/pdf/index-32.pdf';
  const ref={source:'workspace',path,name:'index-32.pdf'};
  const open=vi.fn(), resolve=vi.fn(async()=>[ref]);
  const {getByRole,container}=render(()=><FileReferenceContext.Provider value={{resolve,open,search:()=>{}}}><MdView text={`Download :codex-file-citation{purpose="output" path="${path}"} here.`}/></FileReferenceContext.Provider>);
  await waitFor(()=>expect(getByRole('button',{name:'index-32.pdf'})).toBeTruthy());
  expect(resolve).toHaveBeenCalledWith(path);
  fireEvent.click(getByRole('button',{name:'index-32.pdf'}));
  expect(open).toHaveBeenCalledWith([ref]);
  expect(container.textContent).toBe('Download index-32.pdf here.');
});

it("keeps citation examples inside code literal and handles spaces and markdown punctuation in paths",()=>{
  const citation=':codex-file-citation{path="/tmp/My [draft] (2).pdf" purpose="output"}';
  const {container}=render(()=><MdView text={`${citation}\n\n\`${citation}\`\n\n\`\`\`text\n${citation}\n\`\`\``}/>);
  expect(container.querySelector('p')?.textContent).toBe('My [draft] (2).pdf');
  expect(container.querySelector('p code')?.textContent).toBe(citation);
  expect(container.querySelector('pre')?.textContent).toContain(citation);
});

describe("emphasis around code spans", () => {
  it("keeps asterisks in link destinations opaque to surrounding emphasis", () => {
    const {container} = render(() => <MdView text={'*[docs](https://example.com/search?q=*)* *[file](file:///tmp/a*b.md)* **[`docs`](https://example.com/search?q=**)**'}/>);
    expect([...container.querySelectorAll('em')].map(node => node.textContent)).toEqual(['docs', 'file']);
    expect(container.querySelector('strong')?.textContent).toBe('docs');
    expect([...container.querySelectorAll('a')].map(node => node.getAttribute('href'))).toEqual(['https://example.com/search?q=*', 'https://example.com/search?q=**']);
    expect(container.textContent).toBe('docs file docs');
  });
  it("preserves emphasis around links with plain and code-formatted labels", () => {
    const {container} = render(() => <MdView text={'**[docs](https://example.com)** *[notes](file:///tmp/notes.md)* **[`code docs`](https://example.com/code)** *[`code notes`](file:///tmp/notes.md)*'}/>);
    expect([...container.querySelectorAll('strong')].map(node => node.textContent)).toEqual(['docs', 'code docs']);
    expect([...container.querySelectorAll('em')].map(node => node.textContent)).toEqual(['notes', 'code notes']);
    expect(container.querySelectorAll('strong a')).toHaveLength(2);
    expect(container.querySelector('strong a code')?.textContent).toBe('code docs');
    expect(container.querySelector('em code')?.textContent).toBe('code notes');
    expect(container.textContent).toBe('docs notes code docs code notes');
  });
  it("renders bold that ends with a code span", () => {
    const { container } = render(() => <MdView text={"- **La mission `be655506`** continue de travailler sur `final/*`.\n- **La PR #1 est mergée dans `main`** avec un commit (`12c18b46`)."} />);
    const strong = [...container.querySelectorAll("strong")].map(node => node.textContent);
    expect(strong).toEqual(["La mission be655506", "La PR #1 est mergée dans main"]);
    expect(container.querySelector("strong code")?.textContent).toBe("be655506");
    expect(container.textContent).not.toContain("**");
    expect(container.querySelectorAll("code")).toHaveLength(4);
  });
  it("renders bold that starts with or surrounds a code span", () => {
    const { container } = render(() => <MdView text={"**`main`** is protected and **use `a` then `b` here** works."} />);
    expect([...container.querySelectorAll("strong")].map(node => node.textContent)).toEqual(["main", "use a then b here"]);
    expect(container.textContent).not.toContain("**");
  });
  it("keeps asterisks inside code and separate bold runs apart", () => {
    const { container } = render(() => <MdView text={"**a** uses `x ** y` and **b**; escaped \\*\\*not `bold`\\*\\*"} />);
    expect([...container.querySelectorAll("strong")].map(node => node.textContent)).toEqual(["a", "b"]);
    expect([...container.querySelectorAll("code")].map(node => node.textContent)).toEqual(["x ** y", "bold"]);
    expect(container.textContent).toContain("**not bold**");
  });
});

import { incrementalMarkdown } from "../src/Markdown";
it("streaming keeps the identity of blocks that did not change", () => {
  const parse = incrementalMarkdown();
  const first = parse("# Title\n\nParagraph one\n\n```lean\ntheorem a");
  const second = parse("# Title\n\nParagraph one\n\n```lean\ntheorem a := by\n  simp");
  expect(second.length).toBe(first.length);
  // Stable blocks (before the last blank line) and the unchanged tail blocks are the same objects.
  expect(second[0]).toBe(first[0]);
  expect(second[1]).toBe(first[1]);
  expect(second[2]).not.toBe(first[2]);
  const third = parse("# Title\n\nParagraph one\n\n```lean\ntheorem a := by\n  simp\n```\n\nDone");
  expect(third[0]).toBe(first[0]);
  expect(third.at(-1)).toMatchObject({ t: "p" });
});
