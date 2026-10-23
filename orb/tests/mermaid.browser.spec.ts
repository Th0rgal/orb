import { expect, test } from "@playwright/test";
import path from "node:path";
import { mermaidSamples } from "./mermaidSamples";

const shots = process.env.MERMAID_REPORT_DIR || "test-results/mermaid";
const types = Object.keys(mermaidSamples);

test("diagram is the default view and the toggle switches to the source", async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(navigator, "clipboard", { value: { writeText: async (t: string) => { (window as any).copied = t; } } }));
  await page.goto("/tests/mermaid.html?only=flowchart");
  const block = page.locator(".mermaid-block");
  await expect(block).toHaveAttribute("data-state", "ready");
  await expect(block.locator(".mermaid-svg")).toBeVisible();
  await expect(block.getByRole("button", { name: "Diagram", exact: true })).toHaveAttribute("aria-pressed", "true");
  await block.getByRole("button", { name: "Code", exact: true }).click();
  await expect(block.locator("pre code")).toContainText("flowchart LR");
  await expect(block.locator(".mermaid-svg")).toHaveCount(0);
  await block.getByRole("button", { name: "Diagram", exact: true }).click();
  await expect(block.locator(".mermaid-svg")).toBeVisible();
  await block.getByRole("button", { name: "Copy diagram source" }).click();
  expect(await page.evaluate(() => (window as any).copied)).toBe(mermaidSamples.flowchart);
  // No script or handler survives sanitising.
  // The diagram is an <img> data URL: it cannot run script or fetch anything.
  const src = await block.locator("img.mermaid-svg").getAttribute("src");
  expect(src).toMatch(/^data:image\/svg\+xml/);
  expect(decodeURIComponent(src!)).not.toMatch(/<script|onclick|onload/i);
});

test("invalid syntax falls back to the source with the parser message", async ({ page }) => {
  await page.goto("/tests/mermaid.html?only=pie&invalid");
  const bad = page.locator(".mermaid-block").last();
  await expect(bad).toHaveAttribute("data-state", "error");
  await expect(bad.getByRole("note")).toContainText("Couldn't render diagram");
  await expect(bad.locator("pre code")).toContainText("((( broken");
  await expect(bad.getByRole("button", { name: "Diagram", exact: true })).toBeDisabled();
  await expect(page.getByText("After the broken diagram.")).toBeVisible();
  await bad.screenshot({ path: path.join(shots, "invalid-dark.png") });
  await expect(page.locator(".mermaid-block").first()).toHaveAttribute("data-state", "ready");
  // Mermaid's own error graphic never leaks into the page.
  expect(await page.locator("body > [id^='dorb-mermaid'], body > svg[aria-roledescription='error']").count()).toBe(0);
});

test("streaming shows the source and renders once when the fence closes", async ({ page }) => {
  await page.goto("/tests/mermaid.html?stream");
  await page.evaluate(() => { (window as any).renders = 0; });
  const src = "```mermaid\n" + mermaidSamples.sequence;
  for (let i = 12; i <= src.length; i += 12) await page.evaluate((t) => (window as any).setText(t), src.slice(0, i));
  await page.evaluate((t) => (window as any).setText(t), src);
  const block = page.locator(".mermaid-block");
  await expect(block).toHaveAttribute("data-state", "streaming");
  await expect(block.locator("pre code")).toContainText("sequenceDiagram");
  await expect(block.getByRole("button", { name: "Diagram", exact: true })).toBeDisabled();
  expect(await page.evaluate(() => document.querySelectorAll("[id^='orb-mermaid']").length)).toBe(0);
  await block.screenshot({ path: path.join(shots, "streaming-dark.png") });
  await page.evaluate((t) => (window as any).setText(t), src + "\n```\n\nDone.");
  await expect(block).toHaveAttribute("data-state", "ready");
  await expect(block.locator(".mermaid-svg")).toBeVisible();
  await block.locator(".mermaid-svg").evaluate((el) => { (el as any).__orbMark = 1; });
  // More text after the diagram does not render it again.
  await page.evaluate((t) => (window as any).setText(t), src + "\n```\n\nDone. And some more words after it.");
  await page.waitForTimeout(400);
  expect(await page.locator(".mermaid-block .mermaid-svg").evaluate((el) => (el as any).__orbMark)).toBe(1);
});

test("wide diagrams fit the block and expand supports zoom", async ({ page }) => {
  await page.goto("/tests/mermaid.html?only=wide");
  const block = page.locator(".mermaid-block");
  await expect(block).toHaveAttribute("data-state", "ready");
  const canvas = block.locator(".mermaid-canvas");
  expect(await canvas.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await block.getByRole("button", { name: "Expand diagram" }).click();
  const dialog = page.getByRole("dialog", { name: "Diagram", exact: true });
  await expect(dialog.locator(".mermaid-zoom")).toBeVisible();
  const before = await dialog.locator(".mermaid-zoom-level").textContent();
  await dialog.getByRole("button", { name: "Zoom in" }).click();
  await expect(dialog.locator(".mermaid-zoom-level")).not.toHaveText(before!);
  await page.screenshot({ path: path.join(shots, "expanded-dark.png") });
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
});

for (const theme of ["dark", "light"] as const) {
  test(`every diagram type renders in the ${theme} theme`, async ({ page }) => {
    await page.goto(`/tests/mermaid.html?theme=${theme}`);
    const blocks = page.locator(".mermaid-block");
    await expect(blocks).toHaveCount(types.length);
    for (let i = 0; i < types.length; i++) {
      const block = blocks.nth(i);
      await expect(block, types[i]).toHaveAttribute("data-state", "ready", { timeout: 15_000 });
      await block.scrollIntoViewIfNeeded();
      await block.screenshot({ path: path.join(shots, `${types[i]}-${theme}.png`) });
    }
    await page.screenshot({ path: path.join(shots, `transcript-${theme}.png`), fullPage: true });
  });
}

test("a hostile diagram renders neutralised", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => { if (!r.url().startsWith("http://127.0.0.1")) requests.push(r.url()); });
  await page.goto("/tests/mermaid.html?stream");
  const src = '%%{init: {"theme":"forest","themeCSS":".node rect{fill:url(https://evil.example/x.png)} @import url(https://evil.example/a.css);","themeVariables":{"primaryColor":"#ff0000"}}}%%\nflowchart LR\n  A["<a href=javascript:alert(1)>x</a> <img src=https://evil.example/i.png onerror=alert(1)>"] --> B\n  click A "https://evil.example" _blank';
  await page.evaluate((t) => (window as any).setText(t), "```mermaid\n" + src + "\n```");
  const block = page.locator(".mermaid-block");
  await expect(block).toHaveAttribute("data-state", "ready");
  const html = decodeURIComponent((await block.locator(".mermaid-svg").getAttribute("src"))!);
  expect(html).not.toMatch(/evil\.example|javascript:|onerror|@import|<a[\s>]|href=/i);
  expect(html).not.toContain("#ff0000");
  await page.waitForTimeout(300);
  expect(requests).toEqual([]);
});

test("the diagrams of a real message all render as loaded images", async ({ page }) => {
  await page.goto("/tests/mermaid.html?mission");
  const blocks = page.locator(".mermaid-block");
  await expect(blocks).toHaveCount(16);
  for (let i = 0; i < 16; i++) {
    const block = blocks.nth(i);
    // Diagram 1 has an unquoted `(…)` edge label that mermaid rejects; Orb quotes it and renders.
    await expect(block, `diagram ${i + 1}`).toHaveAttribute("data-state", "ready", { timeout: 15_000 });
    const img = block.locator("img.mermaid-svg");
    await img.scrollIntoViewIfNeeded();
    await expect.poll(() => img.evaluate((el: HTMLImageElement) => el.complete && el.naturalWidth > 0), { message: `diagram ${i + 1} decodes` }).toBe(true);
    const box = (await img.boundingBox())!;
    expect(box.height, `diagram ${i + 1} height`).toBeGreaterThan(40);
    await block.screenshot({ path: path.join(shots, `mission-${i + 1}.png`) });
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

for (const width of [1100, 390]) {
  test(`diagrams fit the card at ${width}px: wide scales down, tall is capped, small is not upscaled`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/tests/mermaid.html?only=wide,tall,flowchart");
    const blocks = page.locator(".mermaid-block");
    await expect(blocks).toHaveCount(3);
    const vh = 844;
    for (let i = 0; i < 3; i++) {
      const block = blocks.nth(i);
      await expect(block).toHaveAttribute("data-state", "ready", { timeout: 15_000 });
      const img = block.locator("img.mermaid-svg");
      await expect.poll(() => img.evaluate((el: HTMLImageElement) => el.complete && el.naturalWidth > 0)).toBe(true);
      const m = await img.evaluate((el: HTMLImageElement) => {
        const r = el.getBoundingClientRect(), c = el.parentElement!.getBoundingClientRect();
        return { w: r.width, h: r.height, natW: el.width ? Number(el.getAttribute("width")) : 0, natH: Number(el.getAttribute("height")), canvasW: c.width, scroll: el.parentElement!.scrollWidth - el.parentElement!.clientWidth };
      });
      expect(m.scroll).toBeLessThanOrEqual(0);
      expect(m.w).toBeLessThanOrEqual(m.canvasW);
      expect(m.w).toBeLessThanOrEqual(m.natW + 1);
      expect(m.h).toBeLessThanOrEqual(vh * 0.6 + 1);
      expect(Math.abs(m.w / m.h - m.natW / m.natH)).toBeLessThan(0.02 * (m.natW / m.natH) + 0.01);
      await block.screenshot({ path: path.join(shots, `fit-${width}-${i}.png`) });
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    // Expanded view opens fitted to the screen.
    await blocks.nth(0).getByRole("button", { name: "Expand diagram" }).click();
    const zoom = page.getByRole("dialog", { name: "Diagram", exact: true }).locator(".mermaid-zoom");
    await expect(zoom).toBeVisible();
    await expect.poll(async () => (await zoom.boundingBox())!.width).toBeLessThanOrEqual(width);
    await page.keyboard.press("Escape");
  });
}
