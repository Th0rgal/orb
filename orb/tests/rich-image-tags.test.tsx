import { describe, expect, it, vi } from "vitest";
import { render, waitFor } from "@solidjs/testing-library";
import { MdView, markdownText } from "../src/Markdown";
import { FileReferenceContext, type ReferenceResolver } from "../src/fileReferenceContext";
import { RICH_TAG, expandMediaLines, parseRichTag } from "../src/richTags";
import spec from "../../shared/orb-spec/file-references.json";

const resolver = (loadImage: ReferenceResolver["loadImage"]): ReferenceResolver =>
  ({ loadImage, resolve: async () => [], open: () => {}, search: () => {} });

describe("rich image tags", () => {
  it("parses attributes, falling back to inner text and the basename", () => {
    expect(parseRichTag("image", 'path="./shots/a b.png" alt="  Door  placed "')).toEqual({ type: "image", path: "./shots/a b.png", label: "Door placed" });
    expect(parseRichTag("image", "path='./x.png'")).toMatchObject({ label: "x.png" });
    expect(parseRichTag("file", 'path="r.pdf"', "My report")).toMatchObject({ type: "file", label: "My report" });
    expect(parseRichTag("image", 'alt="no path"')).toBeNull();
  });

  it("renders <image> tags and relative markdown images through the workspace resolver", async () => {
    const loadImage = vi.fn(async (path: string) => `data:image/png;base64,${btoa(path)}`);
    const text = [
      "1. **Custom Trident** — held and thrown:",
      "",
      '<image path="./screenshots/01_custom_trident.png" alt="Custom Trident held and thrown model" />',
      "",
      "![Door](screenshots/02_door.png) and ![remote](https://example.com/r.png)",
    ].join("\n");
    const { container } = render(() => <FileReferenceContext.Provider value={resolver(loadImage)}><MdView text={text} /></FileReferenceContext.Provider>);
    await waitFor(() => expect(container.querySelectorAll(".md-workspace-image img")).toHaveLength(2));
    expect(loadImage.mock.calls.map(c => c[0])).toEqual(["./screenshots/01_custom_trident.png", "screenshots/02_door.png"]);
    expect(container.querySelector('.md-workspace-image img')?.getAttribute("alt")).toBe("Custom Trident held and thrown model");
    expect(container.querySelector('img[src="https://example.com/r.png"]')).not.toBeNull();
    expect(container.textContent).not.toContain("<image");
  });

  it("shows a labelled placeholder when no resolver can load the image", () => {
    const { container } = render(() => <MdView text={'<image path="./a.png" alt="Chart" />'} />);
    expect(container.querySelector(".md-workspace-image-missing")?.textContent).toContain("Chart");
    expect(container.textContent).not.toContain("<image");
  });

  it("uses labels in plain text", () => {
    expect(markdownText('See <image path="./a.png" alt="Chart" /> and <file path="./r.pdf">Report</file>')).toBe("See Chart and Report");
  });

  it("reads every shared fixture case like iOS and Android", () => {
    for (const c of spec.cases as { name: string; input: string; refs: Record<string, string>[] }[]) {
      const text = expandMediaLines(c.input).replace(/```[\s\S]*?(```|$)/g, "");
      const refs = [...text.matchAll(RICH_TAG)].map(m => parseRichTag(m[1], m[2], m[3])).filter(Boolean);
      expect(refs.map(r => ({ type: r!.type, path: r!.path, label: r!.label, unavailable: r!.unavailable ? "true" : undefined })), c.name)
        .toEqual(c.refs.map(r => ({ type: r.type, path: r.path, label: r.label, unavailable: r.unavailable })));
    }
  });

  it("renders a Hermes MEDIA line as an inline image and never shows the directive", async () => {
    const loadImage = vi.fn(async (path: string) => `data:image/png;base64,${btoa(path)}`);
    const text = "Voici le graphique.\n\nMEDIA:/tmp/orb_usage_30d.png\n\n```\nMEDIA:/tmp/doc.png\n```";
    const { container } = render(() => <FileReferenceContext.Provider value={resolver(loadImage)}><MdView text={text} /></FileReferenceContext.Provider>);
    await waitFor(() => expect(container.querySelectorAll(".md-workspace-image img")).toHaveLength(1));
    expect(loadImage.mock.calls.map(c => c[0])).toEqual(["/tmp/orb_usage_30d.png"]);
    expect(container.querySelector("p")?.textContent).not.toContain("MEDIA:");
    expect(markdownText("MEDIA:/tmp/r.pdf")).toBe("r.pdf");
  });

  it("shows a file Core could not copy as an unavailable chip", () => {
    const { container } = render(() => <MdView text={'Chart:\n<file path="/tmp/gone.png" name="gone.png" unavailable="true" />'} />);
    const chip = container.querySelector(".md-file-unavailable");
    expect(chip?.textContent).toContain("gone.png");
    expect(chip?.textContent).toContain("File no longer available");
    expect(container.textContent).not.toContain("<file");
  });
});
