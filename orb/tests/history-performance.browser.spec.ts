import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test.setTimeout(90000);
test('older history preserves scroll and remains accessible in WebKit',async({page},info)=>{
 const id='aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
 const mission={id,title:'History performance',backend:'claudecode',project:'demo',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 const limits:number[]=[];
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const url=new URL(route.request().url()),path=url.pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path.endsWith('/events')){
   limits.push(Number(url.searchParams.get('limit')));
   const start=url.searchParams.has('before_seq')?1:201;
   return route.fulfill({json:Array.from({length:200},(_,n)=>({id:start+n,sequence:start+n,event_id:`event-${start+n}`,event_type:n%2===0?'user_message':'assistant_message',content:`Message ${start+n}. `+'A paragraph of history. '.repeat(12),timestamp:''}))});
  }
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/control/missions')json=[mission];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:'History performance'}).click();
 const earlier=page.getByRole('button',{name:'Load earlier messages'});
 await expect(earlier).toBeAttached();await earlier.scrollIntoViewIfNeeded();
 const target=page.getByText(/^Message 201\./).first();
 await expect(target).toBeVisible();
 const before=(await target.boundingBox())!.y;
 await earlier.click();await expect(earlier).toHaveCount(0);
 await expect(page.getByText(/^Message 1\./).first()).toBeAttached();
 await page.waitForTimeout(250);
 const after=(await target.boundingBox())!.y;
 expect(Math.abs(after-before)).toBeLessThan(12);
 expect(limits.every(limit=>limit===1000)).toBe(true);
 await page.getByText(/^Message 2\./).first().scrollIntoViewIfNeeded();
 await expect(page.getByText(/^Message 2\./).first()).toBeInViewport();
 await info.attach('history-metrics.json',{body:JSON.stringify({limits,anchorShift:after-before,deferred:await page.locator('.st-deferred').count()}),contentType:'application/json'});
});
