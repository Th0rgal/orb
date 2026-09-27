import {test,expect} from '@playwright/test';
test('dropping a PDF into an empty nested folder preserves bytes, refreshes @ and warns for oversized files',async({page})=>{
 const paths:string[]=[];let blob:Buffer|undefined;
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const url=new URL(route.request().url()),path=url.pathname;
  if(path.endsWith('/context/blobs')){blob=route.request().postDataBuffer()!;return route.fulfill({json:{hash:'binary-hash'}});}
  if(path.endsWith('/context/operations')){paths.push(route.request().postDataJSON().path);return route.fulfill({json:{revision:2,conflict:false}});}
  if(path.endsWith('/context/stream')||path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:'event: changed\ndata: {}\n\n'});
  if(path.endsWith('/context/manifest'))return route.fulfill({json:{revision:2,entries:Object.fromEntries([['PPL',{directory:true,size:0,revision:1,hash:null}],...paths.map(p=>[p,{directory:false,size:10,revision:2,hash:'binary-hash'}])])}});
  if(path.endsWith('/files'))return route.fulfill({json:{entries:url.searchParams.get('path')==='PPL'?paths.map(p=>({name:p.split('/').at(-1),kind:'file'})):[{name:'PPL',kind:'dir'}]}});
  return route.fulfill({json:path==='/api/projects'?{projects:[{slug:'default',title:'Default'}]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/conflicts')?{}:path==='/api/remote-nodes'?{nodes:[]}:[]});
 });
 await page.goto('/');await page.getByRole('button',{name:'Default',exact:true}).click();await page.getByRole('button',{name:'PPL',exact:true}).click();
 const empty=page.getByText('Empty folder',{exact:true});await expect(empty).toBeVisible();
 async function drop(large=false){const rect=await (large?page.locator('.row.folder[data-drop-folder="PPL"]'):empty).boundingBox();const transfer=await page.evaluateHandle(large=>{const dt=new DataTransfer();dt.items.add(new File([large?new Uint8Array(10*1024*1024+1):new Uint8Array([37,80,68,70,0,255])],large?'large.pdf':'guide.pdf',{type:'application/pdf'}));return dt;},large);await page.locator('.row.folder[data-drop-folder="PPL"]').dispatchEvent('drop',{dataTransfer:transfer,clientX:rect!.x+10,clientY:rect!.y+5});}
 await drop();await expect.poll(()=>paths).toEqual(['PPL/guide.pdf']);expect([...blob!]).toEqual([37,80,68,70,0,255]);await expect(page.getByRole('button',{name:'guide.pdf',exact:true})).toBeVisible();
 const composer=page.locator('.composer textarea').first();await composer.fill('@guide');await expect(page.getByRole('option',{name:'context/PPL/guide.pdf',exact:true})).toBeVisible();
 await drop(true);await expect(page.getByRole('alert')).toContainText('10 MiB');expect(paths).toHaveLength(1);
});
