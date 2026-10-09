import {test,expect} from "@playwright/test";
test.use({ browserName: process.env.ORB_TEST_BROWSER === "webkit" ? "webkit" : "chromium" });
test("pasted image stays in the draft until removed or accepted",async({page})=>{
 await page.addInitScript(() => localStorage.setItem('orb-theme','dark'));
 await page.route("**/api/**",r=>r.fulfill({json:{}}));
 await page.goto('/');
 await page.getByRole('button',{name:/^New Agent/}).click();
 const field=page.locator('.composer textarea');
 await field.fill('Inspect this picture');
 await field.evaluate(el=>{
  const transfer=new DataTransfer();
  const bytes=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII='),c=>c.charCodeAt(0));
  transfer.items.add(new File([bytes],'clipboard.png',{type:'image/png'}));
  el.dispatchEvent(new ClipboardEvent('paste',{clipboardData:transfer,bubbles:true,cancelable:true}));
 });
 await expect(page.getByAltText('Image #1', {exact:true})).toBeVisible();
 await expect(field).toHaveValue('Inspect this picture[Image #1]');
 await page.screenshot({path:'test-results/orb-image-paste.png'});
 // Rendering precedes the debounced IndexedDB write. Reload only once the
 // persisted draft contains both parts, so this exercises durable restoration.
 await expect.poll(()=>page.evaluate(async()=>{
  const database=await new Promise<IDBDatabase>((resolve,reject)=>{
   const request=indexedDB.open('orb-composer-drafts',1);
   request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
  });
  try{return await new Promise(resolve=>{
   const request=database.transaction('drafts').objectStore('drafts').get('new-agent');
   request.onsuccess=()=>resolve({text:request.result?.text,images:request.result?.images?.length});
   request.onerror=()=>resolve(null);
  });}finally{database.close();}
 })).toEqual({text:'Inspect this picture[Image #1]',images:1});
 await page.reload();
 await expect(page.getByAltText('Image #1', {exact:true})).toBeVisible();
 await expect(field).toHaveValue('Inspect this picture[Image #1]');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(page.getByAltText('Image #1', {exact:true})).toBeVisible();
 await expect(field).toHaveValue('Inspect this picture[Image #1]');
 await page.getByRole('button',{name:'Remove image',exact:true}).click();
 await expect(page.getByAltText('Image #1', {exact:true})).toHaveCount(0);
 await expect(field).toHaveValue('Inspect this picture');
});
