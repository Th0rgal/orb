import { For, Show, createMemo, createSignal } from "solid-js";
import { ConfirmDialog, Dialog, DialogButton, NameDialog } from "./Dialog";
import { MdSource, MdView } from "./Markdown";
import { Select } from "./Select";
import type { LibrarySkill } from "./api";
import type { SkillSourceRef } from "./localAgents";
import {
  AUDIENCES,
  compactDiff,
  effectiveAudience,
  lineDiff,
  lintSkill,
  parseSkillMeta,
  placesOf,
  placesToMeta,
  setSandboxedMeta,
  type SkillPlaces,
} from "./skillModel";
import { SkillPlacesPicker, type PlaceProject } from "./SkillPlaces";
import { deleteSkillFile, putSkillFile, readSkillFile, referencePaths } from "./skillsApi";
import type { SkillRow } from "./skillRows";

type Tab = "skill" | "files" | "versions";

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));
const formatSize = (n: number) => (n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`);

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
  onClose: () => void;
  /** Persist SKILL.md in the Library, then sync local harnesses. */
  onSave: (name: string, content: string) => Promise<void>;
  /** Import a legacy/divergent copy (SKILL.md + reference files) into the Library. */
  onImport: (name: string, source: SkillSourceRef, rels: string[]) => Promise<void>;
  onDelete: (name: string) => Promise<void>;
  /** Reference file changed in the Library; refresh and sync. */
  onFilesChanged: (name: string) => Promise<void>;
  onOpenProjectFile?: (slug: string, path: string) => void;
  /** Projects that can receive Library skills, and those that currently list this one. */
  projects?: PlaceProject[];
  projectMembership?: string[];
  /** Persist this skill's project memberships (only called when they changed). */
  onSaveProjects?: (name: string, projects: string[]) => Promise<void>;
}

export function SkillDetail(p: SkillDetailProps) {
  const original = () => p.library?.content ?? p.row.content ?? "";
  const editable = () => p.connected && !!p.library;
  const [draft, setDraft] = createSignal(original());
  const [tab, setTab] = createSignal<Tab>(p.row.divergent || p.row.legacyOnly ? "versions" : "skill");
  const [preview, setPreview] = createSignal(!editable());
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [confirmDelete, setConfirmDelete] = createSignal(false);
  const [confirmImport, setConfirmImportRaw] = createSignal<SkillSourceRef | null>(null);
  const [importRels, setImportRels] = createSignal<string[]>([]);
  // Allowed files start checked; the user can deselect any before the PUT.
  const setConfirmImport = (src: SkillSourceRef | null) => { setImportRels(src?.files?.map((f) => f.rel) ?? []); setConfirmImportRaw(src); };
  const dirty = () => editable() && (draft() !== original() || projectsDirty());
  const meta = createMemo(() => parseSkillMeta(draft()));
  const audience = createMemo(() => effectiveAudience(meta()));
  const lint = createMemo(() => lintSkill(p.row.name, draft()));
  const [projectDraft, setProjectDraft] = createSignal<string[]>([...(p.projectMembership ?? [])].sort());
  const projectsDirty = () => projectDraft().join(",") !== [...(p.projectMembership ?? [])].sort().join(",");
  const places = createMemo<SkillPlaces>(() => placesOf(audience(), meta().scope, projectDraft()));
  const setPlaces = (next: SkillPlaces) => {
    const projects = next.common ? [] : next.projects;
    const m = placesToMeta({ ...next, projects }, audience().includes("coordinator") && meta().scope !== "global");
    setProjectDraft(projects);
    setDraft(setSandboxedMeta(draft(), m.audience, m.scope, p.row.name));
  };

  const run = async (fn: () => Promise<void>) => {
    if (busy()) return;
    setBusy(true);
    setError(null);
    try { await fn(); } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  };

  const toggleAudience = (a: string, on: boolean) => {
    const next = on ? [...new Set([...audience(), a])] : audience().filter((x) => x !== a);
    setDraft(setSandboxedMeta(draft(), next, meta().scope ?? null, p.row.name));
  };
  const setScope = (scope: string) => setDraft(setSandboxedMeta(draft(), audience(), scope === "global" ? "global" : null, p.row.name));

  // ── Reference files ──
  const [files, setFiles] = createSignal<string[]>(p.library ? referencePaths(p.library) : []);
  const [openFile, setOpenFile] = createSignal<string | null>(null);
  const [fileText, setFileText] = createSignal("");
  const [fileOriginal, setFileOriginal] = createSignal("");
  const [newFile, setNewFile] = createSignal<string | null>(null);
  const [confirmFileDelete, setConfirmFileDelete] = createSignal<string | null>(null);
  const loadFile = (rel: string) => run(async () => {
    const inline = p.library?.files?.find((f) => (f.path || f.name) === rel);
    const text = inline ? inline.content : await readSkillFile(p.row.name, rel);
    setOpenFile(rel); setFileText(text); setFileOriginal(text);
  });
  const saveFile = () => run(async () => {
    const rel = openFile();
    if (!rel) return;
    await putSkillFile(p.row.name, rel, fileText());
    setFileOriginal(fileText());
    await p.onFilesChanged(p.row.name);
  });
  const createFile = () => run(async () => {
    const rel = (newFile() ?? "").trim().replace(/^\/+/, "");
    if (!rel || rel === "SKILL.md" || rel.split("/").some((s) => !s || s === ".." || s === ".")) throw new Error("Enter a relative path such as references/notes.md.");
    await putSkillFile(p.row.name, rel, "");
    setFiles((list) => [...new Set([...list, rel])].sort());
    setNewFile(null);
    setOpenFile(rel); setFileText(""); setFileOriginal("");
    await p.onFilesChanged(p.row.name);
  });
  const removeFile = (rel: string) => run(async () => {
    await deleteSkillFile(p.row.name, rel);
    setFiles((list) => list.filter((f) => f !== rel));
    if (openFile() === rel) setOpenFile(null);
    setConfirmFileDelete(null);
    await p.onFilesChanged(p.row.name);
  });

  const versions = () => p.row.sources.filter((s) => s.id !== "library");
  const libraryHash = () => p.row.sources.find((s) => s.id === "library")?.hash;

  return (
    <>
      <Dialog size="wide" class="skills-detail" title={p.row.name} description={p.row.description} busy={busy()} dirty={dirty()} onClose={p.onClose}
        footer={(close) => <>
          <Show when={editable()}>
            <DialogButton variant="destructive" class="skills-detail-delete" disabled={busy()} onClick={() => setConfirmDelete(true)}>Delete…</DialogButton>
          </Show>
          <DialogButton disabled={busy()} onClick={close}>{dirty() ? "Cancel" : "Close"}</DialogButton>
          <Show when={editable()}>
            <DialogButton variant="primary" disabled={busy() || !dirty()} onClick={() => void run(async () => { if (draft() !== original()) await p.onSave(p.row.name, draft()); if (projectsDirty()) await p.onSaveProjects?.(p.row.name, projectDraft()); })}>
              {busy() ? "Saving…" : "Save & sync"}
            </DialogButton>
          </Show>
        </>}>
        <div class="skills-detail-badges">
          <SkillBadges row={p.row} harnessTotal={p.harnessTotal} projects={projectDraft()} />
        </div>
        <Show when={error()}>{(e) => <p class="inline-error" role="alert">{e()}</p>}</Show>
        <Show when={lint().length}>
          <ul class="skills-lint" aria-label="Lint warnings">
            <For each={lint()}>{(l) => <li data-lint={l.id}>{l.message}</li>}</For>
          </ul>
        </Show>

        <div class="skills-filter-pills skills-detail-tabs" role="tablist" aria-label="Skill sections">
          <button type="button" role="tab" aria-selected={tab() === "skill"} class={`skills-filter-pill ${tab() === "skill" ? "on" : ""}`} onClick={() => setTab("skill")}>SKILL.md</button>
          <Show when={p.library}>
            <button type="button" role="tab" aria-selected={tab() === "files"} class={`skills-filter-pill ${tab() === "files" ? "on" : ""}`} onClick={() => setTab("files")}>Reference files ({files().length})</button>
          </Show>
          <Show when={versions().length}>
            <button type="button" role="tab" aria-selected={tab() === "versions"} class={`skills-filter-pill ${tab() === "versions" ? "on" : ""}`} onClick={() => setTab("versions")}>
              Copies ({versions().length}){p.row.divergent ? " · divergent" : ""}
            </button>
          </Show>
        </div>

        <Show when={tab() === "skill"}>
          <Show when={editable()}>
            <div class="skills-meta-controls">
              <SkillPlacesPicker value={places()} projects={p.projects ?? []} disabled={busy()} onChange={setPlaces} />
              <button type="button" class="s-btn sm quiet skills-preview-toggle" onClick={() => setPreview(!preview())}>{preview() ? "Edit" : "Preview"}</button>
            </div>
          </Show>
          <Show when={!p.library && p.row.projectFile}>
            {(pf) => (
              <div class="skills-drawer-meta">
                <span>Project context skill · {pf().slug}</span>
                <button type="button" class="s-btn sm" onClick={() => p.onOpenProjectFile?.(pf().slug, pf().path)}>Open in project files</button>
              </div>
            )}
          </Show>
          <Show when={!editable() && !p.row.projectFile && p.connected && !p.row.inLibrary}>
            <p class="skills-sub-note">Not in the Library. Import a copy from the Copies tab to manage it here.</p>
          </Show>
          <div class="skills-editor">
            <Show when={!preview() && editable()} fallback={<div class="skills-md-view"><MdView text={draft() || "_No SKILL.md content available._"} /></div>}>
              <MdSource text={draft()} onInput={setDraft} readOnly={busy()} />
            </Show>
          </div>
          <Show when={dirty()}>
            <details class="skills-pending-diff"><summary>Review changes</summary><DiffView before={original()} after={draft()} beforeLabel="Library" afterLabel="Draft" /></details>
          </Show>
        </Show>

        <Show when={tab() === "files"}>
          <div class="skills-files">
            <div class="skills-files-list" role="list">
              <For each={files()} fallback={<p class="skills-preview-empty">No reference files.</p>}>{(rel) => (
                <div class={`skills-file-row ${openFile() === rel ? "on" : ""}`} role="listitem">
                  <button type="button" class="skills-file-name" disabled={busy()} onClick={() => void loadFile(rel)}>{rel}</button>
                  <button type="button" class="s-btn sm quiet danger" aria-label={`Delete ${rel}`} disabled={busy() || !editable()} onClick={() => setConfirmFileDelete(rel)}>Delete</button>
                </div>
              )}</For>
              <Show when={editable()}><button type="button" class="s-btn sm" disabled={busy()} onClick={() => setNewFile("references/")}>Add file</button></Show>
            </div>
            <Show when={openFile()}>{(rel) => (
              <div class="skills-file-editor">
                <div class="skills-drawer-meta"><code>{rel()}</code>
                  <button type="button" class="s-btn sm primary" disabled={busy() || fileText() === fileOriginal() || !editable()} onClick={() => void saveFile()}>Save file & sync</button>
                </div>
                <div class="skills-editor small"><MdSource text={fileText()} onInput={setFileText} readOnly={busy() || !editable()} /></div>
              </div>
            )}</Show>
          </div>
        </Show>

        <Show when={tab() === "versions"}>
          <div class="skills-versions">
            <Show when={p.row.legacyOnly}>
              <p class="skills-sub-note">Only in a legacy folder: it is no longer synced to local harnesses. Import it to the Library to keep it.</p>
            </Show>
            <For each={versions()}>{(src) => {
              const same = () => !!libraryHash() && src.hash === libraryHash();
              const [compare, setCompare] = createSignal(false);
              return (
                <div class="skills-version" data-source={src.id}>
                  <div class="skills-version-head">
                    <div class="skills-version-title">
                      <span class="skills-origin-tag">{src.legacy ? "legacy" : "canonical"}</span>
                      <strong>{src.label}</strong>
                      <span class="skills-sub-note">{src.lines} lines · {src.hash.slice(0, 8)}</span>
                      <Show when={p.row.inLibrary}><span class={`skills-badge ${same() ? "synced" : "drift"}`}>{same() ? "Same as Library" : "Differs from Library"}</span></Show>
                    </div>
                    <div class="skills-version-actions">
                      <Show when={p.row.inLibrary && !same() && src.content}>
                        <button type="button" class="s-btn sm" onClick={() => setCompare(!compare())}>{compare() ? "Hide diff" : "Compare"}</button>
                      </Show>
                      <Show when={p.connected && src.content && !same()}>
                        <button type="button" class={`s-btn sm${p.row.inLibrary ? "" : " primary"}`} disabled={busy()} onClick={() => setConfirmImport(src)}>{p.row.inLibrary ? "Use this version" : "Import to Library"}</button>
                      </Show>
                    </div>
                  </div>
                  <Show when={src.path}><code class="skills-version-path">{src.path}</code></Show>
                  <Show when={compare() && src.content}>
                    <DiffView before={original()} after={src.content!} beforeLabel="Library" afterLabel={src.label} />
                  </Show>
                </div>
              );
            }}</For>
          </div>
        </Show>
      </Dialog>

      <Show when={confirmDelete()}>
        <ConfirmDialog title={`Delete ${p.row.name}?`} destructive action="Delete skill" busy={busy()} error={error()}
          description={`Removes the skill from the Library and from all ${p.harnessTotal} local harness folders Orb manages. Unmanaged copies you created are kept.`}
          onClose={() => setConfirmDelete(false)}
          onConfirm={() => void run(async () => { await p.onDelete(p.row.name); setConfirmDelete(false); p.onClose(); })} />
      </Show>
      <Show when={confirmImport()}>{(src) => (
        <Dialog size="compact" class="skills-import" title={p.row.inLibrary ? `Replace the Library version of ${p.row.name}?` : `Import ${p.row.name} to the Library?`}
          description={`Writes SKILL.md and the checked reference files from ${src().label} to the Library, then syncs local harnesses.`}
          busy={busy()} onClose={() => setConfirmImport(null)}
          footer={(close) => <>
            <DialogButton disabled={busy()} onClick={close}>Cancel</DialogButton>
            <DialogButton variant="primary" disabled={busy()} onClick={() => void run(async () => { await p.onImport(p.row.name, src(), importRels()); setConfirmImport(null); p.onClose(); })}>
              {busy() ? "Working…" : p.row.inLibrary ? "Use this version" : "Import"}
            </DialogButton>
          </>}>
          <Show when={error()}>{(e) => <p class="inline-error" role="alert">{e()}</p>}</Show>
          <Show when={p.row.inLibrary && dropsSandboxedMetadata(original(), src().content)}>
            <p class="inline-error" role="alert">This copy has no <code>metadata.sandboxed</code> block. Replacing the Library version removes its audience and scope, so missions stop receiving it automatically.</p>
          </Show>
          <Show when={src().files?.length} fallback={<p class="skills-sub-note">No importable reference files: only SKILL.md is imported.</p>}>
            <fieldset class="skills-import-files">
              <legend>Reference files (text under references/, scripts/, assets/, templates/; secrets and dotfiles are never offered)</legend>
              <For each={src().files}>{(f) => (
                <label class="skills-check"><input type="checkbox" checked={importRels().includes(f.rel)} disabled={busy()}
                  onChange={(e) => setImportRels(e.currentTarget.checked ? [...importRels(), f.rel] : importRels().filter((r) => r !== f.rel))} />
                  <code>{f.rel}</code><span class="skills-sub-note">{formatSize(f.size)}</span></label>
              )}</For>
            </fieldset>
          </Show>
        </Dialog>
      )}</Show>
      <Show when={confirmFileDelete()}>{(rel) => (
        <ConfirmDialog title={`Delete ${rel()}?`} destructive action="Delete file" busy={busy()} error={error()}
          description="Removes the reference file from the Library skill and syncs local harnesses."
          onClose={() => setConfirmFileDelete(null)} onConfirm={() => void removeFile(rel())} />
      )}</Show>
      <Show when={newFile() !== null}>
        <NameDialog title="Add reference file" label="Path inside the skill" placeholder="references/notes.md" value={newFile() ?? ""} onInput={setNewFile}
          action="Create" busy={busy()} error={error()} onAction={() => void createFile()} onClose={() => setNewFile(null)} />
      </Show>
    </>
  );
}

export function SkillBadges(p: { row: SkillRow; harnessTotal: number; projects?: string[] }) {
  const r = () => p.row;
  return (
    <>
      <Show when={r().audience.includes("local")}><span class="skills-aud aud-local">local</span></Show>
      <Show when={r().scope === "global"}><span class="skills-aud aud-global">common</span></Show>
      <For each={p.projects ?? []}>{(slug) => <span class="skills-aud aud-project">{slug}</span>}</For>
      <For each={r().sourceKinds}>{(k) => <span class="skills-origin-tag">{k}</span>}</For>
      <Show when={r().desired}>
        <span class={`skills-badge ${r().harnessCount >= p.harnessTotal && !r().staleCount ? "synced" : "drift"}`}>
          {r().staleCount ? `Drift · ${r().harnessCount}/${p.harnessTotal}` : `Synced ${r().harnessCount}/${p.harnessTotal}`}
        </span>
      </Show>
      
      <Show when={r().legacyOnly}><span class="skills-badge drift">Only in legacy folder</span></Show>
      <Show when={r().divergent}><span class="skills-badge drift">Divergent</span></Show>
      <Show when={r().lines}><span class="skills-sub-note">{r().lines} lines</span></Show>
    </>
  );
}

/** True when the Library frontmatter declares sandboxed delivery metadata that the candidate lacks. */
export function dropsSandboxedMetadata(library: string | null | undefined, candidate: string | null | undefined): boolean {
  const front = (text?: string | null) => /^---\n([\s\S]*?)\n---/.exec(text ?? "")?.[1] ?? "";
  return /^\s+sandboxed:/m.test(front(library)) && !/^\s+sandboxed:/m.test(front(candidate));
}
