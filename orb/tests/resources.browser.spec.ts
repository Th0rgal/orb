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

  // Verify Inference is the first/default tab and Compute is the second tab
  const lensTabs = page.locator('[aria-label="Resource lens"] button');
  await expect(lensTabs.nth(0)).toHaveText("Inference");
  await expect(lensTabs.nth(1)).toHaveText("Compute");
  await expect(page.getByTestId("res-summary-stamp")).toContainText("1.46 B tok/h");
  // Rate-limit 429 pill is intentionally omitted from the header summary stamp
  await expect(page.getByTestId("res-summary-stamp")).not.toContainText("429");
  await expect(page.locator(".res-badge-warn")).toHaveCount(0);

  // Regression check: zero layout shift (0px height/y change) on hover, scrub, lens & $ toggles,
  // and fine-grained DOM node preservation across background refreshes.
  const cardHead = page.locator(".res-card-head").first();
  const sankeySvg = page.getByTestId("res-sankey-svg");
  const consumptionCard = page.getByTestId("res-consumption-card");
  const timelineBar = page.getByTestId("res-timeline-bar");

  const baseHeadBox = (await cardHead.boundingBox())!;
  const baseSvgBox = (await sankeySvg.boundingBox())!;
  const baseCurveBox = (await consumptionCard.boundingBox())!;
  const baseTimelineBox = (await timelineBar.boundingBox())!;

  // Switch to Compute lens (2nd tab) -> 0px vertical jump
  await page.getByTestId("res-lens-compute").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("40/48 vCPU");
  expect((await consumptionCard.boundingBox())!.y).toBe(baseCurveBox.y);

  // Tag DOM element identity to verify fine-grained updates do NOT unmount/remount SVG nodes
  const boatNode = page.getByTestId("res-node-boat:large");
  await boatNode.evaluate((el) => {
    (el as unknown as { __orbSameNodeMarker?: boolean }).__orbSameNodeMarker = true;
  });

  // Hover Sankey node -> header pill appears, 0px layout shift
  await boatNode.hover();
  await expect(page.locator(".res-hover-pill")).toContainText("Boat · large");
  const hovNodeHeadBox = (await cardHead.boundingBox())!;
  const hovNodeSvgBox = (await sankeySvg.boundingBox())!;
  const hovNodeCurveBox = (await consumptionCard.boundingBox())!;
  expect(hovNodeHeadBox.height).toBe(baseHeadBox.height);
  expect(hovNodeSvgBox.y).toBe(baseSvgBox.y);
  expect(hovNodeSvgBox.height).toBe(baseSvgBox.height);
  expect(hovNodeCurveBox.y).toBe(baseCurveBox.y);

  // Hover Sankey ribbon link -> header pill updates, 0px layout shift
  await page.getByTestId(`res-link-boat:large-${missionId}`).hover({ force: true });
  await expect(page.locator(".res-hover-pill")).toContainText("Maxwell Kernel Campaign");
  expect((await cardHead.boundingBox())!.height).toBe(baseHeadBox.height);
  expect((await consumptionCard.boundingBox())!.y).toBe(baseCurveBox.y);

  // Scrub consumption curve -> legend updates, 0px layout shift
  const curveSvg = page.locator(".res-curve-svg");
  await curveSvg.hover({ position: { x: 120, y: 40 } });
  expect((await consumptionCard.boundingBox())!.height).toBe(baseCurveBox.height);
  expect((await timelineBar.boundingBox())!.y).toBe(baseTimelineBox.y);

  // Click source node to isolate -> filter chip appears, 0px header/panel height shift, DOM node preserved
  await boatNode.click();
  await expect(page.getByTestId("res-clear-filter")).toBeVisible();
  expect((await cardHead.boundingBox())!.height).toBe(baseHeadBox.height);
  expect((await sankeySvg.boundingBox())!.y).toBe(baseSvgBox.y);
  await page.getByTestId("res-clear-filter").click();

  // Toggle vCPU -> $ in Compute mode -> 0px vertical jump, same DOM node preserved
  await page.getByTestId("res-metric-usd").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$3.84/h");
  expect((await consumptionCard.boundingBox())!.y).toBe(baseCurveBox.y);
  expect(
    await boatNode.evaluate(
      (el) => Boolean((el as unknown as { __orbSameNodeMarker?: boolean }).__orbSameNodeMarker),
    ),
  ).toBe(true);

  // Switch back to Inference lens (keeps $ toggle active, then toggle back to B tok/h) -> 0px vertical jump
  await page.getByTestId("res-lens-inference").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$29.2/h");
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$175");
  expect((await consumptionCard.boundingBox())!.y).toBe(baseCurveBox.y);
  await page.getByTestId("res-metric-raw").click();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("1.46 B tok/h");

  // Bottom Timeline window bar triggers overview fetch for 24h while preserving SVG node identity
  await expect(timelineBar).toBeVisible();
  const claudeNode = page.getByTestId("res-node-anthropic:claude");
  await claudeNode.evaluate((el) => {
    (el as unknown as { __orbPollMarker?: boolean }).__orbPollMarker = true;
  });
  await claudeNode.hover();
  await expect(page.locator(".res-hover-pill")).toContainText("Anthropic · Claude");
  await page.getByTestId("res-range-24h").click();
  await expect.poll(() => overviewRangesRequested.includes("24h")).toBe(true);
  expect(
    await claudeNode.evaluate(
      (el) => Boolean((el as unknown as { __orbPollMarker?: boolean }).__orbPollMarker),
    ),
  ).toBe(true);

  // Click mission node in Sankey to drill down into Fast-DAG
  await page.getByTestId(`res-node-${missionId}`).click();
  await expect(page.getByTestId("res-dag-view")).toBeVisible();
  await expect(page.getByTestId("res-dag-row-b-shard-1")).toContainText("Proof Shard 01");

  // Hover Fast-DAG bar -> 0px header jump
  const dagHeadBoxBefore = (await cardHead.boundingBox())!;
  const dagBoxBefore = (await page.getByTestId("res-dag-view").boundingBox())!;
  await page.getByTestId("res-dag-row-b-shard-1").hover();
  await expect(page.locator(".res-hover-pill")).toContainText("Proof Shard 01");
  expect((await cardHead.boundingBox())!.height).toBe(dagHeadBoxBefore.height);
  expect((await page.getByTestId("res-dag-view").boundingBox())!.y).toBe(dagBoxBefore.y);

  // Switch submode to 3-column Subagent Flow and back -> 0px vertical jump on Consumption card
  const dagCurveBox = (await consumptionCard.boundingBox())!;
  await page.getByTestId("res-submode-flow").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
  expect((await consumptionCard.boundingBox())!.y).toBe(dagCurveBox.y);
  await page.getByTestId("res-submode-dag").click();
  await expect(page.getByTestId("res-dag-view")).toBeVisible();
  expect((await consumptionCard.boundingBox())!.y).toBe(dagCurveBox.y);

  // Navigate back to Fleet
  await page.getByTestId("res-back-fleet").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
});

test("Resources page handles dense 30+ mission fleet and 500-span mission Flow cleanly without text overlap or clipping", async ({
  page,
}) => {
  const bigMissionId = "99999999-9999-4999-8999-999999999999";

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
      const now = Date.now();
      const missions = Array.from({ length: 32 }, (_, i) => ({
        id: i === 0 ? bigMissionId : `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
        title:
          i === 0
            ? "evm.fast (claude takeover)"
            : i === 1
              ? "turbo-lean compilation"
              : i === 2
                ? "You are the independent auditor"
                : `Completed Mission #${i}`,
        project: "ethereum",
        status: i < 5 ? "active" : "completed",
        stall_kind: null,
        subagent_running: i === 0 ? 23 : i < 5 ? 2 : 0,
        subagent_total: i === 0 ? 530 : 18,
        vcpu: i === 0 ? 402 : i === 1 ? 23 : i === 2 ? 14 : 0.2,
        idle_vcpu: 0,
        compute_usd_per_h: i === 0 ? 40.2 : 1.0,
        b_tok_per_h: i === 0 ? 3.2 : i < 8 ? 0.25 : 0.01,
        inference_usd_per_h: i === 0 ? 144 : i === 1 ? 43.2 : i === 2 ? 29.4 : 0.05,
        eta_remaining_secs: i === 0 ? 1800 : null,
        series_vcpu: [10, 20, 30],
        series_compute_usd_per_h: [1, 2, 3],
        series_b_tok_per_h: [1, 2, 3],
        series_inference_usd_per_h: [10, 20, 30],
      }));
      return route.fulfill({
        json: {
          as_of: new Date(now).toISOString(),
          range: "6h",
          bucket_seconds: 300,
          timestamps_ms: [now - 7200_000, now - 3600_000, now],
          compute: {
            total_vcpu: 539,
            active_vcpu: 453,
            idle_leased_vcpu: 2,
            hourly_burn_usd: 48.5,
            sources: [
              { id: "boat:xlarge", label: "Boat · xlarge", sublabel: "26 VMs", total_vcpu: 416, active_vcpu: 400, idle_leased_vcpu: 16, est_usd_per_h: 41.6, health: "ok", series_vcpu: [400, 416, 416], series_usd_per_h: [40, 41.6, 41.6] },
              { id: "static:fleet", label: "Static fleet", sublabel: "6 hosts", total_vcpu: 42, active_vcpu: 30, idle_leased_vcpu: 0, est_usd_per_h: 2.1, health: "ok", series_vcpu: [30, 30, 30], series_usd_per_h: [2.1, 2.1, 2.1] },
              { id: "spark:gpu", label: "DGX Spark", sublabel: "2 VMs", total_vcpu: 40, active_vcpu: 20, idle_leased_vcpu: 0, est_usd_per_h: 3.0, health: "ok", series_vcpu: [20, 20, 20], series_usd_per_h: [3, 3, 3] },
              { id: "hetzner:cpx42", label: "Hetzner · cpx42", sublabel: "1 VM", total_vcpu: 13, active_vcpu: 8, idle_leased_vcpu: 0, est_usd_per_h: 0.6, health: "ok", series_vcpu: [8, 8, 8], series_usd_per_h: [0.6, 0.6, 0.6] },
              { id: "core:host", label: "Local host", sublabel: "local", total_vcpu: 12, active_vcpu: 4, idle_leased_vcpu: 0, est_usd_per_h: 0.4, health: "ok", series_vcpu: [4, 4, 4], series_usd_per_h: [0.4, 0.4, 0.4] },
              { id: "boat:large", label: "Boat · large", sublabel: "1 VM", total_vcpu: 8, active_vcpu: 4, idle_leased_vcpu: 0, est_usd_per_h: 0.4, health: "ok", series_vcpu: [4, 4, 4], series_usd_per_h: [0.4, 0.4, 0.4] },
              { id: "hetzner:ccx33", label: "Hetzner · ccx33", sublabel: "1 VM", total_vcpu: 8, active_vcpu: 4, idle_leased_vcpu: 0, est_usd_per_h: 0.4, health: "ok", series_vcpu: [4, 4, 4], series_usd_per_h: [0.4, 0.4, 0.4] },
            ],
          },
          inference: {
            current_b_tok_per_h: 5.4,
            est_usd_per_h: 256,
            window_total_tokens: 32_400_000_000,
            window_est_usd: 1534,
            throttled_429_count: 0,
            pools: [
              { id: "google:gemini", label: "Google · Gemini", sublabel: "metered", provider: "google", quota_pct_remaining: null, reset_at: null, current_b_tok_per_h: 3.1, est_usd_per_h: 145, health: "ok", series_b_tok_per_h: [3, 3.1, 0], series_usd_per_h: [140, 145, 0] },
              { id: "antigravity:gemini", label: "AGY · Gemini", sublabel: "14% left", provider: "antigravity", quota_pct_remaining: 14, reset_at: null, current_b_tok_per_h: 1.9, est_usd_per_h: 92, health: "ok", series_b_tok_per_h: [1.8, 1.9, 0], series_usd_per_h: [88, 92, 0] },
              { id: "xai:grok", label: "xAI · Grok", sublabel: "33% left", provider: "xai", quota_pct_remaining: 33, reset_at: null, current_b_tok_per_h: 0.25, est_usd_per_h: 14.98, health: "ok", series_b_tok_per_h: [0.2, 0.25, 0], series_usd_per_h: [12, 14.98, 0] },
              { id: "antigravity:claude", label: "AGY · Claude", sublabel: "0% left", provider: "antigravity", quota_pct_remaining: 0, reset_at: null, current_b_tok_per_h: 0.15, est_usd_per_h: 3.93, health: "exhausted", series_b_tok_per_h: [0.15, 0.15, 0], series_usd_per_h: [3.93, 3.93, 0] },
              { id: "openai:codex", label: "OpenAI · Codex", sublabel: "0% left", provider: "openai", quota_pct_remaining: 0, reset_at: null, current_b_tok_per_h: 0, est_usd_per_h: 0, health: "exhausted", series_b_tok_per_h: [0, 0, 0], series_usd_per_h: [0, 0, 0] },
            ],
          },
          missions,
          links: [
            ...missions.map((m, i) => ({
              kind: "inference",
              source_id: i % 2 === 0 ? "google:gemini" : "antigravity:gemini",
              mission_id: m.id,
              value: m.b_tok_per_h,
              est_usd_per_h: m.inference_usd_per_h,
              degraded: i === 0,
            })),
            ...missions.map((m, i) => ({
              kind: "compute",
              source_id: i === 0 ? "boat:xlarge" : "static:fleet",
              mission_id: m.id,
              value: m.vcpu,
              est_usd_per_h: m.compute_usd_per_h,
              degraded: i === 0,
            })),
          ],
        },
      });
    }
    if (path === `/api/resources/missions/${bigMissionId}`) {
      const tracks = Array.from({ length: 85 }, (_, i) => ({
        id: `trk-${i}`,
        label: i === 0 ? "Wave 8 Provers" : `mission-${1000 + i}`,
        sub: i < 12 ? "2 active" : "completed",
        state: i < 12 ? "active" : "done",
      }));
      const subagents = Array.from({ length: 140 }, (_, i) => ({
        id: `sub-${i}`,
        mission_id: `sub-${i}`,
        native: false,
        track_id: `trk-${i % 85}`,
        role: "worker",
        label: `Wave8 R13 Wk${String(i).padStart(2, "0")} Witness`,
        model: "gemini-3-pro",
        node_id: "boat-xl",
        vcpu: i < 23 ? 16 : 0,
        compute_usd_per_h: i < 23 ? 1.6 : 0,
        b_tok_per_h: i < 23 ? 0.14 : 0,
        inference_usd_per_h: i < 23 ? 4.2 : 0,
        state: i < 23 ? "active" : "done",
      }));
      return route.fulfill({
        json: {
          as_of: new Date().toISOString(),
          mission: {
            id: bigMissionId,
            title: "evm.fast (claude takeover)",
            project: "ethereum",
            status: "active",
            started_at: new Date(Date.now() - 86400_000).toISOString(),
            completed_at: null,
            elapsed_secs: 86400,
            eta_remaining_secs: 1800,
            subagent_count: 140,
            track_count: 85,
          },
          available_horizons: [{ id: "6h", label: "Fast-DAG (6h)", span_secs: 21600 }],
          active_horizon: "6h",
          flow: {
            inputs: [
              { id: "google:gemini", kind: "inference", label: "Google · Gemini", sub: "inference", weight: 2.5, est_usd_per_h: 79.7 },
              { id: "antigravity:gemini", kind: "inference", label: "AGY · Gemini", sub: "inference", weight: 0.7, est_usd_per_h: 15.7 },
            ],
            tracks,
            subagents,
            input_to_track: Array.from({ length: 12 }, (_, i) => ({
              kind: "inference",
              source_id: i < 9 ? "google:gemini" : "antigravity:gemini",
              target_id: `trk-${i}`,
              weight: 0.25,
              est_usd_per_h: 7.9,
              degraded: false,
            })),
            track_to_subagent: Array.from({ length: 23 }, (_, i) => ({
              kind: "inference",
              source_id: `trk-${i % 12}`,
              target_id: `sub-${i}`,
              weight: 0.14,
              est_usd_per_h: 4.1,
              degraded: false,
            })),
          },
          dag: {
            origin_unix_secs: 1700000000,
            horizon_secs: 21600,
            now_offset_secs: 14000,
            bars: subagents.slice(0, 12).map((s, idx) => ({
              id: s.id,
              mission_id: s.mission_id,
              label: s.label,
              section: idx < 4 ? "Wave 8 Provers" : "Auditors",
              role: s.role,
              model: s.model,
              node_id: s.node_id,
              vcpu: s.vcpu,
              compute_usd_per_h: s.compute_usd_per_h,
              b_tok_per_h: s.b_tok_per_h,
              inference_usd_per_h: s.inference_usd_per_h,
              start_offset_secs: idx * 600,
              duration_secs: 3600,
              eta_remaining_secs: 1200,
              eta_basis: "cohort_p50",
              state: "active",
              after_ids: idx > 0 ? [`sub-${idx - 1}`] : [],
            })),
          },
          timeline: {
            offsets_secs: [0, 7000, 14000, 21600],
            observed_vcpu: [200, 368, 368, null],
            projected_vcpu: [null, null, 368, 80],
            observed_compute_usd_per_h: [20, 36.8, 36.8, null],
            projected_compute_usd_per_h: [null, null, 36.8, 8],
            observed_b_tok_per_h: [2.4, 3.2, 3.2, null],
            projected_b_tok_per_h: [null, null, 3.2, 0.5],
            observed_inference_usd_per_h: [70, 95, 88, null],
            projected_inference_usd_per_h: [null, null, 88, 12],
          },
        },
      });
    }
    if (path === "/api/projects") return route.fulfill({ json: { projects: [] } });
    if (
      path === "/api/control/missions" ||
      path === "/api/control/queue" ||
      path === "/api/backends" ||
      path === "/api/cloud/accounts"
    ) {
      return route.fulfill({ json: [] });
    }
    return route.fulfill({ json: {} });
  });

  await page.setViewportSize({ width: 1280, height: 960 });
  await page.goto("/");
  await page.getByTestId("sb-resources").click();
  await page.getByTestId("res-metric-usd").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();
  await expect(page.getByTestId("res-summary-stamp")).toContainText("$1,534 (6h)");

  // Verify the Sankey diagram dynamically fills 100% of `.res-card-main`'s available body height
  const cardMainBox = (await page.locator(".res-card-main").boundingBox())!;
  const svgBox = (await page.getByTestId("res-sankey-svg").boundingBox())!;
  expect(svgBox.height).toBeGreaterThan(480);
  expect(Math.abs(svgBox.height - (cardMainBox.height - 38))).toBeLessThanOrEqual(3);

  // Ensure no duplicate "14% left · 14% left" text and zero horizontal clipping of SVG text
  const agyNodeText = await page.getByTestId("res-node-antigravity:gemini").textContent();
  expect(agyNodeText ?? "").not.toContain("14% left · 14% left");
  expect(await page.locator('[data-testid="res-node-openai:codex"]').count()).toBe(0);

  // Scrubbing the rightmost ("now") point of the consumption curve must NOT dive to 0 when active missions run
  const curveSvg = page.locator(".res-curve-svg");
  const cbox = (await curveSvg.boundingBox())!;
  await page.mouse.move(cbox.x + cbox.width - 2, cbox.y + cbox.height / 2);
  await expect(page.getByTestId("res-consumption-card")).toContainText("$256/h");
  await expect(page.getByTestId("res-consumption-card")).not.toContainText("$0.00/h");
  await page.mouse.move(10, 10);

  const textBoxes = await page
    .locator(".res-sankey-svg text")
    .evaluateAll((els) => els.map((el) => el.getBoundingClientRect()));
  for (const b of textBoxes) {
    if (b.width === 0) continue;
    expect(b.x).toBeGreaterThanOrEqual(svgBox.x - 2);
    expect(b.x + b.width).toBeLessThanOrEqual(svgBox.x + svgBox.width + 2);
  }

  // Switch to Compute and verify thick degraded ribbon renders cleanly via fill (no 250px stroke-dasharray)
  await page.getByTestId("res-lens-compute").click();
  const boatLink = page.getByTestId(`res-link-boat:xlarge-${bigMissionId}`);
  await expect(boatLink).toHaveAttribute("stroke-width", "1.1");

  // Drill into Fast-DAG -> switch to 3-col Flow and assert clean capped layout with zero overlapping labels
  await page.getByTestId("res-lens-inference").click();
  await page.getByTestId("res-fast-dag-jump").click();
  await expect(page.getByTestId("res-dag-view")).toBeVisible();
  const dagScrollBox = (await page.getByTestId("res-dag-view").boundingBox())!;
  expect(Math.abs(dagScrollBox.height - (cardMainBox.height - 38))).toBeLessThanOrEqual(3);
  await page.getByTestId("res-submode-flow").click();
  await expect(page.getByTestId("res-sankey-svg")).toBeVisible();

  const flowNodeCount = await page.locator(".res-sankey-node-group").count();
  expect(flowNodeCount).toBeLessThanOrEqual(34);

  // Verify Flow SVG text labels also fit horizontally without clipping
  const flowSvgBox = (await page.getByTestId("res-sankey-svg").boundingBox())!;
  const flowTextBoxes = await page
    .locator(".res-sankey-svg text")
    .evaluateAll((els) => els.map((el) => el.getBoundingClientRect()));
  for (const b of flowTextBoxes) {
    if (b.width === 0) continue;
    expect(b.x).toBeGreaterThanOrEqual(flowSvgBox.x - 2);
    expect(b.x + b.width).toBeLessThanOrEqual(flowSvgBox.x + flowSvgBox.width + 2);
  }
});
