import { describe, expect, it } from "vitest";
import { imageByteLimit, imageMime } from "../src/imageTypes";

describe("image types", () => {
  it("previews SVG as image/svg+xml with a tighter size cap", () => {
    expect(imageMime("logos/svg/Maxwell.SVG")).toBe("image/svg+xml");
    expect(imageMime("a.png")).toBe("image/png");
    expect(imageMime("page.html")).toBeUndefined();
    expect(imageMime("svg")).toBeUndefined();
    expect(imageByteLimit("image/svg+xml")).toBe(5 * 1024 * 1024);
    expect(imageByteLimit("image/png")).toBe(20 * 1024 * 1024);
  });
});
