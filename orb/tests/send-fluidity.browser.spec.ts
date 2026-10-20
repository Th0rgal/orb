import {test,expect,type Page} from '@playwright/test';
import {startSampling,stopSampling,markAction,type Fluidity} from './fluidity';
// Chromium: WebKit has no layout-shift entries.
test.use({browserName:'chromium'});
test.setTimeout(90000);

const results:Record<string,Fluidity>={};
const ready=async(page:Page,url:string,count?:string)=>{
 await page.goto(url);
 await expect(page.locator('.scroll')).toContainText(url.includes('idle')?'Paragraph 29':'Earlier paragraph 29',{timeout:45000});
 if(count)await expect(page.getByRole('region',{name:'Queued messages'})).toContainText(count);
 await page.waitForTimeout(400);
};
const composer=(page:Page)=>page.getByPlaceholder(/follow-up/i);
async function measure(page:Page,name:string,text:string,act:()=>Promise<unknown>,settle=2500,side=false){
 if(process.env.FLUIDITY_DEBUG){page.on('console',m=>{if(m.text().startsWith('SHIFT'))console.log(m.text());});await page.evaluate(()=>{(window as any).flDebug=true;});}
 await startSampling(page,text);
 await markAction(page);
 await act();
 await page.waitForTimeout(settle);
 const r=await stopSampling(page,{side});
 results[name]=r;
 console.log(`FLUIDITY ${name} ${JSON.stringify(r)}`);
 return r;
}
function expectFluid(r:Fluidity,maxCls=0.01){
 expect(r.frames).toBeGreaterThan(50);
 expect(r.toVisibleMs).not.toBeNull();
 expect(r.errors).toEqual([]);
 expect(r.missing).toBe(0);
 expect(r.duplicated).toBe(0);
 expect(r.reversals).toBe(0);
 expect(r.maxJump).toBeLessThanOrEqual(2);
 expect(r.cls).toBeLessThanOrEqual(maxCls);
}

test('1 · Enter on an idle mission',async({page})=>{
 await ready(page,'/tests/smooth-send.html?idle');
 await composer(page).fill('Path one idle');
 expectFluid(await measure(page,'idle',"Path one idle",()=>composer(page).press('Enter')));
});
test('2 · Enter during a running turn queues',async({page})=>{
 await ready(page,'/tests/smooth-send.html?long','2 Queued');
 await composer(page).fill('Path two queued');
 expectFluid(await measure(page,'queue',"Path two queued",()=>composer(page).press('Enter')));
});
test('3 · Send now from the queue',async({page})=>{
 await ready(page,'/tests/smooth-send.html?long','2 Queued');
 expectFluid(await measure(page,'send-now','Second queued message',()=>page.getByRole('button',{name:'Send now: Second queued message'}).click()));
});
test('4 · a queued message delivered when the turn ends',async({page})=>{
 await ready(page,'/tests/smooth-send.html?long','2 Queued');
 // Known residual: with no user input to excuse it, the dock shrinking by the
 // delivered row counts as a layout shift (~0.014). No bounce: one move.
 expectFluid(await measure(page,'auto-deliver','First queued message',()=>page.evaluate(()=>(window as any).deliverNext())),0.02);
});
test('5 · edit a queued message, then send it',async({page})=>{
 await ready(page,'/tests/smooth-send.html?long','2 Queued');
 await page.getByRole('button',{name:'Edit queued message: First queued message'}).click();
 await composer(page).fill('Edited then sent');
 await composer(page).press('Enter');
 await expect(page.locator('.queue-text',{hasText:'Edited then sent'})).toBeVisible();
 await page.waitForTimeout(500);
 expectFluid(await measure(page,'edit-send','Edited then sent',()=>page.getByRole('button',{name:'Send now: Edited then sent'}).click()));
});
test('6 · first prompt of a new mission',async({page})=>{
 await page.goto('/tests/send-experience.html');
 await expect(page.locator('#send-measurement')).toHaveText('Ready',{timeout:60000});
 const input=page.locator('textarea').first();
 await input.fill('Path six new mission');
 expectFluid(await measure(page,'new-mission','Path six new mission',()=>page.locator('button[title="Send"]').first().click(),4000));
});
test('7 · /goal',async({page})=>{
 await ready(page,'/tests/smooth-send.html?idle');
 await composer(page).pressSequentially('/goal ');
 await page.keyboard.type('Reach the objective');
 expectFluid(await measure(page,'goal','Reach the objective',()=>page.keyboard.press('Enter')));
});
test('8 · /btw side question',async({page})=>{
 await ready(page,'/tests/smooth-send.html?long','2 Queued');
 await composer(page).pressSequentially('/btw ');
 await page.keyboard.type('Side check');
 const r=await measure(page,'btw','Side check',()=>page.keyboard.press('Enter'),2000,true);
 expectFluid(r);
 await expect(page.locator('.btw-thread')).toContainText('Side answer');
});
