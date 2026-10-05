import {test,expect} from '@playwright/test';
test('cyber menu saves per mission, preserves failures, and separates requested from confirmed',async({page})=>{
 const id='fa47049a-53a1-4ad5-b003-155c6b61b167';
 const mission={id,title:'Cyber settings check',project:'test',status:'active',backend:'codex',model_override:'gpt-6.1-sol',history:[],remote_node_id:'old-agent',created_at:'',updated_at:''};
 let mode='standard';let fail=false;let patches=0;
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','fixture');localStorage.setItem('orb-theme','dark');localStorage.setItem('orb.harnessPick',JSON.stringify({backend:'codex',model:'gpt-6.1-sol'}));});
 await page.route('**/api/**',async route=>{
  const r=route.request();const u=new URL(r.url());const path=u.pathname;
  if(path==='/api/control/queue')return route.fulfill({json:[]});
  if(path.endsWith('/events'))return route.fulfill({headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false'},json:[]});
  if(path.endsWith('/cyber')){
   if(r.method()==='PATCH'){patches++;if(fail)return route.fulfill({status:403,body:'access_program_not_enabled'});mode=r.postDataJSON().mode;}
   return route.fulfill({json:{mode,status:'requested',revision:'fixture'}});
  }
  if(path.endsWith('/cyber-capabilities'))return route.fulfill({json:{version:2}});
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'Test'}]}
   :path==='/api/backends'?[{id:'codex',name:'Codex'}]
   :path==='/api/providers/backend-models'?{backends:{codex:[{value:'gpt-6.1-sol',label:'GPT-6.1 Sol'}]}}
   :path==='/api/control/missions'?[mission]
   :path===`/api/control/missions/${id}`?mission
   :path==='/api/settings'?{max_parallel_missions:4,max_concurrent_tasks:8}
   :path==='/api/remote-nodes'?{enabled:true,nodes:[],remote_launch:{typed:true,harnesses:['codex'],proxy_url_configured:true}}
   :path.endsWith('/files')?{entries:[]}
   :path.endsWith('/crons')?{jobs:[]}
   :path.endsWith('/history')?[]
   :{job:null,runs:[]};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Test',exact:true}).click();
 await page.getByRole('button',{name:/Cyber settings check/}).click();
 const picker=page.getByRole('button',{name:'Cyber program: Standard'});
 await expect(picker).toBeVisible();
 await expect(picker).toHaveAttribute('title',/next turn/);
 const effort=page.getByRole('button',{name:'Reasoning effort: Default'});
 await expect(effort).toBeVisible();
 expect(await effort.evaluate((el)=>!!(el.compareDocumentPosition(document.querySelector('.cyber-pill')!) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true);
 await picker.click();
 await expect(page.getByRole('menu',{name:'Cyber program'}).locator('small, p')).toHaveCount(0);
 await expect(page.getByRole('menu',{name:'Cyber program'})).toHaveCSS('min-width','180px');
 await page.screenshot({path:'/tmp/orb-cyber-menu.png',animations:'disabled'});
 await page.getByRole('menuitemradio',{name:/Daybreak/}).click();
 await expect(page.getByRole('button',{name:'Cyber program: Daybreak'})).toHaveAttribute('title',/requested/);
 expect(patches).toBe(1);expect(mode).toBe('daybreak');
 fail=true;await page.getByRole('button',{name:'Cyber program: Daybreak'}).click();
 await page.getByRole('menuitemradio',{name:/Standard/}).click();
 await expect(page.getByRole('alert').first()).toContainText(/not enabled|not approved/i);
 expect(mode).toBe('daybreak');
});
