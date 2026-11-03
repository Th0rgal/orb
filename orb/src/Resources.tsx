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
import { ErrorNotice } from "./ErrorNotice";
import { pollWhileVisible } from "./poll";
import {
  buildMissionFlowSankeyInput,
  buildOverviewSankeyInput,
  computeMonotoneCurve,
  computeSankeyLayout,
  formatDurationCompact,
  formatResourceRate,
  formatTokenTotalCompact,
  layoutDagRows,
  pickFastDagCandidate,
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

function barColorForState(state: string): string {
  switch (state) {
    case "done":
      return "var(--green)";
    case "active":
      return "var(--blue)";
    case "capped":
      return "var(--amber)";
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

function formatClockTick(ms: number, range: string): string {
  const d = new Date(ms);
  if (range === "7d") {
    return d.toLocaleDateString(undefined, { weekday: "short", hour: "2-digit" });
  }
  return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

export default function Resources(props: {
  missionId?: string | null;
  onOpen: (page: string | null) => void;
}) {
  const [lens, setLens] = createSignal<ResourceLens>("compute");
  const [metric, setMetric] = createSignal<ResourceMetric>("raw");
  const [range, setRange] = createSignal<ResourcesWindowRange>("6h");
  const [horizon, setHorizon] = createSignal<string>("6h");
  const [submode, setSubmode] = createSignal<MissionDetailSubmode>("dag");

  const [overview, setOverview] = createSignal<ResourcesOverviewResponse | null>(null);
  const [detail, setDetail] = createSignal<MissionResourcesResponse | null>(null);
  const [loading, setLoading] = createSignal<boolean>(true);
  const [error, setError] = createSignal<string | null>(null);

  const [isolatedId, setIsolatedId] = createSignal<string | null>(null);
  const [hoveredNodeId, setHoveredNodeId] = createSignal<string | null>(null);
  const [hoveredLinkId, setHoveredLinkId] = createSignal<string | null>(null);
  const [hoveredBarId, setHoveredBarId] = createSignal<string | null>(null);
  const [hoverFrac, setHoverFrac] = createSignal<number | null>(null);

  const [sankeyWidth, setSankeyWidth] = createSignal<number>(920);
  const [dagLaneWidth, setDagLaneWidth] = createSignal<number>(720);
  const [curveWidth, setCurveWidth] = createSignal<number>(920);

  let sankeyEl: HTMLDivElement | undefined;
  let dagLaneEl: HTMLDivElement | undefined;
  let curveSvgEl: SVGSVGElement | undefined;
  let ro: ResizeObserver | undefined;

  onMount(() => {
    ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const w = Math.floor(entry.contentRect.width);
        if (w <= 40) continue;
        if (entry.target === sankeyEl) setSankeyWidth(w);
        if (entry.target === dagLaneEl) setDagLaneWidth(w);
        if (entry.target === curveSvgEl) setCurveWidth(w);
      }
    });
    if (sankeyEl) ro.observe(sankeyEl);
    if (dagLaneEl) ro.observe(dagLaneEl);
    if (curveSvgEl) ro.observe(curveSvgEl);
    onCleanup(() => ro?.disconnect());
  });

  let activeAbort: AbortController | null = null;

  async function refresh(showSkeleton = false) {
    activeAbort?.abort();
    const ac = new AbortController();
    activeAbort = ac;

    const mid = props.missionId ?? null;
    if (showSkeleton) setLoading(true);
    try {
      if (mid) {
        const res = await getMissionResources(mid, horizon(), ac.signal);
        if (ac.signal.aborted) return;
        setDetail(res);
        setError(null);
      } else {
        const res = await getResourcesOverview(range(), ac.signal);
        if (ac.signal.aborted) return;
        setOverview(res);
        setError(null);
      }
    } catch (err) {
      if (ac.signal.aborted) return;
      setError(err instanceof Error ? err.message : String(err));
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
          setSubmode("dag");
        }
      },
    ),
  );

  // React strictly to missionId, range, horizon, or server connection changes
  createEffect(
    on(
      [connectionVersion, () => props.missionId ?? null, range, horizon],
      ([, mid]) => {
        const needsSkeleton = mid ? detail()?.mission.id !== mid : overview() === null;
        void refresh(needsSkeleton);
      },
    ),
  );

  onMount(() => {
    const stop = pollWhileVisible(() => refresh(false), 10_000, "app.resources");
    onCleanup(() => {
      stop();
      activeAbort?.abort();
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
      if (sankeyEl) {
        ro?.observe(sankeyEl);
        if (sankeyEl.clientWidth > 40) setSankeyWidth(sankeyEl.clientWidth);
      }
      if (dagLaneEl) {
        ro?.observe(dagLaneEl);
        if (dagLaneEl.clientWidth > 40) setDagLaneWidth(dagLaneEl.clientWidth);
      }
      if (curveSvgEl) {
        ro?.observe(curveSvgEl);
        if (curveSvgEl.clientWidth > 40) setCurveWidth(curveSvgEl.clientWidth);
      }
    });
  });

  const isMissionMode = createMemo(() => Boolean(props.missionId));

  const fastDagCandidateId = createMemo(() => {
    const ov = overview();
    return ov ? pickFastDagCandidate(ov.missions) : null;
  });

  // Sankey layout memo (used in Fleet mode & Mission "flow" submode)
  const sankeyGraph = createMemo(() => {
    const l = lens();
    const m = metric();
    const w = sankeyWidth();
    if (isMissionMode()) {
      const det = detail();
      if (!det) return null;
      const { nodes, links } = buildMissionFlowSankeyInput(det, l);
      const h = Math.max(280, Math.min(480, Math.max(nodes.length * 26, 300)));
      return {
        height: h,
        layout: computeSankeyLayout(nodes, links, {
          width: w,
          height: h,
          metric: m,
          marginX: 164,
        }),
      };
    }
    const ov = overview();
    if (!ov) return null;
    const { nodes, links } = buildOverviewSankeyInput(ov, l);
    const col0Count = nodes.filter((n) => n.column === 0).length;
    const col1Count = nodes.filter((n) => n.column === 1).length;
    const h = Math.max(290, Math.min(500, Math.max(col0Count, col1Count) * 44 + 40));
    return {
      height: h,
      layout: computeSankeyLayout(nodes, links, {
        width: w,
        height: h,
        metric: m,
        marginX: 176,
      }),
    };
  });

  // Fast-DAG layout memo
  const dagLayout = createMemo(() => {
    const det = detail();
    if (!det) return null;
    return layoutDagRows(det.dag.bars, det.dag.horizon_secs);
  });

  // Header live summary stamp
  const headerStamp = createMemo(() => {
    const l = lens();
    const m = metric();
    if (isMissionMode()) {
      const det = detail();
      if (!det) return { primary: "—", secondary: null, warn: null };
      const sumVcpu = det.flow.subagents.reduce((s, a) => s + a.vcpu, 0);
      const sumCu = det.flow.subagents.reduce((s, a) => s + a.compute_usd_per_h, 0);
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
      return { primary, secondary: eta, warn: null };
    }

    const ov = overview();
    if (!ov) return { primary: "—", secondary: null, warn: null };
    if (l === "compute") {
      const primary =
        m === "usd"
          ? formatResourceRate(ov.compute.hourly_burn_usd, "compute", "usd", true)
          : `${formatResourceRate(ov.compute.active_vcpu, "compute", "raw", false)}/${formatResourceRate(ov.compute.total_vcpu, "compute", "raw", true)}`;
      const secondary =
        ov.compute.idle_leased_vcpu > 0.4
          ? `${Math.round(ov.compute.idle_leased_vcpu)} idle vCPU`
          : `${ov.missions.length} mission${ov.missions.length === 1 ? "" : "s"}`;
      return { primary, secondary, warn: null };
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
    const warn =
      ov.inference.throttled_429_count > 0
        ? `${ov.inference.throttled_429_count} × 429`
        : null;
    return { primary, secondary, warn };
  });

  // Hover readout text in card header
  const activeReadout = createMemo(() => {
    const l = lens();
    const m = metric();
    const g = sankeyGraph();
    if (hoveredLinkId() && g) {
      const link = g.layout.links.find((x) => x.id === hoveredLinkId());
      if (link) {
        const src = g.layout.nodes.find((n) => n.id === link.source)?.label ?? link.source;
        const dst = g.layout.nodes.find((n) => n.id === link.target)?.label ?? link.target;
        const val = formatResourceRate(
          m === "usd" ? link.usdValue : link.rawValue,
          l,
          m,
          true,
        );
        return `${src} → ${dst} · ${val}`;
      }
    }
    if (hoveredNodeId() && g) {
      const node = g.layout.nodes.find((n) => n.id === hoveredNodeId());
      if (node) {
        const val = formatResourceRate(
          m === "usd" ? node.usdValue : node.rawValue,
          l,
          m,
          true,
        );
        return `${node.label} · ${val}`;
      }
    }
    if (hoveredBarId() && detail()) {
      const bar = detail()!.dag.bars.find((b) => b.id === hoveredBarId());
      if (bar) {
        const rateVal =
          l === "compute"
            ? m === "usd"
              ? bar.compute_usd_per_h
              : bar.vcpu
            : m === "usd"
              ? bar.inference_usd_per_h
              : bar.b_tok_per_h;
        const parts = [
          bar.label,
          formatResourceRate(rateVal, l, m, true),
          formatDurationCompact(bar.duration_secs),
        ];
        if (bar.eta_remaining_secs && bar.eta_remaining_secs > 0) {
          parts.push(`~${formatDurationCompact(bar.eta_remaining_secs)} left`);
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
        for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
      } else {
        for (const p of ov.inference.pools) {
          const arr = m === "usd" ? p.series_usd_per_h : p.series_b_tok_per_h;
          for (let i = 0; i < len; i++) values[i] += arr[i] ?? 0;
        }
      }
    }

    const peak = values.reduce((a, b) => Math.max(a, b), 0);
    const denom = peak > 0 ? peak * 1.12 : 1;
    const n = Math.max(1, len - 1);
    const pts = values.map((v, i) => ({
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
          valLabel: formatResourceRate(values[idx] ?? 0, l, m, true),
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
    if (node.missionId) {
      props.onOpen(`m:${node.missionId}`);
    }
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
    const rect = el.getBoundingClientRect();
    const inner = Math.max(1, rect.width - padLeft - padRight);
    const frac = Math.max(0, Math.min(1, (e.clientX - rect.left - padLeft) / inner));
    setHoverFrac(frac);
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

          <div class="res-seg" role="tablist" aria-label="Resource lens">
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
          </div>

          <Show
            when={isMissionMode()}
            fallback={
              <Show when={fastDagCandidateId()}>
                {(candId) => (
                  <button
                    type="button"
                    class="res-btn res-btn-dag-jump"
                    data-testid="res-fast-dag-jump"
                    onClick={() => props.onOpen(`rm:${candId()}`)}
                  >
                    Fast-DAG ›
                  </button>
                )}
              </Show>
            }
          >
            <div class="res-seg" role="tablist" aria-label="Mission view mode">
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
            <Show when={headerStamp().warn}>
              <span class="res-badge-warn">{headerStamp().warn}</span>
            </Show>
          </div>

          {/* Elegant Raw Unit vs Estimated $ Toggle */}
          <div class="res-seg" role="group" aria-label="Display unit">
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
        </div>
      </div>

      <Show when={error()}>
        {(msg) => (
          <ErrorNotice error={msg()}>
            <button
              type="button"
              class="res-btn"
              onClick={() => void refresh(true)}
            >
              Retry
            </button>
          </ErrorNotice>
        )}
      </Show>

      {/* Main Flow / Fast-DAG Card */}
      <div class="res-card res-card-main">
        <Show
          when={!loading()}
          fallback={
            <div style={{ padding: "16px", display: "flex", "flex-direction": "column", gap: "12px", flex: "1" }}>
              <div class="res-skel" style={{ height: "20px", width: "36%" }} />
              <div class="res-skel" style={{ flex: "1", "min-height": "260px" }} />
            </div>
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
                    <Show when={isolatedId()}>
                      {(iso) => (
                        <button
                          type="button"
                          class="res-filter-chip"
                          data-testid="res-clear-filter"
                          onClick={() => setIsolatedId(null)}
                        >
                          Filtered: {iso()} ×
                        </button>
                      )}
                    </Show>
                  </div>
                  <div class="res-card-head-right">
                    <Show
                      when={activeReadout()}
                      fallback={
                        <span>
                          {isMissionMode()
                            ? "Click subagent to open transcript"
                            : "Click a mission to inspect subagent DAG"}
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
                      <div class="res-empty" data-testid="res-empty-state">
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
                      viewBox={`0 0 ${sankeyWidth()} ${sankeyGraph()!.height}`}
                      style={{ height: `${sankeyGraph()!.height}px` }}
                    >
                      <g>
                        <For each={sankeyGraph()!.layout.links}>
                          {(link) => (
                            <path
                              class="res-sankey-link"
                              data-testid={`res-link-${link.source}-${link.target}`}
                              d={link.path}
                              stroke={link.color}
                              stroke-width={link.width}
                              stroke-dasharray={link.degraded ? "5 3" : undefined}
                              stroke-opacity={
                                isLinkDimmed(link.id, link.source, link.target)
                                  ? 0.12
                                  : hoveredLinkId() === link.id
                                    ? 0.62
                                    : 0.36
                              }
                              onMouseEnter={() => setHoveredLinkId(link.id)}
                              onMouseLeave={() => setHoveredLinkId(null)}
                              onClick={() => handleLinkClick(link)}
                            />
                          )}
                        </For>
                      </g>

                      <g>
                        <For each={sankeyGraph()!.layout.nodes}>
                          {(node) => {
                            const isLeft = () => node.column === 0;
                            const isRight = () =>
                              node.column === sankeyGraph()!.layout.columns - 1;
                            const centerY = () => (node.y0 + node.y1) / 2;
                            const valStr = () =>
                              formatResourceRate(
                                metric() === "usd" ? node.usdValue : node.rawValue,
                                lens(),
                                metric(),
                                true,
                              );
                            return (
                              <g
                                class="res-sankey-node-group"
                                data-testid={`res-node-${node.id}`}
                                onMouseEnter={() => setHoveredNodeId(node.id)}
                                onMouseLeave={() => setHoveredNodeId(null)}
                                onClick={() => handleNodeClick(node)}
                              >
                                <rect
                                  x={node.x0}
                                  y={node.y0}
                                  width={node.x1 - node.x0}
                                  height={Math.max(4, node.y1 - node.y0)}
                                  rx={3}
                                  fill={node.color}
                                  opacity={
                                    isolatedId() && isolatedId() !== node.id ? 0.45 : 0.95
                                  }
                                />
                                <text
                                  class="res-sankey-node-label"
                                  x={
                                    isLeft()
                                      ? node.x0 - 10
                                      : isRight()
                                        ? node.x1 + 10
                                        : (node.x0 + node.x1) / 2
                                  }
                                  y={centerY() - 5}
                                  text-anchor={
                                    isLeft() ? "end" : isRight() ? "start" : "middle"
                                  }
                                >
                                  {node.label.length > 22
                                    ? `${node.label.slice(0, 21)}…`
                                    : node.label}
                                </text>
                                <text
                                  class="res-sankey-node-sub"
                                  x={
                                    isLeft()
                                      ? node.x0 - 10
                                      : isRight()
                                        ? node.x1 + 10
                                        : (node.x0 + node.x1) / 2
                                  }
                                  y={centerY() + 9}
                                  text-anchor={
                                    isLeft() ? "end" : isRight() ? "start" : "middle"
                                  }
                                >
                                  {valStr()}
                                  {node.sub ? ` · ${node.sub.slice(0, 20)}` : ""}
                                </text>
                              </g>
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
                  Subagent Execution DAG · {detail()?.mission.subagent_count ?? 0} spans
                </span>
              </div>
              <div class="res-card-head-right">
                <Show
                  when={activeReadout()}
                  fallback={<span>Hover to scrub · Click subagent to open transcript</span>}
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
                        <For each={dag().rows}>
                          {(row) => (
                            <>
                              <Show when={row.sectionHeader}>
                                {(sec) => (
                                  <div
                                    class="res-dag-sec-hdr"
                                    style={{ top: `${row.y - 20}px` }}
                                  >
                                    {sec()}
                                  </div>
                                )}
                              </Show>
                              <button
                                type="button"
                                class={`res-dag-row-label ${hoveredBarId() === row.bar.id ? "is-hovered" : ""}`}
                                style={{ top: `${row.y + 2}px` }}
                                data-testid={`res-dag-row-${row.bar.id}`}
                                onMouseEnter={() => setHoveredBarId(row.bar.id)}
                                onMouseLeave={() => setHoveredBarId(null)}
                                onClick={() => {
                                  if (row.bar.mission_id) {
                                    props.onOpen(`m:${row.bar.mission_id}`);
                                  }
                                }}
                                title={row.bar.label}
                              >
                                <span class="res-dag-row-title">{row.bar.label}</span>
                                <span class="res-dag-row-meta">
                                  {formatDurationCompact(row.bar.duration_secs)}
                                </span>
                              </button>
                            </>
                          )}
                        </For>
                      </div>

                      <div
                        class="res-dag-canvas"
                        ref={dagLaneEl}
                        onMouseMove={(e) => handlePointerScrub(e, e.currentTarget, 8, 8)}
                        onMouseLeave={() => setHoverFrac(null)}
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
                          <For each={dag().edges}>
                            {(edge) => {
                              const plotW = () => Math.max(40, dagLaneWidth() - 16);
                              const x0 = () => 8 + edge.fromEndFrac * plotW();
                              const x1 = () => 8 + edge.toStartFrac * plotW();
                              const mx = () => (x0() + x1()) / 2;
                              return (
                                <path
                                  d={`M ${x0()} ${edge.fromCenterY} C ${mx()} ${edge.fromCenterY}, ${mx()} ${edge.toCenterY}, ${x1()} ${edge.toCenterY}`}
                                  fill="none"
                                  stroke="var(--stroke-strong)"
                                  stroke-width="1.2"
                                />
                              );
                            }}
                          </For>

                          {/* Execution bars + forward ETA extensions */}
                          <For each={dag().rows}>
                            {(row) => {
                              const plotW = () => Math.max(40, dagLaneWidth() - 16);
                              const xStart = () => 8 + row.startFrac * plotW();
                              const barW = () =>
                                Math.max(6, (row.endFrac - row.startFrac) * plotW());
                              const etaW = () =>
                                row.etaEndFrac != null
                                  ? Math.max(0, (row.etaEndFrac - row.endFrac) * plotW())
                                  : 0;
                              return (
                                <g
                                  style={{ cursor: row.bar.mission_id ? "pointer" : "default" }}
                                  onMouseEnter={() => setHoveredBarId(row.bar.id)}
                                  onMouseLeave={() => setHoveredBarId(null)}
                                  onClick={() => {
                                    if (row.bar.mission_id) {
                                      props.onOpen(`m:${row.bar.mission_id}`);
                                    }
                                  }}
                                >
                                  <rect
                                    x={xStart()}
                                    y={row.barY}
                                    width={barW()}
                                    height={row.barHeight}
                                    rx={4}
                                    fill={barColorForState(row.bar.state)}
                                    opacity={hoveredBarId() === row.bar.id ? 1 : 0.84}
                                  />
                                  <Show when={etaW() > 2}>
                                    <rect
                                      x={xStart() + barW()}
                                      y={row.barY}
                                      width={etaW()}
                                      height={row.barHeight}
                                      rx={4}
                                      fill={barColorForState(row.bar.state)}
                                      fill-opacity="0.18"
                                      stroke={barColorForState(row.bar.state)}
                                      stroke-width="1"
                                      stroke-dasharray="3 2"
                                    />
                                  </Show>
                                </g>
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
          <span class="res-col-title">
            Consumption · {metric() === "usd" ? "Est. USD / hour" : rawUnitLabel()}
          </span>
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
                onMouseMove={(e) =>
                  handlePointerScrub(e, e.currentTarget, cg().padX, cg().padX)
                }
                onMouseLeave={() => setHoverFrac(null)}
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
