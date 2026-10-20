import {test,expect} from '@playwright/test';
// Prod mission c7592dff → 0db534df: a follow-up to a remote pr-writer whose
// session cannot resume. Orb creates a replacement and Core archives the
// original as superseded; both are titled "Verity". The sidebar must never
// list the conversation twice, in any frame.
test('a replacement send never shows the conversation twice in the sidebar',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');localStorage.setItem('orb.machine','core');});
 const old={id:'c7592dff-6b9c-491d-b546-07466b26930e',title:'Verity',backend:'antigravity',status:'interrupted',project:'verity-core',track:'solidity-import-coordinator',tags:['pr-writer'],remote_node_id:'babylon',remote_job:{job_id:'j1',node_id:'babylon',phase:'finished',node_state:'cancelled',finished_at:'2026-10-20T12:00:00Z'},history:[],created_at:'2026-10-20T10:00:00Z',updated_at:'2026-10-20T12:00:00Z'};
 const next={...old,id:'0db534df-6e9f-42d8-95e1-791ca6a6173b',status:'active',remote_job:{job_id:'j2',node_id:'babylon',phase:'running',node_state:'running'},created_at:'2026-10-20T12:43:36Z',updated_at:'2026-10-20T12:43:41Z'};
 let missions:any[]=[old];
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),path=url.pathname,method=req.method();
  if(path==='/api/control/message'&&method==='POST')return route.fulfill({status:409,body:`REMOTE_RESUME_REQUIRES_REPLACEMENT: mission ${old.id} has no resumable session on babylon`});
  if(path==='/api/control/missions'&&method==='POST'){
   // Core: create the replacement and archive the original. The list read
   // that the sidebar has in flight still sees the original.
   missions=[next,{...old,status:'acknowledged',tags:['pr-writer','superseded',`superseded_by:${next.id}`]}];
   return route.fulfill({json:next});
  }
  if(path==='/api/control/missions'){await new Promise(r=>setTimeout(r,200));return route.fulfill({json:missions.filter(m=>m.status!=='acknowledged')});}
  const one=path.match(/^\/api\/control\/missions\/([^/]+)$/);
  if(one)return route.fulfill({json:missions.find(m=>m.id===one[1])??old});
  if(path.endsWith('/events'))return route.fulfill({json:[],headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
  if(path==='/api/control/stream')return route.fulfill({status:200,headers:{'Content-Type':'text/event-stream'},body:''});
  if(path==='/api/projects')return route.fulfill({json:{projects:[{slug:'verity-core',title:'Verity Core'}]}});
  if(path==='/api/remote-nodes')return route.fulfill({json:{enabled:true,nodes:[{id:'babylon',name:'Babylon'}]}});
  if(path.endsWith('/files'))return route.fulfill({json:{entries:[]}});
  if(path.endsWith('/conflicts'))return route.fulfill({json:{}});
  return route.fulfill({json:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[]});
 });
 await page.goto('/');
 const project=page.getByRole('button',{name:'Verity Core',exact:true});
 await expect(project).toBeVisible({timeout:20000});
 await page.waitForTimeout(500);
 if(await project.getAttribute('aria-expanded')!=='true')await project.click();
 const row=page.locator('.row-label').filter({hasText:/^Verity$/});
 await expect(row).toHaveCount(1,{timeout:20000});
 await row.click();
 const input=page.getByPlaceholder(/follow-up/i);
 await expect(input).toBeVisible({timeout:20000});
 await input.fill('Continue the import');
 await page.evaluate(()=>{
  const w=window as any;w.sideFrames=[];
  const tick=()=>{
   const labels=[...document.querySelectorAll('.row-label')].filter(el=>el.getBoundingClientRect().height>0).map(el=>el.textContent?.trim());
   w.sideFrames.push(labels.filter(l=>l==='Verity').length);
   w.sideRaf=requestAnimationFrame(tick);
  };
  tick();
 });
 await input.press('Enter');
 await page.waitForTimeout(2500);
 const seen:number[]=await page.evaluate(()=>{const w=window as any;cancelAnimationFrame(w.sideRaf);return w.sideFrames;});
 expect(seen.length).toBeGreaterThan(50);
 expect(Math.max(...seen)).toBe(1);
 expect(seen.at(-1)).toBe(1);
});
