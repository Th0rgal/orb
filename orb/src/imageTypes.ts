/** Image types Orb previews, by file extension. SVG is listed: it is only ever
 * shown through `<img>` (blob: URL), where scripts never run and external
 * references are never fetched. Never inline SVG markup into the DOM. */
const MIME: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", jfif: "image/jpeg", gif: "image/gif", webp: "image/webp", avif: "image/avif", bmp: "image/bmp", ico: "image/x-icon", svg: "image/svg+xml" };

export function imageMime(name: string): string | undefined {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? undefined : MIME[name.slice(dot + 1).toLowerCase()];
}

/** Largest image Orb downloads for an inline preview. SVG is text the browser
 * must parse in full, so it gets a tighter cap than raster images. */
export function imageByteLimit(mime: string): number {
  return mime === "image/svg+xml" ? 5 * 1024 * 1024 : 20 * 1024 * 1024;
}
