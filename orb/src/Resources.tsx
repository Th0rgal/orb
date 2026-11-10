import {
  For,
  Show,
  createEffect,
  createMemo,
  createSignal,
  on,
  onCleanup,
  onMount,
} from "solid-js";
import {
  connectionVersion,
  getMissionResources,
  getResourcesOverview,
  type MissionResourcesResponse,
  type ResourcesOverviewResponse,
  type ResourcesWindowRange,
} from "./api";
import { ErrorToast } from "./toast";
import { cachePeek, cachePut } from "./pageCache";
import { pollWhileVisible } from "./poll";
import {
  buildMissionFlowSankeyInput,
  buildOverviewSankeyInput,
  computeMonotoneCurve,
  computeSankeyLayout,
  formatDurationCompact,
  formatLargeNumber,
  formatResourceRate,
  formatTokenTotalCompact,
  layoutDagRows,
  stabilizeTrailingOpenBucket,
  type MissionDetailSubmode,
  type ResourceLens,
  type ResourceMetric,
} from "./resourcesModel";
import "./resources.css";

const FLEET_RANGES: Array<{ id: ResourcesWindowRange; label: string }> = [
  { id: "30m", label: "30m" },
  { id: "1h", label: "1h" },
  { id: "6h", label: "6h" },
  { id: "24h", label: "24h" },
  { id: "7d", label: "7d" },
];

function barColorForState(state: string, role?: string): string {
  if (role === "vm") {
    if (state === "active") return "#22959d";
    if (state === "done") return "#1d9a78";
    if (state === "capped") return "var(--amber)";
    return "var(--fg-4)";
  }
  switch (state) {
    case "done":
      return "var(--green)";
    case "active":
      return "var(--blue)";
    case "capped":
      return "var(--amber)";
    case "cancelled":
      return "var(--fg-3)";
    default:
      return "var(--fg-4)";
  }
}

function statusDotClass(status: string | undefined): string {
  if (!status) return "res-status-dot";
  if (status === "active" || status === "waiting_background") {
    return "res-status-dot is-active";
  }
  if (status === "completed" || status === "acknowledged" || status === "done") {
    return "res-status-dot is-done";
  }
  if (status === "blocked" || status === "failed") {
    return "res-status-dot is-capped";
  }
  return "res-status-dot";
}

const CLOCK_FMT_7D = new Intl.DateTimeFormat(undefined, { weekday: "short", hour: "2-digit" });
const CLOCK_FMT_HM = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });

function formatClockTick(ms: number, range: string): string {
  return range === "7d" ? CLOCK_FMT_7D.format(ms) : CLOCK_FMT_HM.format(ms);
}

function eqIds(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

const MIN_SANKEY_CANVAS_HEIGHT = 330;
const CARD_HEAD_HEIGHT = 38;

export default function Resources(props: {
  missionId?: string | null;
  onOpen: (page: string | null) => void;
}) {
  const [lens, setLens] = createSignal<ResourceLens>("inference");
  const [metric, setMetric] = createSignal<ResourceMetric>("raw");
  const [range, setRange] = createSignal<ResourcesWindowRange>("6h");
  const [horizon, setHorizon] = createSignal<string>("6h");
  const [submode, setSubmode] = createSignal<MissionDetailSubmode>("flow");

  const [overview, setOverview] = createSignal<ResourcesOverviewResponse | null>(
    cachePeek<ResourcesOverviewResponse>("resources:overview:6h") ?? null,
  );
  const [detail, setDetail] = createSignal<MissionResourcesResponse | null>(
    props.missionId ? (cachePeek<MissionResourcesResponse>(`resources:mission:${props.missionId}:6h`) ?? null) : null,
  );
  const [loading, setLoading] = createSignal<boolean>(
    props.missionId
      ? cachePeek<MissionResourcesResponse>(`resources:mission:${props.missionId}:6h`) === undefined
      : cachePeek<ResourcesOverviewResponse>("resources:overview:6h") === undefined,
  );
  const [error, setError] = createSignal<string | null>(null);

  const [isolatedId, setIsolatedId] = createSignal<string | null>(null);
  const [hoveredNodeId, setHoveredNodeId] = createSignal<string | null>(null);
  const [hoveredLinkId, setHoveredLinkId] = createSignal<string | null>(null);
  const [hoveredBarId, setHoveredBarId] = createSignal<string | null>(null);
  const [hoverFrac, setHoverFrac] = createSignal<number | null>(null);

  const [sankeyWidth, setSankeyWidth] = createSignal<number>(920);
  const [sankeyHeight, setSankeyHeight] = createSignal<number>(368);
  const [dagLaneWidth, setDagLaneWidth] = createSignal<number>(720);
  const [curveWidth, setCurveWidth] = createSignal<number>(920);

  let cardMainEl: HTMLDivElement | undefined;
  let sankeyEl: HTMLDivElement | undefined;
  let dagLaneEl: HTMLDivElement | undefined;
  let curveSvgEl: SVGSVGElement | undefined;
  let ro: ResizeObserver | undefined;

  const observedEls = new WeakSet<Element>();

  function observeWidth(el: Element | undefined, apply: (w: number) => void) {
    if (!el || !ro) return;
    if (!observedEls.has(el)) {
      observedEls.add(el);
      ro.observe(el);
    }
    const cw = Math.floor((el as HTMLElement).clientWidth || el.getBoundingClientRect().width);
    if (cw > 40) apply(cw);
  }

  function observeCardMainHeight(el: HTMLDivElement | undefined) {
    if (!el || !ro) return;
    if (!observedEls.has(el)) {
      observedEls.add(el);
      ro.observe(el);
    }
    const ch = Math.floor(el.clientHeight || el.getBoundingClientRect().height);
    if (ch > CARD_HEAD_HEIGHT + 80) {
      const bodyH = Math.max(MIN_SANKEY_CANVAS_HEIGHT, ch - CARD_HEAD_HEIGHT);
      setSankeyHeight((prev) => (Math.abs(prev - bodyH) >= 1 ? bodyH : prev));
    }
  }

  onMount(() => {
    ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.target === cardMainEl) {
          const ch = Math.floor(entry.contentRect.height);
          if (ch > CARD_HEAD_HEIGHT + 80) {
            const bodyH = Math.max(MIN_SANKEY_CANVAS_HEIGHT, ch - CARD_HEAD_HEIGHT);
            setSankeyHeight((prev) => (Math.abs(prev - bodyH) >= 1 ? bodyH : prev));
          }
          continue;
        }
        const w = Math.floor(entry.contentRect.width);
        if (w <= 40) continue;
        if (entry.target === sankeyEl) {
          setSankeyWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev));
        }
        if (entry.target === dagLaneEl) {
          setDagLaneWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev));
        }
        if (entry.target === curveSvgEl) {
          setCurveWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev));
        }
      }
    });
    observeCardMainHeight(cardMainEl);
    observeWidth(sankeyEl, (w) => setSankeyWidth(w));
    observeWidth(dagLaneEl, (w) => setDagLaneWidth(w));
    observeWidth(curveSvgEl, (w) => setCurveWidth(w));
    onCleanup(() => ro?.disconnect());
  });

  let activeAbort: AbortController | null = null;

  async function refresh(showSkeleton = false, isBackgroundPoll = false) {
    activeAbort?.abort();
    const ac = new AbortController();
    activeAbort = ac;

    const mid = props.missionId ?? null;
    if (showSkeleton) setLoading(true);
    try {
      if (mid) {
        const h = horizon();
        const res = await getMissionResources(mid, h, ac.signal);
        if (ac.signal.aborted) return;
        cachePut(`resources:mission:${mid}:${h}`, res);
        setDetail(res);
        setError(null);
      } else {
        const r = range();
        const res = await getResourcesOverview(r, ac.signal);
        if (ac.signal.aborted) return;
        cachePut(`resources:overview:${r}`, res);
        setOverview(res);
        setError(null);
      }
    } catch (err) {
      if (ac.signal.aborted) return;
      const hasRenderedData = mid ? detail()?.mission.id === mid : overview() !== null;
      if (!isBackgroundPoll || !hasRenderedData) {
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      if (!ac.signal.aborted) setLoading(false);
    }
  }

  // Reset per-mission submode when entering/leaving a mission drilldown
  createEffect(
    on(
      () => props.missionId ?? null,
      (mid) => {
        setIsolatedId(null);
        setHoveredNodeId(null);
        setHoveredLinkId(null);
        setHoveredBarId(null);
        setHoverFrac(null);
        if (mid) {
          setSubmode("flow");
        }
      },
    ),
  );

  // React strictly to missionId, range, horizon, or server connection changes
  createEffect(
    on(
      [connectionVersion, () => props.missionId ?? null, range, horizon],
      ([, mid, r, h]) => {
        if (mid) {
          const cached = cachePeek<MissionResourcesResponse>(`resources:mission:${mid}:${h}`);
          if (cached) setDetail(cached);
        } else {
          const cached = cachePeek<ResourcesOverviewResponse>(`resources:overview:${r}`);
          if (cached) setOverview(cached);
        }
        const needsSkeleton = mid ? detail()?.mission.id !== mid : overview() === null;
        setError(null);
        void refresh(needsSkeleton, false);
      },
    ),
  );

  let scrubRect: { el: Element; left: number; width: number } | null = null;
  let scrubRaf = 0;
  let pendingScrubFrac: number | null = null;

  function clearPointerScrub() {
    scrubRect = null;
    pendingScrubFrac = null;
    if (scrubRaf) {
      cancelAnimationFrame(scrubRaf);
      scrubRaf = 0;
    }
    setHoverFrac(null);
  }

  onMount(() => {
    const stop = pollWhileVisible(() => refresh(false, true), 10_000, "app.resources");
    onCleanup(() => {
      stop();
      activeAbort?.abort();
      if (scrubRaf) cancelAnimationFrame(scrubRaf);
    });
  });

  // Re-attach ResizeObserver when conditional DOM panes mount
  createEffect(() => {
    const _mid = props.missionId;
    const _sub = submode();
    const _ld = loading();
    void _mid;
    void _sub;
    void _ld;
    queueMicrotask(() => {
      observeCardMainHeight(cardMainEl);
      observeWidth(sankeyEl, (w) =>
        setSankeyWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev)),
      );
      observeWidth(dagLaneEl, (w) => {
        scrubRect = null;
        setDagLaneWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev));
      });
      observeWidth(curveSvgEl, (w) => {
        scrubRect = null;
        setCurveWidth((prev) => (Math.abs(prev - w) >= 1 ? w : prev));
      });
    });
  });

  const isMissionMode = createMemo(() => Boolean(props.missionId));

  const renderLensToggle = (compact = false) => (
    <div
      class={`res-seg ${compact ? "res-seg-compact" : ""}`}
      role="tablist"
      aria-label="Resource lens"
    >
      <button
        type="button"
        role="tab"
        aria-selected={lens() === "inference"}
        class={`res-seg-btn ${lens() === "inference" ? "is-active" : ""}`}
        data-testid="res-lens-inference"
        onClick={() => setLens("inference")}
      >
        Inference
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={lens() === "compute"}
        class={`res-seg-btn ${lens() === "compute" ? "is-active" : ""}`}
        data-testid="res-lens-compute"
        onClick={() => setLens("compute")}
      >
        Compute
      </button>
    </div>
  );

  const renderMetricToggle = (compact = false) => (
    <div
      class={`res-seg ${compact ? "res-seg-compact" : ""}`}
      role="group"
      aria-label="Display unit"
    >
      <button
        type="button"
        class={`res-seg-btn ${metric() === "raw" ? "is-active" : ""}`}
        data-testid="res-metric-raw"
        onClick={() => setMetric("raw")}
      >
        {rawUnitLabel()}
      </button>
      <button
        type="button"
        class={`res-seg-btn ${metric() === "usd" ? "is-active" : ""}`}
        data-testid="res-metric-usd"
        onClick={() => setMetric("usd")}
        title="Switch to estimated USD burn rate"
      >
        $
      </button>
    </div>
  );

  // Sankey layout memo (used in Fleet mode & Mission "flow" submode)
  const sankeyGraph = createMemo(() => {
    const l = lens();
    const m = metric();
    const w = sankeyWidth();
    const h = sankeyHeight();
    if (isMissionMode()) {
      const det = detail();
      if (!det) return null;
      const { nodes, links } = buildMissionFlowSankeyInput(det, l, m, h);
      return {
        height: h,
        layout: computeSankeyLayout(nodes, links, {
          width: w,
          height: h,
          metric: m,
          marginX: 204,
          marginY: 16,
        }),
      };
    }
    const ov = overview();
    if (!ov) return null;
    const { nodes, links } = buildOverviewSankeyInput(ov, l, m, h);
    return {
      height: h,
      layout: computeSankeyLayout(nodes, links, {
        width: w,
        height: h,
        metric: m,
        marginX: 204,
        marginY: 16,
      }),
    };
  });

  const sankeyLinkMap = createMemo(
    () => new Map((sankeyGraph()?.layout.links ?? []).map((l) => [l.id, l])),
  );
  const sankeyLinkIds = createMemo(
    () => sankeyGraph()?.layout.links.map((l) => l.id) ?? [],
    [],
    { equals: eqIds },
  );
  const sankeyNodeMap = createMemo(
    () => new Map((sankeyGraph()?.layout.nodes ?? []).map((n) => [n.id, n])),
  );
  const sankeyNodeIds = createMemo(
    () => sankeyGraph()?.layout.nodes.map((n) => n.id) ?? [],
    [],
    { equals: eqIds },
  );

  // Fast-DAG layout memo
  const dagLayout = createMemo(() => {
    const det = detail();
    if (!det) return null;
    return layoutDagRows(det.dag.bars, det.dag.horizon_secs);
  });

  const dagRowMap = createMemo(
    () => new Map((dagLayout()?.rows ?? []).map((r) => [r.id, r])),
  );
  const dagRowIds = createMemo(
    () => dagLayout()?.rows.map((r) => r.id) ?? [],
    [],
    { equals: eqIds },
  );
  const dagBarById = createMemo(() => {
    type DagBar = MissionResourcesResponse["dag"]["bars"][number];
    const map = new Map<string, DagBar>();
    for (const row of dagLayout()?.rows ?? []) {
      for (const sp of row.spans) {
        map.set(sp.bar.id, sp.bar as DagBar);
      }
    }
    for (const b of detail()?.dag.bars ?? []) {
      if (!map.has(b.id)) map.set(b.id, b);
    }
    return map;
  });
  const dagEdgeMap = createMemo(
    () => new Map((dagLayout()?.edges ?? []).map((e) => [e.id, e])),
  );
  const dagEdgeIds = createMemo(
    () => dagLayout()?.edges.map((e) => e.id) ?? [],
    [],
    { equals: eqIds },
  );

  const isolatedLabel = createMemo(() => {
    const id = isolatedId();
    if (!id) return null;
    return sankeyNodeMap().get(id)?.label ?? id;
  });

  // Header live summary stamp
  const headerStamp = createMemo(() => {
    const l = lens();
    const m = metric();
    if (isMissionMode()) {
      const det = detail();
      if (!det) return { primary: "—", secondary: null };
      const activeVmBars = det.dag.bars.filter(
        (b) => b.role === "vm" && b.state === "active",
      );
      const sumVcpu =
        activeVmBars.length > 0
          ? activeVmBars.reduce((s, b) => s + b.vcpu, 0)
          : det.flow.subagents.reduce((s, a) => s + a.vcpu, 0);
      const sumCu =
        activeVmBars.length > 0
          ? activeVmBars.reduce((s, b) => s + b.compute_usd_per_h, 0)
          : det.flow.subagents.reduce((s, a) => s + a.compute_usd_per_h, 0);
      const sumBtok = det.flow.subagents.reduce((s, a) => s + a.b_tok_per_h, 0);
      const sumIu = det.flow.subagents.reduce((s, a) => s + a.inference_usd_per_h, 0);
      const primary =
        l === "compute"
          ? formatResourceRate(m === "usd" ? sumCu : sumVcpu, "compute", m, true)
          : formatResourceRate(m === "usd" ? sumIu : sumBtok, "inference", m, true);
      const eta =
        det.mission.eta_remaining_secs != null && det.mission.eta_remaining_secs > 0
          ? `ETA ~${formatDurationCompact(det.mission.eta_remaining_secs)}`
          : `${formatDurationCompact(det.mission.elapsed_secs)} elapsed`;
      return { primary, secondary: eta };
    }

    const ov = overview();
    if (!ov) return { primary: "—", secondary: null };
    if (l === "compute") {
      const primary =
        m === "usd"
          ? formatResourceRate(ov.compute.hourly_burn_usd, "compute", "usd", true)
          : `${formatResourceRate(ov.compute.active_vcpu, "compute", "raw", false)}/${formatResourceRate(ov.compute.total_vcpu, "compute", "raw", true)}`;
      const secondary =
        ov.compute.idle_leased_vcpu > 0.4
          ? `${formatLargeNumber(ov.compute.idle_leased_vcpu)} idle vCPU`
          : `${formatLargeNumber(ov.missions.length)} mission${ov.missions.length === 1 ? "" : "s"}`;
      return { primary, secondary };
    }
    const primary = formatResourceRate(
      m === "usd" ? ov.inference.est_usd_per_h : ov.inference.current_b_tok_per_h,
      "inference",
      m,
      true,
    );
    const secondary =
      m === "usd"
        ? `${formatResourceRate(ov.inference.window_est_usd, "inference", "usd", false)} (${ov.range})`
        : `${formatTokenTotalCompact(ov.inference.window_total_tokens)} (${ov.range})`;
    return { primary, secondary };
  });

  // Hover readout text in card header
  const activeReadout = createMemo(() => {
    const l = lens();
    const m = metric();
    const hlId = hoveredLinkId();
    if (hlId) {
      const link = sankeyLinkMap().get(hlId);
      if (link) {
        const src = sankeyNodeMap().get(link.source)?.label ?? link.source;
        const dst = sankeyNodeMap().get(link.target)?.label ?? link.target;
        const val = formatResourceRate(
          m === "usd" ? link.usdValue : link.rawValue,
          l,
          m,
          true,
        );
        return `${src} → ${dst} · ${val}`;
      }
    }
    const hnId = hoveredNodeId();
    if (hnId) {
      const node = sankeyNodeMap().get(hnId);
      if (node) {
        const val = formatResourceRate(
          m === "usd" ? node.usdValue : node.rawValue,
          l,
          m,
          true,
        );
        return node.sub ? `${node.label} · ${val} · ${node.sub}` : `${node.label} · ${val}`;
      }
    }
    if (hoveredBarId() && detail()) {
      const bar = dagBarById().get(hoveredBarId()!);
      if (bar) {
        const effLens = bar.role === "vm" ? "compute" : l;
        const rateVal =
          effLens === "compute"
            ? m === "usd"
              ? bar.compute_usd_per_h
              : bar.vcpu
            : m === "usd"
              ? bar.inference_usd_per_h
              : bar.b_tok_per_h;
        const parts = [
          bar.label,
          formatResourceRate(rateVal, effLens, m, true),
          formatDurationCompact(bar.duration_secs),
        ];
        if (bar.eta_remaining_secs && bar.eta_remaining_secs > 0 && bar.state === "active") {
          parts.push(
            bar.role === "vm"
              ? `lease ~${formatDurationCompact(bar.eta_remaining_secs)}`
              : `~${formatDurationCompact(bar.eta_remaining_secs)} left`,
          );
        }
        return parts.join(" · ");
      }
    }
    return null;
  });

  // Synchronized bottom consumption curve geometry
  const curveGeometry = createMemo(() => {
    const l = lens();
    const m = metric();
    const w = Math.max(240, curveWidth());
    const h = 108;
    const padX = 8;
    const topY = 12;
    const baseY = h - 20;
    const plotW = w - padX * 2;
    const plotH = baseY - topY;

    if (isMissionMode()) {
      const det = detail();
      if (!det || det.timeline.offsets_secs.length === 0) return null;
      const t = det.timeline;
      const obsArr =
        l === "compute"
          ? m === "usd"
            ? t.observed_compute_usd_per_h
            : t.observed_vcpu
          : m === "usd"
            ? t.observed_inference_usd_per_h
            : t.observed_b_tok_per_h;
      const projArr =
        l === "compute"
          ? m === "usd"
            ? t.projected_compute_usd_per_h
            : t.projected_vcpu
          : m === "usd"
            ? t.projected_inference_usd_per_h
            : t.projected_b_tok_per_h;

      let maxVal = 0;
      for (let i = 0; i < t.offsets_secs.length; i++) {
        maxVal = Math.max(maxVal, obsArr[i] ?? 0, projArr[i] ?? 0);
      }
      const peak = maxVal;
      const denom = maxVal > 0 ? maxVal * 1.12 : 1;
      const n = Math.max(1, t.offsets_secs.length - 1);

      const obsPts: Array<{ x: number; y: number; idx: number; val: number }> = [];
      const projPts: Array<{ x: number; y: number; idx: number; val: number }> = [];

      for (let i = 0; i < t.offsets_secs.length; i++) {
        const x = padX + (i / n) * plotW;
        const ovVal = obsArr[i];
        if (ovVal != null) {
          obsPts.push({ x, y: baseY - (ovVal / denom) * plotH, idx: i, val: ovVal });
        }
        const prVal = projArr[i];
        if (prVal != null) {
          projPts.push({ x, y: baseY - (prVal / denom) * plotH, idx: i, val: prVal });
        }
      }

      const nowFrac =
        det.dag.horizon_secs > 0
          ? Math.max(0, Math.min(1, det.dag.now_offset_secs / det.dag.horizon_secs))
          : null;

      return {
        width: w,
        height: h,
        padX,
        plotW,
        baseY,
        peak,
        observed: computeMonotoneCurve(obsPts, baseY),
        projected: projPts.length > 1 ? computeMonotoneCurve(projPts, baseY) : null,
        nowX: nowFrac != null ? padX + nowFrac * plotW : null,
        startLabel: "0m",
        endLabel: formatDurationCompact(det.dag.horizon_secs),
        valueAtFrac: (frac: number) => {
          const idx = Math.min(
            t.offsets_secs.length - 1,
            Math.max(0, Math.round(frac * n)),
          );
          const v = obsArr[idx] ?? projArr[idx] ?? 0;
          const isProj = obsArr[idx] == null && projArr[idx] != null;
          return {
            timeLabel: `+${formatDurationCompact(t.offsets_secs[idx])}${isProj ? " (proj)" : ""}`,
            valLabel: formatResourceRate(v, l, m, true),
          };
        },
      };
    }

    const ov = overview();
    if (!ov || ov.timestamps_ms.length === 0) return null;
    const len = ov.timestamps_ms.length;
    const filterId = isolatedId();
    const values = new Array<number>(len).fill(0);
    const visibleCol1Ids = new Set(
      (sankeyGraph()?.layout.nodes ?? [])
        .filter((n) => n.column === 1 && n.id !== "__other_missions__")
        .map((n) => n.id),
    );

    if (l === "compute") {
      const srcMatch = filterId
        ? ov.compute.sources.find((s) => s.id === filterId)
        : null;
      const misMatch = filterId ? ov.missions.find((ms) => ms.id === filterId) : null;
      if (srcMatch) {
        const arr = m === "usd" ? srcMatch.series_usd_per_h : srcMatch.series_vcpu;
        for (let i = 0; i < len; i++) values[i] = arr[i] ?? 0;
      } else if (misMatch) {
        const arr =
          m === "usd" ? misMatch.series_compute_usd_per_h : misMatch.series_vcpu;
        for (let i = 0; i < len; i++) values[i] = arr[i] ?? 0;
      } else if (filterId === "__other_missions__") {
        for (const ms of ov.missions) {
          if (visibleCol1Ids.has(ms.id)) continue;
          const arr = m === "usd" ? ms.series_compute_usd_per_h : ms.series_vcpu;
          for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
        }
      } else {
        for (const s of ov.compute.sources) {
          const arr = m === "usd" ? s.series_usd_per_h : s.series_vcpu;
          for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
        }
      }
    } else {
      const poolMatch = filterId
        ? ov.inference.pools.find((p) => p.id === filterId)
        : null;
      const misMatch = filterId ? ov.missions.find((ms) => ms.id === filterId) : null;
      if (poolMatch) {
        const arr =
          m === "usd" ? poolMatch.series_usd_per_h : poolMatch.series_b_tok_per_h;
        for (let i = 0; i < len; i++) values[i] = arr[i] ?? 0;
      } else if (misMatch) {
        const arr =
          m === "usd"
            ? misMatch.series_inference_usd_per_h
            : misMatch.series_b_tok_per_h;
        for (let i = 0; i < len; i++) values[i] = arr[i] ?? 0;
      } else if (filterId === "__other_missions__") {
        for (const ms of ov.missions) {
          if (visibleCol1Ids.has(ms.id)) continue;
          const arr =
            m === "usd" ? ms.series_inference_usd_per_h : ms.series_b_tok_per_h;
          for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
        }
      } else {
        for (const p of ov.inference.pools) {
          const arr = m === "usd" ? p.series_usd_per_h : p.series_b_tok_per_h;
          for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
        }
      }
    }

    const hasActiveFleet =
      ov.missions.some(
        (ms) =>
          ms.status === "active" ||
          ms.status === "waiting_background" ||
          ms.subagent_running > 0,
      ) || ov.compute.active_vcpu > 0;
    const asOfMs = Date.parse(ov.as_of);
    const lastBucketStartMs = ov.timestamps_ms[len - 1] ?? 0;
    const openElapsedFrac =
      Number.isFinite(asOfMs) && ov.bucket_seconds > 0
        ? Math.max(0, Math.min(1, (asOfMs - lastBucketStartMs) / (ov.bucket_seconds * 1000)))
        : undefined;
    const displayValues = stabilizeTrailingOpenBucket(
      values,
      hasActiveFleet,
      openElapsedFrac,
    );

    const peak = displayValues.reduce((a, b) => Math.max(a, b), 0);
    const denom = peak > 0 ? peak * 1.12 : 1;
    const n = Math.max(1, len - 1);
    const pts = displayValues.map((v, i) => ({
      x: padX + (i / n) * plotW,
      y: baseY - (v / denom) * plotH,
    }));

    return {
      width: w,
      height: h,
      padX,
      plotW,
      baseY,
      peak,
      observed: computeMonotoneCurve(pts, baseY),
      projected: null,
      nowX: null,
      startLabel: formatClockTick(ov.timestamps_ms[0], ov.range),
      endLabel: "now",
      valueAtFrac: (frac: number) => {
        const idx = Math.min(len - 1, Math.max(0, Math.round(frac * n)));
        return {
          timeLabel: formatClockTick(ov.timestamps_ms[idx], ov.range),
          valLabel: formatResourceRate(displayValues[idx] ?? 0, l, m, true),
        };
      },
    };
  });

  function isLinkDimmed(linkId: string, source: string, target: string): boolean {
    const hl = hoveredLinkId();
    if (hl) return hl !== linkId;
    const hn = hoveredNodeId() ?? isolatedId();
    if (hn) return source !== hn && target !== hn;
    return false;
  }

  function handleNodeClick(node: {
    id: string;
    column: number;
    missionId?: string | null;
  }) {
    if (!isMissionMode()) {
      if (node.column === 1 && node.missionId) {
        props.onOpen(`rm:${node.missionId}`);
        return;
      }
      setIsolatedId((prev) => (prev === node.id ? null : node.id));
      return;
    }
    if (node.column === 2 && node.missionId) {
      props.onOpen(`m:${node.missionId}`);
      return;
    }
    if (node.id === "sub:__other__") {
      setSubmode("dag");
      return;
    }
    setIsolatedId((prev) => (prev === node.id ? null : node.id));
  }

  function handleLinkClick(link: { source: string; target: string }) {
    if (!isMissionMode()) {
      const ov = overview();
      if (ov?.missions.some((m) => m.id === link.target)) {
        props.onOpen(`rm:${link.target}`);
      }
    }
  }

  function handlePointerScrub(e: MouseEvent, el: Element, padLeft = 0, padRight = 0) {
    if (!scrubRect || scrubRect.el !== el) {
      const r = el.getBoundingClientRect();
      scrubRect = { el, left: r.left, width: r.width };
    }
    const inner = Math.max(1, scrubRect.width - padLeft - padRight);
    const frac = Math.max(0, Math.min(1, (e.clientX - scrubRect.left - padLeft) / inner));
    if (scrubRaf === 0) {
      setHoverFrac(frac);
      scrubRaf = requestAnimationFrame(() => {
        scrubRaf = 0;
        if (pendingScrubFrac !== null) {
          const next = pendingScrubFrac;
          pendingScrubFrac = null;
          setHoverFrac(next);
        }
      });
    } else {
      pendingScrubFrac = frac;
    }
  }

  const rawUnitLabel = createMemo(() => (lens() === "compute" ? "vCPU" : "B tok/h"));

  return (
    <div class="res-page" data-testid="resources-page">
      {/* Top Control Bar */}
      <div class="res-topbar">
        <div class="res-topbar-left">
          <Show when={isMissionMode()}>
            <button
              type="button"
              class="res-btn"
              data-testid="res-back-fleet"
              onClick={() => props.onOpen("resources")}
            >
              ← Fleet
            </button>
            <Show when={detail()}>
              {(det) => (
                <>
                  <div class="res-mission-crumb" title={det().mission.title}>
                    <span class={statusDotClass(det().mission.status)} />
                    <span class="res-mission-crumb-title">
                      {det().mission.title || det().mission.id.slice(0, 8)}
                    </span>
                  </div>
                  <button
                    type="button"
                    class="res-btn"
                    data-testid="res-open-transcript"
                    onClick={() => props.onOpen(`m:${det().mission.id}`)}
                  >
                    Transcript ↗
                  </button>
                </>
              )}
            </Show>
          </Show>

          <Show when={!isMissionMode()}>{renderLensToggle(false)}</Show>

          <Show when={isMissionMode()}>
            <div class="res-seg" role="tablist" aria-label="Mission view mode">
              <button
                type="button"
                role="tab"
                aria-selected={submode() === "flow"}
                class={`res-seg-btn ${submode() === "flow" ? "is-active" : ""}`}
                data-testid="res-submode-flow"
                onClick={() => setSubmode("flow")}
              >
                Flow
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={submode() === "dag"}
                class={`res-seg-btn ${submode() === "dag" ? "is-active" : ""}`}
                data-testid="res-submode-dag"
                onClick={() => setSubmode("dag")}
              >
                Fast-DAG
              </button>
            </div>
          </Show>
        </div>

        <div class="res-topbar-right">
          <div class="res-stamp" data-testid="res-summary-stamp">
            <strong>{headerStamp().primary}</strong>
            <Show when={headerStamp().secondary}>
              <span class="res-stamp-sep">·</span>
              <span>{headerStamp().secondary}</span>
            </Show>
          </div>

          <Show when={!isMissionMode()}>{renderMetricToggle(false)}</Show>
        </div>
      </div>

      <ErrorToast
        error={error()}
        background
        action={{
          label: "Retry",
          run: () => refresh(isMissionMode() ? detail()?.mission.id !== props.missionId : overview() === null),
        }}
      />

      {/* Main Flow / Fast-DAG Card */}
      <div class="res-card res-card-main" ref={cardMainEl}>
        <Show
          when={!loading()}
          fallback={
            <>
              <div class="res-card-head">
                <div class="res-skel" style={{ height: "14px", width: "210px" }} />
                <div class="res-skel" style={{ height: "14px", width: "180px" }} />
              </div>
              <div style={{ padding: "14px", flex: "1 1 0", "min-height": "0" }}>
                <div
                  class="res-skel"
                  style={{ height: "100%", width: "100%" }}
                />
              </div>
            </>
          }
        >
          <Show
            when={isMissionMode() && submode() === "dag"}
            fallback={
              <>
                <div class="res-card-head">
                  <div class="res-card-head-left">
                    <span class="res-col-title">
                      {isMissionMode()
                        ? `${lens() === "compute" ? "Machines" : "Pools"} → Tracks → Subagents`
                        : `${lens() === "compute" ? "Inputs · Machines" : "Inputs · Quota Pools"} → Missions`}
                    </span>
                    <Show when={isolatedLabel()}>
                      {(isoLabel) => (
                        <button
                          type="button"
                          class="res-filter-chip"
                          data-testid="res-clear-filter"
                          onClick={() => setIsolatedId(null)}
                        >
                          Filtered: {isoLabel()} ×
                        </button>
                      )}
                    </Show>
                  </div>
                  <div class="res-card-head-right">
                    <Show
                      when={activeReadout()}
                      fallback={
                        <span class="res-head-hint">
                          {isMissionMode()
                            ? "Click subagent to open transcript"
                            : "Click a mission to inspect resource flow"}
                        </span>
                      }
                    >
                      {(txt) => <span class="res-hover-pill">{txt()}</span>}
                    </Show>
                  </div>
                </div>

                <div class="res-sankey-wrap" ref={sankeyEl}>
                  <Show
                    when={
                      sankeyGraph() &&
                      sankeyGraph()!.layout.nodes.length > 0 &&
                      (sankeyGraph()!.layout.links.length > 0 ||
                        sankeyGraph()!.layout.nodes.some((n) => n.value > 0))
                    }
                    fallback={
                      <div
                        class="res-empty"
                        data-testid="res-empty-state"
                      >
                        <div class="res-empty-title">
                          No {lens()} flow recorded in this window
                        </div>
                        <div class="res-empty-sub">
                          {lens() === "compute"
                            ? "Active local host runs, remote fleet jobs, and leased cloud VMs appear here automatically as missions execute."
                            : "Token throughput and quota-pool consumption appear here automatically as missions stream responses."}
                        </div>
                      </div>
                    }
                  >
                    <svg
                      class="res-sankey-svg"
                      data-testid="res-sankey-svg"
                      viewBox={`0 0 ${sankeyWidth()} ${sankeyHeight()}`}
                      style={{ height: `${sankeyHeight()}px` }}
                    >
                      <g>
                        <For each={sankeyLinkIds()}>
                          {(id) => {
                            const link = () => sankeyLinkMap().get(id);
                            return (
                              <Show when={link()}>
                                {(lk) => {
                                  const dimmed = () =>
                                    isLinkDimmed(id, lk().source, lk().target);
                                  const isHov = () => hoveredLinkId() === id;
                                  return (
                                    <path
                                      class="res-sankey-link"
                                      data-testid={`res-link-${lk().source}-${lk().target}`}
                                      d={lk().path}
                                      fill={lk().color}
                                      fill-opacity={dimmed() ? 0.1 : isHov() ? 0.56 : 0.32}
                                      stroke={lk().degraded ? lk().color : "none"}
                                      stroke-width={lk().degraded ? 1.1 : 0}
                                      stroke-dasharray={lk().degraded ? "4 3" : undefined}
                                      stroke-opacity={dimmed() ? 0.16 : isHov() ? 0.85 : 0.55}
                                      onMouseEnter={() => setHoveredLinkId(id)}
                                      onMouseLeave={() =>
                                        setHoveredLinkId((prev) => (prev === id ? null : prev))
                                      }
                                      onClick={() => handleLinkClick(lk())}
                                    />
                                  );
                                }}
                              </Show>
                            );
                          }}
                        </For>
                      </g>

                      <g>
                        <For each={sankeyNodeIds()}>
                          {(id) => {
                            const node = () => sankeyNodeMap().get(id);
                            return (
                              <Show when={node()}>
                                {(nd) => {
                                  const isLeft = () => nd().column === 0;
                                  const isRight = () =>
                                    nd().column === (sankeyGraph()?.layout.columns ?? 2) - 1;
                                  const isMiddle = () => !isLeft() && !isRight();
                                  const centerY = () => (nd().y0 + nd().y1) / 2;
                                  const barH = () => Math.max(5, nd().y1 - nd().y0);
                                  const valStr = () =>
                                    formatResourceRate(
                                      metric() === "usd" ? nd().usdValue : nd().rawValue,
                                      lens(),
                                      metric(),
                                      true,
                                    );
                                  const labelText = () => {
                                    const maxLen = isMiddle() ? 18 : 24;
                                    return nd().label.length > maxLen
                                      ? `${nd().label.slice(0, maxLen - 1)}…`
                                      : nd().label;
                                  };
                                  const subText = () => {
                                    if (!nd().sub) return valStr();
                                    const rawSub =
                                      nd().sub.length > 18
                                        ? `${nd().sub.slice(0, 17)}…`
                                        : nd().sub;
                                    return `${valStr()} · ${rawSub}`;
                                  };
                                  const hitX = () =>
                                    isLeft()
                                      ? Math.max(0, nd().x0 - (nd().showLabel ? 192 : 18))
                                      : isMiddle()
                                        ? nd().x0 - (nd().showLabel ? 72 : 10)
                                        : nd().x0 - 6;
                                  const hitW = () =>
                                    isLeft()
                                      ? nd().x1 - hitX() + 6
                                      : isRight()
                                        ? (nd().showLabel ? 196 : 22) + (nd().x1 - nd().x0)
                                        : nd().showLabel
                                          ? 156
                                          : nd().x1 - nd().x0 + 20;
                                  return (
                                    <g
                                      class="res-sankey-node-group"
                                      data-testid={`res-node-${id}`}
                                      onMouseEnter={() => setHoveredNodeId(id)}
                                      onMouseLeave={() =>
                                        setHoveredNodeId((prev) => (prev === id ? null : prev))
                                      }
                                      onClick={() => handleNodeClick(nd())}
                                    >
                                      <title>
                                        {`${nd().label} · ${valStr()}${nd().sub ? ` (${nd().sub})` : ""}`}
                                      </title>
                                      <rect
                                        x={hitX()}
                                        y={nd().y0 - 3}
                                        width={hitW()}
                                        height={Math.max(12, barH() + 6)}
                                        fill="transparent"
                                      />
                                      <rect
                                        x={nd().x0}
                                        y={nd().y0}
                                        width={nd().x1 - nd().x0}
                                        height={barH()}
                                        rx={3}
                                        fill={nd().color}
                                        opacity={
                                          isolatedId() && isolatedId() !== id
                                            ? 0.42
                                            : hoveredNodeId() === id
                                              ? 1
                                              : 0.92
                                        }
                                      />
                                      <Show when={nd().showLabel}>
                                        <Show when={isMiddle()}>
                                          <rect
                                            class="res-sankey-mid-pill"
                                            x={
                                              (nd().x0 + nd().x1) / 2 -
                                              (labelText().length * 3.4 + 8)
                                            }
                                            y={centerY() - 9}
                                            width={labelText().length * 6.8 + 16}
                                            height={18}
                                            rx={5}
                                          />
                                        </Show>
                                        <text
                                          class={`res-sankey-node-label ${isMiddle() ? "is-middle" : ""}`}
                                          x={
                                            isLeft()
                                              ? nd().x0 - 10
                                              : isRight()
                                                ? nd().x1 + 10
                                                : (nd().x0 + nd().x1) / 2
                                          }
                                          y={nd().showSub ? centerY() - 5 : centerY() + 4}
                                          text-anchor={
                                            isLeft() ? "end" : isRight() ? "start" : "middle"
                                          }
                                        >
                                          {labelText()}
                                        </text>
                                      </Show>
                                      <Show when={nd().showSub}>
                                        <text
                                          class="res-sankey-node-sub"
                                          x={
                                            isLeft()
                                              ? nd().x0 - 10
                                              : isRight()
                                                ? nd().x1 + 10
                                                : (nd().x0 + nd().x1) / 2
                                          }
                                          y={centerY() + 9}
                                          text-anchor={
                                            isLeft() ? "end" : isRight() ? "start" : "middle"
                                          }
                                        >
                                          {subText()}
                                        </text>
                                      </Show>
                                    </g>
                                  );
                                }}
                              </Show>
                            );
                          }}
                        </For>
                      </g>
                    </svg>
                  </Show>
                </div>
              </>
            }
          >
            {/* Mission Fast-DAG View */}
            <div class="res-card-head">
              <div class="res-card-head-left">
                <span class="res-col-title">
                  {(() => {
                    const rows = dagLayout()?.rows ?? [];
                    const laneCount = rows.length;
                    const spanCount = rows.reduce((s, r) => s + r.spans.length, 0);
                    return laneCount > 0 && spanCount > laneCount
                      ? `Execution DAG · ${formatLargeNumber(laneCount)} ${laneCount === 1 ? "lane" : "lanes"} · ${formatLargeNumber(spanCount)} spans`
                      : `Subagent Execution DAG · ${formatLargeNumber(spanCount)} ${spanCount === 1 ? "span" : "spans"}`;
                  })()}
                </span>
              </div>
              <div class="res-card-head-right">
                <Show
                  when={activeReadout()}
                  fallback={
                    <span class="res-head-hint">
                      Hover to scrub · Click subagent to open transcript
                    </span>
                  }
                >
                  {(txt) => <span class="res-hover-pill">{txt()}</span>}
                </Show>
              </div>
            </div>

            <Show
              when={dagLayout() && dagLayout()!.rows.length > 0 ? dagLayout() : null}
              fallback={
                <div class="res-empty">
                  <div class="res-empty-title">No subagent spans recorded yet</div>
                </div>
              }
            >
              {(dag) => {
                const nowFrac = () => {
                  const det = detail()!;
                  return det.dag.horizon_secs > 0
                    ? Math.max(
                        0,
                        Math.min(1, det.dag.now_offset_secs / det.dag.horizon_secs),
                      )
                    : 1;
                };
                return (
                  <div class="res-dag-scroll" data-testid="res-dag-view">
                    <div
                      class="res-dag-layout"
                      style={{ height: `${dag().totalHeight}px` }}
                    >
                      <div class="res-dag-labels">
                        <For each={dagRowIds()}>
                          {(rowId) => {
                            const row = () => dagRowMap().get(rowId);
                            return (
                              <Show when={row()}>
                                {(rw) => {
                                  const activeSpan = () => {
                                    const hid = hoveredBarId();
                                    if (!hid) return null;
                                    return rw().spans.find((sp) => sp.bar.id === hid) ?? null;
                                  };
                                  const dispBar = () => activeSpan()?.bar ?? rw().bar;
                                  return (
                                    <>
                                      <Show when={rw().sectionHeader}>
                                        {(sec) => (
                                          <div
                                            class="res-dag-sec-hdr"
                                            style={{ top: `${rw().y - 20}px` }}
                                          >
                                            {sec()}
                                          </div>
                                        )}
                                      </Show>
                                      <button
                                        type="button"
                                        class={`res-dag-row-label ${activeSpan() ? "is-hovered" : ""}`}
                                        style={{ top: `${rw().y + 2}px` }}
                                        data-testid={`res-dag-row-${rw().bar.id}`}
                                        onMouseEnter={() => setHoveredBarId(rw().bar.id)}
                                        onMouseLeave={() =>
                                          setHoveredBarId((prev) =>
                                            prev === rw().bar.id ? null : prev,
                                          )
                                        }
                                        onClick={() => {
                                          const mid = dispBar().mission_id;
                                          if (mid) props.onOpen(`m:${mid}`);
                                        }}
                                        title={
                                          rw().spans.length > 1
                                            ? rw()
                                                .spans.map((sp) => sp.bar.label)
                                                .join(" → ")
                                            : rw().bar.label
                                        }
                                      >
                                        <span class="res-dag-row-title">{dispBar().label}</span>
                                        <span class="res-dag-row-meta">
                                          <Show
                                            when={!activeSpan() && rw().spans.length > 1}
                                            fallback={formatDurationCompact(
                                              dispBar().duration_secs,
                                            )}
                                          >
                                            <span class="res-dag-lane-count">
                                              {rw().spans.length}×
                                            </span>
                                            {formatDurationCompact(rw().totalDurationSecs)}
                                          </Show>
                                        </span>
                                      </button>
                                    </>
                                  );
                                }}
                              </Show>
                            );
                          }}
                        </For>
                      </div>

                      <div
                        class="res-dag-canvas"
                        ref={dagLaneEl}
                        onMouseEnter={() => { scrubRect = null; }}
                        onMouseMove={(e) => handlePointerScrub(e, e.currentTarget, 8, 8)}
                        onMouseLeave={clearPointerScrub}
                      >
                        <svg
                          class="res-dag-svg"
                          viewBox={`0 0 ${dagLaneWidth()} ${dag().totalHeight}`}
                          style={{ height: `${dag().totalHeight}px` }}
                        >
                          {/* Subtle grid lines */}
                          <For each={[0.25, 0.5, 0.75]}>
                            {(tick) => {
                              const gx = () => 8 + tick * (dagLaneWidth() - 16);
                              return (
                                <line
                                  x1={gx()}
                                  y1={0}
                                  x2={gx()}
                                  y2={dag().totalHeight}
                                  stroke="var(--stroke-soft)"
                                  stroke-width="1"
                                />
                              );
                            }}
                          </For>

                          {/* Dependency connectors (`after_ids`) */}
                          <For each={dagEdgeIds()}>
                            {(edgeId) => {
                              const edge = () => dagEdgeMap().get(edgeId);
                              return (
                                <Show when={edge()}>
                                  {(ed) => {
                                    const plotW = () => Math.max(40, dagLaneWidth() - 16);
                                    const x0 = () => 8 + ed().fromEndFrac * plotW();
                                    const x1 = () => 8 + ed().toStartFrac * plotW();
                                    const mx = () => (x0() + x1()) / 2;
                                    const sameLane = () =>
                                      Math.abs(ed().fromCenterY - ed().toCenterY) < 0.5;
                                    return (
                                      <path
                                        d={
                                          sameLane()
                                            ? `M ${x0()} ${ed().fromCenterY} L ${x1()} ${ed().toCenterY}`
                                            : `M ${x0()} ${ed().fromCenterY} C ${mx()} ${ed().fromCenterY}, ${mx()} ${ed().toCenterY}, ${x1()} ${ed().toCenterY}`
                                        }
                                        fill="none"
                                        stroke="var(--stroke-strong)"
                                        stroke-width="1.2"
                                      />
                                    );
                                  }}
                                </Show>
                              );
                            }}
                          </For>

                          {/* Execution lanes: shared hardware/category swimlanes + sequential spans */}
                          <For each={dagRowIds()}>
                            {(rowId) => {
                              const row = () => dagRowMap().get(rowId);
                              return (
                                <Show when={row()}>
                                  {(rw) => {
                                    const plotW = () => Math.max(40, dagLaneWidth() - 16);
                                    const centerY = () => rw().barY + rw().barHeight / 2;
                                    return (
                                      <g data-testid={`res-dag-lane-${rw().index}`}>
                                        <Show when={rw().spans.length > 1}>
                                          <line
                                            x1={8}
                                            y1={centerY()}
                                            x2={8 + plotW()}
                                            y2={centerY()}
                                            stroke="var(--stroke-soft)"
                                            stroke-width="2"
                                            stroke-linecap="round"
                                          />
                                        </Show>
                                        <For each={rw().spans}>
                                          {(sp, spIdx) => {
                                            const xStart = () => 8 + sp.startFrac * plotW();
                                            const barW = () => {
                                              const raw = Math.max(
                                                6,
                                                (sp.endFrac - sp.startFrac) * plotW(),
                                              );
                                              const nxt = rw().spans[spIdx() + 1];
                                              if (!nxt) return raw;
                                              const nextX = 8 + nxt.startFrac * plotW() - 2;
                                              return Math.max(4, Math.min(raw, nextX - xStart()));
                                            };
                                            const etaW = () =>
                                              sp.etaEndFrac != null
                                                ? Math.max(
                                                    0,
                                                    (sp.etaEndFrac - sp.endFrac) * plotW(),
                                                  )
                                                : 0;
                                            const inlineLabel = () => {
                                              if (rw().spans.length <= 1) return null;
                                              const w = barW();
                                              if (w < 68) return null;
                                              const maxChars = Math.max(
                                                6,
                                                Math.floor((w - 12) / 5.8),
                                              );
                                              return sp.bar.label.length > maxChars
                                                ? `${sp.bar.label.slice(0, Math.max(4, maxChars - 1))}…`
                                                : sp.bar.label;
                                            };
                                            return (
                                              <g
                                                data-testid={`res-dag-bar-${sp.bar.id}`}
                                                style={{
                                                  cursor: sp.bar.mission_id ? "pointer" : "default",
                                                }}
                                                onMouseEnter={() => setHoveredBarId(sp.bar.id)}
                                                onMouseLeave={() =>
                                                  setHoveredBarId((prev) =>
                                                    prev === sp.bar.id ? null : prev,
                                                  )
                                                }
                                                onClick={() => {
                                                  const mid = sp.bar.mission_id;
                                                  if (mid) props.onOpen(`m:${mid}`);
                                                }}
                                              >
                                                <rect
                                                  x={xStart()}
                                                  y={rw().barY}
                                                  width={barW()}
                                                  height={rw().barHeight}
                                                  rx={4}
                                                  fill={barColorForState(
                                                    sp.bar.state,
                                                    sp.bar.role ?? "worker",
                                                  )}
                                                  opacity={
                                                    hoveredBarId() === sp.bar.id
                                                      ? 1
                                                      : sp.bar.state === "cancelled"
                                                        ? 0.48
                                                        : 0.86
                                                  }
                                                />
                                                <Show when={inlineLabel()}>
                                                  {(lbl) => (
                                                    <text
                                                      x={xStart() + 6}
                                                      y={rw().barY + rw().barHeight / 2 + 3.5}
                                                      class="res-dag-bar-inline-label"
                                                    >
                                                      {lbl()}
                                                    </text>
                                                  )}
                                                </Show>
                                                <Show when={etaW() > 2}>
                                                  <rect
                                                    x={xStart() + barW()}
                                                    y={rw().barY}
                                                    width={etaW()}
                                                    height={rw().barHeight}
                                                    rx={4}
                                                    fill={barColorForState(
                                                      sp.bar.state,
                                                      sp.bar.role ?? "worker",
                                                    )}
                                                    fill-opacity="0.18"
                                                    stroke={barColorForState(
                                                      sp.bar.state,
                                                      sp.bar.role ?? "worker",
                                                    )}
                                                    stroke-width="1"
                                                    stroke-dasharray="3 2"
                                                  />
                                                </Show>
                                              </g>
                                            );
                                          }}
                                        </For>
                                      </g>
                                    );
                                  }}
                                </Show>
                              );
                            }}
                          </For>

                          {/* Now marker */}
                          <Show when={nowFrac() < 0.995}>
                            {(_) => {
                              const nx = () =>
                                8 + nowFrac() * Math.max(40, dagLaneWidth() - 16);
                              return (
                                <line
                                  x1={nx()}
                                  y1={0}
                                  x2={nx()}
                                  y2={dag().totalHeight}
                                  stroke="var(--fg-3)"
                                  stroke-width="1"
                                  stroke-dasharray="4 3"
                                />
                              );
                            }}
                          </Show>

                          {/* Synchronized scrub crosshair */}
                          <Show when={hoverFrac()}>
                            {(hf) => {
                              const cx = () =>
                                8 + hf() * Math.max(40, dagLaneWidth() - 16);
                              return (
                                <line
                                  x1={cx()}
                                  y1={0}
                                  x2={cx()}
                                  y2={dag().totalHeight}
                                  stroke="var(--fg-strong)"
                                  stroke-opacity="0.45"
                                  stroke-width="1"
                                />
                              );
                            }}
                          </Show>
                        </svg>
                      </div>
                    </div>
                  </div>
                );
              }}
            </Show>
          </Show>
        </Show>
      </div>

      {/* Synchronized Consumption Curve Underneath */}
      <div class="res-curve-card" data-testid="res-consumption-card">
        <div class="res-curve-head">
          <div class="res-curve-head-left">
            <span class="res-col-title">
              Consumption · {metric() === "usd" ? "Est. USD / hour" : rawUnitLabel()}
            </span>
            <Show when={isMissionMode()}>
              <div class="res-curve-controls">
                {renderLensToggle(true)}
                {renderMetricToggle(true)}
              </div>
            </Show>
          </div>
          <div class="res-curve-legend">
            <Show
              when={hoverFrac() != null && curveGeometry()}
              fallback={
                <Show when={curveGeometry()}>
                  {(cg) => (
                    <>
                      <span>
                        Peak{" "}
                        {formatResourceRate(cg().peak, lens(), metric(), true)}
                      </span>
                      <Show when={cg().projected}>
                        <span>· Dashed = projected wave</span>
                      </Show>
                    </>
                  )}
                </Show>
              }
            >
              {(_) => {
                const sample = () => curveGeometry()!.valueAtFrac(hoverFrac()!);
                return (
                  <span>
                    {sample().timeLabel} · <strong>{sample().valLabel}</strong>
                  </span>
                );
              }}
            </Show>
          </div>
        </div>

        <Show
          when={!loading() && curveGeometry()}
          fallback={<div class="res-skel" style={{ height: "108px", width: "100%" }} />}
        >
          {(cg) => {
            const accent = () =>
              lens() === "compute" ? "var(--blue)" : "var(--purple)";
            return (
              <svg
                ref={curveSvgEl}
                class="res-curve-svg"
                viewBox={`0 0 ${cg().width} ${cg().height}`}
                onMouseEnter={() => { scrubRect = null; }}
                onMouseMove={(e) =>
                  handlePointerScrub(e, e.currentTarget, cg().padX, cg().padX)
                }
                onMouseLeave={clearPointerScrub}
              >
                <defs>
                  <linearGradient id="resCurveGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color={accent()} stop-opacity="0.26" />
                    <stop offset="100%" stop-color={accent()} stop-opacity="0.01" />
                  </linearGradient>
                </defs>

                <line
                  x1={cg().padX}
                  y1={cg().baseY}
                  x2={cg().width - cg().padX}
                  y2={cg().baseY}
                  stroke="var(--stroke-soft)"
                  stroke-width="1"
                />

                <Show when={cg().observed.areaPath}>
                  <path d={cg().observed.areaPath} fill="url(#resCurveGrad)" />
                  <path
                    d={cg().observed.linePath}
                    fill="none"
                    stroke={accent()}
                    stroke-width="1.8"
                  />
                </Show>

                <Show when={cg().projected}>
                  {(proj) => (
                    <path
                      d={proj().linePath}
                      fill="none"
                      stroke={accent()}
                      stroke-width="1.6"
                      stroke-dasharray="5 4"
                      opacity="0.75"
                    />
                  )}
                </Show>

                <Show when={cg().nowX}>
                  {(nx) => (
                    <line
                      x1={nx()}
                      y1={8}
                      x2={nx()}
                      y2={cg().baseY}
                      stroke="var(--fg-3)"
                      stroke-width="1"
                      stroke-dasharray="3 3"
                    />
                  )}
                </Show>

                <Show when={hoverFrac()}>
                  {(hf) => {
                    const cx = () => cg().padX + hf() * cg().plotW;
                    return (
                      <line
                        x1={cx()}
                        y1={6}
                        x2={cx()}
                        y2={cg().baseY}
                        stroke="var(--fg-strong)"
                        stroke-opacity="0.5"
                        stroke-width="1"
                      />
                    );
                  }}
                </Show>

                <text
                  x={cg().padX}
                  y={cg().height - 4}
                  font-family="var(--mono)"
                  font-size="10"
                  fill="var(--fg-3)"
                >
                  {cg().startLabel}
                </text>
                <text
                  x={cg().width - cg().padX}
                  y={cg().height - 4}
                  text-anchor="end"
                  font-family="var(--mono)"
                  font-size="10"
                  fill="var(--fg-3)"
                >
                  {cg().endLabel}
                </text>
              </svg>
            );
          }}
        </Show>
      </div>

      {/* Bottom-Anchored Timeline Bar */}
      <div class="res-timeline-bar" data-testid="res-timeline-bar">
        <div class="res-timeline-left">
          <span class="res-timeline-title">Timeline</span>
          <span class="res-timeline-meta">
            {isMissionMode()
              ? detail()
                ? `${formatDurationCompact(detail()!.mission.elapsed_secs)} mission span`
                : "Mission horizon"
              : `Rolling ${range()} window`}
          </span>
        </div>

        <Show
          when={isMissionMode()}
          fallback={
            <div class="res-seg" role="group" aria-label="Fleet timeline window">
              <For each={FLEET_RANGES}>
                {(opt) => (
                  <button
                    type="button"
                    class={`res-seg-btn ${range() === opt.id ? "is-active" : ""}`}
                    data-testid={`res-range-${opt.id}`}
                    onClick={() => setRange(opt.id)}
                  >
                    {opt.label}
                  </button>
                )}
              </For>
            </div>
          }
        >
          <div class="res-seg" role="group" aria-label="Mission timeline horizon">
            <For
              each={
                detail()?.available_horizons ?? [
                  { id: "6h", label: "Fast-DAG (6h)", span_secs: 21600 },
                ]
              }
            >
              {(opt) => (
                <button
                  type="button"
                  class={`res-seg-btn ${(detail()?.active_horizon ?? horizon()) === opt.id ? "is-active" : ""}`}
                  data-testid={`res-horizon-${opt.id}`}
                  onClick={() => setHorizon(opt.id)}
                >
                  {opt.label}
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>
    </div>
  );
}
