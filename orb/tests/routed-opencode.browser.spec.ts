import {test,expect} from '@playwright/test';

test('installed OpenCode exposes routing chains and direct models in composer',async({page})=>{
 await page.addInitScript(()=>{
  localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');
  localStorage.setItem('orb.harnessPick',JSON.stringify({backend:'claudecode',model:'opus'}));
 });
 await page.route('**/api/**',route=>{
  const path=new URL(route.request().url()).pathname;
  const json=path==='/api/backends'?[{id:'claudecode',name:'Claude Code'},{id:'opencode',name:'OpenCode'}]:
   path==='/api/providers/backend-models'?{backends:{claudecode:[{value:'opus',label:'Opus'}],opencode:[{value:'openrouter/google/gemini',label:'OpenRouter — Gemini'},{value:'xai/grok-4.6',label:'xAI — Grok 4.6'}]}}:
   path==='/api/model-routing/chains'?[{id:'builtin/smart',name:'Smart (Default)',is_default:true}]:
   path==='/api/projects'?{projects:[]}:
   path==='/api/control/missions'?[]:
   path==='/api/remote-nodes'?{enabled:true,nodes:[]}:
   path.endsWith('/crons')?{jobs:[]}:{entries:[],job:null,runs:[]};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Claude Code',exact:true}).click();
 await expect(page.getByRole('option',{name:/OpenCode/})).toBeVisible();
 await page.getByRole('option',{name:/OpenCode/}).click();
 await page.getByRole('button',{name:/Smart \(Default\)/}).click();
 await expect(page.getByRole('option',{name:'Smart (Default)',exact:true})).toBeVisible();
 await expect(page.getByRole('option',{name:'Gemini',exact:true})).toBeVisible();
 await expect(page.getByRole('option',{name:'Grok 4.6',exact:true})).toBeVisible();
});

test('OpenCode dock model picker switches cleanly on active and completed remote missions, survives stale polls, and orders PATCH before follow-up send',async({page})=>{
 const missionId='11111111-2222-3333-4444-555555555555';
 let currentModel='builtin/smart';
 let currentStatus='completed';
 let currentUpdatedAt='2026-11-05T10:00:00Z';
 const callOrder:string[]=[];
 let releaseSecondPatch:(()=>void)|null=null;

 await page.addInitScript((mid)=>{
  localStorage.setItem('orb.apiUrl',location.origin);
  localStorage.setItem('orb.jwt','test');
  localStorage.setItem('orb.selectedConversation',`m:${mid}`);
 },missionId);

 await page.route('**/api/**',async route=>{
  const req=route.request();
  const url=new URL(req.url());
  const path=url.pathname;
  const method=req.method();

  if(path==='/api/backends'){
   return route.fulfill({json:[{id:'opencode',name:'OpenCode'},{id:'claudecode',name:'Claude Code'}]});
  }
  if(path==='/api/providers/backend-models'){
   return route.fulfill({json:{backends:{
    opencode:[
     {value:'builtin/smart',label:'Routing — Smart (Default)'},
     {value:'xai/grok-4.6',label:'xAI — Grok 4.6'},
     {value:'openai/gpt-6-astra',label:'OpenAI — GPT-6 Astra'},
     {value:'fail/rejected-model',label:'Test — Rejected Model'},
    ],
    claudecode:[{value:'opus',label:'Opus'}],
   }}});
  }
  if(path==='/api/model-routing/chains'){
   return route.fulfill({json:[{id:'builtin/smart',name:'Smart (Default)',is_default:true}]});
  }
  if(path==='/api/remote-nodes'){
   return route.fulfill({json:{
    enabled:true,
    nodes:[{id:'uruk',name:'uruk',base_url:'https://uruk',token_env:'T',status:'online',labels:[],version:'1',capacity_total:4,capacity_available:3,active_jobs:1,queued_jobs:0,last_seen:currentUpdatedAt,error:null,cordoned:false}],
    remote_launch:{typed:true,harnesses:['opencode','claudecode'],raw_command:true,proxy_url_configured:true},
   }});
  }
  if(path==='/api/projects'){
   return route.fulfill({json:{projects:[{slug:'orb',name:'orb'}]}});}
  if(path===`/api/control/missions/${missionId}/settings`&&method==='PATCH'){
   const body=JSON.parse(req.postData()||'{}');
   expect(body.resume).toBe(false);
   callOrder.push(`patch:${body.model_override}`);
   if(body.model_override==='fail/rejected-model'){
    return route.fulfill({status:500,json:{error:'Backend rejected model switch'}});
   }
   if(body.model_override==='openai/gpt-6-astra'){
    await new Promise<void>(resolve=>{releaseSecondPatch=resolve;});
   }
   currentModel=body.model_override;
   currentUpdatedAt='2026-11-05T10:05:00Z';
   callOrder.push(`patch-done:${body.model_override}`);
   return route.fulfill({json:{
    id:missionId,title:'Remote OpenCode on uruk',status:currentStatus,backend:'opencode',
    model_override:currentModel,remote_node_id:'uruk',project:'orb',session_id:'ses_uruk_1',
    history:[],created_at:'2026-11-05T09:50:00Z',updated_at:currentUpdatedAt,
   }});
  }
  if((path==='/api/control/message'||path===`/api/control/missions/${missionId}/message`)&&method==='POST'){
   callOrder.push(`message:${currentModel}`);
   currentStatus='active';
   return route.fulfill({json:{id:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',queued:false}});
  }
  if(path===`/api/control/missions/${missionId}`){
   return route.fulfill({json:{
    id:missionId,title:'Remote OpenCode on uruk',status:currentStatus,backend:'opencode',
    model_override:currentModel,remote_node_id:'uruk',project:'orb',session_id:'ses_uruk_1',
    history:[],created_at:'2026-11-05T09:50:00Z',updated_at:currentUpdatedAt,
   }});
  }
  if(path==='/api/control/missions'){
   // Simulate a stale sidebar poll carrying an older updated_at and old model if queried after switch
   const stale=url.searchParams.get('stale')==='1';
   return route.fulfill({json:[{
    id:missionId,title:'Remote OpenCode on uruk',status:currentStatus,backend:'opencode',
    model_override:stale?'builtin/smart':currentModel,remote_node_id:'uruk',project:'orb',session_id:'ses_uruk_1',
    history:[],created_at:'2026-11-05T09:50:00Z',updated_at:stale?'2026-11-05T10:00:00Z':currentUpdatedAt,
   }]});
  }
  if(path.endsWith('/events')){
   return route.fulfill({json:{events:[],has_more:false}});
  }
  if(path.endsWith('/stream')){
   return route.fulfill({status:200,headers:{'content-type':'text/event-stream'},body:': keepalive\n\n'});
  }
  if(path.endsWith('/crons')) return route.fulfill({json:{jobs:[]}});
  return route.fulfill({json:{entries:[],job:null,runs:[],destinations:[]}});
 });

 await page.goto('/');
 // 1. On settled remote ("completed" on uruk), Smart (Default) is an interactive button, not dead text!
 const dockBtn=page.locator('button.under-model').filter({hasText:'Smart (Default)'});
 await expect(dockBtn).toBeVisible();
 await dockBtn.click();
 await expect(page.getByRole('option',{name:'Grok 4.6',exact:true})).toBeVisible();
 await page.getByRole('option',{name:'Grok 4.6',exact:true}).click();

 const grokBtn=page.locator('button.under-model').filter({hasText:'Grok 4.6'});
 await expect(grokBtn).toBeVisible();

 // 2. Switch while active AND immediately send follow-up while PATCH is still in flight:
 currentStatus='active';
 await page.evaluate(()=>window.dispatchEvent(new Event('orb:refresh')));
 await expect(grokBtn).toBeVisible();
 await grokBtn.click();
 await page.getByRole('option',{name:'GPT-6 Astra',exact:true}).click();

 // Optimistic label updates immediately without unmounting button:
 const astraBtn=page.locator('button.under-model').filter({hasText:'GPT-6 Astra'});
 await expect(astraBtn).toBeVisible();

 // Immediately submit a follow-up before PATCH resolves:
 const composer=page.getByPlaceholder('Send follow-up');
 await composer.fill('Continue with GPT-6 Astra');
 await composer.press('Enter');

 // Wait until PATCH has arrived, then release it and verify message waited for PATCH:
 await expect.poll(()=>callOrder.includes('patch:openai/gpt-6-astra')).toBe(true);
 expect(callOrder).not.toContain('message:builtin/smart');
 expect(callOrder).not.toContain('message:xai/grok-4.6');
 releaseSecondPatch?.();

 await expect.poll(()=>callOrder).toEqual([
  'patch:xai/grok-4.6',
  'patch-done:xai/grok-4.6',
  'patch:openai/gpt-6-astra',
  'patch-done:openai/gpt-6-astra',
  'message:openai/gpt-6-astra',
 ]);
 await expect(astraBtn).toBeVisible();

 // 3. Failed optimistic PATCH cleanly rolls back to GPT-6 Astra (parent sync does not undo rollback):
 await astraBtn.click();
 await page.getByRole('option',{name:'Rejected Model',exact:true}).click();
 await expect(astraBtn).toBeVisible();
});
