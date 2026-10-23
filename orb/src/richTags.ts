/**
 * Rich `<image>` / `<file>` tags agents write in replies, shared with the web
 * dashboard (dashboard/src/lib/rich-tags.ts):
 * `<image path="./chart.png" alt="Chart" />`, `<file path="./r.pdf" name="Report" />`
 * and the paired `<file path="r.pdf">Report</file>` form.
 */
import { leansysRichTagAdmitted } from "./orbKernel";

export const RICH_TAG = /<(image|file)\s+([^>]*?)(?:\/\s*>|>([^<]*?)<\/\1\s*>)/gi;

export type RichTag = { type: "image" | "file"; path: string; label: string; unavailable?: true };

const present = (value: string | undefined) => value?.trim().replace(/\s+/g, " ") || undefined;

/** Where one `RICH_TAG` match sits in its source text. */
export type RichTagSpan = { tagOff: number; tagLen: number; attrOff: number; bufLen: number };

export function richTagSpan(match: string, type: string, attrs: string, index: number, bufLen: number): RichTagSpan {
  return { tagOff: index, tagLen: match.length, attrOff: index + match.indexOf(attrs, 1 + type.length), bufLen };
}

export function parseRichTag(
  type: string,
  attrs: string,
  inner?: string,
  span: RichTagSpan = { tagOff: 0, tagLen: attrs.length, attrOff: 0, bufLen: attrs.length },
): RichTag | null {
  const values: Record<string, string> = {};
  for (const m of attrs.matchAll(/(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) values[m[1].toLowerCase()] = m[2] ?? m[3] ?? "";
  const path = values.path?.trim();
  if (!path) return null;
  const kind = type.toLowerCase() as RichTag["type"];
  const tagKind = kind === "image" ? 2 : 1;
  if (!leansysRichTagAdmitted(span.tagOff, span.tagLen, span.attrOff, attrs.length, span.bufLen, tagKind)) return null;
  const label = present(kind === "image" ? values.alt : values.name) ?? present(inner) ?? path.split("/").pop() ?? path;
  return values.unavailable === "true" ? { type: kind, path, label, unavailable: true } : { type: kind, path, label };
}

/** Hermes's attachment directive alone on a line: `MEDIA:/tmp/plot.png`,
 * `**MEDIA:/tmp/r.pdf**`, `MEDIA: "/tmp/a b.csv"`. Core rewrites these at
 * ingestion; this fallback covers messages stored before it did. */
const MEDIA_LINE = /^[ \t]*[*_]{0,3}MEDIA:[ \t]*(?:"([^"<>\n]+)"|'([^'"<>\n]+)'|((?:~\/|\/)[^\s"'<>`]+?))[*_]{0,3}[.,;:]?[ \t\r]*$/;
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp", "bmp"]);

/** One `MEDIA:` line as the equivalent rich tag, or null. */
export function mediaLineTag(line: string): string | null {
  const m = MEDIA_LINE.exec(line);
  const path = (m?.[1] ?? m?.[2] ?? m?.[3])?.trim();
  if (!path) return null;
  const name = path.split("/").pop() || path;
  const ext = name.includes(".") ? name.split(".").pop()!.toLowerCase() : "";
  return IMAGE_EXTENSIONS.has(ext) ? `<image path="${path}" alt="${name}" />` : `<file path="${path}" name="${name}" />`;
}

/** Rewrite `MEDIA:` lines outside fenced code into rich tags. */
export function expandMediaLines(text: string): string {
  if (!text.includes("MEDIA:")) return text;
  let fence: string | null = null;
  return text.split("\n").map(line => {
    const t = line.trimStart();
    if (fence) { if (t.startsWith(fence)) fence = null; return line; }
    if (t.startsWith("```") || t.startsWith("~~~")) { fence = t.slice(0, 3); return line; }
    return mediaLineTag(line) ?? line;
  }).join("\n");
}
