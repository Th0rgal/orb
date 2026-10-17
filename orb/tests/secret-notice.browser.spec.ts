import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('secret request notice: the fingerprint approves, Deny and Review are links',async({page})=>{
 await page.goto('/tests/secret-notice.html');
 const read=page.locator('.toast.secret').filter({hasText:'VERCEL_TOKEN'});
 await expect(read.locator('.toast-title strong')).toHaveText('VERCEL_TOKEN');
 await expect(read.locator('.toast-sub')).toHaveAttribute('title',/autoresearch/);
 const allow=read.getByRole('button',{name:'Allow'});
 await expect(allow.locator('svg')).toBeVisible();
 // The fingerprint button spans the notice's height on the left.
 const box=(await allow.boundingBox())!, toastBox=(await read.boundingBox())!;
 expect(box.x-toastBox.x).toBeLessThan(12);
 expect(box.height).toBeGreaterThan(toastBox.height-20);
 await expect(read.locator('.toast-link')).toHaveText(['Deny','Review in Secrets']);
 await expect(read.locator('.toast-btn')).toHaveCount(0);
 const lineHeight=await read.locator('.toast-message').evaluate(e=>parseFloat(getComputedStyle(e).lineHeight));
 expect((await read.locator('.toast-message').boundingBox())!.height).toBeLessThanOrEqual(lineHeight*2+1);
 // Writes are approvable from the notice too.
 const write=page.locator('.toast.secret').filter({hasText:'SPARK_ROUTER_API_KEY'});
 await expect(write.getByRole('button',{name:'Store'})).toBeVisible();
 await read.screenshot({path:'test-results/secret-notice.png'});
 await write.screenshot({path:'test-results/secret-notice-write.png'});
 await page.emulateMedia({colorScheme:'dark'});
 await write.screenshot({path:'test-results/secret-notice-dark.png'});
});
