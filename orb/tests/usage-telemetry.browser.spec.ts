import { expect, test } from "@playwright/test";

test("Usage telemetry settings aligns inputs cleanly and uses quiet Cursor-style focus in dark and light mode", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });
  await page.route("**/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/usage-telemetry") {
      return route.fulfill({
        json: {
          enabled: true,
          prompts_enabled: false,
          active: true,
          hub_url: "https://telemetry.thomas.md",
          namespace: "th0rgal",
          token_configured: true,
          queued: 0,
          last_error: null,
        },
      });
    }
    const json =
      path === "/api/projects" ? { projects: [] }
      : path === "/api/control/missions" ? []
      : path === "/api/ai/providers" ? []
      : path === "/api/ai/providers/usage" ? { entries: {} }
      : { job: null, runs: [] };
    return route.fulfill({ json });
  });

  await page.goto("/");
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByRole("tab", { name: "Usage telemetry", exact: true }).click();

  const nsInput = page.getByLabel("Telemetry namespace");
  const urlInput = page.getByLabel("Telemetry hub URL");
  const tokenInput = page.getByLabel("Telemetry token");

  await expect(nsInput).toBeVisible();
  await expect(urlInput).toHaveValue("https://telemetry.thomas.md");

  for (const theme of ["dark", "light"] as const) {
    await page.evaluate((t) => {
      document.documentElement.dataset.theme = t;
    }, theme);

    // All three Hub inputs align on the same right-hand control column and fit full URLs without clipping.
    const [nsBox, urlBox, tokBox] = await Promise.all([
      nsInput.boundingBox(),
      urlInput.boundingBox(),
      tokenInput.boundingBox(),
    ]);
    expect(nsBox).not.toBeNull();
    expect(urlBox).not.toBeNull();
    expect(tokBox).not.toBeNull();
    expect(Math.abs(nsBox!.x - urlBox!.x)).toBeLessThanOrEqual(1);
    expect(Math.abs(urlBox!.x - tokBox!.x)).toBeLessThanOrEqual(1);
    expect(Math.abs(nsBox!.width - urlBox!.width)).toBeLessThanOrEqual(1);
    expect(urlBox!.width).toBeGreaterThanOrEqual(240);

    // Clicking and selecting inside the URL field never draws an outer ring or box-shadow halo.
    const restingBorder = await nsInput.evaluate((el) => getComputedStyle(el).borderTopColor);
    await urlInput.click();
    await urlInput.selectText();
    await expect(urlInput).toBeFocused();
    await expect(urlInput).toHaveCSS("outline-style", "none");
    await expect(urlInput).toHaveCSS("box-shadow", "none");
    const focusedBorder = await urlInput.evaluate((el) => getComputedStyle(el).borderTopColor);
    expect(focusedBorder).not.toBe(restingBorder);

    if (process.env.ORB_CAPTURE_DIR) {
      await page.screenshot({ path: `${process.env.ORB_CAPTURE_DIR}/usage-telemetry-${theme}.png` });
    }
  }

  // Reject uppercase and unsupported characters in Namespace.
  const saveBtn = page.getByRole("button", { name: "Save", exact: true });
  await nsInput.fill("Th0rgal");
  await expect(nsInput).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByText(/Uppercase letters aren’t allowed/)).toBeVisible();
  await expect(saveBtn).toBeDisabled();

  await nsInput.fill("th0rgal@bad");
  await expect(nsInput).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByText(/Only lowercase letters/)).toBeVisible();
  await expect(saveBtn).toBeDisabled();

  await nsInput.fill("th0rgal-dev");
  await expect(nsInput).not.toHaveAttribute("aria-invalid", "true");
  await expect(saveBtn).toBeEnabled();
});
