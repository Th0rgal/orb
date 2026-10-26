import { For, Show, createMemo, createResource, createSignal } from "solid-js";
import { Dialog, DialogButton } from "./Dialog";
import { SidebarTree, TreeConnectors } from "./Tree";
import type { TreeNode } from "./treeModel";
import * as Ic from "./icons";
import { MdSource, MdView } from "./Markdown";
import type { LibrarySkill } from "./api";
import type { SkillSourceRef } from "./localAgents";
import { getSkillAt, getSkillHistory, UnsupportedEndpoint } from "./skillsApi";
import { SKILL_BADGE_LABEL, skillBadge } from "./skillRows";
import { orbRelativeTimeString } from "./orbKernel";
import {
  compactDiff,
  effectiveAudience,
  lineDiff,
  lintSkill,
  parseSkillMeta,
  setSandboxedMeta,
} from "./skillModel";
import { deleteSkillFile, putSkillFile, readSkillFile, referencePaths } from "./skillsApi";
import type { SkillRow } from "./skillRows";

type Tab = "skill" | "files" | "versions" | "history";

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

export function DiffView(p: { before: string; after: string; beforeLabel: string; afterLabel: string }) {
  const lines = createMemo(() => compactDiff(lineDiff(p.before, p.after)));
  const stats = createMemo(() => {
    let add = 0, del = 0;
    for (const l of lines()) { if (l.op === "+") add++; else if (l.op === "-") del++; }
    return { add, del };
  });
  return (
    <div class="skills-diff" role="region" aria-label={`Diff ${p.beforeLabel} → ${p.afterLabel}`}>
      <div class="skills-diff-head">
        <span>{p.beforeLabel} → {p.afterLabel}</span>
        <span class="skills-diff-stat"><span class="add">+{stats().add}</span> <span class="del">−{stats().del}</span></span>
      </div>
      <Show when={stats().add + stats().del > 0} fallback={<p class="skills-preview-empty">Identical.</p>}>
        <pre class="skills-diff-body"><For each={lines()}>{(l) => <div class={`skills-diff-line op-${l.op === "…" ? "gap" : l.op === "+" ? "add" : l.op === "-" ? "del" : "ctx"}`}><span class="skills-diff-op">{l.op === "…" ? "" : l.op}</span>{l.text || " "}</div>}</For></pre>
      </Show>
    </div>
  );
}

export interface SkillDetailProps {
  row: SkillRow;
  library?: LibrarySkill;
  connected: boolean;
  harnessTotal: number;
  /** Open on History instead of the editor. */
  initialView?: "edit" | "history";
  onClose: () => void;
  /** Persist SKILL.md in the Library, commit and push it, then sync local harnesses. */
  onSave: (name: string, content: string, message?: string) => Promise<void>;
  /** Import an old copy (SKILL.md + its allowlisted reference files) into the Library. */
  onImport: (name: string, source: SkillSourceRef, rels: string[]) => Promise<void>;
  /** Remove the skill; the caller hides the row at once and restores it on failure. */
  onDelete: (name: string) => Promise<void>;
  /** Reference file changed in the Library; refresh and sync. */
  onFilesChanged: (name: string) => Promise<void>;
  onOpenProjectFile?: (slug: string, path: string) => void;
  /** Projects that can receive Library skills, and those that currently list this one. */
  projects?: { slug: string; title?: string }[];
  projectMembership?: string[];
  /** Persist this skill's project memberships (only called when they changed). */
  onSaveProjects?: (name: string, projects: string[]) => Promise<void>;
}

/** "…/skills/agent-browser/references/a.md" keeps both ends; the tooltip has the rest. */
export function middleTruncate(text: string, max = 48): string {
  if (text.length <= max) return text;
  const keep = max - 1, head = Math.ceil(keep / 2);
  return `${text.slice(0, head)}…${text.slice(text.length - (keep - head))}`;
}

const SKILL_MD = "SKILL.md";
type FileNode = { name: string; path: string; dir: boolean };

/** SKILL.md first, then folders (references/, scripts/, …) like Files & Folders. */
function fileTree(paths: string[]): TreeNode<FileNode>[] {
  const dirs = new Map<string, TreeNode<FileNode>>();
  const top: TreeNode<FileNode>[] = [{ id: SKILL_MD, data: { name: SKILL_MD, path: SKILL_MD, dir: false } }];
  for (const rel of [...paths].sort()) {
    const parts = rel.split("/");
    if (parts.length === 1) { top.push({ id: rel, data: { name: rel, path: rel, dir: false } }); continue; }
    const dir = parts[0];
    let node = dirs.get(dir);
    if (!node) { node = { id: `${dir}/`, data: { name: dir, path: `${dir}/`, dir: true }, expanded: true, children: [] }; dirs.set(dir, node); top.push(node); }
    node.children!.push({ id: rel, data: { name: parts.slice(1).join("/"), path: rel, dir: false } });
  }
  return top;
}

/** One panel per skill, like opening a folder: its files on the left, the open file on the right. */
export function SkillDetail(p: SkillDetailProps) {
  const original = () => p.library?.content ?? p.row.content ?? "";
  const editable = () => p.connected && !!p.library;
  const [draft, setDraft] = createSignal(original());
  // Opens on the rendered skill; Edit switches to the source.
  const [preview, setPreview] = createSignal(true);
  const [view, setView] = createSignal<"edit" | "history">(p.initialView ?? "edit");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [confirmDelete, setConfirmDelete] = createSignal(false);
  const [deleteError, setDeleteError] = createSignal<string | null>(null);
  const dirty = () => editable() && (draft() !== original() || projectsDirty());
  const meta = createMemo(() => parseSkillMeta(draft()));
  const audience = createMemo(() => effectiveAudience(meta()));
  const lint = createMemo(() => lintSkill(p.row.name, draft()));
  const [projectDraft, setProjectDraft] = createSignal<string[]>([...(p.projectMembership ?? [])].sort());
  const projectsDirty = () => projectDraft().join(",") !== [...(p.projectMembership ?? [])].sort().join(",");
  // Two plain controls write the same frontmatter the agents read.
  const toggleAudience = (who: string, on: boolean) => {
    const next = on ? [...new Set([...audience(), who])] : audience().filter((a) => a !== who);
    setDraft(setSandboxedMeta(draft(), next, meta().scope ?? null, p.row.name));
  };
  const setLoad = (always: boolean) => setDraft(setSandboxedMeta(draft(), audience(), always ? "global" : null, p.row.name));
  const toggleProject = (slug: string, on: boolean) => setProjectDraft((list) => (on ? [...new Set([...list, slug])] : list.filter((x) => x !== slug)).sort());
  const [saved, setSaved] = createSignal(false);

  const run = async (fn: () => Promise<void>) => {
    if (busy()) return;
    setBusy(true);
    setError(null);
    try { await fn(); } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  };
  const save = () => void run(async () => {
    setSaved(false);
    if (draft() !== original()) await p.onSave(p.row.name, draft());
    if (projectsDirty()) await p.onSaveProjects?.(p.row.name, projectDraft());
    setSaved(true);
  });
  // A failed delete stays in the confirm with Retry; success closes the panel.
  const remove = async () => {
    if (busy()) return;
    setBusy(true);
    setDeleteError(null);
    try { await p.onDelete(p.row.name); p.onClose(); }
    catch (e) { setDeleteError(errorText(e)); }
    finally { setBusy(false); }
  };

  // ── Files: SKILL.md and its reference files ──
  const [files, setFiles] = createSignal<string[]>(p.library ? referencePaths(p.library) : []);
  const [openFile, setOpenFile] = createSignal(SKILL_MD);
  const [fileText, setFileText] = createSignal("");
  const [fileOriginal, setFileOriginal] = createSignal("");
  const [newFile, setNewFile] = createSignal<string | null>(null);
  const [confirmFileDelete, setConfirmFileDelete] = createSignal<string | null>(null);
  const tree = createMemo(() => fileTree(files()));
  const openPath = (rel: string) => {
    if (rel === SKILL_MD) { setOpenFile(SKILL_MD); setView("edit"); return; }
    void run(async () => {
      const inline = p.library?.files?.find((f) => (f.path || f.name) === rel);
      const text = inline ? inline.content : await readSkillFile(p.row.name, rel);
      setOpenFile(rel); setFileText(text); setFileOriginal(text); setView("edit");
    });
  };
  const saveFile = () => void run(async () => {
    const rel = openFile();
    await putSkillFile(p.row.name, rel, fileText());
    setFileOriginal(fileText());
    await p.onFilesChanged(p.row.name);
  });
  const createFile = () => void run(async () => {
    const rel = (newFile() ?? "").trim().replace(/^\/+/, "");
    if (!rel || rel === SKILL_MD || rel.split("/").some((seg) => !seg || seg === ".." || seg === ".")) throw new Error("Enter a relative path such as references/notes.md.");
    await putSkillFile(p.row.name, rel, "");
    setFiles((list) => [...new Set([...list, rel])].sort());
    setNewFile(null);
    setOpenFile(rel); setFileText(""); setFileOriginal("");
    await p.onFilesChanged(p.row.name);
  });
  const removeFile = (rel: string) => void run(async () => {
    await deleteSkillFile(p.row.name, rel);
    setFiles((list) => list.filter((f) => f !== rel));
    if (openFile() === rel) setOpenFile(SKILL_MD);
    setConfirmFileDelete(null);
    await p.onFilesChanged(p.row.name);
  });

  // An old copy outside the Library gets one quiet line, not a panel of its own.
  const oldCopy = () => p.row.sources.find((src) => src.id !== "library" && src.legacy && src.content);
  const isSkill = () => openFile() === SKILL_MD;

  return (
    <Dialog size="wide" class="skills-detail" title={p.row.name} description={p.row.description} busy={busy()} dirty={dirty()} onClose={p.onClose}
      footer={(close) => <Show when={confirmDelete()} fallback={<>
        <Show when={editable()}>
          <DialogButton variant="destructive" class="skills-detail-delete" disabled={busy()} onClick={() => { setDeleteError(null); setConfirmDelete(true); }}>Delete…</DialogButton>
        </Show>
        <Show when={saved() && !dirty()}><span class="skills-saved" role="status">Saved to repo</span></Show>
        <DialogButton disabled={busy()} onClick={close}>{dirty() ? "Cancel" : "Close"}</DialogButton>
        <Show when={editable()}>
          <DialogButton variant="primary" disabled={busy() || !dirty()} onClick={save}>{busy() ? "Saving…" : "Save"}</DialogButton>
        </Show>
      </>}>
        {/* Delete confirms inside the panel: no dialog on top of a dialog. */}
        <div class="skills-confirm" role="alertdialog" aria-label={`Delete ${p.row.name}?`}>
          <span><strong>Delete {p.row.name}?</strong> It leaves the Library and every agent on this Mac.</span>
          <Show when={deleteError()}>{(e) => <span class="inline-error" role="alert">{e()}</span>}</Show>
          <DialogButton disabled={busy()} onClick={() => setConfirmDelete(false)}>Cancel</DialogButton>
          <DialogButton variant="destructive" disabled={busy()} onClick={() => void remove()}>{busy() ? "Deleting…" : deleteError() ? "Retry" : "Delete"}</DialogButton>
        </div>
      </Show>}>
      <Show when={skillBadge(p.row)}>{(b) => <div class="skills-detail-badges"><span class={`skills-badge ${b()}`}>{SKILL_BADGE_LABEL[b()]}</span></div>}</Show>
      <Show when={error()}>{(e) => <p class="inline-error" role="alert">{e()} <Show when={dirty()}><button type="button" class="s-btn sm" onClick={save}>Retry</button></Show></p>}</Show>
      <Show when={oldCopy()}>{(src) =>
        <p class="skills-oldcopy" title={src().path ?? undefined}>
          Old copy in {src().label}<Show when={src().path}> · <code>{middleTruncate(src().path!, 40)}</code></Show>
          <Show when={p.connected}> · <button type="button" class="link-btn" disabled={busy()} onClick={() => void run(async () => { await p.onImport(p.row.name, src(), src().files?.map((f) => f.rel) ?? []); p.onClose(); })}>Import</button></Show>
        </p>
      }</Show>
      <Show when={!p.library && p.row.projectFile}>{(pf) =>
        <p class="skills-oldcopy">Project context skill · {pf().slug} · <button type="button" class="link-btn" onClick={() => p.onOpenProjectFile?.(pf().slug, pf().path)}>Open in project files</button></p>
      }</Show>

      <div class="skills-panel">
        <nav class="skills-files-tree" aria-label="Skill files">
          <SidebarTree nodes={tree()} label={`${p.row.name} files`} selected={view() === "history" ? null : openFile()} render={(row) => {
            const d = row.data;
            return <>
              <TreeConnectors row={row} />
              <button type="button" class={`row ${!d.dir && openFile() === d.path && view() === "edit" ? "active" : ""}`} disabled={d.dir || busy()} title={d.path} onClick={() => openPath(d.path)}>
                <span class="row-ico"><Show when={d.dir} fallback={<Ic.FileIcon />}><Ic.FolderIcon /></Show></span>
                <span class="row-label">{d.name}</span>
              </button>
              <Show when={!d.dir && d.path !== SKILL_MD && editable()}>
                <Show when={confirmFileDelete() === d.path} fallback={<button type="button" class="icon-btn skills-file-del" aria-label={`Delete ${d.path}`} disabled={busy()} onClick={() => setConfirmFileDelete(d.path)}><Ic.TrashIcon size={12} /></button>}>
                  <button type="button" class="s-btn sm danger" disabled={busy()} onClick={() => removeFile(d.path)}>Delete</button>
                  <button type="button" class="s-btn sm quiet" onClick={() => setConfirmFileDelete(null)}>Keep</button>
                </Show>
              </Show>
            </>;
          }} />
          <Show when={editable()}>
            <Show when={newFile() !== null} fallback={<button type="button" class="s-btn sm quiet skills-file-add" disabled={busy()} onClick={() => setNewFile("references/")}><Ic.PlusIcon size={12} /> New file</button>}>
              <form class="skills-file-new" onSubmit={(e) => { e.preventDefault(); createFile(); }}>
                <input class="s-input" aria-label="New file path" value={newFile() ?? ""} autofocus onInput={(e) => setNewFile(e.currentTarget.value)} onBlur={(e) => { if (!e.currentTarget.value.trim() || e.currentTarget.value === "references/") setNewFile(null); }} />
              </form>
            </Show>
          </Show>
          <Show when={p.library}>
            <button type="button" class={`row skills-history-row ${view() === "history" ? "active" : ""}`} onClick={() => setView(view() === "history" ? "edit" : "history")}>
              <span class="row-ico"><Ic.ReopenIcon /></span><span class="row-label">History</span>
            </button>
          </Show>
        </nav>

        <section class="skills-panel-main">
          <Show when={view() === "edit"} fallback={
            <SkillHistory name={p.row.name} current={original()} busy={busy()} onRestore={(rev, content) => void run(async () => { await p.onSave(p.row.name, content, `skill: restore ${p.row.name} to ${rev.slice(0, 7)}`); setDraft(content); setSaved(true); setView("edit"); })} />
          }>
            <div class="pf-bar skills-file-bar">
              <span class="pf-path" title={`skill/${p.row.name}/${openFile()}`}>{middleTruncate(`${p.row.name}/${openFile()}`)}</span>
              <Show when={editable() && isSkill()}>
                <button type="button" class="s-btn sm quiet" aria-pressed={!preview()} onClick={() => setPreview(!preview())}>{preview() ? "Edit" : "Done"}</button>
              </Show>
              <Show when={editable() && !isSkill()}>
                <button type="button" class="s-btn sm" disabled={busy() || fileText() === fileOriginal()} onClick={saveFile}>Save file</button>
              </Show>
            </div>
            <Show when={isSkill()} fallback={<div class="skills-editor"><MdSource text={fileText()} onInput={setFileText} readOnly={busy() || !editable()} /></div>}>
              <Show when={editable()}>
                <div class="skills-meta-controls">
                  <div class="skills-meta-row" role="group" aria-label="Who uses it">
                    <span class="skills-meta-label">Who uses it</span>
                    <For each={[["mission", "Missions"], ["coordinator", "Assistant"], ["local", "This Mac"]] as const}>{([id, label]) =>
                      <label class="skills-check"><input type="checkbox" checked={audience().includes(id)} disabled={busy()} onChange={(e) => toggleAudience(id, e.currentTarget.checked)} />{label}</label>
                    }</For>
                  </div>
                  <div class="skills-meta-row" role="radiogroup" aria-label="Load">
                    <span class="skills-meta-label">Load</span>
                    <div class="skills-seg">
                      <button type="button" role="radio" aria-checked={meta().scope !== "global"} class={meta().scope !== "global" ? "on" : ""} disabled={busy()} onClick={() => setLoad(false)}>On demand</button>
                      <button type="button" role="radio" aria-checked={meta().scope === "global"} class={meta().scope === "global" ? "on" : ""} disabled={busy()} onClick={() => setLoad(true)}>Always</button>
                    </div>
                  </div>
                  <Show when={(p.projects ?? []).length && meta().scope !== "global"}>
                    <div class="skills-meta-row" role="group" aria-label="Projects">
                      <span class="skills-meta-label">Projects</span>
                      <For each={p.projects ?? []}>{(proj) =>
                        <label class="skills-check"><input type="checkbox" checked={projectDraft().includes(proj.slug)} disabled={busy()} onChange={(e) => toggleProject(proj.slug, e.currentTarget.checked)} />{proj.title || proj.slug}</label>
                      }</For>
                    </div>
                  </Show>
                </div>
              </Show>
              <Show when={lint().length}>
                <ul class="skills-lint" aria-label="Lint warnings"><For each={lint()}>{(l) => <li data-lint={l.id}>{l.message}</li>}</For></ul>
              </Show>
              <div class="skills-editor">
                <Show when={!preview() && editable()} fallback={<div class="skills-md-view"><MdView text={draft().replace(/^---\n[\s\S]*?\n---\n?/, "").trim() || "_No SKILL.md content available._"} /></div>}>
                  <MdSource text={draft()} onInput={setDraft} readOnly={busy()} />
                </Show>
              </div>
              <Show when={dirty()}>
                <details class="skills-pending-diff"><summary>Review changes</summary><DiffView before={original()} after={draft()} beforeLabel="Library" afterLabel="Draft" /></details>
              </Show>
            </Show>
          </Show>
        </section>
      </div>
    </Dialog>
  );
}

/** Git versions of SKILL.md from the Library repo; Restore saves an old one as a new commit. */
function SkillHistory(p: { name: string; current: string; busy: boolean; onRestore: (rev: string, content: string) => void }) {
  const [versions] = createResource(() => p.name, (name) => getSkillHistory(name).catch((e) => (e instanceof UnsupportedEndpoint ? null : Promise.reject(e))));
  const [open, setOpen] = createSignal<{ rev: string; content: string } | null>(null);
  const view = async (rev: string) => setOpen(open()?.rev === rev ? null : { rev, content: await getSkillAt(p.name, rev) });
  return (
    <div class="skills-versions" aria-label="History">
      <Show when={!versions.loading} fallback={<For each={[0, 1, 2]}>{() => <div class="skills-version skeleton"><span class="spend-skel skills-skel-desc" /></div>}</For>}>
        <Show when={!versions.error} fallback={<p class="inline-error">Couldn’t load the history: {String(versions.error?.message ?? versions.error)}</p>}>
          <Show when={versions()} fallback={<p class="skills-sub-note">This Core is too old to show skill history.</p>}>{(list) =>
            <For each={list()} fallback={<p class="skills-sub-note">No saved versions yet.</p>}>{(v, i) =>
              <div class="skills-version">
                <div class="skills-version-head">
                  <div class="skills-version-title">
                    <strong>{v.subject}</strong>
                    <span class="skills-sub-note">{v.author} · {(() => { const t = orbRelativeTimeString(Date.now() / 1000 - v.timestamp); return t === "now" ? "just now" : `${t} ago`; })()} · {v.rev.slice(0, 7)}</span>
                  </div>
                  <div class="skills-version-actions">
                    <button type="button" class="s-btn sm" onClick={() => void view(v.rev)}>{open()?.rev === v.rev ? "Hide" : "Compare"}</button>
                    <Show when={i() > 0}>
                      <button type="button" class="s-btn sm" disabled={p.busy} onClick={() => void getSkillAt(p.name, v.rev).then((content) => p.onRestore(v.rev, content))}>Restore</button>
                    </Show>
                  </div>
                </div>
                <Show when={open()?.rev === v.rev ? open() : null}>{(o) => <DiffView before={o().content} after={p.current} beforeLabel={o().rev.slice(0, 7)} afterLabel="Current" />}</Show>
              </div>
            }</For>
          }</Show>
        </Show>
      </Show>
    </div>
  );
}

/** True when the Library frontmatter declares sandboxed delivery metadata that the candidate lacks. */
export function dropsSandboxedMetadata(library: string | null | undefined, candidate: string | null | undefined): boolean {
  const front = (text?: string | null) => /^---\n([\s\S]*?)\n---/.exec(text ?? "")?.[1] ?? "";
  return /^\s+sandboxed:/m.test(front(library)) && !/^\s+sandboxed:/m.test(front(candidate));
}
