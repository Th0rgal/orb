// Priority request scheduler (`P0 > P1 > P2`) governed by `orb_client_link_budget_step`.
// - `P0`: user mutations, approvals, auth/health checks -> dispatched immediately (0 queueing)
//         and increments `p0InFlight` so `P2` background sweeps pause until the mutation settles.
// - `P1`: active conversation transcript/mission reads & sidebar sync -> bounded by `p1Cap`.
// - `P2`: background software sweeps, transcript prefetches, stats, file tree warmups -> bounded
//         by `p2Cap` (`0` whenever `p0InFlight > 0`, `srtt > 1200 ms`, `consecutiveFailures > 0`, or constrained).
import { adjustP0InFlight, currentLinkBudget, onLinkBudgetChange } from "./networkHealth";

export type RequestPriority = "p0" | "p1" | "p2";

type QueuedTask = {
  priority: "p1" | "p2";
  signal?: AbortSignal | null;
  start: () => void;
  abortHandler?: () => void;
};

let p1Active = 0;
let p2Active = 0;
const p1Queue: QueuedTask[] = [];
const p2Queue: QueuedTask[] = [];

export function classifyClientRequestPriority(
  methodRaw: string | undefined,
  path: string,
  explicit?: RequestPriority,
): RequestPriority {
  if (explicit) return explicit;
  const method = (methodRaw ?? "GET").trim().toUpperCase();
  const cleanPath = path.split("?")[0] ?? path;
  if (
    cleanPath === "/api/file-resources" ||
    cleanPath.endsWith("/inbox-digest") ||
    cleanPath.endsWith("/opened") ||
    cleanPath.startsWith("/api/control/inbox-state/seen/")
  ) {
    return "p1";
  }
  if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
    return "p0";
  }
  if (
    cleanPath === "/api/health" ||
    cleanPath.startsWith("/api/auth/") ||
    cleanPath.startsWith("/api/bitwarden/") ||
    cleanPath.startsWith("/api/privilege-access/")
  ) {
    return "p0";
  }
  if (
    cleanPath.startsWith("/api/software") ||
    cleanPath.startsWith("/api/stats") ||
    cleanPath.startsWith("/api/providers/antigravity-models") ||
    cleanPath.startsWith("/api/antigravity-models") ||
    cleanPath.startsWith("/api/crons") ||
    cleanPath.startsWith("/api/library/skill-delivery") ||
    cleanPath.startsWith("/api/ai/providers/usage") ||
    cleanPath.startsWith("/api/usage-telemetry") ||
    cleanPath.startsWith("/api/remote-nodes") ||
    cleanPath.endsWith("/context/conflicts") ||
    cleanPath.endsWith("/files") ||
    cleanPath.includes("/files/")
  ) {
    return "p2";
  }
  return "p1";
}

function pumpQueues(): void {
  const budget = currentLinkBudget();
  const p1Limit = Math.max(1, budget.p1Cap);
  while (p1Active < p1Limit && p1Queue.length > 0) {
    const task = p1Queue.shift()!;
    if (task.signal && task.abortHandler) {
      task.signal.removeEventListener("abort", task.abortHandler);
    }
    if (task.signal?.aborted) continue;
    p1Active++;
    task.start();
  }
  const p2Limit = Math.max(0, budget.p2Cap);
  while (p2Active < p2Limit && p2Queue.length > 0) {
    const task = p2Queue.shift()!;
    if (task.signal && task.abortHandler) {
      task.signal.removeEventListener("abort", task.abortHandler);
    }
    if (task.signal?.aborted) continue;
    p2Active++;
    task.start();
  }
}

onLinkBudgetChange(pumpQueues);

function makeAbortError(signal: AbortSignal): unknown {
  if (signal.reason !== undefined) return signal.reason;
  return new DOMException("The operation was aborted.", "AbortError");
}

export function scheduleTransportRequest<T>(
  priority: RequestPriority,
  signal: AbortSignal | null | undefined,
  execute: () => Promise<T>,
): Promise<T> {
  if (signal?.aborted) {
    return Promise.reject(makeAbortError(signal));
  }
  if (priority === "p0") {
    adjustP0InFlight(1);
    let p: Promise<T>;
    try {
      p = execute();
    } catch (err) {
      adjustP0InFlight(-1);
      return Promise.reject(err);
    }
    void p.then(
      () => adjustP0InFlight(-1),
      () => adjustP0InFlight(-1),
    );
    return p;
  }

  const budget = currentLinkBudget();
  const limit = priority === "p1" ? Math.max(1, budget.p1Cap) : Math.max(0, budget.p2Cap);
  const activeCount = priority === "p1" ? p1Active : p2Active;
  const targetQueue = priority === "p1" ? p1Queue : p2Queue;
  if (targetQueue.length === 0 && activeCount < limit) {
    if (priority === "p1") p1Active++;
    else p2Active++;
    let runPromise: Promise<T>;
    try {
      runPromise = execute();
    } catch (err) {
      if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
      else p2Active = Math.max(0, p2Active - 1);
      pumpQueues();
      return Promise.reject(err);
    }
    void runPromise.then(
      () => {
        if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
        else p2Active = Math.max(0, p2Active - 1);
        pumpQueues();
      },
      () => {
        if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
        else p2Active = Math.max(0, p2Active - 1);
        pumpQueues();
      },
    );
    return runPromise;
  }

  return new Promise<T>((resolve, reject) => {
    const task: QueuedTask = {
      priority,
      signal,
      start: () => {
        let runPromise: Promise<T>;
        try {
          runPromise = execute();
        } catch (err) {
          if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
          else p2Active = Math.max(0, p2Active - 1);
          pumpQueues();
          reject(err);
          return;
        }
        runPromise.then(
          (val) => {
            if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
            else p2Active = Math.max(0, p2Active - 1);
            pumpQueues();
            resolve(val);
          },
          (err) => {
            if (priority === "p1") p1Active = Math.max(0, p1Active - 1);
            else p2Active = Math.max(0, p2Active - 1);
            pumpQueues();
            reject(err);
          },
        );
      },
    };
    if (signal) {
      const onAbort = () => {
        const idx = targetQueue.indexOf(task);
        if (idx >= 0) {
          targetQueue.splice(idx, 1);
          reject(makeAbortError(signal));
        }
      };
      task.abortHandler = onAbort;
      signal.addEventListener("abort", onAbort, { once: true });
    }
    targetQueue.push(task);
    pumpQueues();
  });
}

export function transportSchedulerStats(): {
  p1Active: number;
  p2Active: number;
  p1Queued: number;
  p2Queued: number;
} {
  return {
    p1Active,
    p2Active,
    p1Queued: p1Queue.length,
    p2Queued: p2Queue.length,
  };
}

export function resetTransportSchedulerForTest(): void {
  p1Active = 0;
  p2Active = 0;
  p1Queue.length = 0;
  p2Queue.length = 0;
}
