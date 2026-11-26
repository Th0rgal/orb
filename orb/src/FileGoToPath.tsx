import { createSignal, onMount, Show } from "solid-js";
import * as Ic from "./icons";
import { nativeInvoke } from "./clientRuns";
import type { FileEntry, FileOp, FileRef, FileReply, FileSource } from "./fileResources";

export interface FileGoToPathProps {
  ensureRoots: () => Promise<FileSource[]>;
  call: (source: string, op: FileOp) => Promise<FileReply>;
  mountLocalRoot: (dir: string) => FileSource;
  onAddSource: (source: FileSource) => void;
  onOpenFile: (ref: FileRef) => void;
  onOpenFolder: (source: string, path: string) => void;
  onClose: () => void;
}

export default function FileGoToPath(p: FileGoToPathProps) {
  const [value, setValue] = createSignal("");
  const [err, setErr] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  let input: HTMLInputElement | undefined;

  onMount(() => {
    requestAnimationFrame(() => input?.focus());
  });

  async function tryInSource(src: FileSource, rel: string): Promise<boolean> {
    if (!rel) {
      p.onOpenFolder(src.id, "");
      return true;
    }
    const slash = rel.lastIndexOf("/");
    const parent = slash < 0 ? "" : rel.slice(0, slash);
    const name = slash < 0 ? rel : rel.slice(slash + 1);
    const listRes = await p.call(src.id, { action: "list", path: parent }).catch(() => null);
    const entry = (listRes?.entries ?? []).find(
      (e: FileEntry) => e.path === rel || e.name === name,
    );
    if (entry) {
      if (entry.kind === "dir") p.onOpenFolder(src.id, entry.path);
      else p.onOpenFile({ ...entry, source: src.id });
      return true;
    }
    try {
      await p.call(src.id, { action: "read", path: rel });
      p.onOpenFile({ source: src.id, path: rel, name, kind: "file" });
      return true;
    } catch {}
    try {
      await p.call(src.id, { action: "list", path: rel });
      p.onOpenFolder(src.id, rel);
      return true;
    } catch {}
    return false;
  }

  async function submit() {
    if (busy()) return;
    const raw = value().trim().replace(/^["']|["']$/g, "");
    if (!raw) return;
    const clean = raw.length > 1 ? raw.replace(/\/+$/, "") : raw;
    setBusy(true);
    setErr("");
    try {
      const roots = await p.ensureRoots().catch(() => [] as FileSource[]);
      const avail = roots.filter((s) => s.available);
      const byPath = avail
        .filter((s) => s.path)
        .map((s) => ({ s, norm: s.path!.replace(/\/+$/, "") }))
        .sort((a, b) => b.norm.length - a.norm.length);
      for (const { s, norm } of byPath) {
        if (clean === norm) {
          p.onOpenFolder(s.id, "");
          return;
        }
        if (norm && clean.startsWith(norm + "/")) {
          if (await tryInSource(s, clean.slice(norm.length + 1))) return;
        }
      }
      if (!clean.startsWith("/") && !clean.startsWith("~/")) {
        const relClean = clean.replace(/^\.\//, "");
        for (const s of avail) {
          if (await tryInSource(s, relClean)) return;
        }
      }
      const invoke = nativeInvoke();
      if (invoke && (clean.startsWith("/") || clean.startsWith("~/"))) {
        try {
          const canonDir = await invoke<string>("local_agents_directory", { path: clean });
          const src = p.mountLocalRoot(canonDir);
          p.onAddSource(src);
          p.onOpenFolder(src.id, "");
          return;
        } catch {}
        const slash = clean.lastIndexOf("/");
        const parentDir = slash > 0 ? clean.slice(0, slash) : "";
        const baseName = slash >= 0 ? clean.slice(slash + 1) : "";
        if (parentDir && baseName) {
          try {
            const canonParent = await invoke<string>("local_agents_directory", { path: parentDir });
            const src = p.mountLocalRoot(canonParent);
            p.onAddSource(src);
            if (await tryInSource(src, baseName)) return;
          } catch (e) {
            setErr(e instanceof Error ? e.message : String(e));
            return;
          }
        }
      }
      setErr("Path not found.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div class="file-search" role="dialog" aria-label="Go to path">
      <button
        class="file-search-close"
        aria-label="Close go to path"
        onClick={() => p.onClose()}
      >
        <Ic.CloseIcon size={14} />
      </button>
      <input
        ref={input}
        autocapitalize="off"
        autocorrect="off"
        spellcheck={false}
        aria-label="Go to file or folder path"
        placeholder="Enter file or folder path…"
        value={value()}
        disabled={busy()}
        onInput={(e) => {
          setValue(e.currentTarget.value);
          if (err()) setErr("");
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            void submit();
          } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            p.onClose();
          }
        }}
      />
      <div class="file-search-results">
        <Show
          when={err()}
          fallback={<p>{busy() ? "Opening…" : "Press Enter to open file or switch to folder"}</p>}
        >
          <p role="alert">{err()}</p>
        </Show>
      </div>
    </div>
  );
}
