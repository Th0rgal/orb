import { expect, test } from "@playwright/test";

test("Resources page renders global Compute/Inference Sankey, USD toggle, bottom Timeline, and Fast-DAG drilldown", async ({
  page,
}) => {
  const missionId = "11111111-1111-4111-8111-111111111111";
  const childId = "22222222-2222-4222-8222-222222222222";
  const overviewRangesRequested: string[] = [];

  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (path === "/api/control/stream") {
      return route.fulfill({ contentType: "text/event-stream", body: "" });
    }
    if (path === "/api/resources/overview") {
      const range = url.searchParams.get("range") ?? "6h";
      overviewRangesRequested.push(range);
      const now = Date.now();
      return route.fulfill({
        json: {
          as_of: new Date(now).toISOString(),
          range,
          bucket_seconds: 300,
          timestamps_ms: [now - 7200_000, now - 3600_000, now],
          compute: {
            total_vcpu: 48,
            active_vcpu: 40,
            idle_leased_vcpu: 8,
            hourly_burn_usd: 3.84,
            sources: [
              {
                id: "boat:large",
                label: "Boat · large",
                sublabel: "2 VMs",
                total_vcpu: 32,
                active_vcpu: 32,
                idle_leased_vcpu: 0,
                est_usd_per_h: 3.2,
                health: "ok",
                series_vcpu: [16, 32, 32],
                series_usd_per_h: [1.6, 3.2, 3.2],
              },
              {
                id: "static:fleet",
                label: "Static fleet",
                sublabel: "2 hosts",
                total_vcpu: 16,
                active_vcpu: 8,
                idle_leased_vcpu: 8,
                est_usd_per_h: 0.64,
                health: "ok",
                series_vcpu: [8, 8, 8],
                series_usd_per_h: [0.64, 0.64, 0.64],
              },
            ],
          },
          inference: {
            current_b_tok_per_h: 1.46,
            est_usd_per_h: 29.2,
            window_total_tokens: 8_760_000_000,
            window_est_usd: 175.2,
            throttled_429_count: 2,
            pools: [
              {
                id: "anthropic:claude",
                label: "Anthropic · Claude",
                sublabel: "Router pool",
                provider: "anthropic",
                quota_pct_remaining: 62,
                reset_at: null,
                current_b_tok_per_h: 1.46,
                est_usd_per_h: 29.2,
                health: "ok",
                series_b_tok_per_h: [0.9, 1.3, 1.46],
                series_usd_per_h: [18.0, 26.0, 29.2],
              },
            ],
          },
          missions: [
            {
              id: missionId,
              title: "Maxwell Kernel Campaign",
              project: "orb",
              status: "active",
              stall_kind: null,
              subagent_running: 3,
              subagent_total: 6,
              vcpu: 40,
              idle_vcpu: 0,
              compute_usd_per_h: 3.52,
              b_tok_per_h: 1.46,
              inference_usd_per_h: 29.2,
              eta_remaining_secs: 2400,
              series_vcpu: [24, 40, 40],
              series_compute_usd_per_h: [2.24, 3.52, 3.52],
              series_b_tok_per_h: [0.9, 1.3, 1.46],
              series_inference_usd_per_h: [18.0, 26.0, 29.2],
            },
          ],
          links: [
            {
              kind: "compute",
              source_id: "boat:large",
              mission_id: missionId,
              value: 32,
              est_usd_per_h: 3.2,
              degraded: false,
            },
            {
              kind: "compute",
              source_id: "static:fleet",
              mission_id: missionId,
              value: 8,
              est_usd_per_h: 0.32,
              degraded: false,
            },
            {
              kind: "inference",
              source_id: "anthropic:claude",
              mission_id: missionId,
              value: 1.46,
              est_usd_per_h: 29.2,
              degraded: false,
            },
          ],
        },
      });
    }
    if (path === `/api/resources/missions/${missionId}`) {
      return route.fulfill({
        json: {
          as_of: new Date().toISOString(),
          mission: {
            id: missionId,
            title: "Maxwell Kernel Campaign",
            project: "orb",
            status: "active",
            started_at: new Date(Date.now() - 5400_000).toISOString(),
            completed_at: null,
            elapsed_secs: 5400,
            eta_remaining_secs: 2400,
            subagent_count: 2,
            track_count: 2,
          },
          available_horizons: [
            { id: "6h", label: "Fast-DAG (6h)", span_secs: 21600 },
            { id: "all", label: "2.1d history", span_secs: 181440 },
          ],
          active_horizon: url.searchParams.get("horizon") ?? "6h",
          flow: {
            inputs: [
              {
                id: "boat:large",
                kind: "compute",
                label: "Boat · large",
                sub: "2 VMs",
                weight: 32,
                est_usd_per_h: 3.2,
              },
              {
                id: "anthropic:claude",
                kind: "inference",
                label: "Anthropic · Claude",
                sub: "Pool",
                weight: 1.46,
                est_usd_per_h: 29.2,
              },
            ],
            tracks: [
              { id: "trk-orch", label: "Orchestrator", sub: "1 span", state: "done" },
              { id: "trk-prov", label: "Provers", sub: "1 active", state: "active" },
            ],
            subagents: [
              {
                id: missionId,
                mission_id: missionId,
                native: false,
                track_id: "trk-orch",
                role: "boss",
                label: "Root Coordinator",
                model: "claude-opus-4-6",
                node_id: "core",
                vcpu: 8,
                compute_usd_per_h: 0.32,
                b_tok_per_h: 0.36,
                inference_usd_per_h: 7.2,
                state: "done",
              },
              {
                id: childId,
                mission_id: childId,
                native: false,
                track_id: "trk-prov",
                role: "worker",
                label: "Proof Shard 01",
                model: "claude-sonnet-4-5",
                node_id: "boat-lg-1",
                vcpu: 32,
                compute_usd_per_h: 3.2,
                b_tok_per_h: 1.1,
                inference_usd_per_h: 22.0,
                state: "active",
              },
            ],
            input_to_track: [
              {
                kind: "compute",
                source_id: "boat:large",
                target_id: "trk-prov",
                weight: 32,
                est_usd_per_h: 3.2,
                degraded: false,
              },
              {
                kind: "inference",
                source_id: "anthropic:claude",
                target_id: "trk-prov",
                weight: 1.46,
                est_usd_per_h: 29.2,
                degraded: false,
              },
            ],
            track_to_subagent: [
              {
                kind: "compute",
                source_id: "trk-prov",
                target_id: childId,
                weight: 32,
                est_usd_per_h: 3.2,
                degraded: false,
              },
              {
                kind: "inference",
                source_id: "trk-prov",
                target_id: childId,
                weight: 1.46,
                est_usd_per_h: 29.2,
                degraded: false,
              },
            ],
          },
          dag: {
            origin_unix_secs: 1700000000,
            horizon_secs: 21600,
            now_offset_secs: 5400,
            bars: [
              {
                id: "b-root",
                mission_id: missionId,
                label: "Spec & Partition",
                section: "Orchestrator",
                role: "boss",
                model: "claude-opus-4-6",
                node_id: "core",
                vcpu: 8,
                compute_usd_per_h: 0.32,
                b_tok_per_h: 0.36,
                inference_usd_per_h: 7.2,
                start_offset_secs: 0,
                duration_secs: 1800,
                eta_remaining_secs: null,
                eta_basis: null,
                state: "done",
                after_ids: [],
              },
              {
                id: "b-shard-1",
                mission_id: childId,
                label: "Proof Shard 01",
                section: "Provers",
                role: "worker",
                model: "claude-sonnet-4-5",
                node_id: "boat-lg-1",
                vcpu: 32,
                compute_usd_per_h: 3.2,
                b_tok_per_h: 1.1,
                inference_usd_per_h: 22.0,
                start_offset_secs: 1800,
                duration_secs: 3600,
                eta_remaining_secs: 2400,
                eta_basis: "cohort_p50",
                state: "active",
                after_ids: ["b-root"],
              },
            ],
          },
          timeline: {
            offsets_secs: [0, 1800, 5400, 7800, 21600],
            observed_vcpu: [8, 40, 32, null, null],
            projected_vcpu: [null, null, 32, 32, 0],
            observed_compute_usd_per_h: [0.32, 3.52, 3.2, null, null],
            projected_compute_usd_per_h: [null, null, 3.2, 3.2, 0],
            observed_b_tok_per_h: [0.36, 1.46, 1.1, null, null],
            projected_b_tok_per_h: [null, null, 1.1, 1.1, 0],
            observed_inference_usd_per_h: [7.2, 29.2, 22.0, null, null],
            projected_inference_usd_per_h: [null, null, 22.0, 22.0, 0],
          },
        },
      });
    }
    if (path === "/api/projects") {
      return route.fulfill({ json: { projects: [{ slug: "orb", title: "Orb" }] } });
    }
    if (
      path === "/api/control/missions" ||
      path === "/api/control/queue" ||
      path === "/api/backends" ||
      path === "/api/cloud/accounts"
    ) {
      return route.fulfill({ json: [] });
    }
    if (path === "/api/providers/backend-models") {
      return route.fulfill({ json: { backends: {} } });
    }
    return route.fulfill({ json: {} });
  });

  await page.goto("/");
  await page.getByTestId("sb-resources").click();

  await expect(page.getByTestId("resources-page")).toBeVisible();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("40/48 vCPU");

  // Toggle vCPU -> $ in Compute mode
  await page.getByTestId("res-metric-usd").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$3.84/h");

  // Switch to Inference lens (keeps $ toggle active, then toggle back to B tok/h)
  await page.getByTestId("res-lens-inference").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$29.2/h");
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$175");
  await page.getByTestId("res-metric-raw").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("1.46 B tok/h");

  // Bottom Timeline window bar triggers overview fetch for 24h
  const timelineBar = page.getByTestId("res-timeline-bar");
  await expect(timelineBar).toBeVisible();
  await page.getByTestId("res-range-24h").click();
  await expect.poll(() => overviewRangesRequested.includes("24h")).toBe(true);

  // Click mission node in Sankey to drill down into Fast-DAG
  await page.getByTestId(`res-node-${missionId}`).click();
  await expect(page.getByTestId("res-dag-view")).toBeVisible();
  await expect(page.getByTestId("res-dag-row-b-shard-1")).toContainText("Proof Shard 01");

  // Switch submode to 3-column Subagent Flow and back
  await page.getByTestId("res-submode-flow").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
  await page.getByTestId("res-submode-dag").click();
  await expect(page.getByTestId("res-dag-view")).toBeVisible();

  // Navigate back to Fleet
  await page.getByTestId("res-back-fleet").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
});
