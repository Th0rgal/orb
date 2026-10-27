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
test('one list: critical rows in red at the end, "Approve N" under the normal ones signs only those',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).show('many'));
 const card=page.getByTestId('approval-queue-card');
 await expect(card.locator('.toast-title')).toContainText('5 approval requests');
 const rows=card.getByTestId('approval-queue-row');
 await expect(rows).toHaveCount(5);
 // Normal rows first, then the critical one, marked only in red.
 await expect(rows.nth(4)).toHaveClass(/approval-critical/);
 await expect(card.locator('.secret-row.approval-critical')).toHaveCount(1);
 await expect(rows.nth(4).locator('.secret-row-key')).toHaveCSS('color',/rgb\((2[0-9]{2}|1[5-9][0-9]), /);
 await expect(card.locator('input[type=checkbox]')).toHaveCount(0);
 const normal=card.getByTestId('approval-approve-normal');
 await expect(normal).toHaveText(/Approve 4/);
 // It sits right under the normal rows, above the critical one.
 const [n, lastNormal, firstCritical]=await Promise.all([normal.boundingBox(),rows.nth(3).boundingBox(),rows.nth(4).boundingBox()]);
 expect(n!.y).toBeGreaterThanOrEqual(lastNormal!.y+lastNormal!.height-1);
 expect(n!.y+n!.height).toBeLessThanOrEqual(firstCritical!.y+1);
 // A batch waits until the list has been on screen briefly.
 await expect(normal).toBeDisabled();
 await expect(normal).toBeEnabled({timeout:3000});
 for(const row of await rows.all()) expect((await row.boundingBox())!.height).toBeLessThan(48);
 await card.screenshot({path:`${shots}/desktop-approval-many.png`});
 await page.emulateMedia({colorScheme:'dark'});
 await card.screenshot({path:`${shots}/desktop-approval-many-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await normal.click();
 await expect.poll(()=>sent(page)).toContain('POST /api/approvals/approve-all');
 const b=await body(page,'/approve-all');
 expect(b.confirm_critical).toBe(false);
 expect(b.items.map((i:any)=>`${i.kind}:${i.id}`)).toEqual(['privilege:i0','secret:i2','secret:i3','mission_access:i4']);
 // Only the critical request is left: the card shows it alone, in red.
 await expect(card.locator('.toast-title strong.approval-critical')).toHaveText('Root on its own node');
});
test('the red "Approve all" at the bottom signs everything, critical first, in one batch',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).show('many'));
 const card=page.getByTestId('approval-queue-card');
 const all=card.locator('.secret-bar').getByTestId('approval-approve-all');
 await expect(all).toHaveText(/Approve all \(5, incl\. 1 critical\)/);
 await expect(all).toHaveClass(/danger/);
 await expect(all).toBeEnabled({timeout:3000});
 await expect(card.locator('.secret-bar').getByRole('button',{name:'Deny all'})).toBeVisible();
 await all.click();
 await expect.poll(()=>sent(page)).toContain('POST /api/approvals/approve-all');
 const b=await body(page,'/approve-all');
 expect(b.confirm_critical).toBe(true);
 // Most severe first: the critical root, then elevated, then routine.
 expect(b.items.map((i:any)=>`${i.kind}:${i.id}:${i.digest}`)).toEqual(['privilege:i1:d1','privilege:i0:d0','secret:i3:d3','mission_access:i4:d4','secret:i2:d2']);
 await expect(card).toHaveCount(0);
});
test('with only normal requests there is one plain "Approve all"',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>{const w=window as any;w.items.normal=w.items.many.filter((i:any)=>i.risk!=='critical');w.show('normal');});
 const card=page.getByTestId('approval-queue-card');
 await expect(card.getByTestId('approval-approve-normal')).toHaveCount(0);
 const all=card.getByTestId('approval-approve-all');
 await expect(all).toHaveText(/^\s*Approve all\s*$/);
 await expect(all).not.toHaveClass(/danger/);
});
test('rows deny through their own kind, Review opens settings',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).show('many'));
 const card=page.getByTestId('approval-queue-card');
 // Rows: deploy, secret read, secret write, mission access, then the critical root.
 await card.getByTestId('approval-queue-row').nth(3).getByRole('button',{name:'Deny'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/mission-access/i4/deny');
 await expect(card.getByTestId('approval-queue-row')).toHaveCount(4);
 await card.getByTestId('approval-queue-row').nth(1).getByRole('button',{name:'Deny'}).click();
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
test('a Core without the queue still shows a pending privilege request, approved through its own route',async({page})=>{
 await page.goto('/tests/approval-queue.html');
 await page.evaluate(()=>(window as any).loadFromLegacyCore());
 const card=page.getByTestId('approval-queue-card');
 await expect(card.locator('.toast-title strong')).toHaveText('Service deploy on agent-core');
 await expect(card.locator('.toast-sub')).toHaveText('asked by Ship usage fix');
 await expect.poll(()=>sent(page)).toContain('GET /api/approvals/queue');
 await card.locator('.secret-bar').getByRole('button',{name:'Allow'}).click();
 await expect.poll(()=>sent(page)).toContain('POST /api/privilege-access/p9/approve');
 expect(await sent(page)).not.toContain('POST /api/approvals/approve-all');
 expect(await body(page,'/p9/approve')).toEqual({ttl_minutes:240,session_scoped:true});
});
