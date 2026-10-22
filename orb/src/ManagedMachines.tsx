import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { connectionVersion, isConnected } from "./api";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { Select } from "./Select";
import { pollWhileVisible } from "./poll";
import { useNow } from "./time";
import * as Ic from "./icons";
import {
  allowedSizes, budgetLine, createManagedMachine, destroyManagedMachine, estimateCost, extendManagedMachine, isLive,
  listManagedMachines, liveCost, managedNodeIds, managedError, minutesLabel, recentMachines, sizeSpec, stateLabel, ttlLeft, ttlUrgent,
  usd, usdPerHour, type ManagedMachine, type ManagedMachinesResponse,
} from "./managedMachineModel";

const openMission = (id: string) => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: `m:${id}` }));

/** TTL choices up to the budget's maximum, always including the default. */
export function ttlChoices(defaultMinutes: number, maxMinutes: number): number[] {
  const set = new Set([15, 30, 60, 120, 240, 480, 720, 1440, defaultMinutes, maxMinutes].filter(m => m > 0 && m <= maxMinutes));
  return [...set].sort((a, b) => a - b);
}

function ManagedRow(p: { m: ManagedMachine; fetchedAt: number; busy: boolean; onDestroy: () => void; onExtend: () => void }) {
  const now = useNow(1000);
  const live = () => isLive(p.m);
  const dot = () => p.m.state === "online" ? "on" : p.m.state === "failed" ? "off" : live() ? "warn" : "";
  return <div class="m-row managed-row" data-state={p.m.state}>
    <span class={`m-dot ${dot()}`} />
    <div class="m-text">
      <div class="m-name">{p.m.size}<span class="m-tag">{stateLabel(p.m.state)}</span>
        <Show when={p.m.owner_mission_id}><button class="sb-link managed-owner" title="Open the mission that owns this machine" onClick={() => openMission(p.m.owner_mission_id!)}>Mission {p.m.owner_mission_id!.slice(0, 8)}</button></Show>
      </div>
      <div class="m-meta">
        <span>{sizeSpec(p.m)}</span><span class="p-dot">·</span>
        <Show when={live()} fallback={<span>Final {usd(p.m.cost_usd)}{p.m.ledger_closed ? " · Ledger closed" : " · Ledger open"}</span>}>
          <span class={ttlUrgent(p.m.expires_at, now()) ? "managed-urgent" : ""} title={`Expires ${new Date(p.m.expires_at).toLocaleString()}`}>{ttlLeft(p.m.expires_at, now())} left</span><span class="p-dot">·</span>
          <span>{usd(liveCost(p.m, p.fetchedAt, now()))} · {usdPerHour(p.m.usd_per_hour)}</span>
        </Show>
      </div>
      <Show when={p.m.error || p.m.reason}><div class="m-note">{p.m.error ?? p.m.reason}</div></Show>
    </div>
    <Show when={live() && p.m.state !== "destroying"}>
      <button class="s-btn sm quiet" disabled={p.busy} onClick={p.onExtend}>+1 h</button>
      <button class="s-btn sm quiet danger" disabled={p.busy} onClick={p.onDestroy}>Destroy</button>
    </Show>
  </div>;
}

function NewManagedMachine(p: { data: ManagedMachinesResponse; onClose: () => void; onCreated: (m: ManagedMachine) => void }) {
  const sizes = () => allowedSizes(p.data.sizes, p.data.budget.max_size);
  const [size, setSize] = createSignal(sizes().find(s => s.size === p.data.budget.default_size)?.size ?? sizes()[0]?.size ?? "");
  const [ttl, setTtl] = createSignal(Math.min(p.data.budget.default_ttl_minutes, p.data.budget.max_ttl_minutes));
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const chosen = () => sizes().find(s => s.size === size());
  const estimate = () => chosen() ? estimateCost(chosen()!.usd_per_hour, ttl()) : 0;
  const remaining = () => p.data.budget.daily_cap_usd - p.data.budget.spent_today_usd;
  const submit = async () => {
    if (busy() || !chosen()) return;
    setBusy(true); setError(null);
    try { p.onCreated(await createManagedMachine({ size: size(), ttl_minutes: ttl() })); }
    catch (e) { setError(managedError(e)); }
    finally { setBusy(false); }
  };
  return <Dialog title="New managed machine" description="A boat.dev machine that joins the fleet and is destroyed when its time runs out." busy={busy()} persistent onClose={p.onClose}
    footer={close => <><DialogButton disabled={busy()} onClick={close}>Cancel</DialogButton><DialogButton variant="primary" disabled={busy() || !chosen()} onClick={submit}>{busy() ? "Creating…" : "Create machine"}</DialogButton></>}>
    <div class="managed-form">
      <div class="field"><label>Size</label>
        <div class="managed-sizes" role="radiogroup" aria-label="Size">
          <For each={sizes()}>{s => <button type="button" role="radio" aria-checked={s.size === size()} class={`managed-size ${s.size === size() ? "on" : ""}`} disabled={busy()} onClick={() => setSize(s.size)}>
            <span class="managed-size-name">{s.size}</span><span class="managed-size-spec">{sizeSpec(s)}</span><span class="managed-size-rate">{usdPerHour(s.usd_per_hour)}</span>
          </button>}</For>
        </div>
      </div>
      <Field label="Time to live" description={`Up to ${minutesLabel(p.data.budget.max_ttl_minutes)}. You can extend it later.`}>
        <Select class="s-input" value={String(ttl())} disabled={busy()} onChange={e => setTtl(Number(e.currentTarget.value))}>
          <For each={ttlChoices(p.data.budget.default_ttl_minutes, p.data.budget.max_ttl_minutes)}>{m => <option value={m}>{minutesLabel(m)}</option>}</For>
        </Select>
      </Field>
      <div class="managed-estimate"><span>Estimated cost</span><strong>{usd(estimate())}</strong></div>
      <Show when={estimate() > remaining()}><div class="m-note managed-urgent">Exceeds today’s remaining budget of {usd(Math.max(0, remaining()))}.</div></Show>
      <Show when={error()}><ErrorNotice title="Couldn’t create the machine" error={error()!} /></Show>
    </div>
  </Dialog>;
}

/** "Managed (boat.dev)" section of the Machines page. Renders nothing when the
 * backend lacks the endpoint or has the feature disabled. */
export function ManagedMachines(p: { onDestroyed?: (nodeIds: string[]) => void } = {}) {
  const [data, setData] = createSignal<ManagedMachinesResponse | null>(null);
  const [fetchedAt, setFetchedAt] = createSignal(Date.now());
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const [creating, setCreating] = createSignal(false);
  const [confirm, setConfirm] = createSignal<ManagedMachine | null>(null);
  const [busy, setBusy] = createSignal<string | null>(null);
  const [actionError, setActionError] = createSignal<string | null>(null);
  const [showRecent, setShowRecent] = createSignal(false);
  const version = connectionVersion();

  const refresh = async () => {
    try {
      const r = await listManagedMachines();
      if (version !== connectionVersion()) return;
      setData(r); setFetchedAt(Date.now()); setLoadError(null);
    } catch (e) { setLoadError(managedError(e)); }
  };
  onMount(() => {
    if (isConnected()) void refresh();
    onCleanup(pollWhileVisible(() => (isConnected() ? refresh() : undefined), 15000, "managed"));
  });
  const replace = (m: ManagedMachine) => setData(d => d && { ...d, machines: [m, ...d.machines.filter(x => x.id !== m.id)] });
  const run = async (id: string, action: () => Promise<ManagedMachine>) => {
    setBusy(id); setActionError(null);
    try { replace(await action()); setFetchedAt(Date.now()); void refresh(); return true; }
    catch (e) { setActionError(managedError(e)); return false; }
    finally { setBusy(null); }
  };
  const live = createMemo(() => (data()?.machines ?? []).filter(isLive));
  const recent = createMemo(() => recentMachines(data()?.machines ?? []));
  const full = () => { const b = data()?.budget; return !!b && (b.active >= b.max_concurrent || b.spent_today_usd >= b.daily_cap_usd); };

  return <Show when={isConnected() && data()?.enabled}>
    <div class="managed-head">
      <h3 class="s-section-title">Managed (boat.dev)</h3>
      <button class="s-btn sm quiet" disabled={full()} title={full() ? "Daily budget or machine limit reached" : undefined} onClick={() => setCreating(true)}><Ic.PlusIcon size={14} />New managed machine</button>
    </div>
    <div class="m-note managed-budget">{budgetLine(data()!.budget)}</div>
    <Show when={actionError() && !confirm()}><ErrorNotice error={actionError()!} onDismiss={() => setActionError(null)} /></Show>
    <Show when={loadError()}><ErrorNotice title="Couldn’t refresh managed machines" error={loadError()!} /></Show>
    <div class="m-list s-card managed-list">
      <For each={live()}>{m => <ManagedRow m={m} fetchedAt={fetchedAt()} busy={busy() === m.id}
        onExtend={() => void run(m.id, () => extendManagedMachine(m.id, 60))} onDestroy={() => setConfirm(m)} />}</For>
      <Show when={live().length === 0}><div class="m-note" style={{ padding: "10px 14px" }}>No managed machines running.</div></Show>
    </div>
    <Show when={recent().length}>
      <button class="s-btn sm quiet managed-recent-toggle" aria-expanded={showRecent()} onClick={() => setShowRecent(!showRecent())}>
        <span class={`chev p-acc-chev ${showRecent() ? "open" : ""}`}>›</span>Recent · last 24 h ({recent().length})
      </button>
      <Show when={showRecent()}><div class="m-list s-card managed-list managed-recent">
        <For each={recent()}>{m => <ManagedRow m={m} fetchedAt={fetchedAt()} busy={false} onExtend={() => {}} onDestroy={() => {}} />}</For>
      </div></Show>
    </Show>
    <Show when={creating()}>
      <NewManagedMachine data={data()!} onClose={() => setCreating(false)} onCreated={m => { setCreating(false); replace(m); void refresh(); }} />
    </Show>
    <Show when={confirm()}>{m => <ConfirmDialog title={`Destroy ${m().size} machine?`} destructive action="Destroy"
      description={`The machine and everything on it are deleted now${m().owner_mission_id ? `, and mission ${m().owner_mission_id!.slice(0, 8)} loses it` : ""}. Cost so far: ${usd(liveCost(m(), fetchedAt()))}.`}
      busy={busy() === m().id} error={actionError()} onClose={() => setConfirm(null)}
      onConfirm={async () => { const gone = m(); if (await run(gone.id, () => destroyManagedMachine(gone.id))) { setConfirm(null); p.onDestroyed?.(managedNodeIds(gone)); } }} />}</Show>
  </Show>;
}
