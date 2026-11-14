/**
 * Hybrid Native Chrome bridge (`window.__ORB_NATIVE_CHROME__ === true`).
 *
 * When a desktop shell opts into Hybrid Native Chrome (`ORB_NATIVE_CHROME=1` injecting
 * `window.__ORB_NATIVE_CHROME__ = true`), the native shell (AppKit `NSSplitView` + `NSTableView` +
 * `NSPanel` on macOS, GTK3 `GtkPaned` + `GtkListBox` + `GtkPopover` on Linux) renders the sidebar
 * navigation tree and `Cmd+K` / `Ctrl+K` quick-switcher natively, backed by
 * `OrbLocald.NativeChrome` (`docs/ui/native-chrome.md`).
 *
 * WebView responsibilities in Native Chrome mode:
 * - Omit mounting the HTML `<aside id="orb-sidebar">` subtree to save DOM/style/layout cost.
 * - Sync canonical sidebar inputs (`native_chrome_sync_state`) fenced by a monotonic `revision`.
 * - Expose `window.__ORB_SELECT_MISSION__(id)` (`~0.2 ms` `keepAlivePool` slot switch),
 *   `window.__ORB_NATIVE_NAV__(target)`, and `window.__ORB_TOGGLE_NATIVE_SIDEBAR__(open?)`.
 *   The native "+" buttons call `__ORB_NATIVE_NAV__("new-project" | "new-agent:<slug>[:<path>]")`.
 */

import type { Mission, ProjectSummary } from "./api";
import { isBtwMission } from "./missionHierarchy";
import { isArchived } from "./missionStatus";
import { forkSource, hasTypedSuperseded, missionParent } from "./missionTree";
import { nativeInvoke } from "./native";

export type NativeChromeMissionWire = {
  id: string;
  title: string;
  status: string;
  project?: string | null;
  folder?: string;
  parent_mission_id: string;
  fork_of: string;
  is_fork: boolean;
  is_btw: boolean;
  acknowledged: boolean;
  superseded: boolean;
  created_at_ms: number;
  updated_at_ms: number;
};

export type NativeChromeProjectWire = {
  slug: string;
  name: string;
  color?: string;
  folders: string[];
  files?: string[];
};

export type NativeChromeSyncSnapshot = {
  scope: string;
  selected: string | null;
  onSettings: boolean;
  isAdmin: boolean;
  inboxEnabled: boolean;
  inboxUnread: number;
  settingsBadge: number;
  settingsDots: readonly string[];
  projects: readonly ProjectSummary[];
  projectColors?: Readonly<Record<string, string | undefined>>;
  projectFolders?: Readonly<Record<string, readonly string[]>>;
  projectFiles?: Readonly<Record<string, readonly string[]>>;
  missions: readonly Mission[];
  completedMissions: readonly Mission[];
  /** Explicitly archived conversations (`listArchivedMissions`), listed under the native Archived section. */
  archivedMissions?: readonly Mission[];
  projectMissions: Readonly<Record<string, readonly Mission[]>>;
};

type NativeChromeWindow = Window & {
  __ORB_NATIVE_CHROME__?: boolean;
  __ORB_SELECT_MISSION__?: (missionId: string) => boolean;
  __ORB_NATIVE_NAV__?: (target: string) => boolean;
  __ORB_NATIVE_EXPAND__?: (rowId: string) => boolean;
  __ORB_TOGGLE_NATIVE_SIDEBAR__?: (open?: boolean) => boolean;
  __ORB_NATIVE_MISSION_ACTION__?: (action: string, missionId: string, arg?: string) => boolean;
  webkit?: {
    messageHandlers?: {
      orbNative?: {
        postMessage: (msg: Record<string, unknown>) => void;
      };
    };
  };
};

/** True when the native desktop shell installed Hybrid Native Chrome (`window.__ORB_NATIVE_CHROME__ === true`). */
export function isNativeChromeEnabled(win: Window | undefined = typeof window === "undefined" ? undefined : window): boolean {
  if (!win) return false;
  return (win as NativeChromeWindow).__ORB_NATIVE_CHROME__ === true;
}

/**
 * Whether the WebView should collapse its own sidebar because the viewport is narrow.
 *
 * In Hybrid Native Chrome the sidebar and its toolbar (toggle, search, back, forward) live in
 * the native pane beside the WebView, so the WebView's width says nothing about room for a
 * sidebar. Collapsing on a narrow WebView changed only the WebView's idea of the sidebar: the
 * native pane stayed open with its toolbar and the WebView drew a second one.
 */
export function shouldAutoCollapseSidebar(narrowViewport: boolean, nativeChrome: boolean): boolean {
  return narrowViewport && !nativeChrome;
}

export function serializeNativeChromeMission(m: Mission): NativeChromeMissionWire {
  const createdMs = Date.parse(m.created_at || "");
  const updatedMs = Date.parse(m.updated_at || m.created_at || "");
  const forkOf = (forkSource(m) ?? "").trim();
  const hasProject = m.project !== undefined;
  const hasFolder = m.folder !== undefined;
  return {
    id: m.id,
    title: (m.title ?? "").trim() || "Untitled",
    status: m.status || "completed",
    ...(hasProject ? { project: (m.project ?? "").trim() || null } : {}),
    ...(hasFolder ? { folder: (m.folder ?? "").trim() } : {}),
    parent_mission_id: (missionParent(m) ?? "").trim(),
    fork_of: forkOf,
    is_fork: Boolean(forkOf),
    is_btw: isBtwMission(m),
    acknowledged: isArchived(m.status),
    superseded: hasTypedSuperseded(m),
    created_at_ms: Number.isFinite(createdMs) && createdMs > 0 ? Math.floor(createdMs) : 0,
    updated_at_ms: Number.isFinite(updatedMs) && updatedMs > 0 ? Math.floor(updatedMs) : 0,
  };
}

/** Execution state of each row comes from its live-list copy, the single owner that
 *  `syncOpenMission` patches (an optimistic send changes status without a newer `updated_at`).
 *  Stale per-project or completed copies would otherwise win `orb-locald`'s timestamp-tie merge. */
export function withLiveExecution(rows: readonly Mission[], live: ReadonlyMap<string, Mission>): Mission[] {
  return rows.map((row) => {
    const owner = live.get(row.id);
    if (!owner || owner === row) return row;
    return { ...row, status: owner.status, updated_at: owner.updated_at, remote_job: owner.remote_job, execution: owner.execution, queue_wait: owner.queue_wait };
  });
}

export function buildNativeChromeSyncArgs(
  snap: NativeChromeSyncSnapshot,
  revision: number,
): Record<string, unknown> {
  const projects: NativeChromeProjectWire[] = snap.projects.map((p) => {
    const col = snap.projectColors?.[p.slug] ?? p.color ?? "";
    const files = snap.projectFiles?.[p.slug];
    return {
      slug: p.slug,
      name: (p.title ?? "").trim() || p.slug,
      ...(col ? { color: col } : {}),
      folders: [...(snap.projectFolders?.[p.slug] ?? [])],
      ...(files && files.length > 0 ? { files: [...files] } : {}),
    };
  });
  const projectMissionsWire: Record<string, NativeChromeMissionWire[]> = {};
  for (const [slug, rows] of Object.entries(snap.projectMissions)) {
    projectMissionsWire[slug] = rows.map(serializeNativeChromeMission);
  }
  return {
    scope: snap.scope,
    revision,
    selected: snap.selected ?? "new-agent",
    on_settings: snap.onSettings,
    is_admin: snap.isAdmin,
    inbox_enabled: snap.inboxEnabled,
    inbox_unread: snap.inboxUnread,
    settings_badge: snap.settingsBadge,
    settings_dots: [...snap.settingsDots],
    projects,
    missions: snap.missions.map(serializeNativeChromeMission),
    completed_missions: snap.completedMissions.map(serializeNativeChromeMission),
    archived_missions: (snap.archivedMissions ?? []).map(serializeNativeChromeMission),
    project_missions: projectMissionsWire,
  };
}

export type NativeChromeBridgeHandlers = {
  open: (id: string | null) => boolean;
  leaveSettings: () => void;
  navHistory?: (delta: -1 | 1) => void;
  getSidebarOpen: () => boolean;
  setSidebarOpen: (open: boolean) => void;
  selectProject?: (slug: string) => void;
  /** Native "+" on a project or folder row (`new-agent:<slug>[:<folder path>]`): the HTML row's "New agent". */
  newAgent?: (slug: string, path: string) => void;
  /** Native "+" on the Projects section row (`new-project`): the HTML header's "New project". */
  newProject?: () => void;
  getScope?: () => string;
  toggleFolderExpand?: (rowId: string) => void;
  /** Native sidebar context menu: `rename` (arg = new title), `move` (arg = project slug),
   *  `archive`, `restore`, `copy-id`, `settings`, `delete` (arg = space-separated ids or "current"). */
  missionAction?: (action: NativeMissionAction, missionId: string, arg: string) => boolean;
};

/** Mission ids a native action applies to: `delete` lists them in `arg` ("current" = the open
 *  conversation), a bulk `move` lists them in `id`; every other action targets `id` alone. */
export function nativeActionTargets(action: NativeMissionAction, id: string, arg: string, current: string | null): string[] {
  const split = (s: string) => s.split(/\s+/).filter(Boolean);
  if (action === "delete") return arg === "current" ? (current ? [current] : []) : split(arg);
  return action === "move" ? split(id) : id ? [id] : [];
}

export type NativeMissionAction = "rename" | "move" | "archive" | "restore" | "copy-id" | "settings" | "delete";
const NATIVE_MISSION_ACTIONS: readonly string[] = ["rename", "move", "archive", "restore", "copy-id", "settings", "delete"];

/** Notify native macOS/Linux shell when the titlebar sidebar toggle, history state, or Cmd+K shortcut fires inside WebView. */
export function notifyNativeChromeShell(
  command: "set_native_sidebar" | "set_native_history",
  args: Record<string, unknown> = {},
): void {
  if (typeof window === "undefined") return;
  const nw = window as NativeChromeWindow;
  try {
    nw.webkit?.messageHandlers?.orbNative?.postMessage({ command, args });
  } catch {
    // Ignore when running outside WKWebView.
  }
  try {
    window.dispatchEvent(new CustomEvent(`orb:${command}`, { detail: args }));
  } catch {
    // Ignore in synthetic environments.
  }
}

/** Install global `window.__ORB_SELECT_MISSION__` / `window.__ORB_NATIVE_NAV__` handlers and return cleanup. */
export function installNativeChromeWindowHandlers(
  handlers: NativeChromeBridgeHandlers,
  win: Window | undefined = typeof window === "undefined" ? undefined : window,
): () => void {
  if (!win) return () => {};
  const nw = win as NativeChromeWindow;
  const selectMission = (missionId: string): boolean => {
    const clean = (missionId ?? "").trim();
    if (!clean) return false;
    return handlers.open(clean.startsWith("m:") ? clean : `m:${clean}`);
  };
  const nativeNav = (target: string): boolean => {
    const clean = (target ?? "").trim();
    if (!clean || clean === "new-agent") return handlers.open(null);
    if (clean === "settings-back") {
      handlers.leaveSettings();
      return true;
    }
    if (clean === "history-back") {
      handlers.navHistory?.(-1);
      return true;
    }
    if (clean === "history-forward") {
      handlers.navHistory?.(1);
      return true;
    }
    if (clean === "new-project") {
      handlers.newProject?.();
      return Boolean(handlers.newProject);
    }
    if (clean.startsWith("new-agent:")) {
      // Slugs never contain ":", so the first one separates the slug from the folder path.
      const rest = clean.slice("new-agent:".length), cut = rest.indexOf(":");
      const slug = (cut < 0 ? rest : rest.slice(0, cut)).trim(), path = cut < 0 ? "" : rest.slice(cut + 1).trim();
      if (!slug || !handlers.newAgent) return false;
      handlers.newAgent(slug, path);
      return true;
    }
    if (clean.startsWith("m:")) return handlers.open(clean);
    if (clean.startsWith("folder:")) {
      if (handlers.toggleFolderExpand) {
        handlers.toggleFolderExpand(clean);
      } else {
        const scope = handlers.getScope?.();
        void nativeInvoke()?.("native_chrome_toggle_expand", {
          ...(scope ? { scope } : {}),
          row_id: clean,
        }).catch(() => {});
      }
      return true;
    }
    if (clean.startsWith("project:")) {
      const slug = clean.slice("project:".length).trim();
      if (!slug) return false;
      handlers.selectProject?.(slug);
      return handlers.open(null);
    }
    return handlers.open(clean);
  };
  const nativeExpand = (rowId: string): boolean => {
    const clean = (rowId ?? "").trim();
    if (!clean) return false;
    try {
      win.dispatchEvent(new CustomEvent("orb:native-expand", { detail: { rowId: clean } }));
    } catch {
      // Ignore in synthetic environments.
    }
    return true;
  };
  const toggleSidebar = (open?: boolean): boolean => {
    const next = typeof open === "boolean" ? open : !handlers.getSidebarOpen();
    handlers.setSidebarOpen(next);
    return next;
  };
  nw.__ORB_SELECT_MISSION__ = selectMission;
  nw.__ORB_NATIVE_NAV__ = nativeNav;
  nw.__ORB_NATIVE_EXPAND__ = nativeExpand;
  nw.__ORB_TOGGLE_NATIVE_SIDEBAR__ = toggleSidebar;
  const missionAction = (action: string, missionId: string, arg?: string): boolean => {
    const id = (missionId ?? "").trim().replace(/^m:/, "");
    if (!id || !NATIVE_MISSION_ACTIONS.includes(action) || !handlers.missionAction) return false;
    return handlers.missionAction(action as NativeMissionAction, id, (arg ?? "").trim());
  };
  nw.__ORB_NATIVE_MISSION_ACTION__ = missionAction;
  return () => {
    if (nw.__ORB_NATIVE_MISSION_ACTION__ === missionAction) delete nw.__ORB_NATIVE_MISSION_ACTION__;
    if (nw.__ORB_SELECT_MISSION__ === selectMission) delete nw.__ORB_SELECT_MISSION__;
    if (nw.__ORB_NATIVE_NAV__ === nativeNav) delete nw.__ORB_NATIVE_NAV__;
    if (nw.__ORB_NATIVE_EXPAND__ === nativeExpand) delete nw.__ORB_NATIVE_EXPAND__;
    if (nw.__ORB_TOGGLE_NATIVE_SIDEBAR__ === toggleSidebar) delete nw.__ORB_TOGGLE_NATIVE_SIDEBAR__;
  };
}

/** Monotonic microtask/timer-coalesced `native_chrome_sync_state` dispatcher.
 *  Seeds `revision` from `Date.now() * 1024` so WebView reloads (`Cmd+R` or process crash recovery)
 *  always outrank revisions retained in `orb-locald` from an earlier page lifetime. */
export function createNativeChromeSyncer(
  invokeOverride?: ReturnType<typeof nativeInvoke>,
  initialBaseRevision?: number,
) {
  let revision =
    typeof initialBaseRevision === "number" && Number.isFinite(initialBaseRevision) && initialBaseRevision >= 0
      ? Math.floor(initialBaseRevision)
      : Math.max(1, Date.now()) * 1024;
  let pendingSnap: NativeChromeSyncSnapshot | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let unsupported = false;

  const flushNow = async (): Promise<void> => {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    const snap = pendingSnap;
    pendingSnap = null;
    if (!snap || !snap.scope || unsupported) return;
    const invoke = invokeOverride ?? nativeInvoke();
    if (!invoke) return;
    revision += 1;
    const args = buildNativeChromeSyncArgs(snap, revision);
    try {
      await invoke("native_chrome_sync_state", args);
    } catch (err) {
      const msg = String((err as Error)?.message ?? err ?? "");
      if (/unknown desktop command|is not supported in this local runtime/i.test(msg)) {
        unsupported = true;
      }
    }
  };

  const schedule = (snap: NativeChromeSyncSnapshot, immediate = false): void => {
    pendingSnap = snap;
    if (immediate) {
      void flushNow();
      return;
    }
    if (timer !== null) return;
    timer = setTimeout(() => {
      timer = null;
      void flushNow();
    }, 16);
  };

  const dispose = (): void => {
    pendingSnap = null;
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
  };

  return { schedule, flushNow, dispose, currentRevision: () => revision };
}
