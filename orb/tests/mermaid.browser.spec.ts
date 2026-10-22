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
  await expect(block.locator(".mermaid-svg svg")).toBeVisible();
  await expect(block.getByRole("button", { name: "Diagram", exact: true })).toHaveAttribute("aria-pressed", "true");
  await block.getByRole("button", { name: "Code", exact: true }).click();
  await expect(block.locator("pre code")).toContainText("flowchart LR");
  await expect(block.locator("svg.flowchart, .mermaid-svg")).toHaveCount(0);
  await block.getByRole("button", { name: "Diagram", exact: true }).click();
  await expect(block.locator(".mermaid-svg svg")).toBeVisible();
  await block.getByRole("button", { name: "Copy diagram source" }).click();
  expect(await page.evaluate(() => (window as any).copied)).toBe(mermaidSamples.flowchart);
  // No script or handler survives sanitising.
  expect(await block.locator("script, [onclick], [onload]").count()).toBe(0);
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
  await expect(block.locator(".mermaid-svg svg")).toBeVisible();
  const id = await block.locator(".mermaid-svg svg").getAttribute("id");
  // More text after the diagram does not render it again.
  await page.evaluate((t) => (window as any).setText(t), src + "\n```\n\nDone. And some more words after it.");
  await page.waitForTimeout(400);
  expect(await page.locator(".mermaid-block .mermaid-svg svg").getAttribute("id")).toBe(id);
});

test("wide diagrams scroll inside the block and expand supports zoom", async ({ page }) => {
  await page.goto("/tests/mermaid.html?only=wide");
  const block = page.locator(".mermaid-block");
  await expect(block).toHaveAttribute("data-state", "ready");
  const canvas = block.locator(".mermaid-canvas");
  expect(await canvas.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await block.getByRole("button", { name: "Expand diagram" }).click();
  const dialog = page.getByRole("dialog", { name: "Diagram", exact: true });
  await expect(dialog.locator(".mermaid-zoom svg")).toBeVisible();
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
