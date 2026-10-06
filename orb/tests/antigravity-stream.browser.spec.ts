import {test,expect} from '@playwright/test';
import {eventPage} from './eventPageFixture';

test('native response remains visible through a tool-only history resync and reload',async({page})=>{
 const id='85cce150-8b72-4a5f-be57-61aea8043104';
 const bubble='antigravity:session:turn:1';
 const mission={id,title:'Gemini streaming canary',status:'active',backend:'antigravity',history:[],created_at:'',updated_at:''};
 const tool={type:'tool_call',data:{tool_call_id:'session:2',name:'bash',args:{command:'true'}}};
 const snapshot={type:'text_op',data:{bubble_id:bubble,ops:[{type:'snapshot',revision:1,text:'First visible update'}]}};
 let history:any[]=[{id:1,sequence:1,event_type:'tool_call',tool_call_id:'session:2',tool_name:'bash',content:'{}',timestamp:''}];
 let historyReads=0;
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:[snapshot,tool].map(event=>`event: ${event.type}\ndata: ${JSON.stringify(event.data)}\n\n`).join('')});
  if(path.endsWith('/events')){historyReads++;return route.fulfill(eventPage(route,history));}
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'test'}]}:path==='/api/control/missions'?[mission]:path===`/api/control/missions/${id}`?mission:path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'test',exact:true}).click();
 await page.getByRole('button',{name:/Gemini streaming canary/}).click();
 await expect(page.locator('.st-text')).toContainText('First visible update');
 await expect.poll(()=>historyReads).toBeGreaterThan(1);
 await expect(page.locator('.st-text')).toContainText('First visible update');
 history=[{id:2,sequence:2,event_type:'assistant_message_canonical',content:'First visible update',timestamp:'',event_id:bubble,metadata:{bubble_id:bubble,revision:1}},history[0]];
 await page.evaluate(()=>window.dispatchEvent(new Event('orb:refresh')));
 await expect(page.locator('.st-text')).toHaveCount(1);
 await expect(page.locator('.st-text')).toContainText('First visible update');
 await page.reload();
 await page.getByRole('button',{name:/Gemini streaming canary/}).click();
 await expect(page.locator('.st-text')).toHaveCount(1);
 await expect(page.locator('.st-text')).toContainText('First visible update');
});
