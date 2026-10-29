import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import { eventPage } from "./eventPageFixture";
import { privilegeSnapshot } from "./privilegeAccessFixture";

const preview = process.env.ORB_KERNEL_PREVIEW === "1";

test("kernel failure prevents App import, then retry opens the real application", async ({ page }) => {
  let attempts = 0;
  const requests: string[] = [];
  const isApp = (url: string) => url.includes("/src/appEntry.tsx") || url.includes("/src/App.tsx") || /\/assets\/appEntry-[^/]+\.js/.test(url);
  page.on("request", request => requests.push(request.url()));
  await page.route("**/*orb_kernel*.wasm*", async route => {
    // Vite also serves a JS URL module at ?import&url. Fail the binary fetch,
    // after that module has loaded, so this exercises kernel Retry itself.
    if (route.request().resourceType() !== "fetch") return route.continue();
    attempts++;
    if (attempts === 1) await route.fulfill({ status: 503, body: "unavailable" });
    else await route.continue();
  });
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText("could not start");
  expect(requests.some(isApp)).toBe(false);
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  await expect.poll(() => requests.some(isApp)).toBe(true);
  expect(attempts).toBe(2);
  await expect(page.getByRole("main")).toBeVisible();
  await expect(page.getByRole("button", { name: "Inbox", exact: true })).toBeVisible();
  await expect(page.getByText("Orb could not open. Please reload.", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Starting Orb…", { exact: true })).toHaveCount(0);
});

test("mounted application executes shared WASM projections across transcript, Inbox, and Providers", async ({ page }) => {
  const pageErrors: string[] = [];
  page.on("pageerror", err => pageErrors.push(err.message));
  let wasmFetches = 0;
  const fixedNow = "2026-10-09T12:00:00Z";
  await page.addInitScript(now => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem("orb-theme", "dark");
    const fixed = Date.parse(now);
    Date.now = () => fixed;
  }, fixedNow);
  const mission = {
    id: "m-wasm",
    title: "Verify shared WASM projections",
    project: "orb",
    status: "completed",
    backend: "opencode",
    created_at: "2026-10-09T11:50:00Z",
    updated_at: "2026-10-09T11:55:00Z",
    history: [
      { role: "user", content: "Run kernel checks" },
      { role: "assistant", content: "All checks completed." },
    ],
  };
  const events = [
    { id: "e1", event_id: "u1", sequence: 1, event_type: "user_message", content: "Run kernel checks", timestamp: "2026-10-09T11:50:00Z" },
    {
      id: "e2", event_id: "tc1", sequence: 2, event_type: "tool_call", tool_call_id: "call_1", tool_name: "todowrite",
      content: JSON.stringify({ todos: [{ content: "Build WASM", status: "completed" }, { content: "Verify projections", status: "in_progress" }] }),
      timestamp: "2026-10-09T11:51:00Z",
    },
    { id: "e3", event_id: "tr1", sequence: 3, event_type: "tool_result", tool_call_id: "call_1", tool_name: "todowrite", content: "ok", timestamp: "2026-10-09T11:51:01Z" },
    { id: "e4", event_id: "n1", sequence: 4, event_type: "assistant_message", content: "Checking the binary now.", timestamp: "2026-10-09T11:52:00Z" },
    { id: "e5", event_id: "tc2", sequence: 5, event_type: "tool_call", tool_call_id: "call_2", tool_name: "bash", content: JSON.stringify({ command: "true" }), timestamp: "2026-10-09T11:52:05Z" },
    { id: "e6", event_id: "tr2", sequence: 6, event_type: "tool_result", tool_call_id: "call_2", tool_name: "bash", content: "exit 0", timestamp: "2026-10-09T11:52:06Z" },
    {
      id: "e7", event_id: "a1", sequence: 7, event_type: "assistant_message",
      content: "All checks completed.\n\nMetric | Count | Latency\nExports | 113 | 2\nImports | 0 | 0\n\n<file path=\"orb/src/assets/orb_kernel.wasm\" name=\"orb_kernel.wasm\" />",
      timestamp: "2026-10-09T11:55:00Z",
    },
  ];
  const anthropicReset = Math.floor(Date.parse("2026-10-09T14:00:00Z") / 1000);
  const anthropicUsage = {
    provider_type: "anthropic",
    account_email: "ops@example.com",
    status_code: 200,
    unified_status: "allowed_warning",
    unified_representative_claim: "seven_day",
    unified_5h_utilization: 0.25,
    unified_7d_utilization: 0.91,
    unified_5h_reset: anthropicReset,
    unified_7d_reset: anthropicReset + 86400,
  };
  await page.route("**/*orb_kernel*.wasm*", async route => {
    if (route.request().resourceType() === "fetch") wasmFetches++;
    await route.continue();
  });
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/privilege-access") return route.fulfill({ json: privilegeSnapshot() });
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "orb", title: "Orb", color: "blue" }] } });
    if (path === "/api/control/missions") return route.fulfill({ json: [mission] });
    if (path === "/api/control/missions/m-wasm" || path.endsWith("/opened")) return route.fulfill({ json: mission });
    if (path === "/api/control/missions/m-wasm/events") return route.fulfill(eventPage(route, events));
    if (path.endsWith("/manifest")) return route.fulfill({ json: { revision: 1, entries: {} } });
    if (path.endsWith("/files")) return route.fulfill({ json: { entries: [] } });
    if (path.endsWith("/crons")) return route.fulfill({ json: { jobs: [] } });
    if (path.endsWith("/controller")) return route.fulfill({ json: { job: null, runs: [] } });
    if (path.endsWith("/queue")) return route.fulfill({ json: [] });
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    if (path === "/api/ai/providers") return route.fulfill({ json: [{ id: "ant", name: "Anthropic (ops@example.com)", account_email: "ops@example.com", provider_type: "anthropic", enabled: true, uses_oauth: true, has_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" } }] });
    if (path === "/api/ai/providers/usage") return route.fulfill({ json: { entries: { ant: anthropicUsage } } });
    if (path === "/api/ai/providers/ant/usage") return route.fulfill({ json: anthropicUsage });
    return route.fulfill({ json: [] });
  });

  await page.goto("/");
  await expect.poll(() => wasmFetches).toBe(1);

  // Inbox relative-time formatting executes orb_relative_time_bucket ("5m" for 11:55 -> 12:00).
  await page.locator("#orb-sidebar").getByRole("button", { name: /^Inbox/ }).click();
  const inboxRow = page.locator('[data-inbox-id="m-wasm"]');
  await expect(inboxRow.locator(".inbox-time")).toHaveText("5m");

  // Open the mission directly from Inbox to exercise orb_workfold_step (narration folded into .st-work),
  // orb_taskcard_step (stale task card), leansys_gfm_pipe_scan (table), and leansys_tag_scan (rich file chip).
  await inboxRow.locator(".inbox-row-title-btn").click();
  await expect(page.locator(".st-text")).toHaveCount(1);
  await expect(page.locator(".st-text")).not.toContainText("Checking the binary now.");
  await expect(page.locator(".st-work")).toHaveCount(1);
  const taskCard = page.locator(".mission-tasks");
  await expect(taskCard).toHaveAttribute("data-state", "stale");
  await expect(taskCard.locator(".tasks-count")).toHaveText("Task list not updated · turn finished (1/2 completed)");
  await expect(page.locator(".st-text table tbody tr")).toHaveCount(2);
  await expect(page.locator(".st-text").getByText("orb_kernel.wasm", { exact: true })).toBeVisible();

  // Providers exercises orb_usage_limit_status ("Approaching limit · weekly 91%").
  await page.getByRole("button", { name: "Providers", exact: true }).click();
  await page.getByRole("button", { name: /ops@example\.com/ }).first().click();
  await expect(page.getByTestId("usage-limit-status")).toHaveText("Approaching limit · weekly 91%");
  expect(pageErrors).toEqual([]);
});

test("generated browser adapters execute shared Lean projection fixtures", async ({ page }) => {
  test.skip(preview, "Vite source module import is dev-server only; production bundle execution is covered above");
  const projection = JSON.parse(readFileSync(new URL("../../shared/orb-spec/fixtures/projection-invariants.json", import.meta.url), "utf8"));
  const appRequested = page.waitForResponse(response => response.url().includes("/src/appEntry.tsx"));
  await page.goto("/");
  await appRequested;
  await expect(page.getByRole("main")).toBeVisible();
  // Keep the same exported presentation adapters used by application callers.
  const observed = await page.evaluate(async cases => {
    // Vite serves this source module; it shares the initialized runtime instance.
    // @ts-expect-error URL import resolved by the running Vite server
    const k = await import("/src/orbKernel.ts");
    return {
      workfold: cases.workfold_cases.map((c: any) => k.orbWorkfoldStep(c.input.is_text ? 2 : 1, c.input.cumulative, c.input.non_empty, c.input.tool_ahead, c.input.next_is_tool, c.input.fold_has_tool)),
      taskcard: cases.taskcard_cases.map((c: any) => k.orbTaskcardStep(c.input.ended, c.input.all_done_or_cancelled, c.input.outcome_finished)),
      saturated: k.orbTranscriptPatchStep({ len: 0xffff_ffff, seq: 0xffff_ffff }, 0, 1),
    };
  }, projection);
  expect(observed.workfold).toEqual(projection.workfold_cases.map((c: any) => ({ foldItem: c.expected.fold, foldHasToolNext: c.expected.next_fold_has_tool })));
  expect(observed.taskcard).toEqual(projection.taskcard_cases.map((c: any) => c.expected.state));
  expect(observed.saturated).toEqual({ len: 0xffff_ffff, seq: 0xffff_ffff });
});
