import { test, expect } from '@playwright/test';
test('settings keep long policy text readable and persist project color', async ({page}) => {
  await page.goto('/tests/project-settings.html');
  await page.getByRole('button',{name:'Purple',exact:true}).click();
  await expect(page.getByRole('button',{name:'Purple',exact:true})).toHaveAttribute('aria-pressed','true');
  const icon=page.locator('.row.project .row-ico');
  await expect(icon).toHaveCSS('color','rgb(173, 154, 203)');
  await page.reload();
  await expect(icon).toHaveCSS('color','rgb(173, 154, 203)');
  await expect(page.getByRole('button',{name:'Purple',exact:true})).toHaveAttribute('aria-pressed','true');
  for (const width of [1100,600,390]) {
    await page.setViewportSize({width,height:900});
    const label=page.getByText('Budget per run',{exact:true});
    const box=await label.boundingBox();
    expect(box!.width).toBeGreaterThan(100);
    expect(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({path:test.info().outputPath(`settings-${width}.png`),fullPage:true});
  }
});
