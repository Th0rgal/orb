import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
// The fixture loads the full composer and its lazy application modules.
test.setTimeout(90000);
test('queue matches the composer width and accepts and removes messages',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toBeVisible();await expect(queue).toContainText('2 Queued');
 const input=page.getByPlaceholder('Send follow-up');await input.fill('un troisième message');await input.press('Enter');
 await expect(queue).toContainText('3 Queued');await expect(input).toHaveValue('');
 await page.getByRole('button',{name:'Remove queued message: un troisième message'}).focus();await page.getByRole('button',{name:'Remove queued message: un troisième message'}).click();
 await expect(queue).toContainText('2 Queued');
 const panel=await queue.boundingBox(),composer=await page.locator('.composer').boundingBox();
 expect(panel!.width).toBe(composer!.width);expect(panel!.x).toBe(composer!.x);expect(composer!.y-panel!.y-panel!.height).toBe(8);
 await page.setViewportSize({width:390,height:844});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
});

test('editing keeps the message in place, marks it, and restores the draft afterwards',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await input.fill('draft in progress');
 const edit=page.getByRole('button',{name:'Edit queued message: et en voici un autre',exact:true});
 await edit.focus();await edit.click();
 await expect(queue).toContainText('2 Queued');await expect(queue).toContainText('Editing');
 await expect(page.getByText('Edit Queued')).toBeVisible();
 await expect(input).toHaveValue('et en voici un autre');
 await input.fill('message corrigé');await input.press('Enter');
 await expect(queue).not.toContainText('Editing');await expect(page.getByText('Edit Queued')).toHaveCount(0);
 await expect(queue.locator('.queue-text')).toHaveText(['ceci est un message dans la queue','message corrigé']);
 await expect(input).toHaveValue('draft in progress');
 const stored=await page.evaluate(async()=>{
  const db=await new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('orb-composer-drafts',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
  return await new Promise<unknown[]>((resolve,reject)=>{const r=db.transaction('drafts').objectStore('drafts').getAll();r.onsuccess=()=>{resolve(r.result);db.close();};r.onerror=()=>reject(r.error);});
 });
 expect(JSON.stringify(stored)).not.toContain('et en voici un autre');
});

test('successive edits keep restoring the real draft',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const input=page.getByPlaceholder('Send follow-up');
 await input.fill('my own draft');
 await page.getByRole('button',{name:'Edit queued message: ceci est un message dans la queue',exact:true}).click();
 await input.fill('premier corrigé');await input.press('Enter');
 await expect(input).toHaveValue('my own draft');
 await page.getByRole('button',{name:'Edit queued message: et en voici un autre',exact:true}).click();
 await expect(input).toHaveValue('et en voici un autre');
 await page.getByRole('button',{name:'Stop editing the queued message'}).click();
 await expect(input).toHaveValue('my own draft');
});

test('cancelling an edit leaves the queue untouched',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await page.getByRole('button',{name:'Edit queued message: ceci est un message dans la queue',exact:true}).click();
 await expect(input).toHaveValue('ceci est un message dans la queue');
 await page.getByRole('button',{name:'Stop editing the queued message'}).click();
 await expect(input).toHaveValue('');await expect(queue).not.toContainText('Editing');
 await expect(queue.locator('.queue-text')).toHaveText(['ceci est un message dans la queue','et en voici un autre']);
});

test('ArrowRight edits the first queued message, Escape cancels, the chevron collapses, and Enter on an empty draft sends the queue',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'}),input=page.getByPlaceholder('Send follow-up');
 await expect(queue).toContainText('to Send');
 const editBtn=page.getByRole('button',{name:'Edit queued message: ceci est un message dans la queue'});
 const sendNowBtn=page.getByRole('button',{name:'Send now: ceci est un message dans la queue'});
 await expect(sendNowBtn).toBeVisible();
 await expect(page.getByRole('button',{name:'Send now: et en voici un autre'})).toBeVisible();
 await editBtn.hover();
 await page.waitForTimeout(150);
 await page.locator('main').screenshot({path:'test-results/orb-queue-hover-edit.png'});
 await sendNowBtn.hover();
 await page.waitForTimeout(150);
 await page.locator('main').screenshot({path:'test-results/orb-queue-hover-send-now.png'});
 await input.focus();
 await input.press('ArrowRight');
 await expect(input).toHaveValue('ceci est un message dans la queue');
 await expect(queue).toContainText('Editing');
 await page.locator('main').screenshot({path:'test-results/orb-queue-editing.png'});
 await input.press('Escape');
 await expect(input).toHaveValue('');
 await expect(queue).not.toContainText('Editing');
 await page.getByRole('button',{name:'Hide queued messages'}).click();
 await expect(queue.locator('.queue-text')).toHaveCount(0);
 await page.getByRole('button',{name:'Show queued messages'}).click();
 await expect(queue.locator('.queue-text')).toHaveCount(2);
 await input.press('Enter');
 expect(await page.evaluate(()=>(window as unknown as {queueSent?:number}).queueSent)).toBe(1);
});

test('long queued prompts stay on one line with the full text available',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const text='A long repository review request. '.repeat(100);
 const input=page.getByPlaceholder('Send follow-up');await input.fill(text);await input.press('Enter');
 const row=page.locator('.queue-text').last();
 await expect(row).toHaveAttribute('title',text.trim());
 expect((await row.boundingBox())!.height).toBeLessThanOrEqual(24);
 await expect(page.getByRole('region',{name:'Queued messages'})).toContainText('3 Queued');
});

test('rapidly stacking multiple messages and deleting from the queue gives instantaneous (<16ms) visual feedback',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toContainText('2 Queued');
 const sendMetrics=await page.evaluate(()=>{
  const ta=document.querySelector('textarea')!;
  const sendLatencies:number[]=[];
  for(const msg of ['rapid stack 1','rapid stack 2','rapid stack 3']){
   const t0=performance.now();
   ta.value=msg;
   ta.dispatchEvent(new InputEvent('input',{bubbles:true,data:msg}));
   ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
   const texts=Array.from(document.querySelectorAll('.queue-text')).map(el=>el.textContent);
   const t1=performance.now();
   if(!texts.includes(msg))throw new Error(`Message ${msg} not immediately visible in queue: ${JSON.stringify(texts)}`);
   if(ta.value!=='')throw new Error(`Textarea did not clear immediately after ${msg}`);
   if(ta.readOnly)throw new Error(`Textarea became readOnly and blocked rapid stacking after ${msg}`);
   sendLatencies.push(t1-t0);
  }
  return {sendLatencies};
 });
 for(const ms of sendMetrics.sendLatencies)expect(ms).toBeLessThan(16);
 // Finish the fixture's pending-to-durable handoff before measuring durable
 // deletion; otherwise its still-pending duplicate can briefly reappear.
 await page.evaluate(async()=>await (window as any).queueSettled());
 await expect(page.locator('button[aria-label="Remove queued message: rapid stack 2"]')).toBeAttached();
 const deleteMetrics=await page.evaluate(()=>{
  const delBtn=document.querySelector('button[aria-label="Remove queued message: rapid stack 2"]') as HTMLButtonElement|null;
  if(!delBtn)throw new Error('Delete button for rapid stack 2 not found');
  const d0=performance.now();
  delBtn.click();
  const afterTexts=Array.from(document.querySelectorAll('.queue-text')).map(el=>el.textContent);
  const d1=performance.now();
  if(afterTexts.includes('rapid stack 2'))throw new Error(`Deleted message still visible synchronously: ${JSON.stringify(afterTexts)}`);
  return {deleteLatency:d1-d0,afterTexts};
 });
 expect(deleteMetrics.deleteLatency).toBeLessThan(16);
 expect(deleteMetrics.afterTexts).toEqual([
  'ceci est un message dans la queue',
  'et en voici un autre',
  'rapid stack 1',
  'rapid stack 3',
 ]);
 await expect(queue).toContainText('4 Queued');
});

