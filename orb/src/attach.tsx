import { contextManifest } from "./projectContext";
import { listProjectFiles, type MissionAttachment } from "./api";

export type AttachKind = "file" | "folder" | "controller" | "context";

export interface AttachChip {
  id: string;
  kind: AttachKind;
  path?: string;
  label: string;
  /** Project owning this path; never inferred from its basename. */
  project?: string;
}

export interface AttachItem {
  id: string;
  kind: AttachKind;
  section: "Files" | "Folders" | "Controller" | "Context";
  path?: string;
  label: string;
  /** Project owning this path; never inferred from its basename. */
  project?: string;
}

/** `@` plus a query at the start of the current token. */
export function atQuery(text: string, caret: number): { open: boolean; query: string; start: number } {
  const before = text.slice(0, caret);
  const m = /(^|[\s])@([^\s]*)$/.exec(before);
  if (!m) return { open: false, query: "", start: -1 };
  const start = before.length - m[2].length - 1;
  return { open: true, query: m[2].toLowerCase(), start };
}

export function filterAttach(items: AttachItem[], query: string): AttachItem[] {
  items = items.filter(item => item.kind !== "controller");
  if (!query) return browseAttachItems(items, "");
  const q = query.replace(/^@/, "");
  const prefix = folderPrefixFromQuery(items, q);
  if (prefix !== null) return browseAttachItems(items, prefix);
  return items.filter((it) => it.label.toLowerCase().includes(q) || (it.path ?? "").toLowerCase().includes(q)).slice(0,100);
}

/** When a query is an exact folder prefix (e.g. `context/`), drill into that folder. */
export function folderPrefixFromQuery(items: AttachItem[], query: string): string | null {
  const raw = query.replace(/^@/, "").trim();
  if (!raw.endsWith("/")) return null;
  const folder = raw.replace(/\/+$/, "").toLowerCase();
  if (!folder) return "";
  const exists = items.some((it) => {
    const p = (it.path ?? "").replace(/\/$/, "").toLowerCase();
    return (it.section === "Folders" && p === folder) || p.startsWith(`${folder}/`);
  });
  return exists ? folder : null;
}

/**
 * Group attachment items by direct children of `folder` ("" for root) so deep
 * trees (like `attachments/<uuid>/<file>`) show only top-level parent folders
 * until a folder is opened.
 */
export function browseAttachItems(items: AttachItem[], folder: string): AttachItem[] {
  const clean = folder.replace(/\/+$/, "");
  const prefix = clean ? `${clean}/` : "";
  const prefixLower = prefix.toLowerCase();
  const contextRows = clean ? [] : items.filter((it) => it.section === "Context");
  const folders = new Map<string, AttachItem>();
  const files: AttachItem[] = [];
  for (const item of items) {
    if (item.kind === "controller" || item.section === "Context") continue;
    const rawPath = (item.path ?? item.label).replace(/\/$/, "");
    if (!rawPath) continue;
    if (prefix && !rawPath.toLowerCase().startsWith(prefixLower)) continue;
    const rest = prefix ? rawPath.slice(prefix.length) : rawPath;
    if (!rest) continue;
    const slash = rest.indexOf("/");
    if (slash >= 0) {
      const childName = rest.slice(0, slash);
      const childPath = `${prefix}${childName}`;
      const key = childPath.toLowerCase();
      if (!folders.has(key)) {
        const exact = items.find((it) => it.section === "Folders" && (it.path ?? "").replace(/\/$/, "").toLowerCase() === key);
        folders.set(
          key,
          exact ?? {
            id: `${item.kind === "context" ? `context:${item.project ?? ""}:` : "folder:"}${childPath}`,
            kind: item.kind === "context" ? "context" : "folder",
            section: "Folders",
            path: childPath,
            label: `${childPath}/`,
            ...(item.project ? { project: item.project } : {}),
          },
        );
      }
    } else if (item.section === "Folders" || item.kind === "folder") {
      const key = rawPath.toLowerCase();
      if (!folders.has(key)) {
        folders.set(key, { ...item, section: "Folders", path: rawPath, label: `${rawPath}/` });
      }
    } else {
      files.push(item);
    }
  }
  const sortedFolders = [...folders.values()].sort((a, b) => (a.path ?? a.label).localeCompare(b.path ?? b.label));
  const sortedFiles = [...files].sort((a, b) => (a.path ?? a.label).localeCompare(b.path ?? b.label));
  return [...contextRows, ...sortedFolders, ...sortedFiles].slice(0, 100);
}


export function chipToAttachment(chip: AttachChip): MissionAttachment {
  return chip.kind === "controller" ? { kind: "controller" } : { kind: chip.kind === "context" ? "path" : chip.kind, path: chip.path };
}

export function consumeAtToken(text: string, caret: number): string {
  const q = atQuery(text, caret);
  if (!q.open || q.start < 0) return text;
  return `${text.slice(0, q.start)}${text.slice(caret)}`;
}

/** The literal the controller is written as; it has no path to name. */
export const CONTROLLER_MENTION = "controller";

/**
 * The text a mention is written as, at the point the user typed `@`.
 *
 * Mentions live in the draft as plain text rather than as widgets over the
 * textarea. That keeps every editing gesture native — arrow keys, shift-select,
 * backspace, undo, dictation, select-all — and means what the user sees is
 * exactly what the agent receives. A quoted form covers paths containing
 * spaces; full paths (never basenames) keep two files of the same name in
 * different folders apart.
 */
export function mentionText(item: { kind: AttachKind; path?: string }): string {
  if (item.kind === "controller") return `@${CONTROLLER_MENTION}`;
  const path = item.path ?? "";
  // A folder keeps its trailing slash so it reads as a folder in the sentence.
  const written = item.kind === "folder" && !path.endsWith("/") ? `${path}/` : path;
  return /[\s"]/.test(written) ? `@"${written.replace(/"/g, '\\"')}"` : `@${written}`;
}

/** Every mention written in a draft, in the order they appear. */
export function scanMentions(text: string): Array<{ raw: string; value: string; index: number }> {
  const out: Array<{ raw: string; value: string; index: number }> = [];
  // `@"..."` (spaces allowed, `\"` escapes a quote) or a bare run up to
  // whitespace. Must start the token, so an email address never matches.
  const re = /(^|[\s(\[{])@(?:"((?:[^"\\]|\\.)*)"|([^\s)\]},;]+))/g;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const quoted = m[2] !== undefined;
    const value = quoted ? m[2].replace(/\\(.)/g, "$1") : m[3];
    const at = m.index + m[1].length;
    out.push({ raw: text.slice(at, m.index + m[0].length), value, index: at });
  }
  return out;
}

/** Trailing punctuation a bare mention should not swallow: "see @a/b.md." */
function trimBare(value: string): string {
  return value.replace(/[.,;:!?]+$/, "");
}

/**
 * The attachments a draft actually refers to, resolved against what the project
 * offers. Derived from the text on every send rather than tracked beside it, so
 * deleting a mention detaches it — nothing can ride along invisibly — and
 * re-typing one attaches it again.
 *
 * Order follows the sentence, and a file mentioned twice is sent once.
 */
export function mentionedChips(text: string, items: AttachItem[]): AttachChip[] {
  const chips: AttachChip[] = [];
  const seen = new Set<string>();
  for (const mention of scanMentions(text)) {
    const bare = (mention.raw.startsWith('@"') ? mention.value : trimBare(mention.value)).replace(/\/$/, "");
    const matches = items.filter(item => item.kind !== "controller" && item.path?.replace(/\/$/, "") === bare);
    // Ambiguous roots must never silently resolve to the last item in a map.
    const roots = new Set(matches.map(item => item.project ?? ""));
    const item = roots.size === 1 ? matches[0] : undefined;
    // An unknown `@word` is ordinary prose, not a silent attachment.
    if (!item || seen.has(item.id)) continue;
    seen.add(item.id);
    chips.push({ id: item.id, kind: item.kind, path: item.path, label: item.label, ...(item.project ? {project:item.project} : {}) });
  }
  return chips;
}

/**
 * Replace the `@query` being typed with the chosen mention and return the new
 * draft plus where the caret belongs. A trailing space lets the sentence carry
 * on without the next word joining the path.
 */
export function insertMention(
  text: string,
  caret: number,
  item: { kind: AttachKind; path?: string },
): { text: string; caret: number } {
  const q = atQuery(text, caret);
  const start = q.open && q.start >= 0 ? q.start : caret;
  const token = `${mentionText(item)} `;
  return {
    text: `${text.slice(0, start)}${token}${text.slice(caret)}`,
    caret: start + token.length,
  };
}

export async function loadAttachItems(slug: string): Promise<AttachItem[]> {
  try {
    const manifest = await contextManifest(slug);
    return Object.entries(manifest.entries).map(([path, entry]) => ({
      id: `context:${slug}:${path}`, kind: "context", project: slug, path,
      label: `${path}${entry.directory ? "/" : ""}`,
      section: entry.directory ? "Folders" : "Files",
    }));
  } catch {
    // Older servers only expose the project file listing.
    const items: AttachItem[] = [];
    await walkFiles(slug, "", items, 0);
    return items.map(item => ({...item, project: slug}));
  }
}

async function walkFiles(slug: string, path: string, items: AttachItem[], depth: number) {
  if (depth > 3 || items.length >= 200) return;
  let entries: Awaited<ReturnType<typeof listProjectFiles>> = [];
  try {
    entries = await listProjectFiles(slug, path);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (items.length >= 200) break;
    const rel = path ? `${path}/${entry.name}` : entry.name;
    if (entry.kind === "dir") {
      items.push({ id: `folder:${rel}`, kind: "folder", section: "Folders", path: rel, label: `${rel}/` });
      await walkFiles(slug, rel, items, depth + 1);
    } else {
      items.push({ id: `file:${rel}`, kind: "file", section: "Files", path: rel, label: rel });
    }
  }
}
