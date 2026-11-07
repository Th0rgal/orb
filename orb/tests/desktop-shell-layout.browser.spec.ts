import { expect, test } from "@playwright/test";
import layoutFixture from "../../shared/orb-spec/fixtures/desktop-shell-layout.json" with { type: "json" };
import { eventPage } from "./eventPageFixture";

test("desktop shell layout: translucent titlebar, pinned Settings footer, scrollable sidebar & mission, crisp top, optimistic folder open, and /btw column lifecycle", async ({ page }) => {
  await page.setViewportSize({ width: 1200, height: 720 });

  // Simulate the native `__ORB_DESKTOP__` host (`orb-locald` RPC contract).
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb-theme", "dark");

    (window as unknown as Record<string, unknown>).__ORB_DESKTOP__ = {
      core: {
        invoke: async (cmd: string) => {
          if (cmd === "desktop_connection_load") return { api_url: location.origin, token: "test" };
          if (cmd === "desktop_connection_save") return null;
          if (cmd === "local_bindings_refresh") return { revision: 1, bindings: {} };
          if (cmd === "local_agents_discover") return [];
          if (cmd === "local_machine_identity") return "test-local-machine-id";
          if (cmd === "project_context_status" || cmd === "project_context_sync" || cmd === "project_context_file") {
            return null;
          }
          return null;
        },
        Channel: class {
          id = 1;
          onmessage: (msg: unknown) => void = () => {};
        },
      },
      event: {
        listen: async () => () => {},
        emit: async () => {},
      },
      window: {
        getCurrentWindow: () => ({
          innerSize: async () => ({ width: 2400, height: 1440 }),
          scaleFactor: async () => 2,
          startDragging: async () => {},
        }),
      },
      webview: {
        getCurrentWebview: () => ({ label: "main" }),
      },
    };
  });

  // Build 45 missions under `ethereum` so the expanded sidebar far exceeds the 720px viewport!
  const targetMissionId = "e8cdf55f-a668-4802-81c2-8ccc33fd15b0";
  const missions = [
    {
      id: targetMissionId,
      title: "evm.fast (claude-opus-4-7)",
      status: "active",
      project: "ethereum",
      backend: "claude_code",
      history: [],
      created_at: "2026-11-07T06:00:00Z",
      updated_at: "2026-11-07T06:10:00Z",
    },
    ...Array.from({ length: 44 }, (_, i) => ({
      id: `eth-m-${i}`,
      title: i < 18 ? `Child live run ${i}` : `Child done run ${i}`,
      status: i < 18 ? "active" : "completed",
      project: "ethereum",
      parent_mission_id: i < 24 ? targetMissionId : undefined,
      history: [],
      created_at: "2026-11-07T05:00:00Z",
      updated_at: "2026-11-07T05:30:00Z",
    })),
  ];

  // Build a long 18-turn conversation on `e8cdf55f-a668-4802-81c2-8ccc33fd15b0` so `.scroll` must scroll far down to reach the composer.
  const events = Array.from({ length: 18 }, (_, i) => [
    {
      id: `u-${i}`,
      event_id: `u-${i}`,
      sequence: i * 2 + 1,
      event_type: "user_message",
      content: `Turn ${i + 1}: check stage-${i + 1} proof obligations`,
      timestamp: "2026-11-07T06:00:00Z",
    },
    {
      id: `a-${i}`,
      event_id: `a-${i}`,
      sequence: i * 2 + 2,
      event_type: "assistant_message",
      content: `Verified stage ${i + 1}.\n\n${"Detailed Lean 4 kernel output line with zero sorryAx. ".repeat(18)}`,
      timestamp: "2026-11-07T06:01:00Z",
    },
  ]).flat();

  let releaseFiles!: () => void;
  const filesGate = new Promise<void>((resolve) => {
    releaseFiles = resolve;
  });

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    if (path === `/api/control/missions/${targetMissionId}` || path.endsWith("/opened")) {
      return route.fulfill({ json: missions[0] });
    }
    if (path === `/api/control/missions/${targetMissionId}/events`) {
      return route.fulfill(eventPage(route, events));
    }
    if (path === "/api/control/stream") {
      return route.fulfill({ contentType: "text/event-stream", body: "" });
    }
    if (path === "/api/projects/ethereum/files") {
      await filesGate;
      return route.fulfill({ json: { entries: [] } });
    }
    if (path === "/api/projects") {
      return route.fulfill({
        json: {
          projects: [
            { slug: "ethereum", title: "Ethereum" },
            { slug: "maxwell", title: "Maxwell" },
          ],
        },
      });
    }
    if (path === "/api/control/missions") {
      return route.fulfill({ json: missions });
    }
    if (path.endsWith("/manifest")) {
      return route.fulfill({ json: { revision: 1, entries: {} } });
    }
    if (path.endsWith("/crons")) {
      return route.fulfill({ json: { jobs: [] } });
    }
    if (path.endsWith("/controller")) {
      return route.fulfill({ json: { job: null, runs: [] } });
    }
    return route.fulfill({ json: [] });
  });

  await page.goto("/");
  const ethBtn = page.getByRole("button", { name: "Ethereum", exact: true });
  if (!(await ethBtn.waitFor({ timeout: 10_000 }).then(() => true, () => false))) {
    await page.reload();
  }

  // 1. Optimistic folder expansion BEFORE `/files` resolves + zero amber context-sync error dot.
  await ethBtn.click();
  const targetRow = page.getByRole("button", { name: "evm.fast (claude-opus-4-7)", exact: true });
  await expect(targetRow).toBeVisible();
  await expect(page.getByText("Loading files…")).toBeVisible();
  await expect(page.locator(".ctx-dot.err")).toHaveCount(0);

  // Release `/files` returning `{ entries: [] }` -> `"Loading files…"` disappears cleanly (never stuck forever).
  releaseFiles();
  await expect(page.getByText("Loading files…")).toHaveCount(0);

  // Check launched-toggle right-padding reserve prevents label/count overlap.
  const rowPadRight = await targetRow.evaluate((el) => parseFloat(getComputedStyle(el).paddingRight));
  expect(rowPadRight).toBeGreaterThanOrEqual(layoutFixture.constants.launchedToggleRightReservePx);

  // 2. Viewport containment: even with 20+ visible rows in the expanded project, `.sidebar` and `.main`
  // NEVER stretch past the 720px viewport, `Settings` stays visible at the bottom-left, and `.sb-scroll` scrolls!
  const viewportHeight = 720;
  const sbBox = (await page.locator("#orb-sidebar.sidebar").boundingBox())!;
  expect(sbBox.y).toBe(0);
  expect(sbBox.y + sbBox.height).toBeLessThanOrEqual(viewportHeight + 1);

  const gearBtn = page.locator(".sb-foot .gear-btn");
  await expect(gearBtn).toBeVisible();
  const gearBox = (await gearBtn.boundingBox())!;
  expect(gearBox.y + gearBox.height).toBeLessThanOrEqual(viewportHeight);
  expect(gearBox.y).toBeGreaterThan(viewportHeight - 60);

  const sbScrollMetrics = await page.locator(".sb-scroll").evaluate((el) => ({
    clientHeight: el.clientHeight,
    scrollHeight: el.scrollHeight,
  }));
  expect(sbScrollMetrics.scrollHeight).toBeGreaterThan(sbScrollMetrics.clientHeight);
  await page.locator(".sb-scroll").evaluate((el) => {
    el.scrollTop = 180;
  });
  expect(await page.locator(".sb-scroll").evaluate((el) => el.scrollTop)).toBeGreaterThan(100);
  await page.locator(".sb-scroll").evaluate((el) => {
    el.scrollTop = 0;
  });

  // 3. Open mission `e8cdf55f-a668-4802-81c2-8ccc33fd15b0` and verify scrolling down to the composer works
  // and `.dock textarea` is strictly inside the viewport!
  await targetRow.click();
  const composerInput = page.getByPlaceholder("Send follow-up");
  await expect(composerInput).toBeVisible();
  const mainBox = (await page.locator(".app > .main").boundingBox())!;
  expect(mainBox.y + mainBox.height).toBeLessThanOrEqual(viewportHeight + 1);
  const composerBox = (await composerInput.boundingBox())!;
  expect(composerBox.y + composerBox.height).toBeLessThanOrEqual(viewportHeight);

  const mainScrollMetrics = await page.locator(".main > .scroll").evaluate((el) => {
    el.scrollTop = el.scrollHeight;
    return {
      scrollTop: el.scrollTop,
      clientHeight: el.clientHeight,
      scrollHeight: el.scrollHeight,
    };
  });
  expect(mainScrollMetrics.scrollHeight).toBeGreaterThan(mainScrollMetrics.clientHeight);
  expect(mainScrollMetrics.scrollTop).toBeGreaterThan(0);

  // 4. Titlebar translucency,compositing isolation, drag region attribute, merged top-fade scroll mask, and Chapters menu.
  const titlebar = page.locator(".app > .titlebar");
  await expect(titlebar).toHaveAttribute("data-orb-drag-region", "");
  for (const sel of ["#orb-sidebar.sidebar", ".app > .titlebar", ".app > .main"]) {
    expect(await page.locator(sel).evaluate((el) => getComputedStyle(el).isolation)).toBe("isolate");
  }
  const tbLeftBox = (await page.locator(".titlebar .tb-left").boundingBox())!;
  expect(tbLeftBox.x).toBeGreaterThanOrEqual(80);
  expect(tbLeftBox.x + tbLeftBox.width).toBeLessThanOrEqual(sbBox.width);

  const scrollMask = await page.locator(".main > .scroll").evaluate((el) => {
    const s = getComputedStyle(el);
    return s.maskImage || s.webkitMaskImage || "";
  });
  // Top of `.scroll` fades smoothly (`transparent 0, #000 14px`) so messages dissolve into the header instead of hard-clipping.
  expect(scrollMask.includes("14px")).toBe(true);

  const chaptersBtn = page.locator("#tb-tools .mission-tools .chapters-btn");
  await expect(chaptersBtn).toBeVisible();
  await chaptersBtn.click();
  const chaptersMenu = (await page.locator(".chapters-list").boundingBox())!;
  expect(chaptersMenu.y).toBeGreaterThanOrEqual(layoutFixture.constants.titlebarHeightPx - 1);
  await page.keyboard.press("Escape");

  // 5. `/btw` and `Files` merge into row 1 (`y === 0`), and side-column lifecycle holds:
  const trackCount = () =>
    page.locator(".app").evaluate((el) => getComputedStyle(el).gridTemplateColumns.trim().split(/\s+/).length);

  expect(await trackCount()).toBe(2);

  await page.getByRole("button", { name: "Side question", exact: true }).click();
  await expect(page.getByPlaceholder(/Ask a side question/)).toBeVisible();
  expect(await trackCount()).toBe(3);
  expect((await page.locator(".btw-sidebar").boundingBox())!.y).toBe(0);

  await page.getByRole("button", { name: "Files", exact: true }).click();
  await expect(page.locator(".file-panel[aria-label='Files']")).toBeVisible();
  expect((await page.locator(".file-panel[aria-label='Files']").boundingBox())!.y).toBe(0);
  expect(await page.locator(".file-panel[aria-label='Files']").evaluate((el) => getComputedStyle(el).isolation)).toBe("isolate");

  await page.getByRole("button", { name: /^Inbox/ }).click();
  await expect(page.locator(".app")).toHaveAttribute("data-pane", "page");
  expect(await trackCount()).toBe(2);

  // Reopen the conversation -> open `/btw` -> close `/btw` -> 2 tracks.
  await targetRow.click();
  const sideToggle = page.getByRole("button", { name: "Side question", exact: true });
  if ((await sideToggle.getAttribute("aria-expanded")) !== "true") {
    await sideToggle.click();
  }
  expect(await trackCount()).toBe(3);
  await sideToggle.click();
  expect(await trackCount()).toBe(2);
});
