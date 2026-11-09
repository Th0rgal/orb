import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { ConfirmDialog } from "./Dialog";
import {
  diffMissionCheckpoints,
  listMissionCheckpoints,
  restoreMissionCheckpoint,
  type CheckpointDiffReport,
  type CheckpointMeta,
} from "./localAgents";
import { ErrorToast } from "./toast";
import "./DiffViewer.css";

export interface ParsedDiffLine {
  kind: "add" | "del" | "ctx";
  oldLine?: number;
  newLine?: number;
  text: string;
}

export interface ParsedDiffHunk {
  header: string;
  lines: ParsedDiffLine[];
}

export interface ParsedDiffFile {
  path: string;
  oldPath?: string;
  hunks: ParsedDiffHunk[];
}

export interface SplitDiffRow {
  left?: ParsedDiffLine;
  right?: ParsedDiffLine;
}

/** Pure unified-diff parser (`git diff` output). Memoized by callers on raw diff text. */
export function parseUnifiedDiff(raw: string): ParsedDiffFile[] {
  if (!raw.trim()) return [];
  const files: ParsedDiffFile[] = [];
  let currentFile: ParsedDiffFile | null = null;
  let currentHunk: ParsedDiffHunk | null = null;
  let oldLine = 0;
  let newLine = 0;

  for (const line of raw.split("\n")) {
    if (line.startsWith("diff --git ")) {
      const m = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
      currentFile = {
        path: m ? m[2] : line.slice("diff --git ".length).trim(),
        oldPath: m && m[1] !== m[2] ? m[1] : undefined,
        hunks: [],
      };
      files.push(currentFile);
      currentHunk = null;
      continue;
    }
    if (!currentFile) continue;
    if (line.startsWith("+++ b/")) {
      currentFile.path = line.slice("+++ b/".length);
      continue;
    }
    if (line.startsWith("--- a/")) {
      const prev = line.slice("--- a/".length);
      if (prev !== currentFile.path) currentFile.oldPath = prev;
      continue;
    }
    if (line.startsWith("@@ ")) {
      const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
      oldLine = m ? Number.parseInt(m[1], 10) : 1;
      newLine = m ? Number.parseInt(m[2], 10) : 1;
      currentHunk = { header: line, lines: [] };
      currentFile.hunks.push(currentHunk);
      continue;
    }
    if (!currentHunk) continue;
    if (line.startsWith("+")) {
      currentHunk.lines.push({ kind: "add", newLine: newLine++, text: line.slice(1) });
    } else if (line.startsWith("-")) {
      currentHunk.lines.push({ kind: "del", oldLine: oldLine++, text: line.slice(1) });
    } else if (line.startsWith(" ")) {
      currentHunk.lines.push({
        kind: "ctx",
        oldLine: oldLine++,
        newLine: newLine++,
        text: line.slice(1),
      });
    }
  }
  return files;
}

export function pairSplitRows(lines: ParsedDiffLine[]): SplitDiffRow[] {
  const rows: SplitDiffRow[] = [];
  let i = 0;
  while (i < lines.length) {
    const cur = lines[i];
    if (cur.kind === "ctx") {
      rows.push({ left: cur, right: cur });
      i++;
      continue;
    }
    const dels: ParsedDiffLine[] = [];
    const adds: ParsedDiffLine[] = [];
    while (i < lines.length && lines[i].kind === "del") dels.push(lines[i++]);
    while (i < lines.length && lines[i].kind === "add") adds.push(lines[i++]);
    const count = Math.max(dels.length, adds.length);
    for (let k = 0; k < count; k++) {
      rows.push({ left: dels[k], right: adds[k] });
    }
  }
  return rows;
}

export default function DiffViewer(p: { missionId: string; cwd?: string }) {
  const [checkpoints, setCheckpoints] = createSignal<CheckpointMeta[]>([]);
  const [selectedRef, setSelectedRef] = createSignal<string>("HEAD");
  const [viewMode, setViewMode] = createSignal<"unified" | "split">("unified");
  const [report, setReport] = createSignal<CheckpointDiffReport | null>(null);
  const [loading, setLoading] = createSignal(true);
  const [error, setError] = createSignal<string | null>(null);
  const [revertTarget, setRevertTarget] = createSignal<CheckpointMeta | null>(null);
  const [restoring, setRestoring] = createSignal(false);
  const [notice, setNotice] = createSignal<string | null>(null);
  const [reloadTick, setReloadTick] = createSignal(0);

  createEffect(() => {
    const missionId = p.missionId;
    const cwd = p.cwd;
    const fromRef = selectedRef();
    reloadTick();
    let active = true;
    onCleanup(() => {
      active = false;
    });
    setLoading(true);
    setError(null);
    void Promise.all([
      listMissionCheckpoints(missionId, cwd).catch(() => [] as CheckpointMeta[]),
      diffMissionCheckpoints(missionId, { cwd, fromRef, toRef: "" }),
    ])
      .then(([cps, diff]) => {
        if (!active) return;
        setCheckpoints([...cps].sort((a, b) => b.turn - a.turn));
        setReport(diff);
      })
      .catch((err) => {
        if (!active) return;
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (active) setLoading(false);
      });
  });

  createEffect(() => {
    const onRefresh = () => setReloadTick((n) => n + 1);
    window.addEventListener("orb:refresh", onRefresh);
    onCleanup(() => window.removeEventListener("orb:refresh", onRefresh));
  });

  const parsedFiles = createMemo(() => parseUnifiedDiff(report()?.raw_diff ?? ""));
  const activeCheckpoint = createMemo(
    () =>
      checkpoints().find((cp) => cp.ref === selectedRef()) ??
      (checkpoints().length > 0 ? checkpoints()[0] : null),
  );

  const confirmRestore = async () => {
    const target = revertTarget();
    if (!target || restoring()) return;
    setRestoring(true);
    setError(null);
    try {
      const res = await restoreMissionCheckpoint(p.missionId, target.ref, p.cwd);
      setRevertTarget(null);
      setNotice(
        `Restored workspace to Turn ${target.turn}${res.backup_ref ? ` (backup saved at ${res.backup_ref.split("/").pop()})` : ""}.`,
      );
      setReloadTick((n) => n + 1);
      window.dispatchEvent(new Event("orb:refresh"));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setRestoring(false);
    }
  };

  let containerRef: HTMLDivElement | undefined;
  const scrollToFile = (path: string) => {
    const target = containerRef?.querySelector<HTMLElement>(
      `[data-diff-file="${CSS.escape(path)}"]`,
    );
    target?.scrollIntoView({ block: "start" });
  };

  return (
    <div class="diff-viewer" aria-label="Workspace changes">
      <div class="diff-toolbar">
        <select
          class="diff-select"
          aria-label="Compare base checkpoint"
          value={selectedRef()}
          onChange={(e) => setSelectedRef(e.currentTarget.value)}
        >
          <option value="HEAD">Working tree vs HEAD</option>
          <For each={checkpoints()}>
            {(cp) => (
              <option value={cp.ref}>
                Since Turn {cp.turn} ({cp.commit.slice(0, 7)})
              </option>
            )}
          </For>
        </select>

        <div class="diff-view-toggle" role="group" aria-label="Diff layout">
          <button
            type="button"
            class={viewMode() === "unified" ? "active" : ""}
            aria-pressed={viewMode() === "unified"}
            onClick={() => setViewMode("unified")}
          >
            Unified
          </button>
          <button
            type="button"
            class={viewMode() === "split" ? "active" : ""}
            aria-pressed={viewMode() === "split"}
            onClick={() => setViewMode("split")}
          >
            Split
          </button>
        </div>

        <button
          type="button"
          class="s-btn"
          disabled={loading()}
          onClick={() => setReloadTick((n) => n + 1)}
        >
          Refresh
        </button>

        <Show when={activeCheckpoint()}>
          {(cp) => (
            <button
              type="button"
              class="s-btn"
              disabled={restoring()}
              onClick={() => setRevertTarget(cp())}
            >
              Revert to Turn {cp().turn}…
            </button>
          )}
        </Show>

        <Show when={report()}>
          {(rep) => (
            <span class="diff-summary">
              <span>
                {rep().files.length} {rep().files.length === 1 ? "file" : "files"}
              </span>
              <span class="diff-stat-add">+{rep().total_additions}</span>
              <span class="diff-stat-del">-{rep().total_deletions}</span>
            </span>
          )}
        </Show>
      </div>

      <ErrorToast
        error={error()}
        title="Couldn’t load workspace changes"
        onDismiss={() => setError(null)}
        action={{ label: "Retry", run: () => setReloadTick((n) => n + 1) }}
      />

      <Show when={notice()}>
        <div class="diff-budget-banner" role="status">
          {notice()}
        </div>
      </Show>

      <Show when={report()?.budget_exceeded}>
        <div class="diff-budget-banner" role="status">
          Large diff truncated by repository diff budget gate to keep the viewer responsive.
        </div>
      </Show>

      <Show when={(report()?.files.length ?? 0) > 0}>
        <div class="diff-files-bar" aria-label="Changed files">
          <For each={report()!.files}>
            {(f) => (
              <button
                type="button"
                class="diff-file-pill"
                onClick={() => scrollToFile(f.path)}
              >
                <span class="diff-status-badge">{f.status || "M"}</span>
                <span>{f.path}</span>
                <Show when={f.additions > 0}>
                  <span class="diff-stat-add">+{f.additions}</span>
                </Show>
                <Show when={f.deletions > 0}>
                  <span class="diff-stat-del">-{f.deletions}</span>
                </Show>
              </button>
            )}
          </For>
        </div>
      </Show>

      <div class="diff-scroll" ref={containerRef}>
        <Show
          when={!loading() || report()}
          fallback={
            <div class="diff-skeleton" aria-busy="true" aria-label="Loading diff">
              <div class="diff-skeleton-bar" style={{ width: "45%" }} />
              <div class="diff-skeleton-bar" style={{ width: "85%" }} />
              <div class="diff-skeleton-bar" style={{ width: "72%" }} />
              <div class="diff-skeleton-bar" style={{ width: "64%" }} />
            </div>
          }
        >
          <Show
            when={parsedFiles().length > 0}
            fallback={
              <div class="diff-empty">
                No uncommitted or checkpoint changes found for this selection.
              </div>
            }
          >
            <For each={parsedFiles()}>
              {(file) => (
                <section class="diff-card" data-diff-file={file.path}>
                  <header class="diff-card-head">
                    <span>
                      {file.oldPath ? `${file.oldPath} → ${file.path}` : file.path}
                    </span>
                  </header>
                  <For each={file.hunks}>
                    {(hunk) => (
                      <div>
                        <div class="diff-hunk-head">{hunk.header}</div>
                        <Show
                          when={viewMode() === "split"}
                          fallback={
                            <table class="diff-table">
                              <tbody>
                                <For each={hunk.lines}>
                                  {(line) => (
                                    <tr
                                      class={
                                        line.kind === "add"
                                          ? "diff-row-add"
                                          : line.kind === "del"
                                            ? "diff-row-del"
                                            : undefined
                                      }
                                    >
                                      <td class="diff-ln">{line.oldLine ?? ""}</td>
                                      <td class="diff-ln">{line.newLine ?? ""}</td>
                                      <td class="diff-code">
                                        {line.kind === "add"
                                          ? "+"
                                          : line.kind === "del"
                                            ? "-"
                                            : " "}
                                        {line.text}
                                      </td>
                                    </tr>
                                  )}
                                </For>
                              </tbody>
                            </table>
                          }
                        >
                          <table class="diff-table">
                            <tbody>
                              <For each={pairSplitRows(hunk.lines)}>
                                {(row) => (
                                  <tr>
                                    <td
                                      class={`diff-ln ${row.left?.kind === "del" ? "diff-row-del" : ""}`}
                                    >
                                      {row.left?.oldLine ?? ""}
                                    </td>
                                    <td
                                      class={`diff-code diff-split-half ${row.left?.kind === "del" ? "diff-row-del" : ""}`}
                                    >
                                      {row.left
                                        ? `${row.left.kind === "del" ? "-" : " "}${row.left.text}`
                                        : ""}
                                    </td>
                                    <td
                                      class={`diff-ln ${row.right?.kind === "add" ? "diff-row-add" : ""}`}
                                    >
                                      {row.right?.newLine ?? ""}
                                    </td>
                                    <td
                                      class={`diff-code diff-split-half ${row.right?.kind === "add" ? "diff-row-add" : ""}`}
                                    >
                                      {row.right
                                        ? `${row.right.kind === "add" ? "+" : " "}${row.right.text}`
                                        : ""}
                                    </td>
                                  </tr>
                                )}
                              </For>
                            </tbody>
                          </table>
                        </Show>
                      </div>
                    )}
                  </For>
                </section>
              )}
            </For>
          </Show>
        </Show>
      </div>

      <Show when={revertTarget()}>
        {(target) => (
          <ConfirmDialog
            title={`Revert workspace to Turn ${target().turn}?`}
            description={`Uncommitted changes since Turn ${target().turn} (${target().commit.slice(0, 7)}) will be replaced. Orb saves an automatic backup ref before restoring.`}
            action={restoring() ? "Reverting…" : "Revert workspace"}
            destructive
            onConfirm={() => void confirmRestore()}
            onClose={() => {
              if (!restoring()) setRevertTarget(null);
            }}
          />
        )}
      </Show>
    </div>
  );
}
