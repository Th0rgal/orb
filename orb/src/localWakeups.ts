import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, getJwt } from "./api";
import { nativeInvoke } from "./clientRuns";
import type { Continuation, ContinuationSummary } from "./continuations";
const [pending, setPending] = createSignal<(Continuation & { mission: string })[]>([]);
export function localContinuation(mission?: string): ContinuationSummary | undefined {
  const items = pending().filter(item => item.mission === mission);
  return items.length ? { count: items.length, items } : undefined;
}
export function startLocalWakeups() {
  const invoke = nativeInvoke(), version = connectionVersion();
  let stopped = false, busy = false;
  setPending([]);
  if (!invoke) return () => {};
  const tick = async () => {
    if (stopped || busy || !getJwt() || version !== connectionVersion()) return;
    busy = true;
    try {
      const result = await invoke("local_wakeups_sync", { connection: { api_url: getApiUrl(), token: getJwt() } }) as { pending: (Continuation & { mission: string })[]; changed: boolean };
      if (stopped || version !== connectionVersion()) return;
      setPending(result.pending);
      if (result.changed) window.dispatchEvent(new Event("orb:refresh"));
    } catch { /* Older native versions do not advertise local scheduling. */ }
    finally { busy = false; }
  };
  void tick();
  const timer = window.setInterval(() => void tick(), 5000);
  return () => { stopped = true; clearInterval(timer); };
}
