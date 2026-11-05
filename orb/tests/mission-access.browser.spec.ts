import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
const shots=process.env.ORB_ACCESS_SHOTS||'test-results';
test('settings section lists pending, live grants with revoke, and the audit log',async({page})=>{
 await page.goto('/tests/mission-access.html');
 const s=page.getByTestId('mission-access-settings');
 await expect(s.getByText('Read Lean eval run #42')).toBeVisible();
 // Long mission titles truncate inside the request body instead of bleeding under the lifetime select or buttons.
 const longRow=s.locator('.bw-request-row').nth(1);
 const [bodyBox,keyBox,metaBox,selectBox,denyBox,allowBox]=await Promise.all([
  longRow.locator('.bw-request-body').boundingBox(),
  longRow.locator('.secret-row-key').boundingBox(),
  longRow.locator('.bw-request-meta').boundingBox(),
  longRow.locator('.orb-select').boundingBox(),
  longRow.getByRole('button',{name:'Deny'}).boundingBox(),
  longRow.getByRole('button',{name:'Allow control'}).boundingBox(),
 ]);
 expect(keyBox!.width).toBeGreaterThan(80);
 expect(metaBox!.width).toBeGreaterThan(40);
 expect(keyBox!.x+keyBox!.width).toBeLessThanOrEqual(metaBox!.x+1);
 expect(metaBox!.x+metaBox!.width).toBeLessThanOrEqual(bodyBox!.x+bodyBox!.width+1);
 expect(bodyBox!.x+bodyBox!.width).toBeLessThanOrEqual(selectBox!.x+1);
 expect(selectBox!.x+selectBox!.width).toBeLessThanOrEqual(denyBox!.x+1);
 expect(denyBox!.x+denyBox!.width).toBeLessThanOrEqual(allowBox!.x+1);
 const g=s.getByTestId('mission-access-grant');
 await expect(g).toHaveCount(1);
 await expect(g).toContainText('Supervisor → DGX Spark setup');
 await expect(g).toContainText(/Read only · 2[23] h/);
 await s.getByRole('button',{name:/Show activity/}).click();
 await expect(s.locator('.bw-log-status.read')).toHaveCount(1);
 await expect(s.locator('.bw-log-status.denied')).toHaveCount(1);
 await s.screenshot({path:`${shots}/desktop-access-settings.png`});
 await g.getByRole('button',{name:'Revoke'}).click();
 await expect.poll(()=>page.evaluate(()=>(window as any).calls.map((c:any)=>`${c.method} ${new URL(c.url).pathname}`))).toContain('DELETE /api/mission-access/g1');
});
