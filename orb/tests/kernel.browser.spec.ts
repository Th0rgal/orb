import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";

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

test("generated browser adapters execute shared Lean projection fixtures", async ({ page }) => {
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
