import type {
  MissionDagBar,
  MissionResourcesResponse,
  ResourcesOverviewResponse,
} from "./api";

export type ResourceLens = "compute" | "inference";
export type ResourceMetric = "raw" | "usd";
export type MissionDetailSubmode = "dag" | "flow";

export interface SankeyInputNode {
  id: string;
  column: number;
  label: string;
  sub: string;
  color: string;
  health?: string;
  badge?: string | null;
  missionId?: string | null;
  fallbackValue?: number;
  fallbackUsd?: number;
}

export interface SankeyInputLink {
  id: string;
  source: string;
  target: string;
  value: number;
  est_usd_per_h: number;
  degraded?: boolean;
  color?: string;
}

export interface SankeyLayoutNode extends SankeyInputNode {
  value: number;
  rawValue: number;
  usdValue: number;
  x0: number;
  x1: number;
  y0: number;
  y1: number;
  showLabel: boolean;
  showSub: boolean;
}

export interface SankeyLayoutLink {
  id: string;
  source: string;
  target: string;
  metricValue: number;
  rawValue: number;
  usdValue: number;
  degraded: boolean;
  color: string;
  sourceX: number;
  targetX: number;
  y0: number;
  y1: number;
  width: number;
  path: string;
}

export interface SankeyLayoutResult {
  nodes: SankeyLayoutNode[];
  links: SankeyLayoutLink[];
  totalRaw: number;
  totalUsd: number;
  columns: number;
}

export interface DagBarItem {
  id: string;
  mission_id?: string | null;
  label: string;
  section: string;
  role?: string;
  model?: string | null;
  node_id?: string | null;
  vcpu?: number;
  compute_usd_per_h?: number;
  b_tok_per_h?: number;
  inference_usd_per_h?: number;
  start_offset_secs: number;
  duration_secs: number;
  eta_remaining_secs?: number | null;
  eta_basis?: string | null;
  state: string;
  after_ids: string[];
}

export interface DagSpanLayout {
  bar: DagBarItem;
  startFrac: number;
  endFrac: number;
  etaEndFrac: number | null;
}

export interface DagRowLayout {
  id: string;
  bar: DagBarItem;
  spans: DagSpanLayout[];
  totalDurationSecs: number;
  index: number;
  sectionHeader: string | null;
  y: number;
  barY: number;
  barHeight: number;
  startFrac: number;
  endFrac: number;
  etaEndFrac: number | null;
}

export interface DagDependencyEdge {
  id: string;
  fromId: string;
  toId: string;
  fromEndFrac: number;
  fromCenterY: number;
  toStartFrac: number;
  toCenterY: number;
}

export interface DagLayoutResult {
  rows: DagRowLayout[];
  edges: DagDependencyEdge[];
  totalHeight: number;
}

const SOURCE_PALETTE: Record<string, string> = {
  "static:fleet": "#1d9a78",
  "core:host": "#4d8bc9",
  "spark:gpu": "#129690",
  "antigravity:claude": "#cf6a2d",
  "antigravity:gemini": "#2d7ec7",
  "anthropic:claude": "#c86432",
  "openai:codex": "#1d9a78",
  "google:gemini": "#3b82f6",
  "xai:grok": "#7c65d6",
  "kimi:moonshot": "#0e9aa7",
  "zai:glm": "#5b8c3e",
};

const MISSION_PALETTE = [
  "#2f83bf",
  "#7b63cf",
  "#1d9a78",
  "#cf6f2e",
  "#be4f78",
  "#22959d",
  "#66883f",
  "#8c6239",
];

export function colorForSource(id: string, index = 0): string {
  if (SOURCE_PALETTE[id]) return SOURCE_PALETTE[id];
  if (id.startsWith("boat:")) return "#2f83bf";
  if (id.startsWith("hetzner:")) return "#cf5c36";
  if (id.startsWith("vast:") || id.startsWith("vastai:")) return "#7b63cf";
  if (id.startsWith("scaleway:")) return "#8a5cf5";
  if (id.startsWith("colab:")) return "#f9ab00";
  return MISSION_PALETTE[index % MISSION_PALETTE.length];
}

export function colorForMission(id: string, index = 0): string {
  let hash = 0;
  for (let i = 0; i < id.length; i++) {
    hash = (hash * 31 + id.charCodeAt(i)) | 0;
  }
  const slot = Math.abs(hash + index) % MISSION_PALETTE.length;
  return MISSION_PALETTE[slot];
}

export function formatIntThousands(value: number): string {
  const s = String(Math.max(0, Math.round(value)));
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

export function formatLargeNumber(value: number): string {
  const safe = Number.isFinite(value) ? Math.max(0, value) : 0;
  const rounded = Math.round(safe);
  if (rounded >= 1_000_000) {
    const m100 = Math.round((safe / 1_000_000) * 100);
    if (m100 >= 10_000) {
      return `${formatIntThousands(Math.round(safe / 1_000_000))}M`;
    }
    if (m100 >= 1_000) {
      const m10 = Math.round((safe / 1_000_000) * 10);
      return m10 % 10 === 0 ? `${m10 / 10}M` : `${(m10 / 10).toFixed(1)}M`;
    }
    if (m100 % 100 === 0) return `${m100 / 100}M`;
    if (m100 % 10 === 0) return `${(m100 / 100).toFixed(1)}M`;
    return `${(m100 / 100).toFixed(2)}M`;
  }
  if (rounded >= 10_000) {
    const k10 = Math.round((safe / 1_000) * 10);
    if (k10 >= 10_000) return "1M";
    if (k10 >= 1_000) {
      const kInt = Math.round(safe / 1_000);
      return kInt >= 1_000 ? "1M" : `${kInt}k`;
    }
    return k10 % 10 === 0 ? `${k10 / 10}k` : `${(k10 / 10).toFixed(1)}k`;
  }
  if (rounded >= 1_000) {
    return formatIntThousands(rounded);
  }
  return String(rounded);
}

export function formatResourceRate(
  value: number,
  lens: ResourceLens,
  metric: ResourceMetric,
  withUnit = true,
): string {
  const safe = Number.isFinite(value) ? Math.max(0, value) : 0;
  if (metric === "usd") {
    if (!withUnit) {
      if (safe >= 100) return `$${formatLargeNumber(safe)}`;
      if (safe >= 10) return `$${safe.toFixed(1)}`;
      return `$${safe.toFixed(2)}`;
    }
    if (safe >= 100) return `$${formatLargeNumber(safe)}/h`;
    if (safe >= 10) return `$${safe.toFixed(1)}/h`;
    if (safe >= 0.01) return `$${safe.toFixed(2)}/h`;
    if (safe > 0) return "<$0.01/h";
    return "$0.00/h";
  }

  if (lens === "compute") {
    const rounded1 = Math.round(safe * 10) / 10;
    const num =
      safe >= 10 || Math.abs(rounded1 - Math.round(safe)) < 0.05
        ? formatLargeNumber(safe)
        : safe.toFixed(1);
    return withUnit ? `${num} vCPU` : num;
  }

  const num =
    safe >= 10
      ? safe.toFixed(1)
      : safe >= 0.1
        ? safe.toFixed(2)
        : safe > 0
          ? safe.toFixed(3)
          : "0.00";
  return withUnit ? `${num} B tok/h` : num;
}

export function formatDurationCompact(secs: number | null | undefined): string {
  if (secs == null || !Number.isFinite(secs) || secs <= 0) return "0m";
  const s = Math.round(secs);
  if (s < 60) return `${s}s`;
  const mins = Math.floor(s / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  const remMins = mins % 60;
  if (hours < 24) {
    return remMins > 0 ? `${hours}h ${remMins}m` : `${hours}h`;
  }
  const days = Math.floor(hours / 24);
  const remHours = hours % 24;
  return remHours > 0 ? `${days}d ${remHours}h` : `${days}d`;
}

export function formatTokenTotalCompact(tokens: number): string {
  if (!Number.isFinite(tokens) || tokens <= 0) return "0 tok";
  if (tokens >= 1e12) return `${(tokens / 1e12).toFixed(2)}T tok`;
  if (tokens >= 1e11) return `${Math.round(tokens / 1e9)}B tok`;
  if (tokens >= 1e10) return `${(tokens / 1e9).toFixed(1)}B tok`;
  if (tokens >= 1e9) return `${(tokens / 1e9).toFixed(2)}B tok`;
  if (tokens >= 1e6) return `${(tokens / 1e6).toFixed(1)}M tok`;
  if (tokens >= 1e3) return `${(tokens / 1e3).toFixed(1)}K tok`;
  return `${Math.round(tokens)} tok`;
}

export function sankeyRibbonPath(
  sourceX: number,
  targetX: number,
  y0: number,
  y1: number,
  w0: number,
  w1?: number,
): string {
  const mx = (sourceX + targetX) / 2;
  const sw = Math.max(1.5, w0);
  const tw = Math.max(1.5, w1 ?? w0);
  const syTop = y0 - sw / 2;
  const syBot = y0 + sw / 2;
  const tyTop = y1 - tw / 2;
  const tyBot = y1 + tw / 2;
  return [
    `M ${sourceX.toFixed(2)} ${syTop.toFixed(2)}`,
    `C ${mx.toFixed(2)} ${syTop.toFixed(2)}, ${mx.toFixed(2)} ${tyTop.toFixed(2)}, ${targetX.toFixed(2)} ${tyTop.toFixed(2)}`,
    `L ${targetX.toFixed(2)} ${tyBot.toFixed(2)}`,
    `C ${mx.toFixed(2)} ${tyBot.toFixed(2)}, ${mx.toFixed(2)} ${syBot.toFixed(2)}, ${sourceX.toFixed(2)} ${syBot.toFixed(2)}`,
    "Z",
  ].join(" ");
}

export function computeSankeyLayout(
  inputNodes: SankeyInputNode[],
  inputLinks: SankeyInputLink[],
  options: {
    width: number;
    height: number;
    metric: ResourceMetric;
    nodeWidth?: number;
    nodePadding?: number;
    marginX?: number;
    marginY?: number;
  },
): SankeyLayoutResult {
  const {
    width,
    height,
    metric,
    nodeWidth = 12,
    nodePadding = 12,
    marginX = 168,
    marginY = 14,
  } = options;

  const maxCol = inputNodes.reduce((m, n) => Math.max(m, n.column), 1);
  const columns = Math.max(2, maxCol + 1);

  const rawIn = new Map<string, number>();
  const rawOut = new Map<string, number>();
  const usdIn = new Map<string, number>();
  const usdOut = new Map<string, number>();

  for (const link of inputLinks) {
    const r = Math.max(0, link.value);
    const u = Math.max(0, link.est_usd_per_h);
    rawOut.set(link.source, (rawOut.get(link.source) ?? 0) + r);
    rawIn.set(link.target, (rawIn.get(link.target) ?? 0) + r);
    usdOut.set(link.source, (usdOut.get(link.source) ?? 0) + u);
    usdIn.set(link.target, (usdIn.get(link.target) ?? 0) + u);
  }

  // Conserved totals across column 0 -> 1 links
  const col0Ids = new Set(inputNodes.filter((n) => n.column === 0).map((n) => n.id));
  let totalRaw = 0;
  let totalUsd = 0;
  for (const link of inputLinks) {
    if (col0Ids.has(link.source)) {
      totalRaw += Math.max(0, link.value);
      totalUsd += Math.max(0, link.est_usd_per_h);
    }
  }
  if (totalRaw === 0 && inputLinks.length === 0) {
    for (const n of inputNodes) {
      if (n.column === 0) {
        totalRaw += Math.max(0, n.fallbackValue ?? 0);
        totalUsd += Math.max(0, n.fallbackUsd ?? 0);
      }
    }
  }

  const innerW = Math.max(120, width - marginX * 2 - nodeWidth);
  const innerH = Math.max(80, height - marginY * 2);

  const nodesByCol: SankeyLayoutNode[][] = Array.from({ length: columns }, () => []);
  const nodeMap = new Map<string, SankeyLayoutNode>();

  for (const n of inputNodes) {
    const rVal = Math.max(rawIn.get(n.id) ?? 0, rawOut.get(n.id) ?? 0, n.fallbackValue ?? 0);
    const uVal = Math.max(usdIn.get(n.id) ?? 0, usdOut.get(n.id) ?? 0, n.fallbackUsd ?? 0);
    const activeVal = metric === "usd" ? uVal : rVal;
    const x0 = marginX + (columns > 1 ? (n.column / (columns - 1)) * innerW : 0);
    const ln: SankeyLayoutNode = {
      ...n,
      rawValue: rVal,
      usdValue: uVal,
      value: activeVal,
      x0,
      x1: x0 + nodeWidth,
      y0: 0,
      y1: 0,
      showLabel: true,
      showSub: true,
    };
    nodesByCol[n.column]?.push(ln);
    nodeMap.set(n.id, ln);
  }

  // Shared scale across all columns so conserved mass has identical pixel height
  let sharedScale = Infinity;
  const isGroupedTailNode = (id: string) => id.includes("__other");
  for (let c = 0; c < columns; c++) {
    const colNodes = nodesByCol[c];
    if (!colNodes || colNodes.length === 0) continue;
    // Sort descending by value with stable id tie-breaker, pinning grouped tail buckets last
    colNodes.sort((a, b) => {
      const aTail = isGroupedTailNode(a.id);
      const bTail = isGroupedTailNode(b.id);
      if (aTail !== bTail) return aTail ? 1 : -1;
      return b.value - a.value || a.id.localeCompare(b.id);
    });
    const sumVal = colNodes.reduce((acc, n) => acc + Math.max(n.value, 0), 0);
    const padTotal = Math.max(0, colNodes.length - 1) * nodePadding;
    const availH = Math.max(36, innerH - padTotal);
    if (sumVal > 0) {
      sharedScale = Math.min(sharedScale, availH / sumVal);
    }
  }
  if (!Number.isFinite(sharedScale) || sharedScale <= 0) {
    sharedScale = 1;
  }

  const minBarH = 8;
  for (let c = 0; c < columns; c++) {
    const colNodes = nodesByCol[c];
    if (!colNodes || colNodes.length === 0) continue;
    const isMiddleCol = columns > 2 && c > 0 && c < columns - 1;
    const minRowGap = colNodes.length <= 12 ? 15 : nodePadding;
    const heights = colNodes.map((n) => Math.max(minBarH, n.value * sharedScale));
    const totalColH =
      heights.reduce((a, b) => a + b, 0) + Math.max(0, colNodes.length - 1) * minRowGap;
    const compress = totalColH > innerH ? innerH / totalColH : 1;
    const effPad = minRowGap * compress;
    const finalTotalH =
      heights.reduce((a, b) => a + b * compress, 0) +
      Math.max(0, colNodes.length - 1) * effPad;
    let cursorY = marginY + Math.max(0, (innerH - finalTotalH) / 2);
    let lastLabelBottom = -Infinity;
    for (let i = 0; i < colNodes.length; i++) {
      const h = Math.max(5, heights[i] * compress);
      const y0 = cursorY;
      const y1 = cursorY + h;
      const centerY = (y0 + y1) / 2;
      const nextCenterY =
        i + 1 < colNodes.length
          ? y1 + effPad + Math.max(5, heights[i + 1] * compress) / 2
          : Infinity;

      const twoLineTop = centerY - 15;
      const singleLineTop = centerY - 9;
      if (singleLineTop >= lastLabelBottom + 3) {
        colNodes[i].showLabel = true;
        // Middle columns in 3-col Flow only show compact 1-line labels so ribbons stay clean
        const subBottom = centerY + 12;
        if (
          !isMiddleCol &&
          twoLineTop >= lastLabelBottom + 3 &&
          nextCenterY - 9 >= subBottom + 4
        ) {
          colNodes[i].showSub = true;
          lastLabelBottom = subBottom;
        } else {
          colNodes[i].showSub = false;
          lastLabelBottom = centerY + 7;
        }
      } else {
        colNodes[i].showLabel = false;
        colNodes[i].showSub = false;
      }

      colNodes[i].y0 = y0;
      colNodes[i].y1 = y1;
      cursorY += h + effPad;
    }
  }

  // Order links to minimize crossings by sorting outgoing by target.y0 and incoming by source.y0
  const outBySource = new Map<string, SankeyInputLink[]>();
  const inByTarget = new Map<string, SankeyInputLink[]>();
  for (const l of inputLinks) {
    if (!nodeMap.has(l.source) || !nodeMap.has(l.target)) continue;
    const mv = metric === "usd" ? l.est_usd_per_h : l.value;
    if (mv <= 0 && l.value <= 0) continue;
    const outs = outBySource.get(l.source) ?? [];
    outs.push(l);
    outBySource.set(l.source, outs);
    const ins = inByTarget.get(l.target) ?? [];
    ins.push(l);
    inByTarget.set(l.target, ins);
  }

  const sourceOffsets = new Map<string, { center: number; width: number }>();
  for (const [srcId, list] of outBySource) {
    const src = nodeMap.get(srcId)!;
    list.sort(
      (a, b) =>
        (nodeMap.get(a.target)?.y0 ?? 0) - (nodeMap.get(b.target)?.y0 ?? 0) ||
        a.id.localeCompare(b.id),
    );
    const nodeH = Math.max(4, src.y1 - src.y0);
    const sumMetric = list.reduce(
      (s, l) => s + Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value),
      0,
    );
    let offset = src.y0;
    for (const l of list) {
      const mv = Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value);
      const w = (mv / sumMetric) * nodeH;
      sourceOffsets.set(l.id, { center: offset + w / 2, width: w });
      offset += w;
    }
  }

  const targetOffsets = new Map<string, { center: number; width: number }>();
  for (const [dstId, list] of inByTarget) {
    const dst = nodeMap.get(dstId)!;
    list.sort(
      (a, b) =>
        (nodeMap.get(a.source)?.y0 ?? 0) - (nodeMap.get(b.source)?.y0 ?? 0) ||
        a.id.localeCompare(b.id),
    );
    const nodeH = Math.max(4, dst.y1 - dst.y0);
    const sumMetric = list.reduce(
      (s, l) => s + Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value),
      0,
    );
    let offset = dst.y0;
    for (const l of list) {
      const mv = Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value);
      const w = (mv / sumMetric) * nodeH;
      targetOffsets.set(l.id, { center: offset + w / 2, width: w });
      offset += w;
    }
  }

  const laidOutLinks: SankeyLayoutLink[] = [];
  for (const l of inputLinks) {
    const src = nodeMap.get(l.source);
    const dst = nodeMap.get(l.target);
    const srcSlot = sourceOffsets.get(l.id);
    const tgt = targetOffsets.get(l.id);
    if (!src || !dst || !srcSlot || !tgt) continue;
    const mv = Math.max(0, metric === "usd" ? l.est_usd_per_h : l.value);
    const sWidthPx = Math.max(1.5, srcSlot.width);
    const widthPx = Math.max(1.5, tgt.width);
    laidOutLinks.push({
      id: l.id,
      source: l.source,
      target: l.target,
      metricValue: mv,
      rawValue: Math.max(0, l.value),
      usdValue: Math.max(0, l.est_usd_per_h),
      degraded: Boolean(l.degraded),
      color: l.color ?? src.color,
      sourceX: src.x1,
      targetX: dst.x0,
      y0: srcSlot.center,
      y1: tgt.center,
      width: widthPx,
      path: sankeyRibbonPath(src.x1, dst.x0, srcSlot.center, tgt.center, sWidthPx, widthPx),
    });
  }

  return {
    nodes: nodesByCol.flat(),
    links: laidOutLinks,
    totalRaw,
    totalUsd,
    columns,
  };
}

function stripVmSectionAffix(section: string): string {
  const trimmed = section.trim();
  if (trimmed.endsWith(" VMs")) {
    return trimmed.slice(0, -4).trim() || section;
  }
  return trimmed || section;
}

function normalizeDagBarsForLanes(bars: DagBarItem[]): DagBarItem[] {
  const vmClassByNode = new Map<string, string>();
  const nodesWithWorkers = new Set<string>();

  for (const b of bars) {
    const nid = b.node_id?.trim() || "";
    if (!nid) continue;
    if (b.role === "vm") {
      vmClassByNode.set(nid, stripVmSectionAffix(b.section));
    } else {
      nodesWithWorkers.add(nid);
    }
  }

  const out: DagBarItem[] = [];
  for (const b of bars) {
    const nid = b.node_id?.trim() || "";
    if (b.role === "vm") {
      // Only render a VM lease bar when NO subagent span already represents work on that node;
      // this keeps direct-compute (`remote_jobs`) or idle leased VMs visible without cluttering
      // agent swimlanes with idle handoff fragments between waves.
      if (nid && nodesWithWorkers.has(nid)) {
        continue;
      }
      out.push({
        ...b,
        section: nid ? stripVmSectionAffix(b.section) : b.section,
      });
      continue;
    }

    let section = b.section;
    const role = (b.role ?? "worker").toLowerCase();
    if (role === "coordinator" || role === "boss" || role === "orchestrator") {
      section = b.section || "Orchestrator";
    } else if (nid && vmClassByNode.has(nid)) {
      section = vmClassByNode.get(nid)!;
    } else if (nid && nid !== "core" && nid !== "local") {
      if (nid.startsWith("managed-")) {
        section = b.section.includes("·") ? stripVmSectionAffix(b.section) : "Cloud VMs";
      } else if (nid.startsWith("spark")) {
        section = "DGX Spark";
      } else {
        section = "Static fleet";
      }
    }
    out.push({ ...b, section });
  }
  return out;
}

export function layoutDagRows(
  bars: DagBarItem[],
  horizonSecs: number,
  options?: {
    rowHeight?: number;
    sectionHeaderHeight?: number;
    topPadding?: number;
  },
): DagLayoutResult {
  const rowHeight = options?.rowHeight ?? 28;
  const sectionHeaderHeight = options?.sectionHeaderHeight ?? 22;
  const topPadding = options?.topPadding ?? 8;
  const safeHorizon = Math.max(60, horizonSecs);

  const normalized = normalizeDagBarsForLanes(bars);
  const sectionOrder: string[] = [];
  const bySection = new Map<string, DagBarItem[]>();
  for (const b of normalized) {
    let list = bySection.get(b.section);
    if (!list) {
      list = [];
      bySection.set(b.section, list);
      sectionOrder.push(b.section);
    }
    list.push(b);
  }
  // Place Orchestrator section at the very top when present alongside hardware sections
  const orchIdx = sectionOrder.indexOf("Orchestrator");
  if (orchIdx > 0) {
    sectionOrder.splice(orchIdx, 1);
    sectionOrder.unshift("Orchestrator");
  }

  const rows: DagRowLayout[] = [];
  const spanLookup = new Map<string, { centerY: number; span: DagSpanLayout }>();
  let cursorY = topPadding;
  let rowIndex = 0;

  for (const sec of sectionOrder) {
    const secBars = (bySection.get(sec) ?? []).slice().sort(
      (a, b) =>
        a.start_offset_secs - b.start_offset_secs ||
        b.duration_secs - a.duration_secs ||
        a.id.localeCompare(b.id),
    );

    const lanes: Array<{
      lastEndSecs: number;
      lastOccFrac: number;
      lastNodeId: string | null;
      spans: DagSpanLayout[];
    }> = [];

    for (const b of secBars) {
      const dur = Math.max(30, b.duration_secs);
      const startFrac = Math.max(0, Math.min(1, b.start_offset_secs / safeHorizon));
      const endFrac = Math.max(
        startFrac + 0.008,
        Math.min(1, (b.start_offset_secs + dur) / safeHorizon),
      );
      const etaEndFrac =
        b.eta_remaining_secs != null && b.eta_remaining_secs > 0 && b.state === "active"
          ? Math.max(
              endFrac,
              Math.min(
                1,
                (b.start_offset_secs + b.duration_secs + b.eta_remaining_secs) / safeHorizon,
              ),
            )
          : null;
      const occEndSecs =
        b.start_offset_secs +
        dur +
        (b.state === "active" && b.eta_remaining_secs && b.eta_remaining_secs > 0
          ? b.eta_remaining_secs
          : 0);
      const occEndFrac = etaEndFrac ?? endFrac;
      const nid = b.node_id?.trim() || null;

      let chosen = -1;
      if (nid) {
        for (let i = 0; i < lanes.length; i++) {
          const ln = lanes[i];
          if (
            ln.lastNodeId === nid &&
            ln.lastEndSecs <= b.start_offset_secs + 5 &&
            ln.lastOccFrac <= startFrac + 0.002
          ) {
            chosen = i;
            break;
          }
        }
      }
      if (chosen < 0) {
        for (let i = 0; i < lanes.length; i++) {
          const ln = lanes[i];
          if (
            ln.lastEndSecs <= b.start_offset_secs + 5 &&
            ln.lastOccFrac <= startFrac + 0.002
          ) {
            chosen = i;
            break;
          }
        }
      }

      const span: DagSpanLayout = { bar: b, startFrac, endFrac, etaEndFrac };
      if (chosen < 0) {
        lanes.push({
          lastEndSecs: occEndSecs,
          lastOccFrac: occEndFrac,
          lastNodeId: nid,
          spans: [span],
        });
      } else {
        lanes[chosen].lastEndSecs = Math.max(lanes[chosen].lastEndSecs, occEndSecs);
        lanes[chosen].lastOccFrac = Math.max(lanes[chosen].lastOccFrac, occEndFrac);
        if (nid) lanes[chosen].lastNodeId = nid;
        lanes[chosen].spans.push(span);
      }
    }

    for (let li = 0; li < lanes.length; li++) {
      const ln = lanes[li];
      const sectionHeader = li === 0 ? sec : null;
      if (sectionHeader !== null) {
        cursorY += sectionHeaderHeight;
      }
      const barHeight = 16;
      const barY = cursorY + (rowHeight - barHeight) / 2;
      const centerY = barY + barHeight / 2;

      let primarySpan = ln.spans[ln.spans.length - 1];
      for (let si = ln.spans.length - 1; si >= 0; si--) {
        if (ln.spans[si].bar.state === "active") {
          primarySpan = ln.spans[si];
          break;
        }
      }
      const totalDurationSecs = ln.spans.reduce(
        (acc, sp) => acc + Math.max(0, sp.bar.duration_secs),
        0,
      );
      const rowId =
        ln.spans.length === 1
          ? primarySpan.bar.id
          : `lane:${sec}:${li}:${ln.spans[0].bar.id}`;

      const row: DagRowLayout = {
        id: rowId,
        bar: primarySpan.bar,
        spans: ln.spans,
        totalDurationSecs,
        index: rowIndex++,
        sectionHeader,
        y: cursorY,
        barY,
        barHeight,
        startFrac: primarySpan.startFrac,
        endFrac: primarySpan.endFrac,
        etaEndFrac: primarySpan.etaEndFrac,
      };
      rows.push(row);
      for (const sp of ln.spans) {
        spanLookup.set(sp.bar.id, { centerY, span: sp });
      }
      cursorY += rowHeight;
    }
  }

  const edges: DagDependencyEdge[] = [];
  for (const row of rows) {
    for (const sp of row.spans) {
      const toCenterY = row.barY + row.barHeight / 2;
      for (const depId of sp.bar.after_ids) {
        const pred = spanLookup.get(depId);
        if (!pred) continue;
        edges.push({
          id: `${depId}->${sp.bar.id}`,
          fromId: depId,
          toId: sp.bar.id,
          fromEndFrac: pred.span.endFrac,
          fromCenterY: pred.centerY,
          toStartFrac: sp.startFrac,
          toCenterY,
        });
      }
    }
  }

  return {
    rows,
    edges,
    totalHeight: Math.max(120, cursorY + 12),
  };
}

export function computeMonotoneCurve(
  points: Array<{ x: number; y: number }>,
  baselineY: number,
): { linePath: string; areaPath: string } {
  if (points.length === 0) return { linePath: "", areaPath: "" };
  if (points.length === 1) {
    const p = points[0];
    return {
      linePath: `M ${p.x.toFixed(2)} ${p.y.toFixed(2)}`,
      areaPath: `M ${p.x.toFixed(2)} ${baselineY.toFixed(2)} L ${p.x.toFixed(2)} ${p.y.toFixed(2)} L ${p.x.toFixed(2)} ${baselineY.toFixed(2)} Z`,
    };
  }

  const n = points.length;
  const dx: number[] = [];
  const dy: number[] = [];
  const slopes: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    const dxi = Math.max(1e-6, points[i + 1].x - points[i].x);
    const dyi = points[i + 1].y - points[i].y;
    dx.push(dxi);
    dy.push(dyi);
    slopes.push(dyi / dxi);
  }

  const tangents: number[] = new Array(n).fill(0);
  tangents[0] = slopes[0];
  tangents[n - 1] = slopes[n - 2];
  for (let i = 1; i < n - 1; i++) {
    const m0 = slopes[i - 1];
    const m1 = slopes[i];
    if (m0 * m1 <= 0) {
      tangents[i] = 0;
    } else {
      tangents[i] = (m0 + m1) / 2;
    }
  }
  for (let i = 0; i < n - 1; i++) {
    const m = slopes[i];
    if (Math.abs(m) < 1e-9) {
      tangents[i] = 0;
      tangents[i + 1] = 0;
    } else {
      const a = tangents[i] / m;
      const b = tangents[i + 1] / m;
      const s = a * a + b * b;
      if (s > 9) {
        const tau = 3 / Math.sqrt(s);
        tangents[i] = tau * a * m;
        tangents[i + 1] = tau * b * m;
      }
    }
  }

  let d = `M ${points[0].x.toFixed(2)} ${points[0].y.toFixed(2)}`;
  for (let i = 0; i < n - 1; i++) {
    const p0 = points[i];
    const p1 = points[i + 1];
    const h = dx[i];
    const c1x = p0.x + h / 3;
    const c1y = Math.min(baselineY, p0.y + (tangents[i] * h) / 3);
    const c2x = p1.x - h / 3;
    const c2y = Math.min(baselineY, p1.y - (tangents[i + 1] * h) / 3);
    d += ` C ${c1x.toFixed(2)} ${c1y.toFixed(2)}, ${c2x.toFixed(2)} ${c2y.toFixed(2)}, ${p1.x.toFixed(2)} ${p1.y.toFixed(2)}`;
  }

  const first = points[0];
  const last = points[n - 1];
  const areaPath = `${d} L ${last.x.toFixed(2)} ${baselineY.toFixed(2)} L ${first.x.toFixed(2)} ${baselineY.toFixed(2)} Z`;
  return { linePath: d, areaPath };
}

/**
 * Stabilize a rolling consumption series whose final bucket (`now`) is still open
 * and accumulating in-flight LLM turns (tokens are billed on turn completion).
 * If the fleet has live runs right now (`hasActiveMissions`) and the incomplete
 * final bucket currently reads `0` (or is an early partial bucket dipping well below
 * the settled preceding bucket), carry/blend the settled rate so the `now` endpoint
 * doesn't artificially dive to `0`.
 */
export function stabilizeTrailingOpenBucket(
  values: number[],
  hasActiveMissions: boolean,
  openBucketElapsedFrac?: number,
): number[] {
  if (values.length < 2 || !hasActiveMissions) return values;
  const lastIdx = values.length - 1;
  const lastVal = values[lastIdx] ?? 0;
  const prevVal = values[lastIdx - 1] ?? 0;
  if (prevVal <= 0) return values;
  if (lastVal <= 0) {
    const copy = values.slice();
    copy[lastIdx] = prevVal;
    return copy;
  }
  if (
    openBucketElapsedFrac != null &&
    Number.isFinite(openBucketElapsedFrac) &&
    openBucketElapsedFrac < 0.7 &&
    lastVal < prevVal * 0.45
  ) {
    const frac = Math.max(0.08, Math.min(0.7, openBucketElapsedFrac));
    const rescaled = Math.min(prevVal * 1.15, lastVal / Math.max(0.25, frac));
    const w = Math.min(1, frac / 0.7);
    const blended = prevVal * (1 - w) + Math.max(lastVal, rescaled) * w;
    const copy = values.slice();
    copy[lastIdx] = blended;
    return copy;
  }
  return values;
}

export function buildOverviewSankeyInput(
  overview: ResourcesOverviewResponse,
  lens: ResourceLens,
  metric: ResourceMetric = "raw",
  canvasHeight = 368,
): { nodes: SankeyInputNode[]; links: SankeyInputLink[] } {
  const nodes: SankeyInputNode[] = [];
  const links: SankeyInputLink[] = [];

  if (lens === "compute") {
    overview.compute.sources.forEach((src, idx) => {
      nodes.push({
        id: src.id,
        column: 0,
        label: src.label,
        sub: src.sublabel,
        color: colorForSource(src.id, idx),
        health: src.health,
        fallbackValue: src.total_vcpu,
        fallbackUsd: src.est_usd_per_h,
      });
    });
  } else {
    const maxPoolBtok = overview.inference.pools.reduce(
      (mx, p) => Math.max(mx, p.current_b_tok_per_h),
      0,
    );
    const maxPoolUsd = overview.inference.pools.reduce(
      (mx, p) => Math.max(mx, p.est_usd_per_h),
      0,
    );
    const activeSourceIds = new Set(
      overview.links
        .filter(
          (l) =>
            l.kind === "inference" &&
            (l.value >= Math.max(1e-6, maxPoolBtok * 0.002) ||
              l.est_usd_per_h >= Math.max(1e-4, maxPoolUsd * 0.002)),
        )
        .map((l) => l.source_id),
    );
    const activePools = overview.inference.pools.filter((pool) => {
      const significant =
        maxPoolBtok >= 0.02
          ? pool.current_b_tok_per_h >= 0.0005 || pool.est_usd_per_h >= 0.01
          : pool.current_b_tok_per_h > 0 || pool.est_usd_per_h > 0;
      return significant || activeSourceIds.has(pool.id);
    });
    const poolsToRender =
      activePools.length > 0 ? activePools : overview.inference.pools.slice(0, 5);
    poolsToRender.forEach((pool, idx) => {
      const remBadge =
        pool.quota_pct_remaining != null
          ? `${Math.round(pool.quota_pct_remaining)}% left`
          : null;
      const baseSub = (pool.sublabel || "").trim();
      const subHasPct = /%\s*left/i.test(baseSub);
      const cleanSub =
        subHasPct || !remBadge
          ? baseSub
          : [baseSub, remBadge].filter(Boolean).join(" · ");
      nodes.push({
        id: pool.id,
        column: 0,
        label: pool.label,
        sub: cleanSub,
        color: colorForSource(pool.id, idx),
        health: pool.health,
        badge: remBadge,
        fallbackValue: pool.current_b_tok_per_h,
        fallbackUsd: pool.est_usd_per_h,
      });
    });
  }

  const relevantLinks = overview.links.filter((l) => l.kind === lens);
  const missionIdsWithFlow = new Set(relevantLinks.map((l) => l.mission_id));
  const missionScore = (m: ResourcesOverviewResponse["missions"][number]) =>
    lens === "compute"
      ? metric === "usd"
        ? m.compute_usd_per_h
        : m.vcpu
      : metric === "usd"
        ? m.inference_usd_per_h
        : m.b_tok_per_h;

  const maxCol1Missions = Math.max(
    9,
    Math.min(18, Math.floor((Math.max(340, canvasHeight) - 32) / 34)),
  );
  const candidateMissions = overview.missions
    .filter((m) => {
      const hasMass =
        missionIdsWithFlow.has(m.id) ||
        (lens === "compute" ? m.vcpu > 0 : m.b_tok_per_h > 0);
      return hasMass || overview.missions.length <= 6;
    })
    .slice()
    .sort((a, b) => missionScore(b) - missionScore(a) || a.id.localeCompare(b.id));

  const needsTailBucket = candidateMissions.length > maxCol1Missions + 1;
  const visibleMissions = needsTailBucket
    ? candidateMissions.slice(0, maxCol1Missions)
    : candidateMissions;
  const overflowMissions = needsTailBucket
    ? candidateMissions.slice(maxCol1Missions)
    : [];
  const overflowSet = new Set(overflowMissions.map((m) => m.id));
  const tailBucketId = "__other_missions__";

  visibleMissions.forEach((m) => {
    const subParts: string[] = [];
    if (m.subagent_total > 1) {
      subParts.push(
        m.subagent_running > 0
          ? `${formatLargeNumber(m.subagent_running)}/${formatLargeNumber(m.subagent_total)} agents`
          : `${formatLargeNumber(m.subagent_total)} agents`,
      );
    } else {
      subParts.push(m.status);
    }
    if (m.eta_remaining_secs != null && m.eta_remaining_secs > 0) {
      subParts.push(`~${formatDurationCompact(m.eta_remaining_secs)} left`);
    }
    nodes.push({
      id: m.id,
      column: 1,
      label: m.title || m.project || m.id.slice(0, 8),
      sub: subParts.join(" · "),
      color: colorForMission(m.id, 0),
      health: m.stall_kind ? "stalled" : "ok",
      missionId: m.id,
      fallbackValue: lens === "compute" ? m.vcpu : m.b_tok_per_h,
      fallbackUsd: lens === "compute" ? m.compute_usd_per_h : m.inference_usd_per_h,
    });
  });

  if (overflowMissions.length > 0) {
    const sumRaw = overflowMissions.reduce(
      (s, m) => s + (lens === "compute" ? m.vcpu : m.b_tok_per_h),
      0,
    );
    const sumUsd = overflowMissions.reduce(
      (s, m) => s + (lens === "compute" ? m.compute_usd_per_h : m.inference_usd_per_h),
      0,
    );
    nodes.push({
      id: tailBucketId,
      column: 1,
      label: `+${formatLargeNumber(overflowMissions.length)} smaller missions`,
      sub: "long tail",
      color: "#6b7280",
      health: "ok",
      missionId: null,
      fallbackValue: sumRaw,
      fallbackUsd: sumUsd,
    });
  }

  const tailLinksBySource = new Map<
    string,
    { value: number; est_usd_per_h: number; degraded: boolean }
  >();
  relevantLinks.forEach((l) => {
    if (overflowSet.has(l.mission_id)) {
      const prev = tailLinksBySource.get(l.source_id) ?? {
        value: 0,
        est_usd_per_h: 0,
        degraded: false,
      };
      prev.value += l.value;
      prev.est_usd_per_h += l.est_usd_per_h;
      prev.degraded = prev.degraded || l.degraded;
      tailLinksBySource.set(l.source_id, prev);
      return;
    }
    links.push({
      id: `${l.kind}:${l.source_id}->${l.mission_id}`,
      source: l.source_id,
      target: l.mission_id,
      value: l.value,
      est_usd_per_h: l.est_usd_per_h,
      degraded: l.degraded,
    });
  });

  for (const [sourceId, agg] of tailLinksBySource) {
    links.push({
      id: `${lens}:${sourceId}->${tailBucketId}`,
      source: sourceId,
      target: tailBucketId,
      value: agg.value,
      est_usd_per_h: agg.est_usd_per_h,
      degraded: agg.degraded,
    });
  }

  return { nodes, links };
}

export function buildMissionFlowSankeyInput(
  detail: MissionResourcesResponse,
  lens: ResourceLens,
  metric: ResourceMetric = "raw",
  canvasHeight = 368,
): { nodes: SankeyInputNode[]; links: SankeyInputLink[] } {
  const nodes: SankeyInputNode[] = [];
  const links: SankeyInputLink[] = [];

  detail.flow.inputs
    .filter((inp) => inp.kind === lens)
    .forEach((inp, idx) => {
      nodes.push({
        id: inp.id,
        column: 0,
        label: inp.label,
        sub: inp.sub,
        color: colorForSource(inp.id, idx),
        fallbackValue: inp.weight,
        fallbackUsd: inp.est_usd_per_h,
      });
    });

  const i2tFiltered = detail.flow.input_to_track.filter((e) => e.kind === lens);
  const t2sFiltered = detail.flow.track_to_subagent.filter((e) => e.kind === lens);

  const subRaw = (s: MissionResourcesResponse["flow"]["subagents"][number]) =>
    lens === "compute" ? s.vcpu : s.b_tok_per_h;
  const subUsd = (s: MissionResourcesResponse["flow"]["subagents"][number]) =>
    lens === "compute" ? s.compute_usd_per_h : s.inference_usd_per_h;
  const subScore = (s: MissionResourcesResponse["flow"]["subagents"][number]) =>
    metric === "usd" ? subUsd(s) : subRaw(s);

  const trackRaw = new Map<string, number>();
  const trackUsd = new Map<string, number>();
  for (const e of i2tFiltered) {
    trackRaw.set(e.target_id, (trackRaw.get(e.target_id) ?? 0) + e.weight);
    trackUsd.set(e.target_id, (trackUsd.get(e.target_id) ?? 0) + e.est_usd_per_h);
  }
  const subSumRawByTrack = new Map<string, number>();
  const subSumUsdByTrack = new Map<string, number>();
  for (const s of detail.flow.subagents) {
    subSumRawByTrack.set(s.track_id, (subSumRawByTrack.get(s.track_id) ?? 0) + subRaw(s));
    subSumUsdByTrack.set(s.track_id, (subSumUsdByTrack.get(s.track_id) ?? 0) + subUsd(s));
  }
  for (const [tid, r] of subSumRawByTrack) {
    if ((trackRaw.get(tid) ?? 0) < r) trackRaw.set(tid, r);
  }
  for (const [tid, u] of subSumUsdByTrack) {
    if ((trackUsd.get(tid) ?? 0) < u) trackUsd.set(tid, u);
  }
  const trackScore = (tid: string) =>
    metric === "usd" ? (trackUsd.get(tid) ?? 0) : (trackRaw.get(tid) ?? 0);

  const tracksWithFlow = detail.flow.tracks.filter(
    (t) =>
      (trackRaw.get(t.id) ?? 0) > 0 ||
      (trackUsd.get(t.id) ?? 0) > 0 ||
      detail.flow.tracks.length <= 5,
  );
  const candidateTracks =
    tracksWithFlow.length > 0 ? tracksWithFlow : detail.flow.tracks.slice(0, 5);

  const maxCol1Tracks = Math.max(
    7,
    Math.min(14, Math.floor((Math.max(340, canvasHeight) - 36) / 47)),
  );
  const sortedTracks = candidateTracks
    .slice()
    .sort((a, b) => trackScore(b.id) - trackScore(a.id) || a.id.localeCompare(b.id));
  const capTracks = sortedTracks.length > maxCol1Tracks + 1;
  const visibleTracks = capTracks ? sortedTracks.slice(0, maxCol1Tracks) : sortedTracks;
  const overflowTracks = capTracks ? sortedTracks.slice(maxCol1Tracks) : [];
  const overflowTrackSet = new Set(overflowTracks.map((t) => t.id));
  const tailTrackId = "track:__other__";

  visibleTracks.forEach((trk, idx) => {
    nodes.push({
      id: trk.id,
      column: 1,
      label: trk.label,
      sub: trk.sub,
      color: MISSION_PALETTE[idx % MISSION_PALETTE.length],
      health: trk.state === "capped" ? "stalled" : "ok",
      fallbackValue: trackRaw.get(trk.id) ?? 0,
      fallbackUsd: trackUsd.get(trk.id) ?? 0,
    });
  });
  if (overflowTracks.length > 0) {
    nodes.push({
      id: tailTrackId,
      column: 1,
      label: `+${overflowTracks.length} tracks`,
      sub: "grouped",
      color: "#6b7280",
      health: "ok",
      fallbackValue: overflowTracks.reduce((s, t) => s + (trackRaw.get(t.id) ?? 0), 0),
      fallbackUsd: overflowTracks.reduce((s, t) => s + (trackUsd.get(t.id) ?? 0), 0),
    });
  }

  const subsWithEdge = new Set(
    t2sFiltered.filter((e) => e.weight > 0 || e.est_usd_per_h > 0).map((e) => e.target_id),
  );
  const subsWithMass = detail.flow.subagents.filter(
    (s) =>
      subsWithEdge.has(s.id) ||
      subRaw(s) > 0 ||
      subUsd(s) > 0 ||
      detail.flow.subagents.length <= 6,
  );
  const candidateSubs =
    subsWithMass.length > 0 ? subsWithMass : detail.flow.subagents.slice(0, 6);

  const maxCol2Subagents = Math.max(
    9,
    Math.min(18, Math.floor((Math.max(340, canvasHeight) - 32) / 34)),
  );
  const sortedSubagents = candidateSubs
    .slice()
    .sort((a, b) => subScore(b) - subScore(a) || a.id.localeCompare(b.id));
  const capSubs = sortedSubagents.length > maxCol2Subagents + 1;
  const visibleSubs = capSubs ? sortedSubagents.slice(0, maxCol2Subagents) : sortedSubagents;
  const overflowSubList = capSubs ? sortedSubagents.slice(maxCol2Subagents) : [];
  const overflowSubSet = new Set(overflowSubList.map((s) => s.id));
  const tailSubId = "sub:__other__";

  visibleSubs.forEach((sub) => {
    nodes.push({
      id: sub.id,
      column: 2,
      label: sub.label,
      sub: [sub.role, sub.model, sub.node_id].filter(Boolean).join(" · "),
      color: colorForMission(sub.id, 0),
      health: sub.state === "capped" ? "stalled" : "ok",
      missionId: sub.mission_id ?? null,
      fallbackValue: subRaw(sub),
      fallbackUsd: subUsd(sub),
    });
  });
  if (overflowSubList.length > 0) {
    nodes.push({
      id: tailSubId,
      column: 2,
      label: `+${overflowSubList.length} active spans`,
      sub: "all in Fast-DAG",
      color: "#6b7280",
      health: "ok",
      missionId: null,
      fallbackValue: overflowSubList.reduce((s, x) => s + subRaw(x), 0),
      fallbackUsd: overflowSubList.reduce((s, x) => s + subUsd(x), 0),
    });
  }

  const i2tAgg = new Map<string, { source: string; target: string; value: number; usd: number; degraded: boolean }>();
  for (const e of i2tFiltered) {
    const tgt = overflowTrackSet.has(e.target_id) ? tailTrackId : e.target_id;
    const key = `${e.source_id}->${tgt}`;
    const prev = i2tAgg.get(key) ?? { source: e.source_id, target: tgt, value: 0, usd: 0, degraded: false };
    prev.value += e.weight;
    prev.usd += e.est_usd_per_h;
    prev.degraded = prev.degraded || e.degraded;
    i2tAgg.set(key, prev);
  }
  for (const [key, agg] of i2tAgg) {
    links.push({
      id: `i2t:${key}`,
      source: agg.source,
      target: agg.target,
      value: agg.value,
      est_usd_per_h: agg.usd,
      degraded: agg.degraded,
    });
  }

  const t2sAgg = new Map<string, { source: string; target: string; value: number; usd: number; degraded: boolean }>();
  for (const e of t2sFiltered) {
    const src = overflowTrackSet.has(e.source_id) ? tailTrackId : e.source_id;
    const tgt = overflowSubSet.has(e.target_id) ? tailSubId : e.target_id;
    const key = `${src}->${tgt}`;
    const prev = t2sAgg.get(key) ?? { source: src, target: tgt, value: 0, usd: 0, degraded: false };
    prev.value += e.weight;
    prev.usd += e.est_usd_per_h;
    prev.degraded = prev.degraded || e.degraded;
    t2sAgg.set(key, prev);
  }
  for (const [key, agg] of t2sAgg) {
    links.push({
      id: `t2s:${key}`,
      source: agg.source,
      target: agg.target,
      value: agg.value,
      est_usd_per_h: agg.usd,
      degraded: agg.degraded,
    });
  }

  return { nodes, links };
}

export type { MissionDagBar };
