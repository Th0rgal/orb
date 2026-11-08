// Single owner of client-side link telemetry (`srttMs`, `rttVarMs`, `consecutiveFailures`,
// `p0InFlight`, `wsConnected`, `lastUpstreamOrigin`) and Lean-verified link budgets.
import { createSignal, untrack } from "solid-js";
import { getBackgroundSyncVerdict } from "./backgroundSync";
import { orbClientLinkBudgetStep, orbRttEwmaStep, type ClientLinkBudget } from "./orbKernel";

export type NetworkHealthStatus = "healthy" | "slow" | "reconnecting";

export type NetworkHealthSnapshot = {
  status: NetworkHealthStatus;
  srttMs: number;
  rttVarMs: number;
  consecutiveFailures: number;
  p0InFlight: number;
  wsConnected: boolean | null;
  lastUpstreamOrigin: string | null;
};

const INITIAL_SNAPSHOT: NetworkHealthSnapshot = {
  status: "healthy",
  srttMs: 0,
  rttVarMs: 0,
  consecutiveFailures: 0,
  p0InFlight: 0,
  wsConnected: null,
  lastUpstreamOrigin: null,
};

let currentState: NetworkHealthSnapshot = INITIAL_SNAPSHOT;
const [snapshot, setSnapshot] = createSignal<NetworkHealthSnapshot>(INITIAL_SNAPSHOT);
const budgetListeners = new Set<() => void>();

let lastNotifiedBudgetKey = "";

function commitState(next: NetworkHealthSnapshot): void {
  currentState = next;
  setSnapshot(next);
}

function notifyBudgetListeners(): void {
  const b = currentLinkBudget();
  const key = `${b.p1Cap}:${b.p2Cap}`;
  if (key === lastNotifiedBudgetKey) return;
  lastNotifiedBudgetKey = key;
  for (const fn of budgetListeners) fn();
}

function deriveStatus(
  srttMs: number,
  consecutiveFailures: number,
  wsConnected: boolean | null,
): NetworkHealthStatus {
  if (consecutiveFailures >= 1 || wsConnected === false) return "reconnecting";
  if (srttMs > 1200) return "slow";
  return "healthy";
}

function isLinkConstrained(): boolean {
  const verdict = untrack(getBackgroundSyncVerdict);
  return verdict.mode === "off" || verdict.reason === "data_saver";
}

export function networkHealthSnapshot(): NetworkHealthSnapshot {
  return snapshot();
}

export function networkHealth(): NetworkHealthStatus {
  return snapshot().status;
}

export function currentLinkBudget(): ClientLinkBudget {
  const s = currentState;
  return orbClientLinkBudgetStep({
    srttMs: s.srttMs,
    rttVarMs: s.rttVarMs,
    consecutiveFailures: s.consecutiveFailures,
    isConstrained: isLinkConstrained(),
    p0InFlight: s.p0InFlight,
  });
}

export function onLinkBudgetChange(listener: () => void): () => void {
  budgetListeners.add(listener);
  return () => {
    budgetListeners.delete(listener);
  };
}

export function recordTransportRttSample(
  sampleMs: number,
  upstreamOrigin?: string | null,
): void {
  if (!Number.isFinite(sampleMs) || sampleMs < 0) return;
  const clamped = Math.max(1, Math.min(60_000, Math.round(sampleMs)));
  const prev = currentState;
  const ewma = orbRttEwmaStep(prev.srttMs, prev.rttVarMs, clamped);
  const nextFailures = 0;
  const nextOrigin = upstreamOrigin?.trim() ? upstreamOrigin.trim() : prev.lastUpstreamOrigin;
  const nextStatus = deriveStatus(ewma.srttMs, nextFailures, prev.wsConnected);
  commitState({
    ...prev,
    srttMs: ewma.srttMs,
    rttVarMs: ewma.rttVarMs,
    consecutiveFailures: nextFailures,
    lastUpstreamOrigin: nextOrigin,
    status: nextStatus,
  });
  notifyBudgetListeners();
}

export function recordTransportFailure(): void {
  const prev = currentState;
  const nextFailures = Math.min(255, prev.consecutiveFailures + 1);
  const nextStatus = deriveStatus(prev.srttMs, nextFailures, prev.wsConnected);
  commitState({
    ...prev,
    consecutiveFailures: nextFailures,
    status: nextStatus,
  });
  notifyBudgetListeners();
}

export function recordSyncWsState(connected: boolean): void {
  const prev = currentState;
  const nextFailures = connected ? 0 : prev.consecutiveFailures;
  const nextStatus = deriveStatus(prev.srttMs, nextFailures, connected);
  commitState({
    ...prev,
    wsConnected: connected,
    consecutiveFailures: nextFailures,
    status: nextStatus,
  });
  notifyBudgetListeners();
}

export function adjustP0InFlight(delta: 1 | -1): void {
  const prev = currentState;
  const nextP0 = Math.max(0, prev.p0InFlight + delta);
  if (nextP0 === prev.p0InFlight) return;
  commitState({
    ...prev,
    p0InFlight: nextP0,
  });
  notifyBudgetListeners();
}

export function resetNetworkHealth(): void {
  commitState(INITIAL_SNAPSHOT);
  notifyBudgetListeners();
}
