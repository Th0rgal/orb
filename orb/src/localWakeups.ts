import { createSignal } from "solid-js";
import { connectionVersion, getApiUrl, getJwt } from "./api";
import { nativeInvoke } from "./clientRuns";
import type { Continuation, ContinuationSummary } from "./continuations";
const [pending, setPending] = createSignal<(Continuation & { mission: string })[]>([]);
export function localContinuation(mission?: string): ContinuationSummary | undefined {
  const items = pending().filter(item => item.mission === mission);
  return items.length ? { count: items.length, items } : undefined;
}
/** A pending Stop is recovered before any new native launch is allowed. */
export async function replayLocalWakeupStops(valid:()=>boolean=()=>true) {
  const invoke=nativeInvoke(),version=connectionVersion();
  if(!invoke||!getJwt())return;
  const connection={api_url:getApiUrl(),token:getJwt()};
  const queue=await import("./localMessageQueue");
  await queue.replayWakeupStops((mission,cancelToken)=>invoke("local_wakeups_cancel",{mission,connection,cancelToken}),()=>valid()&&version===connectionVersion());
  if(!valid()||version!==connectionVersion())throw new Error("Connection changed during Stop recovery");
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
      const connection={api_url:getApiUrl(),token:getJwt()};
      await replayLocalWakeupStops(()=>!stopped&&version===connectionVersion());
      if(stopped||version!==connectionVersion())return;
      const result = await invoke("local_wakeups_sync", { connection }) as { pending: (Continuation & { mission: string })[]; changed: boolean; cancelled?: {mission:string;token:string}[] };
      if (stopped || version !== connectionVersion()) return;
      await import("./localMessageQueue").then(m => { if (!stopped && version === connectionVersion()) return m.confirmWakeupStops(result.cancelled ?? []); });
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

export async function discardLocalWakeup(mission: string, requestId: string) {
  const invoke = nativeInvoke();
  if (!invoke) throw new Error("Open this mission on its originating computer to dismiss the rejected wake-up");
  await invoke("local_wakeups_discard", {mission, requestId, connection: {api_url: getApiUrl(), token: getJwt()}});
  setPending(items => items.filter(item => item.mission !== mission || item.id !== requestId));
}
