import { test, expect } from '@playwright/test';
test('cloud menu is available at project and folder level without launching on account discovery', async ({ page }) => {
 const posts: unknown[] = [];
 await page.addInitScript(() => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt','test'); });
 await page.route('**/api/**', async route => {
  const request = route.request(), url = new URL(request.url()), path = url.pathname;
  if (request.method() === 'POST' && path === '/api/control/missions') posts.push(request.postDataJSON());
  if (path === '/api/control/stream') return route.fulfill({contentType:'text/event-stream',body:''});
  let json: unknown = {};
  if (path === '/api/projects') json = {projects:[{slug:'demo',title:'Demo'}]};
  else if (path === '/api/cloud/accounts') json = [{id:'grok',provider:'grok_bot',label:'Grok Bot',available:false,experimental:true,reason:'Protocol compatibility not validated',capabilities:{}}];
  else if (path === '/api/control/missions' || path === '/api/control/queue' || path === '/api/backends') json = [];
  else if (path.endsWith('/files')) json = {entries: url.searchParams.get('path') ? [] : [{name:'notes',kind:'dir'}]};
  else if (path.endsWith('/crons')) json = {jobs:[]};
  else if (path.includes('/controller')) json = {job:null,runs:[]};
  else if (path === '/api/providers/backend-models') json = {backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Project actions for Demo'}).click();
 await page.getByRole('menuitem',{name:'Cloud agent',exact:true}).click();
 const dialog = page.locator('main').getByRole('region',{name:'Cloud agent'});
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(page.getByRole('button',{name:'Cloud agent',exact:true})).toHaveClass(/active/);
 await expect(dialog).toBeVisible();
 await expect(page.locator('main .composer')).toHaveCount(1);
 await expect(page.getByPlaceholder('Describe a task, / for commands, @ for context')).toHaveCount(0);
 await dialog.getByLabel('Service').click();
 await page.getByRole('option',{name:'Grok Bot'}).click();
 await expect(dialog.getByLabel('Experimental connector')).toBeVisible();
 await expect(dialog.getByText('Protocol compatibility not validated')).toBeVisible();
 await expect(dialog.getByRole('button',{name:'Create cloud agent'})).toBeDisabled();
 await page.getByRole('button',{name:/New Agent/}).click();
 await expect(dialog).toHaveCount(0);
 // Expand via the visible project tree row when it is initially collapsed.
 const folder = page.getByRole('button',{name:'Folder actions for notes'});
 if (!(await folder.isVisible())) await page.getByRole('button',{name:'Demo',exact:true}).click();
 await folder.click();
 await page.getByRole('menuitem',{name:'Cloud agent',exact:true}).click();
 await expect(dialog.getByText('/ notes',{exact:true})).toBeVisible();
 await dialog.getByLabel('Service').click();
 await page.getByRole('option',{name:'Grok Bot'}).click();
 await expect(dialog.getByText('Protocol compatibility not validated')).toBeVisible();
 await page.reload();
 await expect(page.getByRole('region',{name:'Cloud agent'})).toBeVisible();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 expect(posts).toEqual([]);
 await dialog.getByLabel('Service').click();
 await page.getByRole('option',{name:'Grok Bot'}).click();
 await page.screenshot({path:'screenshots/cloud-agent-page.png',fullPage:true});
});

test('reopening Orb retains the provider identity, result and follow-up target', async ({page}) => {
 const id='aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
 const mission={id,title:'Cloud proof',backend:'cloud_cursor',project:'demo',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 const followups: any[]=[];
 let observations=0;
 await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route => {
  const request=route.request(),path=new URL(request.url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path==='/api/control/message'){followups.push(request.postDataJSON());return route.fulfill({json:{message_accepted:true,queued:true,mission_id:id}});}
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/control/missions')json=[mission];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/cloud'))json={mission_id:id,selection:{provider:'cursor_cloud',account:'cursor-default'},external_url:'https://cursor.com/agents/bc-test',turns:[{key:'first',prompt:'Prove one plus one',phase:++observations < 2 ? 'queued' : 'response_complete',external_id:'run-test',result:observations < 2 ? undefined : 'Two.',artifacts:[],branches:[]}]};
  else if(path==='/api/cloud/accounts')json=[{id:'cursor-default',provider:'cursor_cloud',label:'Cursor',available:true,capabilities:{follow_up:true,cancel:true}}];
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:'Cloud proof'}).click();
 await expect(page.getByText('Two.',{exact:true})).toBeVisible({timeout:10000});
 await expect(page.locator('.mission-lead .provider-logo > span')).toHaveCSS('width','15px');
 await expect(page.locator('.mission-lead .provider-logo > span')).toHaveCSS('mask-image', /cursor.svg/);
 await expect(page.getByRole('link',{name:'Open in Cursor Cloud'})).toHaveAttribute('href','https://cursor.com/agents/bc-test');
 await expect(page.getByRole('button',{name:'Change machine',exact:true})).toHaveCount(0);
 await page.reload();
 await expect(page.getByRole('button',{name:'Demo',exact:true})).toBeVisible();
 if (await page.getByRole('button',{name:'Demo',exact:true}).getAttribute('aria-expanded') !== 'true') await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:'Cloud proof'}).click();
 await expect(page.getByText('Two.',{exact:true})).toBeVisible({timeout:10000});
 await expect(page.locator('.mission-lead .provider-logo > span')).toHaveCSS('width','15px');
 await expect(page.locator('.mission-lead .provider-logo > span')).toHaveCSS('mask-image', /cursor.svg/);
 await page.getByPlaceholder('Continue this conversation…').fill('Explain the same result');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect.poll(()=>followups.length).toBe(1);
 expect(followups[0].mission_id).toBe(id);
 expect(followups[0].client_message_id).toMatch(/^[a-f0-9-]{36}$/);
});

test('section shortcuts and real model variants use the shared menus',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const launches:any[]=[];
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/cloud/accounts')json=[{id:'chatgpt-profile',provider:'chatgpt',label:'ChatGPT · chatgpt-profile',available:true,experimental:true,capabilities:{models:true}},{id:'cursor-default',provider:'cursor_cloud',label:'Cursor Cloud',available:true,capabilities:{models:true}}];
  else if(path==='/api/cloud/chatgpt/options')json={models:{items:[{id:'gpt-6-pro',displayName:'GPT-6 Pro'},{id:'gpt-6-high',displayName:'GPT-6 High'}]}};
  else if(path==='/api/cloud/cursor/options')json={models:{items:[{id:'grok-4.6',displayName:'Grok 4.6',parameters:[{id:'effort',values:[{value:'high',displayName:'High'}]}],variants:[{isDefault:true,params:[{id:'effort',value:'high'}]}]}]},repositories:{items:[]}};
  else if(path==='/api/control/missions' && route.request().method()==='POST'){launches.push(route.request().postDataJSON());return route.fulfill({status:503,body:'Test submission ends here'});}
  else if(path==='/api/control/missions'||path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Cloud agent',exact:true}).waitFor();
 await page.keyboard.press('Meta+2');
 const form=page.getByRole('region',{name:'Cloud agent'});
 await expect(form.getByText('Profile 1',{exact:true})).toBeVisible();
 await expect(form.getByText('GPT-6 Pro',{exact:true})).toBeVisible();
 await expect(form.getByText('Experimental',{exact:true})).toHaveCount(0);
 await form.getByLabel('Model',{exact:true}).click();
 await page.getByRole('option',{name:'GPT-6 High'}).click();
 await expect(form.getByText('GPT-6 High',{exact:true})).toBeVisible();
 await form.getByLabel('Service',{exact:true}).click();
 await page.getByRole('option',{name:'Cursor Cloud'}).click();
 await expect(form.getByText('Grok 4.6 · High',{exact:true})).toBeVisible();
 await form.getByLabel('Prompt',{exact:true}).fill('Variant test');
 await form.getByRole('button',{name:'Create cloud agent'}).click();
 await expect.poll(()=>launches.length).toBe(1);
 expect(launches[0].cloud.model).toBe('grok-4.6');
 expect(launches[0].cloud.model_params).toEqual([{id:'effort',value:'high'}]);
 await page.keyboard.press('Meta+3');await expect(page.getByRole('button',{name:'Machines',exact:true})).toHaveClass(/active/);
 await page.keyboard.press('Meta+4');await expect(page.getByRole('button',{name:'Providers',exact:true})).toHaveClass(/active/);
 await page.keyboard.press('Meta+5');await expect(page.getByRole('button',{name:'Demo',exact:true})).toBeFocused();
});

test('Hermes uses Paloma and profile default, preserves a failed draft and request identity',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const launches:any[]=[];
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/cloud/accounts')json=[{id:'paloma',provider:'hermes',label:'Paloma',available:true,capabilities:{models:true,follow_up:true,cancel:true}}];
  else if(path==='/api/cloud/hermes/options')json={models:{items:[{id:'',name:'Profile default'},{id:'configured-alias',name:'Configured model'}]}};
  else if(path==='/api/control/missions'&&route.request().method()==='POST'){launches.push(route.request().postDataJSON());return route.fulfill({status:503,body:'Hermes temporarily unavailable'});}
  else if(path==='/api/control/missions'||path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Cloud agent',exact:true}).click();
 const form=page.getByRole('region',{name:'Cloud agent'});
 await form.getByLabel('Service',{exact:true}).click();
 await page.getByRole('option',{name:'Hermes',exact:true}).click();
 await expect(form.getByLabel('Profile',{exact:true})).toContainText('Paloma');
 await expect(form.getByLabel('Model',{exact:true})).toContainText('Profile default');
 await expect(form.locator('img[src="/hermes.png"]').first()).toBeVisible();
 expect(launches).toHaveLength(0);
 await form.getByLabel('Prompt',{exact:true}).fill('Remember ORB_HERMES_LOCAL_TEST');
 await form.getByRole('button',{name:'Create cloud agent'}).click();
 await expect(form.getByRole('alert')).toContainText('Hermes temporarily unavailable');
 await expect(form.getByLabel('Prompt',{exact:true})).toHaveValue('Remember ORB_HERMES_LOCAL_TEST');
 await form.getByRole('button',{name:'Create cloud agent'}).click();
 await expect.poll(()=>launches.length).toBe(2);
 expect(launches[0]).toEqual(launches[1]);
 expect(launches[0].cloud).toEqual({provider:'hermes',account:'paloma'});
 await page.screenshot({path:'screenshots/hermes-cloud-local.png',fullPage:true});
});

test('Hermes approvals, turn-only stop and reload retain the same conversation',async({page})=>{
 const id='bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb';
 const mission={id,title:'Paloma local acceptance',backend:'cloud_hermes',project:'demo',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 let phase='waiting_user'; const actions:{path:string;body:any}[]=[];
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const request=route.request(),path=new URL(request.url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(request.method()==='POST'){
   if(path.endsWith('/opened'))return route.fulfill({json:{}});
   actions.push({path,body:request.postData()?request.postDataJSON():null});
   if(path.endsWith('/approval'))phase='running';
   if(path.endsWith('/cancel'))phase='cancelled';
   return route.fulfill({json:{message_accepted:true,queued:true,mission_id:id}});
  }
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/control/missions')json=[mission];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/cloud'))json={mission_id:id,selection:{provider:'hermes',account:'paloma',model:'configured-alias'},turns:[{key:'first',prompt:'Bounded test',phase,external_id:'run_one',result:'Marker retained.',artifacts:phase==='waiting_user'?[{kind:'hermes_approval',run_id:'run_one',request:{request_id:'request_one',command:'Bounded test action',choices:['once','deny']}}]:[],branches:[]}]};
  else if(path.endsWith('/cloud/children'))json={missions:[{id:'child',title:'Harmless delegated check',status:'active'}]};
  else if(path==='/api/cloud/accounts')json=[{id:'paloma',provider:'hermes',label:'Paloma',available:true,capabilities:{models:true,follow_up:true,cancel:true}}];
  else if(path==='/api/cloud/hermes/options')json={models:{items:[{id:'',name:'Profile default'},{id:'configured-alias',name:'Configured model'}]}};
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:mission.title}).click();
 await expect(page.getByRole('button',{name:'Harmless delegated check'})).toBeVisible();
 await expect(page.locator('.mission-lead img[src="/hermes.png"]')).toBeVisible();
 expect(actions).toHaveLength(0);
 await page.getByRole('button',{name:'Approve once'}).click();
 await expect.poll(()=>actions.length).toBe(1);
 expect(actions[0].body).toEqual({run_id:'run_one',request_id:'request_one',choice:'once'});
 await page.getByRole('button',{name:'Stop',exact:true}).click();
 await expect.poll(()=>phase).toBe('cancelled');
 expect(actions[1].path).toBe(`/api/control/missions/${id}/cloud/cancel`);
 await page.reload();
 await page.getByRole('button',{name:'Demo',exact:true}).waitFor();
 if(await page.getByRole('button',{name:'Demo',exact:true}).getAttribute('aria-expanded')!=='true')await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:mission.title}).click();
 await expect(page.getByText('Marker retained.',{exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Harmless delegated check'})).toBeVisible();
 await page.getByLabel('Model',{exact:true}).click();
 await page.getByRole('option',{name:'Profile default'}).click();
 await page.getByPlaceholder('Continue this conversation…').fill('Recall the marker');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect.poll(()=>actions.length).toBe(3);
 expect(actions[2].body.mission_id).toBe(id);
 expect(actions[2].body.cloud_model).toBe('');
});

test('Hermes cloud agent supports custom router model selection and image attachments on launch and follow-up',async({page})=>{
 const id='cccccccc-cccc-4ccc-cccc-cccccccccccc';
 const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64');
 const mission={id,title:'Inspect image',backend:'cloud_hermes',project:'demo',workspace_id:'00000000-0000-0000-0000-000000000000',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 const launches:any[]=[],followups:any[]=[];
 let uploadedCount=0;
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const request=route.request(),path=new URL(request.url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path==='/api/fs/upload'&&request.method()==='POST'){
   uploadedCount++;
   return route.fulfill({json:{path:`/var/lib/sandboxed-sh/context/image-${uploadedCount}.png`}});
  }
  if(path==='/api/fs/download')return route.fulfill({contentType:'image/png',body:png});
  if(path==='/api/control/missions'&&request.method()==='POST'){
   const body=request.postDataJSON();
   launches.push(body);
   return route.fulfill({json:mission});
  }
  if(path==='/api/control/message'&&request.method()==='POST'){
   followups.push(request.postDataJSON());
   return route.fulfill({json:{message_accepted:true,queued:true,mission_id:id}});
  }
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/cloud/accounts')json=[{id:'paloma',provider:'hermes',label:'Paloma',available:true,capabilities:{models:true,attachments:true,follow_up:true,cancel:true}}];
  else if(path==='/api/cloud/hermes/options')json={models:{items:[{id:'',name:'Profile default'},{id:'builtin/smart',name:'Smart (Default) · builtin/smart'},{id:'builtin/private',name:'Private · builtin/private'}]}};
  else if(path==='/api/control/missions')json=launches.length?[mission]:[];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/cloud'))json={mission_id:id,selection:{provider:'hermes',account:'paloma',model:'builtin/private'},turns:[{key:'first',prompt:launches[0]?.prompt ?? 'Inspect image\n\n[Image #1] [Uploaded: /var/lib/sandboxed-sh/context/image-1.png]',phase:'response_complete',external_id:'run_img',result:'Red pixel seen.',artifacts:[],branches:[]}]};
  else if(path.endsWith('/cloud/children'))json={missions:[]};
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Cloud agent',exact:true}).click();
 const form=page.getByRole('region',{name:'Cloud agent'});
 await form.getByLabel('Service',{exact:true}).click();
 await page.getByRole('option',{name:'Hermes',exact:true}).click();
 await form.getByLabel('Model',{exact:true}).click();
 await page.getByRole('option',{name:'Private · builtin/private'}).click();
 await expect(form.getByLabel('Model',{exact:true})).toContainText('Private · builtin/private');
 await form.getByLabel('Choose images').setInputFiles({name:'pixel.png',mimeType:'image/png',buffer:png});
 await expect(form.locator('.composer-image img')).toBeVisible();
 await form.getByLabel('Prompt',{exact:true}).fill('Describe this image [Image #1]');
 await form.getByRole('button',{name:'Create cloud agent'}).click();
 await expect.poll(()=>launches.length).toBe(1);
 expect(launches[0].cloud).toEqual({provider:'hermes',account:'paloma',model:'builtin/private'});
 expect(launches[0].prompt).toContain('[Uploaded: /var/lib/sandboxed-sh/context/image-1.png]');
 await expect(page.getByText('Red pixel seen.',{exact:true})).toBeVisible();
 await expect(page.locator('.message-image img')).toBeVisible();
 await page.getByLabel('Choose images').setInputFiles({name:'followup.png',mimeType:'image/png',buffer:png});
 await page.getByPlaceholder('Continue this conversation…').fill('Compare with second image [Image #1]');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect.poll(()=>followups.length).toBe(1);
 expect(followups[0].cloud_model).toBe('builtin/private');
 expect(followups[0].content).toContain('[Uploaded: /var/lib/sandboxed-sh/context/image-2.png]');
});

test('Hermes supports router catalog models, effort switching mid-mission without fork, thoughts and tool steps, arbitrary file uploads, Default crons, and Hermes settings',async({page})=>{
 const id='dddddddd-dddd-4ddd-dddd-dddddddddddd';
 const mission={id,title:'Hermes full flow',backend:'cloud_hermes',project:'default',workspace_id:'00000000-0000-0000-0000-000000000000',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 const launches:any[]=[],followups:any[]=[],settingsPuts:any[]=[],deletedCrons:string[]=[];
 let currentModel='builtin/private';
 let currentParams=[{id:'effort',value:'high'}];
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const request=route.request(),url=new URL(request.url()),path=url.pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path==='/api/uploads'&&request.method()==='POST'){
   const body=request.postDataJSON();
   const name=body?.name||'notes.txt';
   return route.fulfill({json:{name,path:`/var/lib/sandboxed-sh/uploads/${name}`,size:23,sha256:'abc123'}});
  }
  if(path==='/api/fs/upload'&&request.method()==='POST'){
   const name=url.searchParams.get('name')||'notes.txt';
   return route.fulfill({json:{path:`/var/lib/sandboxed-sh/context/${name}`}});
  }
  if(path==='/api/control/missions'&&request.method()==='POST'){
   const body=request.postDataJSON();
   launches.push(body);
   currentModel=body.cloud?.model??'';
   currentParams=body.cloud?.model_params??[];
   return route.fulfill({json:mission});
  }
  if(path==='/api/control/message'&&request.method()==='POST'){
   const body=request.postDataJSON();
   followups.push(body);
   if(body.cloud_model!==undefined)currentModel=body.cloud_model;
   if(body.cloud_model_params!==undefined)currentParams=body.cloud_model_params;
   return route.fulfill({json:{message_accepted:true,queued:true,mission_id:id}});
  }
  if(path==='/api/cloud/hermes/settings'&&request.method()==='PUT'){
   const body=request.postDataJSON();
   settingsPuts.push(body);
   return route.fulfill({json:{
    runtime:{service_name:'hermes-gateway.service',service_state:'active',gateway_state:'active',api_server_healthy:true,active_runs:0},
    sessions:{available:true,total_sessions:42,active_sessions_24h:5,total_tokens:125000},
    home_dir:'/var/lib/hermes',
    config_path:'/var/lib/hermes/config.yaml',
    soul_path:'/var/lib/hermes/SOUL.md',
    default_model:body.default_model??'builtin/smart',
    provider:'custom',
    base_url:'http://127.0.0.1:3000/v1',
    use_sandboxed_router:true,
    reasoning_effort:body.reasoning_effort??'high',
    memory_enabled:true,
    user_profile_enabled:true,
    memory_char_limit:4000,
    user_char_limit:2000,
    compression_enabled:true,
    compression_threshold:0.5,
    telegram_tool_progress:'new',
    telegram_cleanup_progress:false,
    soul_markdown:body.soul_markdown??'# Soul\nHelpful assistant.',
    models:[{id:'builtin/smart',name:'Smart (Default) · builtin/smart'},{id:'builtin/private',name:'Private · builtin/private'}],
    efforts:[{id:'',name:'Default'},{id:'high',name:'High'}]
   }});
  }
  if(path==='/api/projects/default/crons/cron_digest'&&request.method()==='DELETE'){
   deletedCrons.push('cron_digest');
   return route.fulfill({json:{deleted:true,id:'cron_digest'}});
  }
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'default',title:'Default'}]};
  else if(path==='/api/cloud/accounts')json=[{id:'paloma',provider:'hermes',label:'Paloma',available:true,capabilities:{models:true,attachments:true,follow_up:true,cancel:true}}];
  else if(path==='/api/cloud/hermes/options')json={
   models:{items:[
    {id:'',name:'Profile default'},
    {id:'builtin/smart',name:'Smart (Default) · builtin/smart'},
    {id:'builtin/private',name:'Private · builtin/private'},
    {id:'anthropic/claude-opus-4-6',name:'Claude Opus 4.6 (Anthropic) · anthropic/claude-opus-4-6'}
   ]},
   efforts:[
    {id:'',name:'Default'},
    {id:'low',name:'Low'},
    {id:'medium',name:'Medium'},
    {id:'high',name:'High'},
    {id:'xhigh',name:'Max'}
   ]
  };
  else if(path==='/api/cloud/hermes/settings')json={
   runtime:{service_name:'hermes-gateway.service',service_state:'active',gateway_state:'active',api_server_healthy:true,active_runs:0},
   sessions:{available:true,total_sessions:42,active_sessions_24h:5,total_tokens:125000},
   home_dir:'/var/lib/hermes',
   config_path:'/var/lib/hermes/config.yaml',
   soul_path:'/var/lib/hermes/SOUL.md',
   default_model:'builtin/smart',
   provider:'custom',
   base_url:'http://127.0.0.1:3000/v1',
   use_sandboxed_router:true,
   reasoning_effort:'medium',
   memory_enabled:true,
   user_profile_enabled:true,
   memory_char_limit:4000,
   user_char_limit:2000,
   compression_enabled:true,
   compression_threshold:0.5,
   telegram_tool_progress:'new',
   telegram_cleanup_progress:false,
   soul_markdown:'# Soul\nHelpful assistant.',
   models:[{id:'builtin/smart',name:'Smart (Default) · builtin/smart'},{id:'builtin/private',name:'Private · builtin/private'}],
   efforts:[{id:'',name:'Default'},{id:'medium',name:'Medium'},{id:'high',name:'High'}]
  };
  else if(path==='/api/control/missions')json=launches.length?[mission]:[];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/cloud'))json={
   mission_id:id,
   external_id:`orb_${id}`,
   selection:{provider:'hermes',account:'paloma',model:currentModel,model_params:currentParams},
   turns:[{
    key:'first',
    prompt:launches[0]?.prompt ?? 'Analyze notes.txt',
    phase:'response_complete',
    external_id:'run_full',
    result:'Summary ready.',
    steps:[
     {kind:'think',id:'think_1',text:'Inspecting the uploaded notes.txt and checking cron state.'},
     {kind:'tool',id:'tool_1',name:'terminal',input:'cat /var/lib/sandboxed-sh/uploads/notes.txt',output:'Important project notes',status:'done'}
    ],
    artifacts:[],
    branches:[]
   }]
  };
  else if(path.endsWith('/cloud/children'))json={missions:[]};
  else if(path==='/api/projects/default/crons')json={jobs:deletedCrons.length?[]:[{id:'cron_digest',name:'Daily Hermes Digest',schedule:'0 9 * * *',enabled:true,state:'scheduled',next_run_at:'2026-10-07T09:00:00Z',last_status:'ok',failure_streak:0,prompt:'Summarize daily progress'}]};
  else if(path==='/api/projects/default/crons/cron_digest')json={
   job:{id:'cron_digest',name:'Daily Hermes Digest',schedule:'0 9 * * *',enabled:true,state:'scheduled',next_run_at:'2026-10-07T09:00:00Z',last_status:'ok',failure_streak:0,prompt:'Summarize daily progress'},
   runs:[{id:'run_cron_1',at:'2026-10-06T09:00:00Z',duration_secs:14,status:'completed',silent:false,report:'Digest delivered.'}]
  };
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });

 await page.goto('/');
 // 1. Launch Hermes with Private router model, High effort, and an arbitrary text file upload
 await page.getByRole('button',{name:'Cloud agent',exact:true}).click();
 const form=page.getByRole('region',{name:'Cloud agent'});
 await form.getByLabel('Service',{exact:true}).click();
 await page.getByRole('option',{name:'Hermes',exact:true}).click();
 await form.getByLabel('Model',{exact:true}).click();
 await page.getByRole('option',{name:'Private · builtin/private'}).click();
 await form.getByLabel('Effort',{exact:true}).click();
 await page.getByRole('option',{name:'High',exact:true}).click();
 await form.getByLabel('Choose images').setInputFiles({name:'notes.txt',mimeType:'text/plain',buffer:Buffer.from('Important project notes')});
 await expect(form.getByText('notes.txt')).toBeVisible();
 await form.getByLabel('Prompt',{exact:true}).fill('Analyze this file');
 await form.getByRole('button',{name:'Create cloud agent'}).click();
 await expect.poll(()=>launches.length).toBe(1);
 expect(launches[0].cloud).toEqual({
  provider:'hermes',
  account:'paloma',
  model:'builtin/private',
  model_params:[{id:'effort',value:'high'}]
 });
 expect(launches[0].prompt).toContain('@/var/lib/sandboxed-sh/uploads/notes.txt');

 // 2. Verify thoughts + tool steps render in the transcript
 await expect(page.getByText('Summary ready.',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'1 command'}).click();
 await expect(page.getByText('Inspecting the uploaded notes.txt and checking cron state.')).toBeVisible();
 await expect(page.getByText('cat /var/lib/sandboxed-sh/uploads/notes.txt')).toBeVisible();

 // 3. Switch model to direct router catalog model and effort to Max mid-mission without forking
 await page.getByLabel('Model',{exact:true}).click();
 await page.getByRole('option',{name:'Claude Opus 4.6 (Anthropic) · anthropic/claude-opus-4-6'}).click();
 await page.getByLabel('Effort',{exact:true}).click();
 await page.getByRole('option',{name:'Max',exact:true}).click();
 await page.getByPlaceholder('Continue this conversation…').fill('Deep dive with Opus Max');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect.poll(()=>followups.length).toBe(1);
 expect(followups[0].mission_id).toBe(id);
 expect(followups[0].cloud_model).toBe('anthropic/claude-opus-4-6');
 expect(followups[0].cloud_model_params).toEqual([{id:'effort',value:'xhigh'}]);

 // 4. Verify Hermes cron under Default project in sidebar, view run history, and delete
 const defaultBtn=page.getByRole('button',{name:'Default',exact:true});
 if(await defaultBtn.getAttribute('aria-expanded')!=='true')await defaultBtn.click();
 await page.locator('button.row.agent.cron').filter({hasText:'Daily Hermes Digest'}).click();
 await expect(page.getByText('Digest delivered.')).toBeVisible();
 await page.getByRole('button',{name:'Delete',exact:true}).click();
 await expect.poll(()=>deletedCrons.length).toBe(1);
 await expect(page.locator('button.row.agent.cron').filter({hasText:'Daily Hermes Digest'})).toHaveCount(0);
 await expect(page.getByRole('dialog')).toHaveCount(0);

 // 5. Open Hermes Settings page and save updated configuration
 await page.getByRole('button',{name:'Settings',exact:true}).click();
 await page.getByRole('button',{name:'Hermes',exact:true}).click();
 await expect(page.getByText('Paloma · hermes-gateway.service')).toBeVisible();
 await page.getByRole('button',{name:'Save',exact:true}).click();
 await expect.poll(()=>settingsPuts.length).toBe(1);
 expect(settingsPuts[0].default_model).toBe('builtin/smart');
});

