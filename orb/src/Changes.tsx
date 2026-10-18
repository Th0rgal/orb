import { createMemo, createSignal, For, onCleanup, Show } from "solid-js";
import type { StreamItem } from "./transcriptModel";
import { computeDiffStats } from "./workModel";
import { openExternalUrl } from "./api";

export type FileChange = { file: string; additions: number; deletions: number; edits: number };
/** Files the agent edited in this conversation, from its edit tool calls. */
export function changedFiles(items: StreamItem[]): FileChange[] {
  const files = new Map<string, FileChange>();
  for (const item of items) {
    if (item.kind !== "tool" || !item.done) continue;
    const d = computeDiffStats(item);
    if (!d?.file) continue;
    const row = files.get(d.file) ?? { file: d.file, additions: 0, deletions: 0, edits: 0 };
    row.additions += d.additions; row.deletions += d.deletions; row.edits++;
    files.set(d.file, row);
  }
  return [...files.values()].sort((a, b) => b.additions + b.deletions - (a.additions + a.deletions));
}
/** github_pr is free-form: a URL, owner/repo#123, or a bare number. */
export function prLink(raw?: string | null): { label: string; url?: string } | null {
  const v = raw?.trim();
  if (!v) return null;
  const url = v.match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)/);
  if (url) return { label: `${url[1]}#${url[2]}`, url: v };
  const short = v.match(/^([\w.-]+\/[\w.-]+)#(\d+)$/);
  if (short) return { label: v, url: `https://github.com/${short[1]}/pull/${short[2]}` };
  return { label: /^\d+$/.test(v) ? `PR ${v}` : v };
}
const short = (path: string) => path.split("/").slice(-3).join("/");

/** Codex-style review entry point: what changed and where it ships, without reading the thread. */
export function Changes(p: { items: StreamItem[]; githubPr?: string | null }) {
  const files = createMemo(() => changedFiles(p.items));
  const pr = createMemo(() => prLink(p.githubPr));
  const totals = createMemo(() => files().reduce((t, f) => ({ a: t.a + f.additions, d: t.d + f.deletions }), { a: 0, d: 0 }));
  const [open, setOpen] = createSignal(false);
  let root!: HTMLDivElement;
  const close = (e: PointerEvent) => { if (open() && !root.contains(e.target as Node)) setOpen(false); };
  document.addEventListener("pointerdown", close);
  onCleanup(() => document.removeEventListener("pointerdown", close));
  return (
    <Show when={files().length || pr()}>
      <div class="changes" ref={root}>
        <button type="button" class={`chapters-btn ${open() ? "on" : ""}`} aria-expanded={open()} title="Changes in this conversation" onClick={() => setOpen(!open())}>
          <Show when={files().length} fallback={<span>{pr()!.label}</span>}>
            <span>{files().length} file{files().length === 1 ? "" : "s"}</span>
            <span class="diff-add">+{totals().a}</span><span class="diff-del">−{totals().d}</span>
          </Show>
        </button>
        <Show when={open()}>
          <div class="chapters-list changes-list" role="dialog" aria-label="Changes">
            <Show when={pr()}>{link => (
              <div class="changes-pr">
                <span>Pull request</span>
                <Show when={link().url} fallback={<code>{link().label}</code>}>
                  <button type="button" class="s-btn sm" onClick={() => void openExternalUrl(link().url!)}>{link().label} ↗</button>
                </Show>
              </div>
            )}</Show>
            <For each={files()}>{f => (
              <div class="changes-row" title={f.file}>
                <span class="chapters-t">{short(f.file)}</span>
                <span class="diff-add">+{f.additions}</span><span class="diff-del">−{f.deletions}</span>
              </div>
            )}</For>
            <Show when={files().length}><p class="dim changes-note">From the agent's edit tools; shell edits are not counted.</p></Show>
          </div>
        </Show>
      </div>
    </Show>
  );
}
