import {createEffect, createMemo, createSignal, onCleanup, Show} from 'solid-js';
import {api, connectionVersion, isConnected} from './api';
import {copyText} from './clipboard';
import type {StreamItem} from './transcriptModel';

export type Reminder = {origin: string; seconds?: number};
/** Legacy wakeups have no source: attribute only an exact successful tool prompt. */
export function reminderMessages(items: StreamItem[]): Map<string, Reminder> {
  const scheduled = new Map<string, Reminder>(), result = new Map<string, Reminder>();
  for (const item of items) {
    if (item.kind === 'tool' && item.done && !item.unresolved && /(?:^|__)schedule_?wakeup$/i.test(item.name)) {
      const args = item.args as Record<string, unknown> | null;
      const output = item.result as Record<string, unknown> | null;
      if (args && typeof args.prompt === 'string' && !output?.error && output?.isError !== true) {
        const seconds = Number(args.delaySeconds ?? args.delay_seconds);
        scheduled.set(args.prompt, {origin: item.name === 'ScheduleWakeup' ? 'Scheduled by Claude' : 'Scheduled by the agent', seconds: Number.isFinite(seconds) && seconds > 0 ? seconds : undefined});
      }
    }
    if (item.kind === 'user') {
      const reminder = (!item.source || item.source === 'scheduler') ? scheduled.get(item.text) : undefined;
      if (reminder || item.source === 'scheduler') result.set(item.key, reminder ?? {origin: 'Mission scheduler'});
      scheduled.delete(item.text);
    }
  }
  return result;
}

export function AutomaticReminder(p: {text: string; reminder: Reminder}) {
  const [copied, setCopied] = createSignal('');
  return <details class="automatic-reminder">
    <summary><span aria-hidden="true">◷</span><strong>Automatic reminder</strong><span class="reminder-origin">{p.reminder.origin}<Show when={p.reminder.seconds}> · after {Math.round(p.reminder.seconds! / 60)} min</Show></span><span class="reminder-summary">Resume mission follow-up</span></summary>
    <div class="reminder-details"><pre>{p.text}</pre><button class="s-btn sm" onClick={() => void copyText(p.text).then(() => setCopied('Copied'), () => setCopied('Copy failed'))}>Copy instructions</button><span role="status">{copied()}</span></div>
  </details>;
}

type Wakeup = {active: boolean; driver?: string; trigger: {type: string; seconds?: number}; stop_policy: {type: string}; created_at: string; last_triggered_at?: string | null; variables?: Record<string,string>};
export function nextReminder(rows: Wakeup[]): number | undefined {
  const dates = rows.filter(row => row.active && row.driver !== 'harness' && row.stop_policy.type === 'after_first_fire' && row.trigger.type === 'interval')
    .map(row => Date.parse(row.last_triggered_at ?? row.created_at) + (row.trigger.seconds ?? NaN) * 1000).filter(Number.isFinite);
  return dates.length ? Math.min(...dates) : undefined;
}
export function NextReminder(p: {mission: string; busy: boolean}) {
  const [due, setDue] = createSignal<number>(), [now, setNow] = createSignal(Date.now());
  createEffect(() => {
    const mission = p.mission; connectionVersion(); setDue(undefined);
    if (!mission || !isConnected()) return;
    let alive = true, timer: ReturnType<typeof setTimeout>;
    const refresh = async () => {
      try { const rows = await api<Wakeup[]>(`/api/control/missions/${encodeURIComponent(mission)}/automations`); if (alive) setDue(nextReminder(rows)); }
      catch { if (alive) setDue(undefined); }
      if (alive) timer = setTimeout(refresh, 30000);
    };
    void refresh();
    const clock = setInterval(() => setNow(Date.now()), 10000);
    onCleanup(() => {alive = false; clearTimeout(timer); clearInterval(clock);});
  });
  const remaining = createMemo(() => due() === undefined ? 0 : Math.max(0, Math.ceil((due()! - now()) / 60000)));
  return <Show when={due() !== undefined && !p.busy}><div class="next-reminder"><span aria-hidden="true">◷</span> Next reminder at {new Date(due()!).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'})} · {remaining() ? `in ${remaining()} min` : 'waiting to run'}</div></Show>;
}
