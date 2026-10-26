import {test,expect} from '@playwright/test';
test('file picker uploads temporary session attachments and re-transfers when switching machine',async({page})=>{
 const uploads:{node_id:string;name:string;data_base64:string}[]=[];
 await page.route('**/api/**',route=>{
  const path=new URL(route.request().url()).pathname;
  if(path.endsWith('/api/uploads')){
   const body=route.request().postDataJSON();
   uploads.push(body);
   return route.fulfill({json:{name:body.name,path:`/tmp/orb-uploads/${body.node_id}/${body.name}`,size:4,sha256:'blob'}});
  }
  return route.fulfill({json:{}});
 });
 await page.goto('/tests/uploads.html');await page.getByTitle('Add context').click();
 const chooser=page.waitForEvent('filechooser');await page.getByText('Upload file or image…').click();
 await (await chooser).setFiles({name:'sample one.bin',mimeType:'application/octet-stream',buffer:Buffer.from([0,255,1,2])});
 const input=page.getByPlaceholder('Describe a task');await expect(input).toHaveValue(/@"\/tmp\/orb-uploads\/core\/sample one\.bin"/);
 expect(uploads).toHaveLength(1);expect(Buffer.from(uploads[0].data_base64,'base64')).toEqual(Buffer.from([0,255,1,2]));
 await page.getByLabel('Machine').selectOption('ashur');await page.getByTitle('Send',{exact:true}).click();
 await expect(page.getByLabel('Sent prompt')).toHaveText('@"/tmp/orb-uploads/ashur/sample one.bin"');expect(uploads).toHaveLength(2);
});
