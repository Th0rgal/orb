import { test, expect } from '@playwright/test';
test.use({ browserName: 'webkit' });
for (const format of ['png', 'jpeg', 'webp', 'broken']) test(`image preview ${format}`, async ({ page }) => {
  const bytes = format === 'broken' ? [1, 2, 3] : await page.evaluate(format => {
    const canvas = document.createElement('canvas'); canvas.width = 2400; canvas.height = 1600;
    const context = canvas.getContext('2d')!; context.fillStyle = '#c6934e'; context.fillRect(0, 0, 2400, 1600);
    return Array.from(atob(canvas.toDataURL(`image/${format}`).split(',')[1]), c => c.charCodeAt(0));
  }, format);
  const name = `sample.${format === 'broken' ? 'png' : format}`; let downloads = 0;
  await page.route('**/api/**', route => {
    const q = route.request().postDataJSON() ?? {}; let json: unknown = {};
    if (q.action === 'roots') json = {sources:[{id:'workspace',label:'Workspace',available:true}]};
    if (q.action === 'resolve') json = {results:q.paths.map((reference:string)=>({reference,matches:reference.includes('IMPLEMENTATION')?[{name,path:name,kind:'file'}]:[]}))};
    if (q.action === 'list') json = {entries:[{name,path:name,kind:'file'}]};
    if (q.action === 'read') json = {binary:true,size:bytes.length,truncated:false};
    if (q.action === 'download') { downloads++; json = {bytes,size:bytes.length,next:bytes.length}; }
    return route.fulfill({json});
  });
  await page.goto('/tests/file-panel.html');
  await page.getByRole('button', {name:'IMPLEMENTATION-BRIEF.md',exact:true}).click();
  if (format === 'broken') await expect(page.getByRole('alert')).toContainText('Couldn’t display this image');
  else {
    const viewport = page.locator('.image-viewport'), image = viewport.locator('img');
    await expect(viewport).toHaveAttribute('aria-busy','false');
    expect(await image.evaluate(i => (i as HTMLImageElement).naturalWidth)).toBe(2400);
    await page.getByRole('button',{name:'Actual size',exact:true}).click();
    await expect(page.getByRole('button',{name:'Actual size',exact:true})).toHaveText('100%');
    await page.getByRole('button',{name:'Zoom in',exact:true}).click();
    await expect(page.getByRole('button',{name:'Actual size',exact:true})).toHaveText('125%');
    const bounds = (await viewport.boundingBox())!;
    await page.mouse.move(bounds.x + bounds.width/2, bounds.y + bounds.height/2);
    await page.mouse.down(); await page.mouse.move(bounds.x + bounds.width/2+80,bounds.y + bounds.height/2+60); await page.mouse.up();
    await expect.poll(() => image.evaluate(i => getComputedStyle(i).transform)).toContain('80, 60');
    await page.keyboard.press('0');
    await expect(page.getByRole('button',{name:'Actual size',exact:true})).not.toHaveText('125%');
    await viewport.dispatchEvent('wheel', {deltaY:-30,ctrlKey:true,clientX:bounds.x+bounds.width/2,clientY:bounds.y+bounds.height/2});
    await page.getByRole('button',{name:'Fit',exact:true}).click();
    const fitted = `${Math.round(Math.min(1,(bounds.width-32)/2400,(bounds.height-80)/1600)*100)}%`;
    await expect(page.getByRole('button',{name:'Actual size',exact:true})).toHaveText(fitted);
    await page.getByRole('textbox',{name:'Draft'}).focus(); await page.keyboard.press('+');
    await expect(page.getByRole('button',{name:'Actual size',exact:true})).toHaveText(fitted!);
    expect(downloads).toBe(1);
    if (format === 'png') await page.screenshot({path:'artifacts/image-preview.png'});
  }
  await page.getByRole('button',{name:'Back',exact:true}).click();
  await expect(page.locator('.image-viewer')).toHaveCount(0);
  await expect(page.getByRole('button',{name:'View image',exact:true})).toBeVisible();
});
