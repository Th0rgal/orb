/**
 * Rich `<image>` / `<file>` tags agents write in replies, shared with the web
 * dashboard (dashboard/src/lib/rich-tags.ts):
 * `<image path="./chart.png" alt="Chart" />`, `<file path="./r.pdf" name="Report" />`
 * and the paired `<file path="r.pdf">Report</file>` form.
 */
export const RICH_TAG = /<(image|file)\s+([^>]*?)(?:\/\s*>|>([^<]*?)<\/\1\s*>)/gi;

export type RichTag = { type: "image" | "file"; path: string; label: string };

const present = (value: string | undefined) => value?.trim().replace(/\s+/g, " ") || undefined;

export function parseRichTag(type: string, attrs: string, inner?: string): RichTag | null {
  const values: Record<string, string> = {};
  for (const m of attrs.matchAll(/(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) values[m[1].toLowerCase()] = m[2] ?? m[3] ?? "";
  const path = values.path?.trim();
  if (!path) return null;
  const kind = type.toLowerCase() as RichTag["type"];
  const label = present(kind === "image" ? values.alt : values.name) ?? present(inner) ?? path.split("/").pop() ?? path;
  return { type: kind, path, label };
}
