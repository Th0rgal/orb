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

test('Send now over a streaming turn: no empty queue header, no duplicated or glued text',async({page})=>{
 await page.goto('/tests/smooth-send.html?cut');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toContainText('1 Queued');
 // The live turn streams over the stored snapshot, as on prod.
 await page.evaluate(()=>{const w=window as any;w.push('text_op',{bubble_id:'text_delta_latest',ops:[{type:'insert',pos:0,text:'step 1 done'}]});w.push('text_op',{bubble_id:'text_delta_latest',ops:[{type:'replace',range:[0,11],text:w.STEPS}]});});
 await expect(page.locator('.scroll')).toContainText('step 5 done');
 await page.evaluate(()=>{
  const frames:any[]=[];(window as any).cutFrames=frames;
  const tick=()=>{
   const scroll=document.querySelector('.scroll')?.textContent??'';
   frames.push({
    counts:[...document.querySelectorAll('.queue-count')].map(n=>n.textContent),
    steps:scroll.split('step 5 done').length-1,
    glued:scroll.includes('doneYou said'),
   });
   (window as any).cutRaf=requestAnimationFrame(tick);
  };
  tick();
 });
 await page.getByRole('button',{name:'Send now: retest queued'}).click();
 await expect(page.locator('.scroll')).toContainText('You said',{timeout:10000});
 await page.waitForTimeout(300);
 const seen=await page.evaluate(()=>{cancelAnimationFrame((window as any).cutRaf);return (window as any).cutFrames as any[];});
 expect(seen.length).toBeGreaterThan(10);
 expect(seen.flatMap(f=>f.counts).filter(c=>/^0 /.test(c))).toEqual([]);
 expect(Math.max(...seen.map(f=>f.steps))).toBe(1);
 expect(seen.some(f=>f.glued)).toBe(false);
 await expect(page.locator('.followup-queue')).toHaveCount(0);
});

test('a follow-up to an idle mission does not shift the transcript once shown',async({page})=>{
 await page.goto('/tests/smooth-send.html?idle');
 await expect(page.locator('.scroll')).toContainText('Paragraph 29',{timeout:20000});
 const input=page.getByPlaceholder(/follow-up/i);
 await input.fill('Idle follow-up');
 await page.evaluate(()=>{
  const frames:any[]=[];(window as any).idleFrames=frames;
  const tick=()=>{
   const bubble=[...document.querySelectorAll('.scroll .user')].find(el=>el.textContent?.includes('Idle follow-up'));
   frames.push({t:performance.now(),top:bubble?Math.round(bubble.getBoundingClientRect().top):null,working:!!document.querySelector('.st-working')});
   (window as any).idleRaf=requestAnimationFrame(tick);
  };
  tick();
 });
 await input.press('Enter');
 await page.waitForTimeout(2500);
 const seen=await page.evaluate(()=>{cancelAnimationFrame((window as any).idleRaf);return (window as any).idleFrames as any[];});
 const shown=seen.filter(f=>f.top!=null);
 expect(shown.length).toBeGreaterThan(10);
 // Never nowhere once shown, and anchored: at most a pixel of drift.
 expect(seen.slice(seen.findIndex(f=>f.top!=null)).every(f=>f.top!=null)).toBe(true);
 // The frame the bubble mounts in may precede the pin-to-bottom scroll.
 const tops=shown.filter(f=>f.t-shown[0].t>50).map(f=>f.top);
 // The Working row stays from the send until the turn runs.
 expect(shown.every(f=>f.working)).toBe(true);
 expect(Math.max(...tops)-Math.min(...tops)).toBeLessThanOrEqual(1);
});

test('a follow-up refused with "turn still running" is queued, never an error',async({page})=>{
 await page.goto('/tests/smooth-send.html?conflict');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toContainText('2 Queued',{timeout:20000});
 const input=page.getByPlaceholder('Send follow-up');
 await input.fill('Follow-up during auto resume');
 await page.evaluate(()=>{
  const frames:any[]=[];(window as any).conflictFrames=frames;
  const tick=()=>{
   const text='Follow-up during auto resume';
   const inQueue=[...document.querySelectorAll('.followup-queue .queue-row')].some(el=>el.textContent?.includes(text));
   const inTranscript=[...document.querySelectorAll('.scroll .user')].some(el=>el.textContent?.includes(text));
   frames.push({shown:inQueue||inTranscript,error:/turn is still running|REMOTE_JOB_STILL_RUNNING/i.test(document.body.textContent??'')});
   (window as any).conflictRaf=requestAnimationFrame(tick);
  };
  tick();
 });
 await input.press('Enter');
 await expect(queue).toContainText('3 Queued',{timeout:15000});
 const seen=await page.evaluate(()=>{cancelAnimationFrame((window as any).conflictRaf);return (window as any).conflictFrames as any[];});
 const from=seen.findIndex(f=>f.shown);
 expect(from).toBeGreaterThanOrEqual(0);
 expect(seen.slice(from).every(f=>f.shown)).toBe(true);
 expect(seen.some(f=>f.error)).toBe(false);
 await expect(page.locator('.queue-text',{hasText:'Follow-up during auto resume'})).toHaveCount(1);
});
