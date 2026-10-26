import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
const shots=process.env.ORB_ACCESS_SHOTS||'test-results';
const sent=(page:any)=>page.evaluate(()=>(window as any).calls.map((c:any)=>`${c.method} ${new URL(c.url).pathname}`));
const body=async(page:any,path:string)=>JSON.parse(await page.evaluate((p:string)=>(window as any).calls.filter((c:any)=>c.url.includes(p)).pop().body,path));
test('one request: title, who, why, what it unlocks, Allow signs one item',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 const card=page.getByTestId('approval-queue-card');
 await expect(card.locator('.toast-title strong')).toHaveText('Service deploy on agent-core');
 await expect(card.locator('.toast-sub')).toHaveText('asked by Ship usage fix');
 await expect(card.locator('.toast-message')).toContainText('usage-limit fix');
 await expect(card.locator('.access-scope')).toHaveText('Allows restart and deploy services, including production · for this session (max 4 h)');
 await card.screenshot({path:`${shots}/desktop-approval-one.png`});
 await card.locator('.secret-bar').getByRole('button',{name:'Allow'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/approvals/approve-all');
 expect(await body(page,'/approve-all')).toEqual({items:[{kind:'privilege',id:'i0',digest:'d0'}],confirm_critical:false});
 await expect(card).toHaveCount(0);
});
test('every kind in one card: risk summary, critical left out until ticked, one signed batch',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).show('many'));
 const card=page.getByTestId('approval-queue-card');
 await expect(card.locator('.toast-title')).toContainText('5 approval requests');
 await expect(card.getByTestId('approval-queue-row')).toHaveCount(5);
 await expect(card.locator('.secret-row.approval-critical')).toHaveCount(1);
 const sum=card.getByTestId('approval-queue-summary');
 await expect(sum).toContainText('1 critical · 3 elevated · 1 routine');
 await expect(sum).toContainText('for Fleet health, Mission 9a8b7c6d, Ship usage fix');
 const bar=card.locator('.secret-bar');
 // A batch waits until the list has been on screen briefly.
 await expect(bar.getByRole('button',{name:'Approve 4'})).toBeDisabled();
 await expect(bar.getByRole('button',{name:'Approve 4'})).toBeEnabled({timeout:3000});
 for(const row of await card.locator('.secret-row').all()) expect((await row.boundingBox())!.height).toBeLessThan(48);
 await card.screenshot({path:`${shots}/desktop-approval-many.png`});
 await page.emulateMedia({colorScheme:'dark'});
 await card.screenshot({path:`${shots}/desktop-approval-many-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await sum.getByRole('checkbox').check();
 await bar.getByRole('button',{name:'Approve all'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/approvals/approve-all');
 const b=await body(page,'/approve-all');
 expect(b.confirm_critical).toBe(true);
 expect(b.items.map((i:any)=>`${i.kind}:${i.id}:${i.digest}`)).toEqual(['privilege:i0:d0','privilege:i1:d1','secret:i2:d2','secret:i3:d3','mission_access:i4:d4']);
 await expect(card).toHaveCount(0);
});
test('rows deny through their own kind, Review opens settings',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).show('many'));
 const card=page.getByTestId('approval-queue-card');
 await card.getByTestId('approval-queue-row').nth(4).getByRole('button',{name:'Deny'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/mission-access/i4/deny');
 await expect(card.getByTestId('approval-queue-row')).toHaveCount(4);
 await card.getByTestId('approval-queue-row').nth(2).getByRole('button',{name:'Deny'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/bitwarden/requests/i2/reject');
 await card.locator('.secret-bar').getByRole('button',{name:'Review'}).click();
 expect(await page.evaluate(()=>(window as any).opened)).toBe(true);
 await expect(card).toHaveCount(0);
});
test('the card is centred on the conversation composer and as wide',async({page})=>{
 for(const width of [1400,900]){
  await page.setViewportSize({width,height:900});
  await page.goto('/tests/approval-queue.html');
  await page.evaluate(()=>{(window as any).addDock();(window as any).show('many');});
  const card=page.getByTestId('approval-queue-card');
  await expect(card).toBeVisible();
  await expect.poll(async()=>{
   const c=await page.locator('.toast').filter({has:card}).boundingBox();const k=await page.locator('.dock .composer').boundingBox();
   return Math.abs((c!.x+c!.width/2)-(k!.x+k!.width/2))<=1&&Math.abs(c!.width-k!.width)<=1;
  }).toBe(true);
 }
});
