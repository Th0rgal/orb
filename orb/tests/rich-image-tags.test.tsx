import { describe, expect, it, vi } from "vitest";
import { render, waitFor } from "@solidjs/testing-library";
import { MdView, markdownText } from "../src/Markdown";
import { FileReferenceContext, type ReferenceResolver } from "../src/fileReferenceContext";
import { parseRichTag } from "../src/richTags";

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
});
