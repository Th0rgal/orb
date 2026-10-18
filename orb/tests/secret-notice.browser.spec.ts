import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('secret requests share one card: D for one, rows for several',async({page})=>{
 await page.goto('/tests/secret-notice.html');
 const card=page.locator('.secret-card');
 await expect(card.locator('.toast-title strong')).toHaveText('SPARK_ROUTER_API_KEY');
 await expect(card.locator('.toast-sub')).toHaveText('DGX Spark');
 await expect(card.locator('.secret-rows')).toHaveCount(0);
 const bar=card.locator('.secret-bar');
 await expect(bar.getByRole('button',{name:'Store'})).toBeVisible();
 await expect(bar.getByRole('button',{name:'Deny'})).toBeVisible();
 await expect(bar.locator('.secret-grace')).toHaveText('Touch ID required');
 await card.screenshot({path:'test-results/secret-card-one.png'});

 await page.evaluate(()=>(window as any).showMany());
 await expect(card.locator('.toast-title')).toContainText('3 secret requests');
 await expect(card.locator('.secret-row')).toHaveCount(3);
 await expect(card.locator('.secret-kind[aria-label="Write"]')).toHaveCount(1);
 await expect(card.locator('.secret-kind[aria-label="Read"]')).toHaveCount(2);
 // A batch approve waits until the list has been on screen briefly.
 await expect(bar.getByRole('button',{name:'Approve all'})).toBeDisabled();
 await expect(bar.getByRole('button',{name:'Approve all'})).toBeEnabled({timeout:3000});
 await expect(bar.getByRole('button',{name:'Deny all'})).toBeVisible();
 // The action bar and every row stay on one line.
 const lineBox=(await bar.boundingBox())!;
 expect(lineBox.height).toBeLessThan(40);
 for(const row of await card.locator('.secret-row').all()) expect((await row.boundingBox())!.height).toBeLessThan(48);
 await card.screenshot({path:'test-results/secret-card-many.png'});
 await page.emulateMedia({colorScheme:'dark'});
 await card.screenshot({path:'test-results/secret-card-many-dark.png'});

 await bar.getByRole('button',{name:'Review'}).click();
 expect(await page.evaluate(()=>(window as any).opened)).toBe(true);
 await expect(card).toHaveCount(0);
});
