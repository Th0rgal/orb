import { For, Show, createMemo, createResource, createSignal, onCleanup } from "solid-js";
import { ConfirmDialog } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { PopupMenu, type MenuEntry } from "./Menu";
import { FileDocument } from "./ProjectFiles";
import { mdSource, setMdSource } from "./Markdown";
import { cachedSkill } from "./skillCache";
import { isConnected, listProjects } from "./api";
import { localSkillsSync } from "./localAgents";
import { SidebarTree, TreeConnectors } from "./Tree";
import type { TreeNode } from "./treeModel";
import * as Ic from "./icons";
import type { LibrarySkill } from "./api";
import { commitAndPush, deleteLibrarySkill, fetchLibrarySkill, getProjectSkills, getSkillAt, getSkillHistory, putLibrarySkill, putProjectSkills, UnsupportedEndpoint } from "./skillsApi";
import { orbRelativeTimeString } from "./orbKernel";
import {
  compactDiff,
  effectiveAudience,
  lineDiff,
  lintSkill,
  parseSkillMeta,
  setSandboxedMeta,
} from "./skillModel";
import { putSkillFile, readSkillFile, referencePaths } from "./skillsApi";

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

/** A skill opens like a project file: a page with a breadcrumb, its files as a slim
 * tree and the open file in the shared FileDocument editor (⌘/ source, ⌘S save). */
export function SkillPage(p: { name: string; initialView?: "edit" | "history"; onBack: () => void; onOpenPage?: (id: string) => void }) {
  const [skill, setSkill] = createSignal<LibrarySkill | null>(null);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const local = () => cachedSkill(p.name);
  const editable = () => isConnected() && !!skill();
  const [view, setView] = createSignal<"edit" | "history">(p.initialView ?? "edit");
  const [openFile, setOpenFile] = createSignal(SKILL_MD);
  // One draft per open file; SKILL.md's original comes from the Library.
  const [drafts, setDrafts] = createSignal<Record<string, string>>({});
  const [originals, setOriginals] = createSignal<Record<string, string>>({});
  const [projectsOriginal, setProjectsOriginal] = createSignal<string[]>([]);
  const [projectDraft, setProjectDraft] = createSignal<string[]>([]);
  const [projects, setProjects] = createSignal<{ slug: string; title?: string }[]>([]);
  const [state, setState] = createSignal<"idle" | "saving" | "saved" | "error">("idle");
  const [error, setError] = createSignal<string | null>(null);
  const [menu, setMenu] = createSignal<{ x: number; y: number } | null>(null);
  const [confirmDelete, setConfirmDelete] = createSignal(false);
  const [deleteBusy, setDeleteBusy] = createSignal(false);
  const [deleteError, setDeleteError] = createSignal<string | null>(null);
  const [newFile, setNewFile] = createSignal<string | null>(null);

  const load = async () => {
    try {
      const s = await fetchLibrarySkill(p.name);
      setSkill(s);
      setOriginals({ [SKILL_MD]: s.content });
      setDrafts({ [SKILL_MD]: s.content });
      setLoadError(null);
    } catch (e) { setLoadError(errorText(e)); }
    void listProjects().then(async (list) => {
      setProjects(list.map((x) => ({ slug: x.slug, title: x.title ?? undefined })));
      const pairs = await Promise.all(list.map(async (x) => [x.slug, (await getProjectSkills(x.slug).catch(() => ({ skills: [] as string[] }))).skills] as const));
      const mine = pairs.filter(([, names]) => names.includes(p.name)).map(([slug]) => slug).sort();
      setProjectsOriginal(mine); setProjectDraft(mine);
    }).catch(() => {});
  };
  void load();

  const text = () => drafts()[openFile()] ?? null;
  const setText = (t: string) => { setDrafts((d) => ({ ...d, [openFile()]: t })); if (state() === "saved") setState("idle"); };
  const dirtyFiles = () => Object.keys(drafts()).filter((k) => drafts()[k] !== originals()[k]);
  const projectsDirty = () => projectDraft().join(",") !== projectsOriginal().join(",");
  const dirty = () => editable() && (dirtyFiles().length > 0 || projectsDirty());
  const skillMd = () => drafts()[SKILL_MD] ?? "";
  const meta = createMemo(() => parseSkillMeta(skillMd()));
  const audience = createMemo(() => effectiveAudience(meta()));
  const lint = createMemo(() => lintSkill(p.name, skillMd()));
  const setSkillMd = (t: string) => setDrafts((d) => ({ ...d, [SKILL_MD]: t }));
  const toggleAudience = (who: string, on: boolean) => setSkillMd(setSandboxedMeta(skillMd(), on ? [...new Set([...audience(), who])] : audience().filter((a) => a !== who), meta().scope ?? null, p.name));
  const setLoad = (always: boolean) => setSkillMd(setSandboxedMeta(skillMd(), audience(), always ? "global" : null, p.name));
  const toggleProject = (slug: string, on: boolean) => setProjectDraft((list) => (on ? [...new Set([...list, slug])] : list.filter((x) => x !== slug)).sort());

  const files = createMemo(() => (skill() ? referencePaths(skill()!) : []));
  const tree = createMemo(() => fileTree([...new Set([...files(), ...Object.keys(drafts()).filter((k) => k !== SKILL_MD)])]));
  const openPath = async (rel: string) => {
    setView("edit");
    setOpenFile(rel);
    if (rel === SKILL_MD || drafts()[rel] !== undefined) return;
    try {
      const inline = skill()?.files?.find((f) => (f.path || f.name) === rel);
      const t = inline ? inline.content : await readSkillFile(p.name, rel);
      setOriginals((o) => ({ ...o, [rel]: t })); setDrafts((d) => ({ ...d, [rel]: t }));
    } catch (e) { setError(errorText(e)); }
  };

  /** Save every changed file, commit once and push; harnesses on this Mac follow. */
  const save = async (message = `skill: update ${p.name}`) => {
    if (!dirty() || state() === "saving") return;
    setState("saving"); setError(null);
    try {
      for (const rel of dirtyFiles()) {
        if (rel === SKILL_MD) await putLibrarySkill(p.name, drafts()[rel]);
        else await putSkillFile(p.name, rel, drafts()[rel]);
      }
      if (projectsDirty()) {
        for (const slug of projects().map((x) => x.slug)) {
          if (projectsOriginal().includes(slug) === projectDraft().includes(slug)) continue;
          const current = (await getProjectSkills(slug)).skills;
          await putProjectSkills(slug, projectDraft().includes(slug) ? [...current, p.name] : current.filter((n) => n !== p.name));
        }
      }
      await commitAndPush(message);
      setOriginals({ ...originals(), ...drafts() }); setProjectsOriginal(projectDraft());
      setState("saved");
      void syncThisSkill();
    } catch (e) { setError(errorText(e)); setState("error"); }
  };
  const syncThisSkill = async () => {
    const s = await fetchLibrarySkill(p.name).catch(() => null);
    if (!s) return;
    setSkill(s);
    await localSkillsSync({ librarySkills: [{ name: s.name, content: s.content, files: (s.files ?? []).filter((f) => (f.path || f.name) !== SKILL_MD).map((f) => ({ rel: f.path || f.name, content: f.content })) }] }).catch(() => null);
  };
  const discardLocal = async () => {
    const s = skill();
    if (!s) return;
    await localSkillsSync({ librarySkills: [{ name: s.name, content: s.content }], replaceUnmanaged: [s.name] });
  };
  const remove = async () => {
    setDeleteBusy(true); setDeleteError(null);
    try {
      await deleteLibrarySkill(p.name).catch((e) => { if (!/not found|404/i.test(errorText(e))) throw e; });
      await commitAndPush(`skill: delete ${p.name}`);
      void localSkillsSync({ librarySkills: [], pruneRemoved: false }).catch(() => null);
      p.onBack();
    } catch (e) { setDeleteError(deleteMessage(p.name, e)); }
    finally { setDeleteBusy(false); }
  };
  const createFile = async () => {
    const rel = (newFile() ?? "").trim().replace(/^\/+/, "");
    setNewFile(null);
    if (!rel || rel === SKILL_MD || rel.split("/").some((seg) => !seg || seg === ".." || seg === ".")) { if (rel) setError("Enter a relative path such as references/notes.md."); return; }
    setOriginals((o) => ({ ...o, [rel]: "\u0000new" })); setDrafts((d) => ({ ...d, [rel]: "" }));
    setOpenFile(rel); setView("edit");
  };

  const oldCopy = () => local()?.sources?.find((src) => src.id !== "library" && src.legacy && src.content);
  const isSkill = () => openFile() === SKILL_MD;
  const onKeyDown = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key === "s") { e.preventDefault(); void save(); } };
  window.addEventListener("keydown", onKeyDown);
  onCleanup(() => window.removeEventListener("keydown", onKeyDown));

  const menuItems = (): MenuEntry[] => [
    ...(skill() ? [{ kind: "item" as const, label: view() === "history" ? "Back to the file" : "History", icon: Ic.ReopenIcon, onClick: () => setView(view() === "history" ? "edit" : "history") }] : []),
    ...(local()?.edited_copy ? [{ kind: "item" as const, label: "Discard local edits", onClick: () => void discardLocal().catch((e) => setError(errorText(e))) }] : []),
    ...(editable() ? [{ kind: "sep" as const }, { kind: "item" as const, label: "Delete…", icon: Ic.TrashIcon, danger: true, onClick: () => { setDeleteError(null); setConfirmDelete(true); } }] : []),
  ];

  return (
    <div class="skill-page">
      <div class="pf-bar">
        <button type="button" class="icon-btn" aria-label="Back to Skills" onClick={p.onBack}><Ic.ArrowLeft /></button>
        <nav class="skill-crumbs" aria-label="Breadcrumb">
          <button type="button" class="link-btn" onClick={p.onBack}>Skills</button>
          <span class="dim">›</span>
          <span class="skill-crumb-name">{p.name}</span>
          <Show when={!isSkill() && view() === "edit"}><span class="dim">›</span><span class="pf-path" title={openFile()}>{middleTruncate(openFile(), 40)}</span></Show>
        </nav>
        <span class="dlg-spacer" />
        <Show when={state() === "saving"}><span class="pf-state">Saving…</span></Show>
        <Show when={state() === "saved" && !dirty()}><span class="pf-state dim" role="status">Saved to repo</span></Show>
        <Show when={state() === "error"}><span class="pf-state inline-error" role="alert">{error()} <button type="button" class="link-btn" onClick={() => void save()}>Retry</button></span></Show>
        <Show when={editable() && view() === "edit"}>
          <button class="s-btn" title="Toggle source and preview (⌘/)" onClick={() => setMdSource(!mdSource())}>{mdSource() ? "Preview" : "Edit"}</button>
          <button class="s-btn primary" title="Save (⌘S)" disabled={!dirty() || state() === "saving"} onClick={() => void save()}>Save</button>
        </Show>
        <button type="button" class="icon-btn" aria-label={`Actions for ${p.name}`} aria-haspopup="menu" onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); setMenu({ x: r.right - 200, y: r.bottom + 4 }); }}><span aria-hidden="true">···</span></button>
      </div>
      <Show when={menu()}>{(m) => <PopupMenu x={m().x} y={m().y} items={menuItems()} onClose={() => setMenu(null)} />}</Show>

      <Show when={editable() && isSkill() && view() === "edit"}>
        <div class="skill-strip">
          <div class="skills-meta-row" role="group" aria-label="Who uses it">
            <span class="skills-meta-label">Who uses it</span>
            <For each={[["mission", "Missions"], ["coordinator", "Assistant"], ["local", "This Mac"]] as const}>{([id, label]) =>
              <label class="skills-check"><input type="checkbox" checked={audience().includes(id)} onChange={(e) => toggleAudience(id, e.currentTarget.checked)} />{label}</label>
            }</For>
          </div>
          <div class="skills-meta-row" role="radiogroup" aria-label="Load">
            <span class="skills-meta-label">Load</span>
            <div class="skills-seg">
              <button type="button" role="radio" aria-checked={meta().scope !== "global"} class={meta().scope !== "global" ? "on" : ""} onClick={() => setLoad(false)}>On demand</button>
              <button type="button" role="radio" aria-checked={meta().scope === "global"} class={meta().scope === "global" ? "on" : ""} onClick={() => setLoad(true)}>Always</button>
            </div>
          </div>
          <Show when={projects().length && meta().scope !== "global"}>
            <div class="skills-meta-row" role="group" aria-label="Projects">
              <span class="skills-meta-label">Projects</span>
              <For each={projects()}>{(proj) =>
                <label class="skills-check"><input type="checkbox" checked={projectDraft().includes(proj.slug)} onChange={(e) => toggleProject(proj.slug, e.currentTarget.checked)} />{proj.title || proj.slug}</label>
              }</For>
            </div>
          </Show>
          <Show when={oldCopy()}>{(src) =>
            <p class="skills-oldcopy" title={src().path ?? undefined}>Old copy in {src().label}<Show when={src().path}> · <code>{middleTruncate(src().path!, 40)}</code></Show></p>
          }</Show>
          <Show when={lint().length}><ul class="skills-lint" aria-label="Lint warnings"><For each={lint()}>{(l) => <li data-lint={l.id}>{l.message}</li>}</For></ul></Show>
        </div>
      </Show>

      <div class="skill-body">
        <nav class="skills-files-tree" aria-label="Skill files">
          <SidebarTree nodes={tree()} label={`${p.name} files`} selected={view() === "history" ? null : openFile()} render={(row) => {
            const d = row.data;
            return <>
              <TreeConnectors row={row} />
              <button type="button" class={`row ${!d.dir && openFile() === d.path && view() === "edit" ? "active" : ""}`} disabled={d.dir} title={d.path} onClick={() => void openPath(d.path)}>
                <span class="row-ico"><Show when={d.dir} fallback={<Ic.FileIcon />}><Ic.FolderIcon /></Show></span>
                <span class="row-label">{d.name}</span>
                <Show when={dirtyFiles().includes(d.path)}><span class="skill-dirty" aria-label="Unsaved">•</span></Show>
              </button>
            </>;
          }} />
          <Show when={editable()}>
            <Show when={newFile() !== null} fallback={<button type="button" class="s-btn sm quiet skills-file-add" onClick={() => setNewFile("references/")}><Ic.PlusIcon size={12} /> New file</button>}>
              <form class="skills-file-new" onSubmit={(e) => { e.preventDefault(); void createFile(); }}>
                <input class="s-input" aria-label="New file path" value={newFile() ?? ""} autofocus onInput={(e) => setNewFile(e.currentTarget.value)} onBlur={() => void createFile()} />
              </form>
            </Show>
          </Show>
        </nav>
        <section class="skill-main">
          <Show when={loadError()}>{(e) => <div class="col"><ErrorNotice error={e()} /></div>}</Show>
          <Show when={view() === "edit"} fallback={
            <div class="scroll"><div class="col">
              <SkillHistory name={p.name} current={originals()[SKILL_MD] ?? ""} busy={state() === "saving"} onRestore={(rev, content) => { setDrafts((d) => ({ ...d, [SKILL_MD]: content })); setOpenFile(SKILL_MD); void save(`skill: restore ${p.name} to ${rev.slice(0, 7)}`).then(() => setView("edit")); }} />
            </div></div>
          }>
            <FileDocument text={isSkill() && !mdSource() ? (text() ?? "").replace(/^---\n[\s\S]*?\n---\n?/, "") : text()} name={openFile()} readOnly={!editable()} onInput={setText} />
          </Show>
        </section>
      </div>

      <Show when={confirmDelete()}>
        <ConfirmDialog title={`Delete ${p.name}?`} description="It leaves the Library and every agent on this Mac." destructive
          action={deleteError() ? "Retry" : "Delete"} busy={deleteBusy()} error={deleteError()} onClose={() => setConfirmDelete(false)} onConfirm={() => void remove()} />
      </Show>
    </div>
  );
}

/** Plain words instead of a raw 500 dump (shared with the Skills list). */
export function deleteMessage(name: string, e: unknown): string {
  const raw = errorText(e).replace(/^\d{3}\s+/, "");
  if (/gpg|sign/i.test(raw)) return `Core couldn’t sign the Library commit, so ${name} is still there. (${raw.slice(0, 120)})`;
  if (/push|rejected|denied/i.test(raw)) return `Core couldn’t push the Library, so the delete isn’t saved yet. (${raw.slice(0, 120)})`;
  return `Couldn’t delete ${name}: ${raw}`;
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
