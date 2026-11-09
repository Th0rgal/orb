import { createSignal } from "solid-js";
import { readString, writeString } from "./storage";

export type BackgroundSyncMode = "auto" | "on" | "off";

export type BackgroundSyncReason =
  | "healthy"
  | "forced_on"
  | "forced_off"
  | "data_saver"
  | "slow_rtt"
  | "lagged"
  | "unstable";

export type BackgroundSyncPauseReason = "data_saver" | "slow_rtt" | "lagged" | "unstable";

export const MAX_WARM_MISSIONS = 12;
export const SYNC_MAX_PAYLOAD_BYTES = 4096;
export const HIGH_RTT_THRESHOLD_MS = 750;
export const HIGH_RTT_CONSECUTIVE_TRIPS = 2;
export const LOW_RTT_THRESHOLD_MS = 350;
export const LOW_RTT_CONSECUTIVE_RECOVER = 3;
export const DISCONNECT_WINDOW_MS = 60_000;
export const DISCONNECT_BURST_TRIPS = 2;
export const RECOVERY_COOLDOWN_MS = 30_000;

const STORAGE_KEY = "orb:background-sync-mode";

export type BackgroundSyncLinkPauseReason = "slow_rtt" | "lagged" | "unstable";

export interface BackgroundSyncMonitorState {
  mode: BackgroundSyncMode;
  autoPausedReason: BackgroundSyncLinkPauseReason | null;
  dataSaver: boolean;
  slowLink: boolean;
  highRttStreak: number;
  lowRttStreak: number;
  lastPenaltyAtMs: number | null;
  disconnectTimestampsMs: number[];
  lastRttMs?: number;
}

export type BackgroundSyncEvent =
  | { type: "mode"; mode: BackgroundSyncMode }
  | { type: "network"; dataSaver: boolean; slowLink: boolean; nowMs: number }
  | { type: "pong"; rttMs: number; nowMs: number }
  | { type: "lagged"; nowMs: number }
  | { type: "disconnect"; nowMs: number };

export interface BackgroundSyncVerdict {
  mode: BackgroundSyncMode;
  active: boolean;
  reason: BackgroundSyncReason;
  rttMs?: number;
}

export function normalizeBackgroundSyncMode(raw: unknown): BackgroundSyncMode {
  if (typeof raw !== "string") return "auto";
  const clean = raw.trim().toLowerCase();
  if (clean === "on" || clean === "off" || clean === "auto") return clean;
  return "auto";
}

export function createBackgroundSyncMonitorState(
  mode: BackgroundSyncMode = "auto",
): BackgroundSyncMonitorState {
  return {
    mode,
    autoPausedReason: null,
    dataSaver: false,
    slowLink: false,
    highRttStreak: 0,
    lowRttStreak: 0,
    lastPenaltyAtMs: null,
    disconnectTimestampsMs: [],
  };
}

export function stepBackgroundSyncMonitor(
  prev: BackgroundSyncMonitorState,
  event: BackgroundSyncEvent,
): BackgroundSyncMonitorState {
  switch (event.type) {
    case "mode":
      return { ...prev, mode: normalizeBackgroundSyncMode(event.mode) };

    case "network": {
      const constrained = event.dataSaver || event.slowLink;
      return {
        ...prev,
        dataSaver: event.dataSaver,
        slowLink: event.slowLink,
        lowRttStreak: constrained ? 0 : prev.lowRttStreak,
      };
    }

    case "lagged":
      return {
        ...prev,
        autoPausedReason: "lagged",
        lastPenaltyAtMs: event.nowMs,
        highRttStreak: 0,
        lowRttStreak: 0,
      };

    case "disconnect": {
      const recent = prev.disconnectTimestampsMs.filter(
        (ts) => event.nowMs - ts <= DISCONNECT_WINDOW_MS,
      );
      recent.push(event.nowMs);
      const burst = recent.length >= DISCONNECT_BURST_TRIPS;
      return {
        ...prev,
        disconnectTimestampsMs: recent,
        lowRttStreak: 0,
        autoPausedReason: burst ? "unstable" : prev.autoPausedReason,
        lastPenaltyAtMs: burst ? event.nowMs : prev.lastPenaltyAtMs,
      };
    }

    case "pong": {
      const rtt = Math.max(0, Math.round(event.rttMs));
      if (rtt > HIGH_RTT_THRESHOLD_MS) {
        const highRttStreak = prev.highRttStreak + 1;
        const tripped = highRttStreak >= HIGH_RTT_CONSECUTIVE_TRIPS;
        return {
          ...prev,
          lastRttMs: rtt,
          highRttStreak,
          lowRttStreak: 0,
          autoPausedReason: tripped ? "slow_rtt" : prev.autoPausedReason,
          lastPenaltyAtMs: tripped ? event.nowMs : prev.lastPenaltyAtMs,
        };
      }
      if (rtt < LOW_RTT_THRESHOLD_MS) {
        const lowRttStreak = prev.lowRttStreak + 1;
        const cooldownMet =
          prev.lastPenaltyAtMs === null ||
          event.nowMs - prev.lastPenaltyAtMs >= RECOVERY_COOLDOWN_MS;
        const canRecover =
          !prev.dataSaver &&
          !prev.slowLink &&
          prev.autoPausedReason !== null &&
          lowRttStreak >= LOW_RTT_CONSECUTIVE_RECOVER &&
          cooldownMet;
        return {
          ...prev,
          lastRttMs: rtt,
          highRttStreak: 0,
          lowRttStreak,
          autoPausedReason: canRecover ? null : prev.autoPausedReason,
          lastPenaltyAtMs: canRecover ? null : prev.lastPenaltyAtMs,
          disconnectTimestampsMs: canRecover ? [] : prev.disconnectTimestampsMs,
        };
      }
      return {
        ...prev,
        lastRttMs: rtt,
        highRttStreak: 0,
        lowRttStreak: 0,
      };
    }
  }
}

export function evaluateBackgroundSync(
  state: BackgroundSyncMonitorState,
): BackgroundSyncVerdict {
  if (state.mode === "on") {
    return { mode: "on", active: true, reason: "forced_on", rttMs: state.lastRttMs };
  }
  if (state.mode === "off") {
    return { mode: "off", active: false, reason: "forced_off", rttMs: state.lastRttMs };
  }
  if (state.dataSaver || state.slowLink) {
    return { mode: "auto", active: false, reason: "data_saver", rttMs: state.lastRttMs };
  }
  if (state.autoPausedReason !== null) {
    return {
      mode: "auto",
      active: false,
      reason: state.autoPausedReason,
      rttMs: state.lastRttMs,
    };
  }
  return { mode: "auto", active: true, reason: "healthy", rttMs: state.lastRttMs };
}

export function selectWarmMissionIds(params: {
  backgroundActive: boolean;
  maxWarm?: number;
  focusedIds: readonly string[];
  liveIds?: readonly string[];
  recentIds: readonly string[];
  btwByParent?: Readonly<Record<string, string | undefined>>;
  openBtwParentIds?: readonly string[];
}): string[] {
  const maxWarm = Math.max(1, params.maxWarm ?? MAX_WARM_MISSIONS);
  const warmParents: string[] = [];
  const seen = new Set<string>();
  for (const id of params.focusedIds) {
    if (id && !seen.has(id)) {
      seen.add(id);
      warmParents.push(id);
    }
  }
  if (params.backgroundActive) {
    if (params.liveIds) {
      for (const id of params.liveIds) {
        if (warmParents.length >= maxWarm) break;
        if (id && !seen.has(id)) {
          seen.add(id);
          warmParents.push(id);
        }
      }
    }
    for (let i = params.recentIds.length - 1; i >= 0; i--) {
      if (warmParents.length >= maxWarm) break;
      const id = params.recentIds[i];
      if (id && !seen.has(id)) {
        seen.add(id);
        warmParents.push(id);
      }
    }
  }

  const btwParents: string[] = [];
  const btwParentSet = new Set<string>();
  if (params.btwByParent) {
    if (params.backgroundActive) {
      for (const parentId of warmParents) {
        if (params.btwByParent[parentId] && !btwParentSet.has(parentId)) {
          btwParentSet.add(parentId);
          btwParents.push(parentId);
        }
      }
    } else if (params.openBtwParentIds?.length) {
      const openSet = new Set(params.openBtwParentIds);
      for (const parentId of warmParents) {
        if (openSet.has(parentId) && params.btwByParent[parentId] && !btwParentSet.has(parentId)) {
          btwParentSet.add(parentId);
          btwParents.push(parentId);
        }
      }
    }
    if (params.openBtwParentIds?.length) {
      for (const parentId of params.openBtwParentIds) {
        if (parentId && params.btwByParent[parentId] && !btwParentSet.has(parentId)) {
          btwParentSet.add(parentId);
          btwParents.push(parentId);
        }
      }
    }
  }

  const out = [...warmParents];
  if (params.btwByParent) {
    for (const parentId of btwParents) {
      const btwId = params.btwByParent[parentId];
      if (btwId && !seen.has(btwId)) {
        seen.add(btwId);
        out.push(btwId);
      }
    }
  }
  return out;
}

export function describeBackgroundSyncStatus(verdict: BackgroundSyncVerdict): string {
  if (verdict.mode === "on") {
    return "Always keeping recently opened conversations and /btw tabs live in the background.";
  }
  if (verdict.mode === "off") {
    return "Low-bandwidth mode — only streams the open conversation and syncs others when opened.";
  }
  if (verdict.active) {
    const rttSuffix = verdict.rttMs !== undefined ? ` (${verdict.rttMs} ms)` : "";
    return `Active${rttSuffix} — keeping recent conversations live; pauses automatically on slow links.`;
  }
  switch (verdict.reason) {
    case "data_saver":
      return "Paused — Data Saver or slow network detected; syncing conversations on open.";
    case "slow_rtt":
      return `Paused — high latency${verdict.rttMs !== undefined ? ` (${verdict.rttMs} ms)` : ""}; syncing conversations on open.`;
    case "lagged":
      return "Paused — stream backpressure detected; syncing conversations on open.";
    case "unstable":
      return "Paused — unstable connection; syncing conversations on open.";
    default:
      return "Paused — syncing conversations on open.";
  }
}

function readStoredMode(): BackgroundSyncMode {
  return normalizeBackgroundSyncMode(readString(STORAGE_KEY));
}

type BrowserConnectionInfo = {
  saveData?: boolean;
  effectiveType?: string;
  downlink?: number;
  addEventListener?: (type: string, cb: () => void) => void;
};

function readBrowserNetworkConstraint(): { dataSaver: boolean; slowLink: boolean } {
  if (typeof navigator === "undefined") return { dataSaver: false, slowLink: false };
  const conn = (navigator as unknown as { connection?: BrowserConnectionInfo }).connection;
  if (!conn) return { dataSaver: false, slowLink: false };
  const dataSaver = conn.saveData === true;
  const eff = typeof conn.effectiveType === "string" ? conn.effectiveType.toLowerCase() : "";
  const slowEff = eff === "slow-2g" || eff === "2g";
  const slowDownlink = typeof conn.downlink === "number" && conn.downlink > 0 && conn.downlink < 1.0;
  return { dataSaver, slowLink: slowEff || slowDownlink };
}

const initialConstraint = readBrowserNetworkConstraint();
const initialMonitor = stepBackgroundSyncMonitor(
  createBackgroundSyncMonitorState(readStoredMode()),
  {
    type: "network",
    dataSaver: initialConstraint.dataSaver,
    slowLink: initialConstraint.slowLink,
    nowMs: Date.now(),
  },
);

const [monitorState, setMonitorState] = createSignal<BackgroundSyncMonitorState>(initialMonitor);
const listeners = new Set<() => void>();

function notifyIfActiveChanged(prev: BackgroundSyncMonitorState, next: BackgroundSyncMonitorState) {
  if (evaluateBackgroundSync(prev).active !== evaluateBackgroundSync(next).active) {
    for (const cb of listeners) cb();
  }
}

function dispatchMonitorEvent(ev: BackgroundSyncEvent) {
  const prev = monitorState();
  const next = stepBackgroundSyncMonitor(prev, ev);
  setMonitorState(next);
  notifyIfActiveChanged(prev, next);
}

if (typeof navigator !== "undefined") {
  const conn = (navigator as unknown as { connection?: BrowserConnectionInfo }).connection;
  conn?.addEventListener?.("change", () => {
    const c = readBrowserNetworkConstraint();
    dispatchMonitorEvent({
      type: "network",
      dataSaver: c.dataSaver,
      slowLink: c.slowLink,
      nowMs: Date.now(),
    });
  });
}

export function getBackgroundSyncMode(): BackgroundSyncMode {
  return monitorState().mode;
}

export function setBackgroundSyncMode(mode: BackgroundSyncMode): void {
  const clean = normalizeBackgroundSyncMode(mode);
  writeString(STORAGE_KEY, clean);
  dispatchMonitorEvent({ type: "mode", mode: clean });
}

export function getBackgroundSyncVerdict(): BackgroundSyncVerdict {
  return evaluateBackgroundSync(monitorState());
}

export function isBackgroundSyncActive(): boolean {
  return evaluateBackgroundSync(monitorState()).active;
}

export function onBackgroundSyncActiveChange(cb: () => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

export function reportSyncPongRtt(rttMs: number, nowMs = Date.now()): void {
  dispatchMonitorEvent({ type: "pong", rttMs, nowMs });
}

export function reportSyncStreamLagged(nowMs = Date.now()): void {
  dispatchMonitorEvent({ type: "lagged", nowMs });
}

export function reportSyncUnexpectedDisconnect(nowMs = Date.now()): void {
  dispatchMonitorEvent({ type: "disconnect", nowMs });
}

export function resetBackgroundSyncMonitorForTest(): void {
  const mode = readStoredMode();
  const next = createBackgroundSyncMonitorState(mode);
  const prev = monitorState();
  setMonitorState(next);
  notifyIfActiveChanged(prev, next);
}
