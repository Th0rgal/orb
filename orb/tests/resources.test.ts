import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  buildMissionFlowSankeyInput,
  buildOverviewSankeyInput,
  computeMonotoneCurve,
  computeSankeyLayout,
  formatResourceRate,
  layoutDagRows,
  type ResourceLens,
  type ResourceMetric,
} from "../src/resourcesModel";
import type {
  MissionResourcesResponse,
  ResourcesOverviewResponse,
} from "../src/api";

const fixturePath = resolve(
  __dirname,
  "../../shared/orb-spec/fixtures/resources-flow.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

describe("resourcesModel shared spec", () => {
  it("formats raw vCPU, B tok/h, and estimated USD rates identically to shared fixture", () => {
    for (const row of fixture.formatting) {
      expect(
        formatResourceRate(
          row.value,
          row.lens as ResourceLens,
          row.metric as ResourceMetric,
          row.withUnit,
        ),
      ).toBe(row.expected);
    }
  });

  it("conserves raw and USD mass across 2-column Sankey layout", () => {
    const rawLayout = computeSankeyLayout(
      fixture.sankey_2col.nodes,
      fixture.sankey_2col.links,
      { width: 900, height: 320, metric: "raw" },
    );
    expect(rawLayout.totalRaw).toBeCloseTo(fixture.sankey_2col.expected.total_raw, 5);
    expect(rawLayout.totalUsd).toBeCloseTo(fixture.sankey_2col.expected.total_usd, 5);

    const m1 = rawLayout.nodes.find((n) => n.id === "m1")!;
    const m2 = rawLayout.nodes.find((n) => n.id === "m2")!;
    expect(m1.rawValue).toBeCloseTo(fixture.sankey_2col.expected.m1_raw, 5);
    expect(m2.rawValue).toBeCloseTo(fixture.sankey_2col.expected.m2_raw, 5);
    // m1 has 5x the vCPU of m2, so its vertical bar height is larger
    expect(m1.y1 - m1.y0).toBeGreaterThan(m2.y1 - m2.y0);

    const usdLayout = computeSankeyLayout(
      fixture.sankey_2col.nodes,
      fixture.sankey_2col.links,
      { width: 900, height: 320, metric: "usd" },
    );
    expect(usdLayout.links).toHaveLength(3);
    expect(
      usdLayout.links.reduce((s, l) => s + l.usdValue, 0),
    ).toBeCloseTo(fixture.sankey_2col.expected.total_usd, 5);
  });

  it("lays out DAG rows, section headers, and dependency connectors", () => {
    const dag = layoutDagRows(fixture.dag.bars, fixture.dag.horizon_secs);
    expect(dag.rows.map((r) => r.sectionHeader)).toEqual(
      fixture.dag.expected_section_headers,
    );
    expect(dag.edges.map((e) => e.id)).toEqual(["b1->b2", "b2->b3"]);
    expect(dag.rows[1].startFrac).toBeCloseTo(1800 / 21600, 4);
  });

  it("builds non-overshooting monotone curves", () => {
    const curve = computeMonotoneCurve(
      [
        { x: 0, y: 80 },
        { x: 100, y: 80 },
        { x: 200, y: 20 },
        { x: 300, y: 60 },
      ],
      80,
    );
    expect(curve.linePath.startsWith("M 0.00 80.00")).toBe(true);
    expect(curve.areaPath.endsWith("Z")).toBe(true);
  });

  it("renders closed filled Sankey ribbon polygons without stroke-dasharray barcode artifacts", () => {
    const layout = computeSankeyLayout(
      fixture.sankey_2col.nodes,
      fixture.sankey_2col.links,
      { width: 900, height: 368, metric: "raw" },
    );
    expect(layout.links.length).toBeGreaterThan(0);
    for (const link of layout.links) {
      expect(link.path.startsWith("M ")).toBe(true);
      expect(link.path.endsWith(" Z")).toBe(true);
      expect(link.path).toContain(" L ");
    }
  });

  it("suppresses overlapping labels on dense columns and groups long-tail missions while conserving 100% of mass", () => {
    const missions = Array.from({ length: 24 }, (_, idx) => ({
      id: `m-${String(idx).padStart(2, "0")}`,
      title: `Mission ${idx}`,
      project: "orb",
      status: idx < 4 ? "active" : "completed",
      stall_kind: null,
      subagent_running: idx < 4 ? 2 : 0,
      subagent_total: 4,
      vcpu: idx === 0 ? 400 : 1,
      idle_vcpu: 0,
      compute_usd_per_h: idx === 0 ? 40 : 0.1,
      b_tok_per_h: 0,
      inference_usd_per_h: 0,
      eta_remaining_secs: null,
      series_vcpu: [1],
      series_compute_usd_per_h: [0.1],
      series_b_tok_per_h: [0],
      series_inference_usd_per_h: [0],
    }));

    const ov: ResourcesOverviewResponse = {
      as_of: new Date().toISOString(),
      range: "6h",
      bucket_seconds: 300,
      timestamps_ms: [Date.now()],
      compute: {
        total_vcpu: 423,
        active_vcpu: 423,
        idle_leased_vcpu: 0,
        hourly_burn_usd: 42.3,
        sources: Array.from({ length: 10 }, (_, idx) => ({
          id: `src-${idx}`,
          label: `Machine ${idx}`,
          sublabel: "1 VM",
          total_vcpu: idx === 0 ? 414 : 1,
          active_vcpu: idx === 0 ? 414 : 1,
          idle_leased_vcpu: 0,
          est_usd_per_h: idx === 0 ? 41.4 : 0.1,
          health: "ok",
          series_vcpu: [1],
          series_usd_per_h: [0.1],
        })),
      },
      inference: {
        current_b_tok_per_h: 0,
        est_usd_per_h: 0,
        window_total_tokens: 0,
        window_est_usd: 0,
        throttled_429_count: 0,
        pools: [],
      },
      missions,
      links: missions.map((m, idx) => ({
        kind: "compute" as const,
        source_id: idx === 0 ? "src-0" : `src-${(idx % 9) + 1}`,
        mission_id: m.id,
        value: m.vcpu,
        est_usd_per_h: m.compute_usd_per_h,
        degraded: idx === 0,
      })),
    };

    const input = buildOverviewSankeyInput(ov, "compute");
    const col1 = input.nodes.filter((n) => n.column === 1);
    expect(col1).toHaveLength(10); // Top 9 + 1 conserved tail bucket
    expect(col1.some((n) => n.id === "__other_missions__")).toBe(true);

    const layout = computeSankeyLayout(input.nodes, input.links, {
      width: 920,
      height: 368,
      metric: "raw",
    });
    expect(layout.totalRaw).toBeCloseTo(423, 5);
    expect(layout.totalUsd).toBeCloseTo(42.3, 5);

    // Ensure any two visible labels in the same column maintain non-overlapping vertical centers
    for (const col of [0, 1]) {
      const labeled = layout.nodes.filter((n) => n.column === col && n.showLabel);
      for (let i = 1; i < labeled.length; i++) {
        const prevCenter = (labeled[i - 1].y0 + labeled[i - 1].y1) / 2;
        const currCenter = (labeled[i].y0 + labeled[i].y1) / 2;
        const minGap = labeled[i - 1].showSub ? 26 : 16;
        expect(currCenter - prevCenter).toBeGreaterThanOrEqual(minGap - 0.5);
      }
    }
  });

  it("caps 3-column mission flow subagents cleanly for large wave campaigns", () => {
    const subagents = Array.from({ length: 40 }, (_, i) => ({
      id: `sub-${i}`,
      mission_id: `sub-${i}`,
      native: false,
      track_id: `trk-${i % 20}`,
      role: "worker",
      label: `Worker ${i}`,
      model: "gemini-3-pro",
      node_id: "boat-xl",
      vcpu: 2,
      compute_usd_per_h: 0.2,
      b_tok_per_h: 0.1,
      inference_usd_per_h: 1.0,
      state: "active",
    }));
    const det: MissionResourcesResponse = {
      as_of: new Date().toISOString(),
      mission: {
        id: "root",
        title: "Campaign",
        project: "orb",
        status: "active",
        started_at: new Date().toISOString(),
        completed_at: null,
        elapsed_secs: 600,
        eta_remaining_secs: 600,
        subagent_count: 40,
        track_count: 20,
      },
      available_horizons: [],
      active_horizon: "6h",
      flow: {
        inputs: [
          {
            id: "google:gemini",
            kind: "inference",
            label: "Google · Gemini",
            sub: "metered",
            weight: 4.0,
            est_usd_per_h: 40.0,
          },
        ],
        tracks: Array.from({ length: 20 }, (_, i) => ({
          id: `trk-${i}`,
          label: `Track ${i}`,
          sub: "2 spans",
          state: "active",
        })),
        subagents,
        input_to_track: Array.from({ length: 20 }, (_, i) => ({
          kind: "inference" as const,
          source_id: "google:gemini",
          target_id: `trk-${i}`,
          weight: 0.2,
          est_usd_per_h: 2.0,
          degraded: false,
        })),
        track_to_subagent: subagents.map((s) => ({
          kind: "inference" as const,
          source_id: s.track_id,
          target_id: s.id,
          weight: 0.1,
          est_usd_per_h: 1.0,
          degraded: false,
        })),
      },
      dag: { origin_unix_secs: 0, horizon_secs: 21600, now_offset_secs: 600, bars: [] },
      timeline: {
        offsets_secs: [],
        observed_vcpu: [],
        projected_vcpu: [],
        observed_compute_usd_per_h: [],
        projected_compute_usd_per_h: [],
        observed_b_tok_per_h: [],
        projected_b_tok_per_h: [],
        observed_inference_usd_per_h: [],
        projected_inference_usd_per_h: [],
      },
    };

    const flow = buildMissionFlowSankeyInput(det, "inference");
    expect(flow.nodes.filter((n) => n.column === 1).length).toBeLessThanOrEqual(8);
    expect(flow.nodes.filter((n) => n.column === 2).length).toBeLessThanOrEqual(10);
    const layout = computeSankeyLayout(flow.nodes, flow.links, {
      width: 920,
      height: 368,
      metric: "usd",
    });
    expect(layout.totalUsd).toBeCloseTo(40.0, 5);
  });
});
