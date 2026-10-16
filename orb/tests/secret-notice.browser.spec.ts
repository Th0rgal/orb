import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('secret request notice is compact: key first, mission muted, Allow primary',async({page})=>{
 await page.goto('/tests/secret-notice.html');
 const toast=page.locator('.toast.secret');
 await expect(toast.locator('.toast-title strong')).toHaveText('VERCEL_TOKEN');
 await expect(toast.locator('.toast-sub')).toHaveAttribute('title',/autoresearch/);
 await expect(toast.locator('.toast-glyph svg')).toBeVisible();
 await expect(toast.getByRole('button',{name:'Allow'})).toHaveClass(/primary/);
 // Title stays on one line and the reason is clamped to two.
 const lineHeight=await toast.locator('.toast-message').evaluate(e=>parseFloat(getComputedStyle(e).lineHeight));
 expect((await toast.locator('.toast-message').boundingBox())!.height).toBeLessThanOrEqual(lineHeight*2+1);
 expect((await toast.locator('.toast-title').boundingBox())!.height).toBeLessThan(lineHeight*1.6);
 await toast.screenshot({path:'test-results/secret-notice.png'});
 await page.emulateMedia({colorScheme:'dark'});
 await toast.screenshot({path:'test-results/secret-notice-dark.png'});
});
