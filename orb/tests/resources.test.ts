import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  computeMonotoneCurve,
  computeSankeyLayout,
  formatResourceRate,
  layoutDagRows,
  type ResourceLens,
  type ResourceMetric,
} from "../src/resourcesModel";

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
});
