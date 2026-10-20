import {test,expect,type Page} from '@playwright/test';
test.use({browserName:'webkit'});
test.setTimeout(90000);

/** Samples, every animation frame, where a message is and what the turn shows. */
async function record(page:Page,text:string){
 await page.evaluate(text=>{
  const frames:any[]=[];(window as any).frames_=frames;
  const tick=()=>{
   const row=[...document.querySelectorAll('.followup-queue .queue-row')].find(el=>el.textContent?.includes(text));
   const bubble=[...document.querySelectorAll('.scroll .user')].find(el=>el.textContent?.includes(text));
   frames.push({
    queued:!!row&&!row.classList.contains('leaving'),
    leaving:!!row?.classList.contains('leaving'),
    transcript:!!bubble,
    sending:!!bubble?.classList.contains('sending'),
    stop:!!document.querySelector('.send.stop'),
    failure:document.body.textContent?.includes('Mission interrupted')??false,
    working:document.querySelector('.st-working .agent-wait-status')?.textContent??'',
   });
   (window as any).raf_=requestAnimationFrame(tick);
  };
  tick();
 },text);
}
const frames=(page:Page)=>page.evaluate(()=>{cancelAnimationFrame((window as any).raf_);return (window as any).frames_ as any[];});

test('Send now is one continuous Sending → Working state, with the message never nowhere',async({page})=>{
 await page.goto('/tests/smooth-send.html');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toContainText('2 Queued');
 await expect(page.locator('.send.stop')).toBeVisible();
 await record(page,'Second queued message');
 await page.getByRole('button',{name:'Send now: Second queued message'}).click();
 await expect(page.locator('.st-working .agent-wait-status')).toHaveText(/^Working on /,{timeout:10000});
 await page.waitForTimeout(200);
 const seen=await frames(page);
 // Atomic: from the click on, every frame shows the message in the queue or the transcript.
 const from=seen.findIndex(f=>!f.queued);
 expect(seen.slice(from).every(f=>f.transcript)).toBe(true);
 expect(seen.some(f=>f.leaving&&f.transcript)).toBe(true);
 // Continuous: Stop stays, no interruption notice, "Sending…" then "Working…".
 expect(seen.every(f=>f.stop)).toBe(true);
 expect(seen.some(f=>f.failure)).toBe(false);
 const labels=seen.map(f=>f.working.replace(/ on .*/,'')).filter((l,i,all)=>l&&l!==all[i-1]);
 expect(labels.slice(labels.indexOf('Sending'))).toEqual(['Sending','Working']);
 expect(seen.some(f=>f.sending)).toBe(true);
 expect(seen.at(-1)!.sending).toBe(false);
 await expect(queue).toContainText('1 Queued');
 await expect(page.locator('.scroll .user',{hasText:'Second queued message'})).toHaveCount(1);
});

test('editing a queued message keeps its place and count and clears the chip at once',async({page})=>{
 await page.goto('/tests/smooth-send.html');
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await expect(queue).toContainText('2 Queued');
 await page.getByRole('button',{name:'Edit queued message: First queued message'}).click();
 await expect(page.getByText('Edit Queued')).toBeVisible();
 await input.fill('First message, corrected');
 const height=(await queue.boundingBox())!.height;
 await input.press('Enter');
 // Optimistic, before Core answers (250 ms): chip gone, text replaced in place.
 await expect(page.getByText('Edit Queued')).toHaveCount(0,{timeout:150});
 await expect(queue.locator('.queue-text')).toHaveText(['First message, corrected','Second queued message'],{timeout:150});
 await expect(queue).toContainText('2 Queued');
 expect((await queue.boundingBox())!.height).toBe(height);
 await page.waitForTimeout(400);
 await expect(queue.locator('.queue-text')).toHaveText(['First message, corrected','Second queued message']);
 expect(await page.evaluate(()=>(window as any).core.rows.map((r:any)=>r.id))).toEqual(['q1','q2']);
});

test('a refused edit reverts with a toast',async({page})=>{
 await page.goto('/tests/smooth-send.html');
 await page.evaluate(()=>{(window as any).core.refuseEdit=true;});
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await page.getByRole('button',{name:'Edit queued message: First queued message'}).click();
 await input.fill('Too late');await input.press('Enter');
 await expect(queue.locator('.queue-text').first()).toHaveText('Too late');
 await expect(page.getByRole('alert')).toContainText('already sent');
 await expect(queue.locator('.queue-text')).toHaveText(['First queued message','Second queued message']);
});

test('a queued row keeps its size from sending to confirmed',async({page})=>{
 await page.goto('/tests/smooth-send.html');
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await expect(queue).toContainText('2 Queued');
 await page.evaluate(()=>{
  const sizes:any[]=[];(window as any).sizes_=sizes;
  const tick=()=>{const row=[...document.querySelectorAll('.queue-row')].find(el=>el.textContent?.includes('Third one'));const box=row?.getBoundingClientRect();const panel=document.querySelector('.followup-queue')!.getBoundingClientRect();if(box)sizes.push({h:box.height,w:box.width,panel:panel.height,sending:row!.classList.contains('sending')});(window as any).raf_=requestAnimationFrame(tick);};
  tick();
 });
 await input.fill('Third one');await input.press('Enter');
 await expect(queue).toContainText('3 Queued');
 await expect(queue.locator('.queue-row.sending')).toHaveCount(0,{timeout:5000});
 await page.waitForTimeout(200);
 const sizes=await page.evaluate(()=>{cancelAnimationFrame((window as any).raf_);return (window as any).sizes_ as any[];});
 expect(sizes.some(s=>s.sending)&&sizes.some(s=>!s.sending)).toBe(true);
 expect(new Set(sizes.map(s=>s.h)).size).toBe(1);
 expect(new Set(sizes.map(s=>s.panel)).size).toBe(1);
});

test('reduced motion: the sent row leaves without animating',async({page})=>{
 await page.emulateMedia({reducedMotion:'reduce'});
 await page.goto('/tests/smooth-send.html');
 await expect(page.getByRole('region',{name:'Queued messages'})).toContainText('2 Queued');
 await page.getByRole('button',{name:'Send now: First queued message'}).click();
 await expect(page.locator('.queue-row.leaving')).toBeHidden();
 const animation=await page.locator('.scroll .user',{hasText:'First queued message'}).evaluate(el=>getComputedStyle(el).animationName);
 expect(animation).toBe('none');
});
