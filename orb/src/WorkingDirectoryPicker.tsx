import { createEffect, createMemo, createSignal, For, onCleanup, Show } from "solid-js";
import { api, type Mission } from "./api";
import {
  CheckIcon,
  ChevronRight,
  CloseIcon,
  ComputeNodeIcon,
  CoreServerIcon,
  FolderIcon,
  FolderOpenIcon,
  LaptopIcon,
  PlusIcon,
  Spinner,
} from "./icons";

export interface FsEntry {
  name: string;
  path: string;
  kind: "dir" | "file" | "link" | "other" | string;
  size?: number;
  mtime?: number;
  subtitle?: string;
}

const RECENT_PREFIX = "orb.recentDirs:";

function loadRecentDirs(machine: string): string[] {
  try {
    const raw = localStorage.getItem(`${RECENT_PREFIX}${machine}`);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string" && x.trim().length > 0) : [];
  } catch {
    return [];
  }
}

function saveRecentDir(machine: string, dir: string) {
  const clean = normalizePath(dir);
  if (!clean) return;
  try {
    const next = [clean, ...loadRecentDirs(machine).filter((x) => x !== clean)].slice(0, 8);
    localStorage.setItem(`${RECENT_PREFIX}${machine}`, JSON.stringify(next));
  } catch {}
}

function normalizePath(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  if (trimmed === "/") return "/";
  return trimmed.replace(/\/+$/, "");
}

function parentDir(path: string): string | null {
  const clean = normalizePath(path);
  if (!clean || clean === "." || clean === "/") return null;
  const idx = clean.lastIndexOf("/");
  if (idx < 0) return ".";
  if (idx === 0) return "/";
  return clean.slice(0, idx);
}

function joinPath(base: string, name: string): string {
  const cleanName = name.trim().replace(/^\/+|\/+$/g, "");
  if (!cleanName) return base;
  const cleanBase = normalizePath(base);
  if (!cleanBase || cleanBase === ".") return cleanName;
  if (cleanBase === "/") return `/${cleanName}`;
  return `${cleanBase}/${cleanName}`;
}

function inferParentFromEntries(entries: FsEntry[]): string | null {
  for (const entry of entries) {
    if (!entry.path || !entry.name) continue;
    const suffix = `/${entry.name}`;
    if (entry.path.startsWith("/") && entry.path.endsWith(suffix)) {
      const parent = entry.path.slice(0, -suffix.length);
      return parent || "/";
    }
  }
  return null;
}

function missionMatchesMachine(m: Mission, machine: string): boolean {
  const transfer = m.machine_transfer?.destination;
  const dest = transfer
    ? transfer.kind === "client"
      ? "local"
      : transfer.kind === "core"
        ? "core"
        : transfer.id
    : m.tags?.includes("placement:client")
      ? "local"
      : m.remote_job?.node_id ?? m.remote_node_id ?? "core";
  return dest === machine;
}

export function WorkingDirectoryPicker(p: {
  machine: string;
  machineName?: string;
  value: string;
  disabled?: boolean;
  missions?: Mission[];
  onChange: (value: string) => void;
}) {
  const [open, setOpen] = createSignal(false);
  const [error, setError] = createSignal("");
  const [picking, setPicking] = createSignal(false);
  const [browsedDir, setBrowsedDir] = createSignal(".");
  const [resolvedDir, setResolvedDir] = createSignal<string | null>(null);
  const [entries, setEntries] = createSignal<FsEntry[]>([]);
  const [fileCount, setFileCount] = createSignal(0);
  const [loading, setLoading] = createSignal(false);
  const [liveAvailable, setLiveAvailable] = createSignal(false);
  const [showHidden, setShowHidden] = createSignal(false);
  const [creatingFolder, setCreatingFolder] = createSignal(false);
  const [newFolderName, setNewFolderName] = createSignal("");
  const [creatingBusy, setCreatingBusy] = createSignal(false);
  const [recents, setRecents] = createSignal<string[]>([]);

  let rootRef: HTMLDivElement | undefined;
  let pathInputRef: HTMLInputElement | undefined;
  let newFolderInputRef: HTMLInputElement | undefined;
  let requestSeq = 0;

  const machineTitle = () =>
    p.machine === "local" ? "this computer" : p.machineName || p.machine;

  const MachineIcon = () => {
    if (p.machine === "local") return <LaptopIcon size={13} />;
    if (p.machine === "core") return <CoreServerIcon size={13} />;
    return <ComputeNodeIcon size={13} />;
  };

  const knownMachineDirs = createMemo(() => {
    const seen = new Set<string>();
    const list: { path: string; subtitle: string }[] = [];
    for (const dir of recents()) {
      const clean = normalizePath(dir);
      if (clean && !seen.has(clean)) {
        seen.add(clean);
        list.push({ path: clean, subtitle: "Recent folder" });
      }
    }
    for (const m of p.missions ?? []) {
      if (!missionMatchesMachine(m, p.machine)) continue;
      const wd = normalizePath(m.working_directory ?? "");
      if (wd && !seen.has(wd)) {
        seen.add(wd);
        list.push({
          path: wd,
          subtitle: m.project ? `Project · ${m.project}` : m.title ? `Mission · ${m.title}` : "Mission folder",
        });
      }
    }
    return list;
  });

  async function loadDir(targetDir: string) {
    const seq = ++requestSeq;
    const queryPath = normalizePath(targetDir) || ".";
    setLoading(true);
    try {
      const endpoint =
        p.machine === "core"
          ? `/api/fs/list?path=${encodeURIComponent(queryPath)}`
          : `/api/remote-nodes/${encodeURIComponent(p.machine)}/fs/list?path=${encodeURIComponent(queryPath)}`;
      const raw = await api<FsEntry[]>(endpoint);
      if (seq !== requestSeq) return;
      const list = Array.isArray(raw) ? raw : [];
      const inferred = inferParentFromEntries(list);
      setResolvedDir(inferred ?? (queryPath.startsWith("/") ? queryPath : null));
      setFileCount(list.filter((e) => e.kind === "file").length);
      const dirs = list
        .filter((e) => e.kind === "dir" && e.name && e.name !== "." && e.name !== "..")
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
      setEntries(dirs);
      setLiveAvailable(true);
    } catch {
      if (seq !== requestSeq) return;
      setResolvedDir(queryPath.startsWith("/") ? queryPath : null);
      setEntries([]);
      setFileCount(0);
      setLiveAvailable(false);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  }

  const effectiveDir = () => resolvedDir() ?? (browsedDir() !== "." ? normalizePath(browsedDir()) : "");

  const breadcrumbs = createMemo(() => {
    const dir = effectiveDir();
    if (!dir || dir === ".") return [];
    if (!dir.startsWith("/")) {
      const parts = dir.split("/").filter(Boolean);
      let acc = "";
      return parts.map((part) => {
        acc = acc ? `${acc}/${part}` : part;
        return { name: part, path: acc };
      });
    }
    const parts = dir.split("/").filter(Boolean);
    const crumbs: { name: string; path: string }[] = [{ name: "/", path: "/" }];
    let acc = "";
    for (const part of parts) {
      acc += `/${part}`;
      crumbs.push({ name: part, path: acc });
    }
    return crumbs;
  });

  const hiddenCount = createMemo(() => entries().filter((e) => e.name.startsWith(".")).length);

  const visibleEntries = createMemo(() => {
    const all = entries();
    return showHidden() ? all : all.filter((e) => !e.name.startsWith("."));
  });

  const canGoUp = () => {
    const dir = effectiveDir();
    return !!dir && dir !== "." && dir !== "/";
  };

  const navigateTo = (dirPath: string, select = true) => {
    const clean = normalizePath(dirPath);
    setBrowsedDir(clean || ".");
    if (select) p.onChange(clean);
    void loadDir(clean || ".");
  };

  const goUp = () => {
    const parent = parentDir(effectiveDir());
    if (!parent) {
      navigateTo(".", false);
      p.onChange("");
      return;
    }
    navigateTo(parent, parent !== ".");
  };

  const submitNewFolder = async () => {
    const name = newFolderName().trim().replace(/^\/+|\/+$/g, "");
    if (!name || creatingBusy()) return;
    const base = effectiveDir() || ".";
    const target = joinPath(base, name);
    setCreatingBusy(true);
    try {
      const mkdirUrl =
        p.machine === "core"
          ? "/api/fs/mkdir"
          : `/api/remote-nodes/${encodeURIComponent(p.machine)}/fs/mkdir`;
      await api(mkdirUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: target }),
      }).catch(() => {});
      setCreatingFolder(false);
      setNewFolderName("");
      saveRecentDir(p.machine, target);
      setRecents(loadRecentDirs(p.machine));
      navigateTo(target, true);
    } finally {
      setCreatingBusy(false);
    }
  };

  createEffect(() => {
    if (!open()) return;
    const machine = p.machine;
    setRecents(loadRecentDirs(machine));
    setCreatingFolder(false);
    setNewFolderName("");
    const initial = normalizePath(p.value) || ".";
    setBrowsedDir(initial);
    void loadDir(initial);
  });

  createEffect(() => {
    if (!open()) return;
    const onPointerDown = (e: PointerEvent) => {
      if (rootRef && !rootRef.contains(e.target as Node)) {
        if (p.value.trim()) saveRecentDir(p.machine, p.value);
        setOpen(false);
      }
    };
    window.addEventListener("pointerdown", onPointerDown);
    onCleanup(() => window.removeEventListener("pointerdown", onPointerDown));
  });

  const choose = async () => {
    setError("");
    if (p.machine !== "local") {
      setOpen(!open());
      return;
    }
    const invoke = (window as any).__TAURI__?.core?.invoke;
    if (!invoke) {
      setOpen(!open());
      return;
    }
    const machine = p.machine;
    setPicking(true);
    try {
      const path = await invoke("pick_working_directory");
      if (path && p.machine === machine) p.onChange(path);
    } catch (e) {
      setError(String(e));
    } finally {
      setPicking(false);
    }
  };

  const finish = () => {
    if (p.value.trim()) {
      saveRecentDir(p.machine, p.value);
      setRecents(loadRecentDirs(p.machine));
    }
    setOpen(false);
  };

  const label = () => p.value.replace(/\/$/, "").split("/").pop() || "Folder";

  return (
    <div ref={rootRef} class="directory-picker">
      <button
        type="button"
        class="model directory-button"
        title={p.value || "Choose working folder"}
        aria-label="Choose working folder"
        aria-expanded={open()}
        disabled={p.disabled || picking()}
        onClick={() => void choose()}
      >
        <FolderIcon size={14} />
        <span>{label()}</span>
      </button>
      <Show when={open()}>
        <div class="menu directory-menu" role="dialog" aria-label={`Folder on ${machineTitle()}`}>
          <div class="directory-menu-head">
            <div class="directory-menu-title">
              <span class="directory-machine-ico">
                <MachineIcon />
              </span>
              <span>Folder on {machineTitle()}</span>
            </div>
            <div class="directory-menu-tools">
              <button
                type="button"
                class="icon-btn sm"
                aria-label="Parent folder"
                title="Parent folder"
                disabled={!canGoUp()}
                onClick={goUp}
              >
                <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M12 10 8 6l-4 4" />
                </svg>
              </button>
              <button
                type="button"
                class="icon-btn sm"
                aria-label="New folder"
                title="New folder"
                onClick={() => {
                  setCreatingFolder((v) => !v);
                  if (!creatingFolder()) {
                    queueMicrotask(() => newFolderInputRef?.focus());
                  }
                }}
              >
                <PlusIcon size={13} />
              </button>
              <button
                type="button"
                class="icon-btn sm"
                aria-label="Refresh folders"
                title="Refresh folders"
                onClick={() => void loadDir(browsedDir())}
              >
                <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M13.5 8a5.5 5.5 0 1 1-1.4-3.7M13.5 2.5v2.6h-2.6" />
                </svg>
              </button>
            </div>
          </div>

          <div class="directory-breadcrumbs" aria-label="Folder breadcrumbs">
            <button
              type="button"
              class="directory-crumb"
              classList={{ active: !p.value && (!effectiveDir() || effectiveDir() === ".") }}
              onClick={() => {
                p.onChange("");
                navigateTo(".", false);
              }}
            >
              Default
            </button>
            <For each={breadcrumbs()}>
              {(crumb, i) => (
                <>
                  <span class="directory-crumb-sep" aria-hidden="true">
                    /
                  </span>
                  <button
                    type="button"
                    class="directory-crumb"
                    classList={{ active: i() === breadcrumbs().length - 1 && Boolean(p.value) }}
                    title={crumb.path}
                    onClick={() => navigateTo(crumb.path, true)}
                  >
                    {crumb.name === "/" ? "root" : crumb.name}
                  </button>
                </>
              )}
            </For>
          </div>

          <label class="directory-path-field">
            <span class="sr-only">Folder on {machineTitle()}</span>
            <div class="directory-input-row">
              <input
                ref={pathInputRef}
                aria-label="Folder path"
                value={p.value}
                placeholder={resolvedDir() ? `${resolvedDir()} (default)` : "Default directory or /path/to/folder"}
                onInput={(e) => {
                  const next = e.currentTarget.value;
                  p.onChange(next);
                  const trimmed = next.trim();
                  if (!trimmed) {
                    setBrowsedDir(".");
                    void loadDir(".");
                  } else if (trimmed.startsWith("/")) {
                    const target = trimmed.endsWith("/") && trimmed.length > 1
                      ? normalizePath(trimmed)
                      : trimmed;
                    setBrowsedDir(target);
                    void loadDir(target);
                  }
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    finish();
                  } else if (e.key === "Escape") {
                    e.preventDefault();
                    setOpen(false);
                  }
                }}
              />
              <Show when={p.value}>
                <button
                  type="button"
                  class="directory-input-clear"
                  aria-label="Clear folder path"
                  title="Clear folder path"
                  onClick={() => {
                    p.onChange("");
                    navigateTo(".", false);
                    pathInputRef?.focus();
                  }}
                >
                  <CloseIcon size={12} />
                </button>
              </Show>
            </div>
          </label>

          <Show when={creatingFolder()}>
            <div class="directory-new-folder">
              <input
                ref={newFolderInputRef}
                aria-label="New folder name"
                placeholder="New folder name…"
                value={newFolderName()}
                onInput={(e) => setNewFolderName(e.currentTarget.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    void submitNewFolder();
                  } else if (e.key === "Escape") {
                    e.preventDefault();
                    setCreatingFolder(false);
                  }
                }}
              />
              <button
                type="button"
                class="directory-new-btn"
                disabled={!newFolderName().trim() || creatingBusy()}
                onClick={() => void submitNewFolder()}
              >
                Create
              </button>
            </div>
          </Show>

          <div class="directory-browser-list" role="listbox" aria-label="Folders">
            <button
              type="button"
              role="option"
              aria-selected={!p.value}
              class="menu-item directory-row"
              classList={{ selected: !p.value }}
              onClick={() => {
                p.onChange("");
                navigateTo(".", false);
              }}
            >
              <span class="directory-row-ico">
                <FolderIcon size={14} />
              </span>
              <span class="directory-row-main">
                <span class="directory-row-name">Default workspace folder</span>
                <span class="directory-row-sub">
                  {resolvedDir() && browsedDir() === "." ? resolvedDir()! : "Automatic mission directory"}
                </span>
              </span>
              <Show when={!p.value}>
                <span class="directory-row-end">
                  <CheckIcon size={13} />
                </span>
              </Show>
            </button>

            <Show when={knownMachineDirs().length > 0 && (browsedDir() === "." || !liveAvailable())}>
              <div class="directory-section-label">Recent &amp; project folders</div>
              <For each={knownMachineDirs()}>
                {(item) => (
                  <button
                    type="button"
                    role="option"
                    aria-selected={normalizePath(p.value) === item.path}
                    class="menu-item directory-row"
                    classList={{ selected: normalizePath(p.value) === item.path }}
                    onClick={() => navigateTo(item.path, true)}
                    onDblClick={() => {
                      p.onChange(item.path);
                      finish();
                    }}
                  >
                    <span class="directory-row-ico">
                      <FolderOpenIcon size={14} />
                    </span>
                    <span class="directory-row-main">
                      <span class="directory-row-name">{item.path.split("/").pop() || item.path}</span>
                      <span class="directory-row-sub">{item.path} · {item.subtitle}</span>
                    </span>
                    <span class="directory-row-end">
                      <Show when={normalizePath(p.value) === item.path}>
                        <CheckIcon size={13} />
                      </Show>
                      <ChevronRight size={12} />
                    </span>
                  </button>
                )}
              </For>
            </Show>

            <Show when={loading()}>
              <div class="directory-browser-status" role="status">
                <Spinner size={12} />
                <span>Loading folders…</span>
              </div>
            </Show>

            <Show when={!loading() && liveAvailable()}>
              <div class="directory-section-label">
                <span>Folders in {effectiveDir() ? effectiveDir().split("/").pop() || "/" : "workspace"}</span>
                <Show when={fileCount() > 0}>
                  <span class="directory-file-count">{fileCount()} {fileCount() === 1 ? "file" : "files"}</span>
                </Show>
              </div>
              <Show
                when={visibleEntries().length > 0}
                fallback={
                  <div class="directory-browser-empty">
                    No subfolders in this directory
                  </div>
                }
              >
                <For each={visibleEntries()}>
                  {(entry) => {
                    const selected = () => normalizePath(p.value) === normalizePath(entry.path);
                    return (
                      <button
                        type="button"
                        role="option"
                        aria-selected={selected()}
                        class="menu-item directory-row"
                        classList={{ selected: selected() }}
                        title={entry.path}
                        onClick={() => navigateTo(entry.path, true)}
                        onDblClick={() => {
                          p.onChange(entry.path);
                          finish();
                        }}
                      >
                        <span class="directory-row-ico">
                          {selected() ? <FolderOpenIcon size={14} /> : <FolderIcon size={14} />}
                        </span>
                        <span class="directory-row-main">
                          <span class="directory-row-name">{entry.name}</span>
                        </span>
                        <span class="directory-row-end">
                          <Show when={selected()}>
                            <CheckIcon size={13} />
                          </Show>
                          <ChevronRight size={12} />
                        </span>
                      </button>
                    );
                  }}
                </For>
              </Show>
              <Show when={hiddenCount() > 0}>
                <button
                  type="button"
                  class="directory-hidden-toggle"
                  onClick={() => setShowHidden((v) => !v)}
                >
                  {showHidden() ? "Hide hidden folders" : `Show ${hiddenCount()} hidden ${hiddenCount() === 1 ? "folder" : "folders"}`}
                </button>
              </Show>
            </Show>
          </div>

          <div class="directory-menu-foot">
            <button
              type="button"
              class="menu-item directory-foot-btn"
              onClick={() => {
                p.onChange("");
                setOpen(false);
              }}
            >
              Use default folder
            </button>
            <button
              type="button"
              class="menu-item directory-foot-btn primary"
              onClick={finish}
            >
              Done
            </button>
          </div>
        </div>
      </Show>
      <Show when={error()}>
        <div role="alert" class="menu directory-menu">
          {error()}
          <button onClick={() => setError("")}>Dismiss</button>
        </div>
      </Show>
    </div>
  );
}
