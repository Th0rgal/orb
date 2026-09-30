import {test,expect} from '@playwright/test';
test('file picker preserves binary bytes in shared context across machine changes',async({page})=>{
 const uploads:Buffer[]=[],operations:any[]=[];
 await page.route('**/api/**',route=>{
  const path=new URL(route.request().url()).pathname;
  if(path.endsWith('/context/blobs')){uploads.push(route.request().postDataBuffer()!);return route.fulfill({json:{hash:'blob'}});}
  if(path.endsWith('/context/operations')){operations.push(route.request().postDataJSON());return route.fulfill({json:{revision:1,conflict:false}});}
  return route.fulfill({json:{}});
 });
 await page.goto('/tests/uploads.html');await page.getByTitle('Add context').click();
 const chooser=page.waitForEvent('filechooser');await page.getByText('Upload file or image…').click();
 await (await chooser).setFiles({name:'sample one.bin',mimeType:'application/octet-stream',buffer:Buffer.from([0,255,1,2])});
 const input=page.getByPlaceholder('Describe a task');await expect(input).toHaveValue(/attachments\/.*\/sample one.bin/);
 const reference=(await input.inputValue()).trim();expect(uploads).toEqual([Buffer.from([0,255,1,2])]);expect(operations).toHaveLength(1);
 await page.getByLabel('Machine').selectOption('ashur');await page.getByTitle('Send',{exact:true}).click();
 await expect(page.getByLabel('Sent prompt')).toHaveText(reference);expect(uploads).toHaveLength(1);
});
