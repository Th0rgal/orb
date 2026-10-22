import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { api, connectionVersion, isConnected } from "./api";
import { swallow } from "./log";
import { PopupMenu, type MenuEntry } from "./Menu";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { Select } from "./Select";
import { pollWhileVisible } from "./poll";
import { useNow } from "./time";
import * as Ic from "./icons";
import {
  allowedSizes, budgetFull, budgetLeft, budgetLine, costLine, sizeLabel, specLine, ttlFraction, ttlShort, createManagedMachine, destroyManagedMachine, estimateCost, extendManagedMachine, isLive,
  isStarting, listManagedMachines, liveCost, machineName, managedNodeIds, managedError, minutesLabel, recentMachines, sizeSpec, stateLabel, ttlLeft, ttlUrgent,
  usd, usdPerHour, type CreateManagedMachine, type ManagedMachine, type ManagedMachinesResponse, type ManagedSize,
} from "./managedMachineModel";

const openMission = (id: string) => window.dispatchEvent(new CustomEvent("orb:open-page", { detail: `m:${id}` }));

/** TTL choices up to the budget's maximum, always including the default. */
export function ttlChoices(defaultMinutes: number, maxMinutes: number): number[] {
  const set = new Set([15, 30, 60, 120, 240, 480, 720, 1440, defaultMinutes, maxMinutes].filter(m => m > 0 && m <= maxMinutes));
  return [...set].sort((a, b) => a - b);
}

export type RowActions = { busy?: boolean; onDestroy?: () => void; onExtend?: () => void; onRetry?: () => void; onDismiss?: () => void };

// Mission titles for owner chips: fetched once per id and shared by every row.
const [titles, setTitles] = createSignal<ReadonlyMap<string, string>>(new Map());
const titleRequests = new Set<string>();
export function missionTitle(id: string): string | undefined {
  if (!titleRequests.has(id)) {
    titleRequests.add(id);
    void api<{ title?: string | null }>(`/api/control/missions/${encodeURIComponent(id)}`)
      .then(m => { if (m?.title) setTitles(t => new Map(t).set(id, m.title!)); })
      .catch(swallow("managed.missionTitle", { id }));
  }
  return titles().get(id);
}

/** Small ring that empties as the TTL runs out. */
function TtlRing(p: { fraction: number; urgent: boolean }) {
  const r = 5, c = 2 * Math.PI * r;
  return <svg class="managed-ttl-ring" classList={{ urgent: p.urgent }} width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
    <circle cx="7" cy="7" r={r} class="track" /><circle cx="7" cy="7" r={r} class="fill" stroke-dasharray={`${c * p.fraction} ${c}`} transform="rotate(-90 7 7)" />
  </svg>;
}

function ManagedRow(p: { m: ManagedMachine; fetchedAt: number; disk?: number | null; muted?: boolean } & RowActions) {
  const now = useNow(1000);
  const live = () => isLive(p.m);
  const starting = () => isStarting(p.m);
  const failed = () => p.m.state === "failed";
  const destroying = () => p.m.state === "destroying";
  const dot = () => p.m.state === "online" ? "on" : failed() ? "off" : live() ? "warn" : "";
  const details = () => [p.m.reason ? `Reason: ${p.m.reason}` : "", p.m.id && !p.m.id.startsWith("pending-") ? `Machine ${p.m.id}` : "", p.m.provider_id ? `${p.m.provider} ${p.m.provider_id}` : "", p.m.node_id ? `Node ${p.m.node_id}` : "", p.m.image ? `Image ${p.m.image}` : ""].filter(Boolean).join("\n");
  const owner = () => p.m.owner_mission_id ?? undefined;
  const ownerTitle = () => owner() ? missionTitle(owner()!) ?? `Mission ${owner()!.slice(0, 8)}` : "";
  const canAct = () => live() && !destroying() && !!p.onDestroy;
  const [menu, setMenu] = createSignal<{ x: number; y: number } | null>(null);
  const menuItems = (): MenuEntry[] => [
    ...(!starting() ? [{ kind: "item" as const, label: "Extend +1 h", disabled: p.busy, onClick: () => p.onExtend?.() }] : []),
    { kind: "item", label: "Destroy", danger: true, disabled: p.busy, onClick: () => p.onDestroy?.() },
  ];
  return <div class="managed-row" classList={{ "managed-fading": destroying(), "managed-muted": !!p.muted }} data-state={p.m.state} title={details() || undefined}>
    <div class="managed-main">
      <div class="managed-line1">
        <span class="managed-status-icon"><Show when={starting() || destroying()} fallback={<span class={`m-dot ${dot()}`} />}><Ic.Spinner size={12} class="managed-spinner" /></Show></span>
        <span class="managed-name">{machineName(p.m)}</span>
        <span class="managed-size-label">{sizeLabel(p.m.size)}</span>
        <span class="managed-state" classList={{ "managed-error": failed() }}>{stateLabel(p.m.state)}</span>
        <Show when={owner()}><button class="managed-mission-chip" title={`Open ${ownerTitle()}`} onClick={() => openMission(owner()!)}><span>{ownerTitle()}</span></button></Show>
      </div>
      <div class="managed-line2">
        <span class="managed-spec">{specLine({ cpu: p.m.cpu, ram_gb: p.m.ram_gb, disk_gb: p.disk })}</span>
        <Show when={live()} fallback={<Show when={!failed() || p.m.destroyed_at}><span class="managed-cost">Final {usd(p.m.cost_usd)}{p.m.ledger_closed ? " · ledger closed" : " · ledger open"}</span></Show>}>
          <Show when={p.m.expires_at}><span class="managed-ttl" classList={{ "managed-urgent": ttlUrgent(p.m.expires_at, now()) }} title={`Expires ${new Date(p.m.expires_at).toLocaleString()}`}>
            <TtlRing fraction={ttlFraction(p.m.created_at, p.m.expires_at, now())} urgent={ttlUrgent(p.m.expires_at, now())} />{ttlShort(p.m.expires_at, now())}</span></Show>
          <span class="managed-cost">{costLine(liveCost(p.m, p.fetchedAt, now()), p.m.usd_per_hour)}</span>
        </Show>
      </div>
      <Show when={p.m.error}><div class="managed-line2 managed-error" role="alert">{p.m.error}</div></Show>
    </div>
    <div class="managed-actions">
      <Show when={failed() && (p.onRetry || p.onDismiss)}>
        <Show when={p.onRetry}><button class="s-btn sm" disabled={p.busy} onClick={p.onRetry}>Retry</button></Show>
        <Show when={p.onDismiss}><button class="s-btn sm quiet" onClick={p.onDismiss}>Dismiss</button></Show>
      </Show>
      <Show when={canAct()}>
        <span class="managed-inline-actions">
          <Show when={!starting()}><button class="s-btn sm" disabled={p.busy} onClick={p.onExtend}>Extend +1 h</button></Show>
          <button class="s-btn sm quiet danger" disabled={p.busy} onClick={p.onDestroy}>Destroy</button>
        </span>
        <button class="icon-btn sm managed-more" aria-label={`Actions for ${machineName(p.m)}`} aria-haspopup="menu" onClick={e => { const r = e.currentTarget.getBoundingClientRect(); setMenu({ x: r.right - 160, y: r.bottom + 4 }); }}><Ic.DotsIcon size={16} /></button>
        <Show when={menu()}>{at => <PopupMenu x={at().x} y={at().y} items={menuItems()} onClose={() => setMenu(null)} />}</Show>
      </Show>
    </div>
  </div>;
}

function NewManagedMachine(p: { data: ManagedMachinesResponse; onClose: () => void; onCreate: (request: CreateManagedMachine, size: ManagedSize) => void }) {
  const sizes = () => allowedSizes(p.data.sizes, p.data.budget.max_size);
  const [size, setSize] = createSignal(sizes().find(s => s.size === p.data.budget.default_size)?.size ?? sizes()[0]?.size ?? "");
  const [ttl, setTtl] = createSignal(Math.min(p.data.budget.default_ttl_minutes, p.data.budget.max_ttl_minutes));
  const chosen = () => sizes().find(s => s.size === size());
  const estimate = () => chosen() ? estimateCost(chosen()!.usd_per_hour, ttl()) : 0;
  const remaining = () => budgetLeft(p.data.budget);
  // The dialog closes at once; the row shows progress and any refusal.
  const submit = () => { if (chosen()) p.onCreate({ size: size(), ttl_minutes: ttl() }, chosen()!); };
  return <Dialog title="New managed machine" description="A boat.dev machine that joins the fleet and is destroyed when its time runs out." persistent onClose={p.onClose}
    footer={close => <><DialogButton onClick={close}>Cancel</DialogButton><DialogButton variant="primary" disabled={!chosen()} onClick={submit}>Create machine</DialogButton></>}>
    <div class="managed-form">
      <div class="field"><label>Size</label>
        <div class="managed-sizes" role="radiogroup" aria-label="Size">
          <For each={sizes()}>{s => <button type="button" role="radio" aria-checked={s.size === size()} class={`managed-size ${s.size === size() ? "on" : ""}`} onClick={() => setSize(s.size)}>
            <span class="managed-size-check" aria-hidden="true"><Show when={s.size === size()}><Ic.CheckIcon size={14} /></Show></span><span class="managed-size-name">{sizeLabel(s.size)}</span><span class="managed-size-spec">{sizeSpec(s)}</span><span class="managed-size-rate">{usdPerHour(s.usd_per_hour)}</span>
          </button>}</For>
        </div>
      </div>
      <Field label="Time to live" description={`Up to ${minutesLabel(p.data.budget.max_ttl_minutes)}. You can extend it later.`}>
        <Select class="s-input" value={String(ttl())} onChange={e => setTtl(Number(e.currentTarget.value))}>
          <For each={ttlChoices(p.data.budget.default_ttl_minutes, p.data.budget.max_ttl_minutes)}>{m => <option value={m}>{minutesLabel(m)}</option>}</For>
        </Select>
      </Field>
      <div class="managed-estimate" aria-live="polite"><span>Estimated cost · {sizeLabel(chosen()?.size ?? "")} for {minutesLabel(ttl())}</span><strong>{usd(estimate())}</strong></div>
      <Show when={remaining() != null && estimate() > remaining()!}><div class="m-note managed-urgent">Exceeds today’s remaining budget of {usd(Math.max(0, remaining()!))}.</div></Show>
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
  // Rows created from here: optimistic placeholders until the POST answers,
  // then the server id, so a later failure stays in view with Retry / Dismiss.
  const [pending, setPending] = createSignal<Pending[]>([]);
  const [watched, setWatched] = createSignal<Map<string, CreateManagedMachine>>(new Map());
  const [destroying, setDestroying] = createSignal<ReadonlySet<string>>(new Set());
  const version = connectionVersion();
  let seq = 0;

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
  const machines = createMemo(() => (data()?.machines ?? []).map(m => destroying().has(m.id) && isLive(m) ? { ...m, state: "destroying" } : m));
  const starting = createMemo(() => pending().some(x => !x.error) || machines().some(isStarting));
  // Poll quickly while anything is starting, until it is online or failed.
  createEffect(() => { if (!starting()) return; onCleanup(pollWhileVisible(() => refresh(), FAST_POLL_MS, "managed.fast")); });

  const create = async (request: CreateManagedMachine, size: ManagedSize, key = `pending-${++seq}`) => {
    setCreating(false);
    setPending(list => [...list.filter(x => x.key !== key), { key, request, size }]);
    try {
      const m = await createManagedMachine({ ...request, wait: false });
      setPending(list => list.filter(x => x.key !== key));
      setWatched(w => new Map(w).set(m.id, request));
      replace(m); setFetchedAt(Date.now());
      void refresh();
    } catch (e) {
      setPending(list => list.map(x => x.key === key ? { ...x, error: managedError(e) } : x));
    }
  };
  const sizeOf = (name: string): ManagedSize => data()?.sizes.find(s => s.size === name) ?? { size: name, cpu: 0, ram_gb: 0, disk_gb: 0, usd_per_hour: 0 };
  const dismiss = (id: string) => setWatched(w => { const n = new Map(w); n.delete(id); return n; });
  const extend = async (m: ManagedMachine) => {
    setBusy(m.id); setActionError(null);
    try { replace(await extendManagedMachine(m.id, 60)); setFetchedAt(Date.now()); }
    catch (e) { setActionError(managedError(e)); }
    finally { setBusy(null); }
  };
  const destroy = async (m: ManagedMachine) => {
    setConfirm(null); setActionError(null);
    setDestroying(s => new Set(s).add(m.id));
    try {
      replace(await destroyManagedMachine(m.id));
      p.onDestroyed?.(managedNodeIds(m));
      void refresh();
    } catch (e) {
      setActionError(`Couldn’t destroy ${machineName(m)}: ${managedError(e)}`);
    } finally {
      setDestroying(s => { const n = new Set(s); n.delete(m.id); return n; });
    }
  };
  const failedHere = createMemo(() => machines().filter(m => m.state === "failed" && watched().has(m.id)));
  const live = createMemo(() => [...pending().map(x => placeholder(x)), ...machines().filter(isLive), ...failedHere()]);
  const recent = createMemo(() => recentMachines(machines()).filter(m => !failedHere().includes(m)));
  const full = () => { const b = data()?.budget; return !!b && budgetFull(b); };
  const diskOf = (size: string) => data()?.sizes.find(s => s.size === size)?.disk_gb ?? null;
  const actions = (m: ManagedMachine): RowActions => {
    const local = pending().find(x => x.key === m.id);
    if (local) return { onRetry: () => void create(local.request, local.size, local.key), onDismiss: () => setPending(l => l.filter(x => x.key !== local.key)) };
    if (m.state === "failed") return { onRetry: () => { const r = watched().get(m.id)!; dismiss(m.id); void create(r, sizeOf(r.size ?? m.size)); }, onDismiss: () => dismiss(m.id) };
    return { busy: busy() === m.id, onExtend: () => void extend(m), onDestroy: () => setConfirm(m) };
  };

  return <Show when={isConnected() && data()?.enabled}>
    <div class="managed-head">
      <h3 class="s-section-title">Managed (boat.dev)</h3>
      <button class="s-btn sm quiet" disabled={full()} title={full() ? "Daily budget or machine limit reached" : undefined} onClick={() => setCreating(true)}><Ic.PlusIcon size={14} />New managed machine</button>
    </div>
    <div class="m-note managed-budget">{budgetLine(data()!.budget)}</div>
    <Show when={actionError()}><ErrorNotice error={actionError()!} onDismiss={() => setActionError(null)} /></Show>
    <Show when={loadError()}><ErrorNotice title="Couldn’t refresh managed machines" error={loadError()!} /></Show>
    <div class="m-list s-card managed-list">
      <For each={live().map(m => m.id)}>{id => { const m = () => live().find(x => x.id === id)!; return <Show when={live().some(x => x.id === id)}>
        <ManagedRow m={m()} fetchedAt={fetchedAt()} disk={diskOf(m().size)} {...actions(m())} /></Show>; }}</For>
      <Show when={live().length === 0}><div class="m-note" style={{ padding: "10px 14px" }}>No managed machines running.</div></Show>
    </div>
    <Show when={recent().length}>
      <button class="s-btn sm quiet managed-recent-toggle" aria-expanded={showRecent()} onClick={() => setShowRecent(!showRecent())}>
        <span class={`chev p-acc-chev ${showRecent() ? "open" : ""}`}>›</span>Recent · last 24 h ({recent().length})
      </button>
      <Show when={showRecent()}><div class="m-list s-card managed-list managed-recent">
        <For each={recent().map(m => m.id)}>{id => { const m = () => recent().find(x => x.id === id)!; return <Show when={recent().some(x => x.id === id)}><ManagedRow m={m()} fetchedAt={fetchedAt()} disk={diskOf(m().size)} muted /></Show>; }}</For>
      </div></Show>
    </Show>
    <Show when={creating()}>
      <NewManagedMachine data={data()!} onClose={() => setCreating(false)} onCreate={(r, size) => void create(r, size)} />
    </Show>
    <Show when={confirm()}>{m => <ConfirmDialog title={`Destroy ${machineName(m())}?`} destructive action="Destroy"
      description={`The ${m().size} machine and everything on it are deleted now${m().owner_mission_id ? `, and mission ${m().owner_mission_id!.slice(0, 8)} loses it` : ""}. Cost so far: ${usd(liveCost(m(), fetchedAt()))}.`}
      onClose={() => setConfirm(null)} onConfirm={() => void destroy(m())} />}</Show>
  </Show>;
}

export const FAST_POLL_MS = 2000;
type Pending = { key: string; request: CreateManagedMachine; size: ManagedSize; error?: string };
/** The row shown between Create and the server's answer. */
export function placeholder(x: Pending, now = Date.now()): ManagedMachine {
  return { id: x.key, name: "New machine", provider: "boat", provider_id: "", node_id: "", image: x.request.image ?? "", size: x.size.size, cpu: x.size.cpu, ram_gb: x.size.ram_gb,
    state: x.error ? "failed" : "provisioning", created_at: new Date(now).toISOString(), expires_at: "", cost_usd: 0, usd_per_hour: x.size.usd_per_hour,
    error: x.error ?? null, ledger_closed: false };
}
