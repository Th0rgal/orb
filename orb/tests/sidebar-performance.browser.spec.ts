import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('sidebar joins preload and click, reopens from cache, and keeps files on refresh failure',async({page},info)=>{
 const counts:Record<string,number>={};
 let failFiles=false;
 await page.route('**/api/**',async route=>{
  const url=new URL(route.request().url()), key=url.pathname.includes('missions')?'missions':url.pathname.split('/').at(-1)!;
  counts[key]=(counts[key]??0)+1;
  if(key!=='projects')await new Promise(r=>setTimeout(r,180));
  if(key==='files'&&failFiles){await route.fulfill({status:503,body:'offline'});return;}
  const json=key==='projects'?{projects:[{slug:'sample',title:'Sample'}]}:key==='missions'?Array.from({length:100},(_,i)=>({id:`m${i}`,title:`Agent ${i}`,status:'completed',tags:[],project:'sample'})):key==='files'?{entries:[{name:'notes',kind:'dir'}]}:key==='crons'?{jobs:[]}:key==='controller'?{job:null,runs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/tests/sidebar-performance.html');
 const project=page.getByRole('button',{name:'Sample',exact:true});
 await project.waitFor();
 const frame=()=>page.evaluate(async()=>{
  const button=[...document.querySelectorAll('button')].find(b=>b.textContent==='Sample')!;
  const start=performance.now();button.click();await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  return performance.now()-start;
 });
 const firstFrameMs=await frame();
 await expect(page.getByRole('button',{name:'Agent 99',exact:true})).toBeVisible();
 await page.waitForTimeout(250);
 for(const key of ['missions','files','controller','crons'])expect(counts[key]).toBe(1);
 await project.click();const warmFrameMs=await frame();
 await expect(page.getByRole('button',{name:'Agent 99',exact:true})).toBeVisible();
 await page.waitForTimeout(250);
 for(const key of ['missions','files','controller','crons'])expect(counts[key]).toBe(1);
 await info.attach('sidebar-timing.json',{body:JSON.stringify({firstFrameMs,warmFrameMs,requests:counts,apiDelayMs:180,conversations:100}),contentType:'application/json'});
 failFiles=true;
 await expect(page.getByText('Couldn’t refresh files. Showing saved list.')).toBeVisible({timeout:13000});
 await expect(page.getByRole('button',{name:'notes',exact:true})).toBeVisible();
 await project.focus();await page.keyboard.press('ArrowLeft');
 await expect(project).toHaveAttribute('aria-expanded','false');
 await page.keyboard.press('ArrowRight');await expect(project).toHaveAttribute('aria-expanded','true');
});
