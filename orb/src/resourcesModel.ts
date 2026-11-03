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

export interface DagRowLayout {
  bar: {
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
  };
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
  if (id.startsWith("vast:")) return "#7b63cf";
  if (id.startsWith("scaleway:")) return "#8a5cf5";
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

export function formatResourceRate(
  value: number,
  lens: ResourceLens,
  metric: ResourceMetric,
  withUnit = true,
): string {
  const safe = Number.isFinite(value) ? Math.max(0, value) : 0;
  if (metric === "usd") {
    if (!withUnit) {
      if (safe >= 100) return `$${Math.round(safe)}`;
      if (safe >= 10) return `$${safe.toFixed(1)}`;
      return `$${safe.toFixed(2)}`;
    }
    if (safe >= 100) return `$${Math.round(safe)}/h`;
    if (safe >= 10) return `$${safe.toFixed(1)}/h`;
    if (safe >= 0.01) return `$${safe.toFixed(2)}/h`;
    if (safe > 0) return "<$0.01/h";
    return "$0.00/h";
  }

  if (lens === "compute") {
    const rounded1 = Math.round(safe * 10) / 10;
    const num =
      safe >= 10 || Math.abs(rounded1 - Math.round(safe)) < 0.05
        ? String(Math.round(safe))
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
): string {
  const mx = (sourceX + targetX) / 2;
  return `M ${sourceX.toFixed(2)} ${y0.toFixed(2)} C ${mx.toFixed(2)} ${y0.toFixed(2)}, ${mx.toFixed(2)} ${y1.toFixed(2)}, ${targetX.toFixed(2)} ${y1.toFixed(2)}`;
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
    };
    nodesByCol[n.column]?.push(ln);
    nodeMap.set(n.id, ln);
  }

  // Shared scale across all columns so conserved mass has identical pixel height
  let sharedScale = Infinity;
  for (let c = 0; c < columns; c++) {
    const colNodes = nodesByCol[c];
    if (!colNodes || colNodes.length === 0) continue;
    // Sort descending by value for clean reading order
    colNodes.sort((a, b) => b.value - a.value);
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

  const minBarH = 6;
  for (let c = 0; c < columns; c++) {
    const colNodes = nodesByCol[c];
    if (!colNodes || colNodes.length === 0) continue;
    const heights = colNodes.map((n) => Math.max(minBarH, n.value * sharedScale));
    const totalColH =
      heights.reduce((a, b) => a + b, 0) + Math.max(0, colNodes.length - 1) * nodePadding;
    const compress = totalColH > innerH ? innerH / totalColH : 1;
    const effPad = nodePadding * compress;
    const finalTotalH =
      heights.reduce((a, b) => a + b * compress, 0) +
      Math.max(0, colNodes.length - 1) * effPad;
    let cursorY = marginY + Math.max(0, (innerH - finalTotalH) / 2);
    for (let i = 0; i < colNodes.length; i++) {
      const h = Math.max(4, heights[i] * compress);
      colNodes[i].y0 = cursorY;
      colNodes[i].y1 = cursorY + h;
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

  const sourceOffsets = new Map<string, number>();
  for (const [srcId, list] of outBySource) {
    const src = nodeMap.get(srcId)!;
    list.sort((a, b) => (nodeMap.get(a.target)?.y0 ?? 0) - (nodeMap.get(b.target)?.y0 ?? 0));
    const nodeH = Math.max(4, src.y1 - src.y0);
    const sumMetric = list.reduce(
      (s, l) => s + Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value),
      0,
    );
    let offset = src.y0;
    for (const l of list) {
      const mv = Math.max(1e-6, metric === "usd" ? l.est_usd_per_h : l.value);
      const w = (mv / sumMetric) * nodeH;
      sourceOffsets.set(l.id, offset + w / 2);
      offset += w;
    }
  }

  const targetOffsets = new Map<string, { center: number; width: number }>();
  for (const [dstId, list] of inByTarget) {
    const dst = nodeMap.get(dstId)!;
    list.sort((a, b) => (nodeMap.get(a.source)?.y0 ?? 0) - (nodeMap.get(b.source)?.y0 ?? 0));
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
    const y0 = sourceOffsets.get(l.id);
    const tgt = targetOffsets.get(l.id);
    if (!src || !dst || y0 == null || !tgt) continue;
    const mv = Math.max(0, metric === "usd" ? l.est_usd_per_h : l.value);
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
      y0,
      y1: tgt.center,
      width: widthPx,
      path: sankeyRibbonPath(src.x1, dst.x0, y0, tgt.center),
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

export function layoutDagRows(
  bars: DagRowLayout["bar"][],
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

  const rows: DagRowLayout[] = [];
  const byId = new Map<string, DagRowLayout>();
  let cursorY = topPadding;
  let prevSection: string | null = null;

  for (let i = 0; i < bars.length; i++) {
    const b = bars[i];
    const sectionHeader = b.section !== prevSection ? b.section : null;
    prevSection = b.section;
    if (sectionHeader !== null) {
      cursorY += sectionHeaderHeight;
    }
    const barHeight = 16;
    const barY = cursorY + (rowHeight - barHeight) / 2;
    const startFrac = Math.max(0, Math.min(1, b.start_offset_secs / safeHorizon));
    const endFrac = Math.max(
      startFrac + 0.008,
      Math.min(1, (b.start_offset_secs + Math.max(30, b.duration_secs)) / safeHorizon),
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

    const row: DagRowLayout = {
      bar: b,
      index: i,
      sectionHeader,
      y: cursorY,
      barY,
      barHeight,
      startFrac,
      endFrac,
      etaEndFrac,
    };
    rows.push(row);
    byId.set(b.id, row);
    cursorY += rowHeight;
  }

  const edges: DagDependencyEdge[] = [];
  for (const row of rows) {
    for (const depId of row.bar.after_ids) {
      const pred = byId.get(depId);
      if (!pred) continue;
      edges.push({
        id: `${depId}->${row.bar.id}`,
        fromId: depId,
        toId: row.bar.id,
        fromEndFrac: pred.endFrac,
        fromCenterY: pred.barY + pred.barHeight / 2,
        toStartFrac: row.startFrac,
        toCenterY: row.barY + row.barHeight / 2,
      });
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

export function buildOverviewSankeyInput(
  overview: ResourcesOverviewResponse,
  lens: ResourceLens,
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
    overview.inference.pools.forEach((pool, idx) => {
      const remBadge =
        pool.quota_pct_remaining != null
          ? `${Math.round(pool.quota_pct_remaining)}% left`
          : null;
      nodes.push({
        id: pool.id,
        column: 0,
        label: pool.label,
        sub: remBadge ? `${pool.sublabel} · ${remBadge}` : pool.sublabel,
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

  overview.missions.forEach((m, idx) => {
    const hasMass =
      missionIdsWithFlow.has(m.id) ||
      (lens === "compute" ? m.vcpu > 0 : m.b_tok_per_h > 0);
    if (!hasMass && overview.missions.length > 6) return;
    const subParts: string[] = [];
    if (m.subagent_total > 1) {
      subParts.push(
        m.subagent_running > 0
          ? `${m.subagent_running}/${m.subagent_total} agents`
          : `${m.subagent_total} agents`,
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
      color: colorForMission(m.id, idx),
      health: m.stall_kind ? "stalled" : "ok",
      missionId: m.id,
      fallbackValue: lens === "compute" ? m.vcpu : m.b_tok_per_h,
      fallbackUsd: lens === "compute" ? m.compute_usd_per_h : m.inference_usd_per_h,
    });
  });

  relevantLinks.forEach((l, idx) => {
    links.push({
      id: `${l.kind}:${l.source_id}->${l.mission_id}:${idx}`,
      source: l.source_id,
      target: l.mission_id,
      value: l.value,
      est_usd_per_h: l.est_usd_per_h,
      degraded: l.degraded,
    });
  });

  return { nodes, links };
}

export function buildMissionFlowSankeyInput(
  detail: MissionResourcesResponse,
  lens: ResourceLens,
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

  detail.flow.tracks.forEach((trk, idx) => {
    nodes.push({
      id: trk.id,
      column: 1,
      label: trk.label,
      sub: trk.sub,
      color: MISSION_PALETTE[idx % MISSION_PALETTE.length],
      health: trk.state === "capped" ? "stalled" : "ok",
    });
  });

  detail.flow.subagents.forEach((sub, idx) => {
    nodes.push({
      id: sub.id,
      column: 2,
      label: sub.label,
      sub: [sub.role, sub.model, sub.node_id].filter(Boolean).join(" · "),
      color: colorForMission(sub.id, idx),
      health: sub.state === "capped" ? "stalled" : "ok",
      missionId: sub.mission_id ?? null,
      fallbackValue: lens === "compute" ? sub.vcpu : sub.b_tok_per_h,
      fallbackUsd: lens === "compute" ? sub.compute_usd_per_h : sub.inference_usd_per_h,
    });
  });

  detail.flow.input_to_track
    .filter((e) => e.kind === lens)
    .forEach((e, idx) => {
      links.push({
        id: `i2t:${e.source_id}->${e.target_id}:${idx}`,
        source: e.source_id,
        target: e.target_id,
        value: e.weight,
        est_usd_per_h: e.est_usd_per_h,
        degraded: e.degraded,
      });
    });

  detail.flow.track_to_subagent
    .filter((e) => e.kind === lens)
    .forEach((e, idx) => {
      links.push({
        id: `t2s:${e.source_id}->${e.target_id}:${idx}`,
        source: e.source_id,
        target: e.target_id,
        value: e.weight,
        est_usd_per_h: e.est_usd_per_h,
        degraded: e.degraded,
      });
    });

  return { nodes, links };
}

export function pickFastDagCandidate(
  missions: ResourcesOverviewResponse["missions"],
): string | null {
  if (missions.length === 0) return null;
  const multi = missions.find((m) => m.subagent_total > 1 && m.status === "active");
  if (multi) return multi.id;
  const anyMulti = missions.find((m) => m.subagent_total > 1);
  if (anyMulti) return anyMulti.id;
  return missions[0].id;
}

export type { MissionDagBar };
