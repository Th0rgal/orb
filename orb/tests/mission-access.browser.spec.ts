import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
const shots=process.env.ORB_ACCESS_SHOTS||'test-results';
test('settings section lists pending, live grants with revoke, and the audit log',async({page})=>{
 await page.goto('/tests/mission-access.html');
 const s=page.getByTestId('mission-access-settings');
 await expect(s.getByText('Read Lean eval run #42')).toBeVisible();
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
