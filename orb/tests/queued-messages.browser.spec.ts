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

test('send next reorders, the chevron collapses, and Enter on an empty draft sends the queue',async({page})=>{
 await page.goto('/tests/queued-messages.html');
 const queue=page.getByRole('region',{name:'Queued messages'});
 await expect(queue).toContainText('to Send');
 await page.getByRole('button',{name:'Send next: et en voici un autre'}).click();
 await expect(queue.locator('.queue-text')).toHaveText(['et en voici un autre','ceci est un message dans la queue']);
 await page.getByRole('button',{name:'Hide queued messages'}).click();
 await expect(queue.locator('.queue-text')).toHaveCount(0);
 await page.getByRole('button',{name:'Show queued messages'}).click();
 await expect(queue.locator('.queue-text')).toHaveCount(2);
 await page.getByPlaceholder('Send follow-up').press('Enter');
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
