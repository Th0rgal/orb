/**
 * Hybrid Native Chrome bridge (`window.__ORB_NATIVE_CHROME__ === true`).
 *
 * When a desktop shell opts into Hybrid Native Chrome (`ORB_NATIVE_CHROME=1` or `?chrome=native`),
 * the native shell (AppKit `NSSplitView` + `NSTableView` + `NSPanel` on macOS, GTK3 `GtkPaned` +
 * `GtkListBox` + `GtkPopover` on Linux) renders the sidebar navigation tree and `Cmd+K` / `Ctrl+K`
 * quick-switcher natively, backed by `OrbLocald.NativeChrome` (`docs/ui/native-chrome.md`).
 *
 * WebView responsibilities in Native Chrome mode:
 * - Omit mounting the HTML `<aside id="orb-sidebar">` subtree to save DOM/style/layout cost.
 * - Sync canonical sidebar inputs (`native_chrome_sync_state`) fenced by a monotonic `revision`.
 * - Expose `window.__ORB_SELECT_MISSION__(id)` (`~0.2 ms` `keepAlivePool` slot switch),
 *   `window.__ORB_NATIVE_NAV__(target)`, and `window.__ORB_TOGGLE_NATIVE_SIDEBAR__(open?)`.
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
  folders: string[];
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
  projectFolders?: Readonly<Record<string, readonly string[]>>;
  missions: readonly Mission[];
  completedMissions: readonly Mission[];
  projectMissions: Readonly<Record<string, readonly Mission[]>>;
};

type NativeChromeWindow = Window & {
  __ORB_NATIVE_CHROME__?: boolean;
  __ORB_SELECT_MISSION__?: (missionId: string) => boolean;
  __ORB_NATIVE_NAV__?: (target: string) => boolean;
  __ORB_TOGGLE_NATIVE_SIDEBAR__?: (open?: boolean) => boolean;
  webkit?: {
    messageHandlers?: {
      orbNative?: {
        postMessage: (msg: Record<string, unknown>) => void;
      };
    };
  };
};

/** True when the desktop shell or URL query (`?chrome=native`) enabled Hybrid Native Chrome. */
export function isNativeChromeEnabled(win: Window | undefined = typeof window === "undefined" ? undefined : window): boolean {
  if (!win) return false;
  const nw = win as NativeChromeWindow;
  if (nw.__ORB_NATIVE_CHROME__ === true) return true;
  if (nw.__ORB_NATIVE_CHROME__ === false) return false;
  try {
    const params = new URLSearchParams(win.location?.search ?? "");
    return params.get("chrome") === "native";
  } catch {
    return false;
  }
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

export function buildNativeChromeSyncArgs(
  snap: NativeChromeSyncSnapshot,
  revision: number,
): Record<string, unknown> {
  const projects: NativeChromeProjectWire[] = snap.projects.map((p) => ({
    slug: p.slug,
    name: (p.title ?? "").trim() || p.slug,
    folders: [...(snap.projectFolders?.[p.slug] ?? [])],
  }));
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
    project_missions: projectMissionsWire,
  };
}

export type NativeChromeBridgeHandlers = {
  open: (id: string | null) => boolean;
  leaveSettings: () => void;
  getSidebarOpen: () => boolean;
  setSidebarOpen: (open: boolean) => void;
  selectProject?: (slug: string) => void;
};

/** Notify native macOS/Linux shell when the titlebar sidebar toggle or Cmd+K shortcut fires inside WebView. */
export function notifyNativeChromeShell(command: "set_native_sidebar" | "open_native_palette", args: Record<string, unknown> = {}): void {
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
    if (clean.startsWith("m:")) return handlers.open(clean);
    if (clean.startsWith("project:")) {
      const slug = clean.slice("project:".length).trim();
      if (!slug) return false;
      handlers.selectProject?.(slug);
      return handlers.open(null);
    }
    return handlers.open(clean);
  };
  const toggleSidebar = (open?: boolean): boolean => {
    const next = typeof open === "boolean" ? open : !handlers.getSidebarOpen();
    handlers.setSidebarOpen(next);
    return next;
  };
  nw.__ORB_SELECT_MISSION__ = selectMission;
  nw.__ORB_NATIVE_NAV__ = nativeNav;
  nw.__ORB_TOGGLE_NATIVE_SIDEBAR__ = toggleSidebar;
  return () => {
    if (nw.__ORB_SELECT_MISSION__ === selectMission) delete nw.__ORB_SELECT_MISSION__;
    if (nw.__ORB_NATIVE_NAV__ === nativeNav) delete nw.__ORB_NATIVE_NAV__;
    if (nw.__ORB_TOGGLE_NATIVE_SIDEBAR__ === toggleSidebar) delete nw.__ORB_TOGGLE_NATIVE_SIDEBAR__;
  };
}

/** Monotonic microtask/timer-coalesced `native_chrome_sync_state` dispatcher. */
export function createNativeChromeSyncer(invokeOverride?: ReturnType<typeof nativeInvoke>) {
  let revision = 0;
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
