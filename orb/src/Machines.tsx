import { AgentSoftware } from "./AgentSoftware";
import { ResourceIcon } from "./ResourceIcon";
import { readHistory, saveHistory, freshSamples, historyScope } from "./resourceCache";
import { ResourceHistory, appendSamples, type ResourceSample } from "./ResourceHistory";
import { LocalMachine } from "./LocalMachine";
import { ManagedMachines } from "./ManagedMachines";
import { providerLabel } from "./managedMachineModel";
import { MACHINES, MANAGED_FLEET_COLLAPSE_AFTER, groupManagedNodesByProvider, isManagedNode, managedFleetGroupSummary, nodeProvider, nodeSize, type Machine } from "./machines/nodes";
import { For, Show, createSignal, createMemo, createEffect, untrack, onCleanup, onMount } from "solid-js";
import { pollWhileVisible } from "./poll";
import * as Ic from "./icons";
import { readPalomaPub } from "./pubKey";
import { recordFleet } from "./machineLoad";
import { connectionVersion, getRemoteNodes, getApiUrl, getJwt, isConnected, type RemoteNodeView } from "./api";

export { MACHINES, type Machine };

function target(m: Machine) {
  if (m.id === "local") return "local";
  return m.port !== 22 ? `${m.user}@${m.host}:${m.port}` : `${m.user}@${m.host}`;
}

type Metrics = { cpu_percent: number; memory_used: number; memory_total: number; disk_used: number; disk_total: number; timestamp_ms: number };
const gib = (n: number) => `${(n / 1024 ** 3).toFixed(1)} GiB`;
function Resource(p: { label: string; used?: number | null; total?: number | null; value?: string }) {
  const known = () => p.used != null && p.total != null && p.total > 0;
  return <div class="machine-resource"><span><ResourceIcon kind={p.label}/>{p.label}</span><strong>{p.value ?? (known() ? `${Math.round(p.used! / p.total! * 100)}%` : "Unavailable")}</strong>
    <Show when={known()}><small>{gib(p.used!)} / {gib(p.total!)}</small></Show></div>;
}
function FleetRow(p: { node?: RemoteNodeView; core?: Metrics; live?: boolean; history?: ResourceSample[] }) {
  const [open, setOpen] = createSignal(false);
  const cacheScope = historyScope();
  const [nodeHistory, setNodeHistory] = createSignal<ResourceSample[]>(readHistory(p.node ? `node:${p.node.id}` : "core", cacheScope));
  createEffect(() => {
    const node = p.node;
    if (node?.mem_total_bytes && node.mem_available_bytes != null) {
      const time = node.last_seen ? Date.parse(node.last_seen) : Date.now();
      setNodeHistory(old => freshSamples(appendSamples(old, node.resource_history ?? [{ time, memory: (node.mem_total_bytes! - node.mem_available_bytes!) / node.mem_total_bytes! * 100 }])));
      saveHistory(`node:${node.id}`, untrack(nodeHistory), false, cacheScope);
    }
  });
  onCleanup(() => { if (p.node) saveHistory(`node:${p.node.id}`, nodeHistory(), true, cacheScope); });
  const memory = () => p.node ? (p.node.mem_total_bytes != null && p.node.mem_available_bytes != null ? p.node.mem_total_bytes - p.node.mem_available_bytes : undefined) : p.core?.memory_used;
  const disk = () => p.node ? (p.node.disk_total_bytes != null && p.node.disk_available_bytes != null ? p.node.disk_total_bytes - p.node.disk_available_bytes : undefined) : p.core?.disk_used;
  return <div class="p-acc-wrap"><button class="s-row p-acc-btn" aria-expanded={open()} onClick={() => setOpen(!open())}>
    <Show when={p.node} fallback={<Ic.CoreServerIcon size={18} />}><Ic.ComputeNodeIcon size={18} /></Show>
    <div class="s-row-text"><div class="s-row-title" title={p.node?.display_name ? p.node.id : undefined}>{p.node ? p.node.display_name || p.node.id : "Core"}<Show when={isManagedNode(p.node)}><span class="m-tag">Managed</span><Show when={nodeProvider(p.node) && nodeProvider(p.node) !== "boat"}><span class="m-tag">{providerLabel(nodeProvider(p.node))}</span></Show></Show></div><div class="s-row-desc">{p.node ? `${p.node.status}${isManagedNode(p.node) && nodeSize(p.node) ? ` · ${nodeSize(p.node)}` : ""}${p.node.cordoned ? " · Cordoned" : ""}` : p.live ? "Live · Control plane" : p.core ? "Disconnected · Last snapshot" : "Connecting · Control plane"}</div></div>
    <Show when={p.node?.active_jobs != null}><span class="s-row-desc">{p.node!.active_jobs} active</span></Show>
    <span class={`chev p-acc-chev ${open() ? "open" : ""}`}>›</span></button>
    <Show when={open()}><div class="p-acc-body machine-expanded">
      <ResourceHistory samples={p.node ? nodeHistory() : p.history ?? []} live={p.node ? p.node.status === "online" : !!p.live} /><div class="machine-resources">
      <Resource label="CPU" value={p.node ? (p.node.resource_history?.at(-1)?.cpu != null ? `${Math.round(p.node.resource_history.at(-1)!.cpu!)}%` : p.node.cpu_total != null ? `${p.node.cpu_total} cores` : "Unavailable") : p.core ? `${Math.round(p.core.cpu_percent)}%` : "Unavailable"} />
      <Resource label="Memory" used={memory()} total={p.node?.mem_total_bytes ?? p.core?.memory_total} />
      <Resource label="Disk" used={disk()} total={p.node?.disk_total_bytes ?? p.core?.disk_total} />
      <Show when={p.node?.resource_history?.some(s => s.gpu != null)}><Resource label="GPU" value={p.node!.resource_history!.at(-1)?.gpu != null ? `${Math.round(p.node!.resource_history!.at(-1)!.gpu!)}%` : "Unavailable"} /></Show>
    </div>
    </div></Show></div>;
}

export function Machines() {
  return <For each={[connectionVersion()]}>{() => <MachinesPage />}</For>;
}

function MachinesPage() {
  const cacheScope = historyScope();
  const [history, setHistory] = createSignal<ResourceSample[]>(readHistory("core", cacheScope));
  const [core, setCore] = createSignal<Metrics>();
  const [live, setLive] = createSignal(false);
  const [pub, setPub] = createSignal("");
  const [copied, setCopied] = createSignal(false);
  const [nodes, setNodes] = createSignal<RemoteNodeView[] | null>(null);
  const [fleetGroupOpen, setFleetGroupOpen] = createSignal<Readonly<Record<string, boolean>>>({});
  const managedFleetGroups = createMemo(() => groupManagedNodesByProvider(nodes() ?? []));
  const destroyedNodes = new Set<string>();
  const dropNodes = (ids: string[]) => { ids.forEach(id => destroyedNodes.add(id)); setNodes(ns => ns && ns.filter(n => !destroyedNodes.has(n.id))); void refresh(); };

  const refresh = async () => {
    try {
      const r = await getRemoteNodes();
      // A destroyed managed machine keeps heartbeating "online" until it times out.
      setNodes(r.nodes.filter(n => !destroyedNodes.has(n.id)));
      recordFleet(r.nodes);
    } catch {
      /* keep last good snapshot */
    }
  };

  onMount(() => {
    void readPalomaPub().then(setPub);
    if (isConnected()) void refresh();
    onCleanup(pollWhileVisible(() => (isConnected() ? refresh() : undefined), 15000));
  });

  onMount(() => {
    let socket: WebSocket | undefined;
    let retry: ReturnType<typeof setTimeout> | undefined;
    let stopped = false;
    const connect = () => {
      if (stopped || !isConnected() || document.hidden || (socket && socket.readyState < WebSocket.CLOSING)) return;
      const url = new URL(getApiUrl());
      url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
      url.pathname = `${url.pathname.replace(/\/$/, "")}/api/monitoring/ws`;
      socket = new WebSocket(url, ["sandboxed", `jwt.${getJwt()}`]);
      socket.onmessage = event => {
        try {
          const data = JSON.parse(event.data);
          const sample = data.type === "history" ? data.history?.at(-1) : data;
          if (sample && Number.isFinite(sample.cpu_percent) && Number.isFinite(sample.timestamp_ms)) { setCore(sample); setLive(true);
            const samples: Metrics[] = data.type === "history" ? data.history : [sample];
            setHistory(old => freshSamples(appendSamples(old, samples.map(s => ({ time: s.timestamp_ms, cpu: s.cpu_percent, memory: s.memory_total > 0 ? s.memory_used / s.memory_total * 100 : null })))));
            saveHistory("core", history(), false, cacheScope); }
        } catch { /* Ignore non-metric frames. */ }
      };
      socket.onclose = () => { setLive(false); if (!stopped && !document.hidden) retry = setTimeout(connect, 5000); };
      socket.onerror = () => socket?.close();
    };
    const visibility = () => { clearTimeout(retry); if (document.hidden) { socket?.close(); setLive(false); } else connect(); };
    connect();
    document.addEventListener("visibilitychange", visibility);
    onCleanup(() => { saveHistory("core", history(), true, cacheScope); stopped = true; clearTimeout(retry); socket?.close(); document.removeEventListener("visibilitychange", visibility); });
  });

  const copyKey = async () => {
    const k = pub();
    if (!k) return;
    await navigator.clipboard.writeText(k);
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };

  const staticMachines = () => (isConnected() ? [] : MACHINES.slice(1));

  return (
    <div class="page">
      <div class="page-head">
        <h2>Machines</h2>
      </div>
      <p class="s-lead">
        {isConnected()
          ? "Core metrics stream live. Node heartbeats refresh every 15 seconds."
          : "New Agent runs on one of these over Paloma SSH. Connect a backend in Settings to see the live fleet."}
      </p>

      <h3 class="s-section-title">Local</h3>
      <LocalMachine />
      <h3 class="s-section-title">Remote</h3>
      <div class="m-list s-card">
        <Show when={isConnected()}>
          <FleetRow core={core()} live={live()} history={history()} />
          <For each={(nodes() ?? []).filter(n => !isManagedNode(n)).map(n => n.id)}>{id => <FleetRow node={nodes()?.find(n => n.id === id)} />}</For>
          <For each={managedFleetGroups().map(g => g.provider)}>{provider => {
            const group = () => managedFleetGroups().find(g => g.provider === provider)!;
            const open = () => fleetGroupOpen()[provider] ?? (group().nodes.length <= MANAGED_FLEET_COLLAPSE_AFTER);
            return <Show when={managedFleetGroups().some(g => g.provider === provider)}>
              <div class="fleet-provider-group" data-provider={provider}>
                <button type="button" class="fleet-group-toggle" aria-expanded={open()} onClick={() => setFleetGroupOpen(prev => ({ ...prev, [provider]: !open() }))}>
                  <span class="machine-section-label fleet-group-label">{group().label}</span>
                  <span class="fleet-group-meta">{managedFleetGroupSummary(group().nodes)}</span>
                  <span class={`chev p-acc-chev ${open() ? "open" : ""}`}>›</span>
                </button>
                <Show when={open()}>
                  <div class="managed-group-scroll fleet-group-scroll">
                    <For each={group().nodes.map(n => n.id)}>{id => <FleetRow node={nodes()?.find(n => n.id === id)} />}</For>
                  </div>
                </Show>
              </div>
            </Show>;
          }}</For>
          <Show when={nodes()?.length === 0}>
            <div class="m-note" style={{ padding: "6px 8px" }}>No remote nodes registered.</div>
          </Show>
        </Show>

        <For each={staticMachines()}>
          {(m) => (
            <div class="m-row">
              <span class="m-dot on" title="Paloma SSH" />
              <div class="m-text">
                <div class="m-name">{m.name}</div>
                <div class="m-meta">{target(m)}</div>
                <Show when={m.note}>
                  <div class="m-note">{m.note}</div>
                </Show>
              </div>
            </div>
          )}
        </For>
      </div>
      <ManagedMachines nodes={nodes()} onDestroyed={dropNodes} />

      <AgentSoftware external={staticMachines()} />
      <div class="key-bar">
        <div class="key-bar-text">
          <div class="s-row-title">Paloma public key</div>
          <div class="key-text">{pub() || "Couldn’t read ~/.ssh/paloma.pub"}</div>
        </div>
        <button class="s-btn" disabled={!pub()} onClick={copyKey}>
          {copied() ? "Copied" : "Copy"}
        </button>
      </div>

    </div>
  );
}
