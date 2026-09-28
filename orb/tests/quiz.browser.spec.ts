import {test,expect} from '@playwright/test';
test('cloud quiz survives polling and submits choices to the same conversation',async({page})=>{
 const id='aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
 const mission={id,title:'Quiz de révision',backend:'cloud_chatgpt',project:'demo',status:'awaiting_user',history:[],created_at:'',updated_at:''};
 let polls=0;const sent:any[]=[];
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path==='/api/control/message'){sent.push(route.request().postDataJSON());return route.fulfill({json:{message_accepted:true}});}
  let json:unknown={};
  if(path==='/api/projects')json={projects:[{slug:'demo',title:'Demo'}]};
  else if(path==='/api/control/missions')json=[mission];
  else if(path===`/api/control/missions/${id}`)json=mission;
  else if(path.endsWith('/cloud')){polls++;json={mission_id:id,selection:{provider:'chatgpt',account:'profile'},turns:[{key:'one',prompt:'Fais-moi un quiz de test.',phase:'response_complete',result:'Oui.\n\n## Quiz de test\n\n**1. Combien font 7 × 8 ?** A) 48 B) 56 C) 64\n\n**2. Quel mot est un verbe ?** A) Rapidement B) Maison C) Apprendre\n\nRéponds pour recevoir ton score.',artifacts:[],branches:[]}]};}
  else if(path==='/api/cloud/accounts')json=[{id:'profile',provider:'chatgpt',label:'Profile 1',available:true,capabilities:{follow_up:true}}];
  else if(path.endsWith('/files'))json={entries:[]};
  else if(path.endsWith('/crons'))json={jobs:[]};
  else if(path.includes('/controller'))json={job:null,runs:[]};
  else if(path==='/api/control/queue'||path==='/api/backends')json=[];
  else if(path==='/api/providers/backend-models')json={backends:{}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Demo',exact:true}).click();
 await page.locator('button.row.agent').filter({hasText:'Quiz de révision'}).click();
 await page.getByRole('radio',{name:'B 56'}).check();
 await expect.poll(()=>polls).toBeGreaterThan(1);
 await expect(page.getByRole('radio',{name:'B 56'})).toBeChecked();
 await expect(page.getByRole('region',{name:'Quiz interactif'})).toHaveCSS('background-color','rgb(241, 240, 237)');
 const box=await page.getByRole('region',{name:'Quiz interactif'}).boundingBox();expect(box!.height).toBeLessThan(520);
 await page.screenshot({path:'screenshots/chatgpt-quiz-interactive.png',fullPage:true});
 await page.emulateMedia({colorScheme:'dark'});
 await page.screenshot({path:'screenshots/chatgpt-quiz-interactive-dark.png',fullPage:true});
 await page.getByRole('button',{name:'Suivant →'}).click();
 await page.getByRole('radio',{name:'C Apprendre'}).check();
 await page.getByRole('button',{name:'Envoyer mes réponses'}).click();
 await expect.poll(()=>sent.length).toBe(1);
 expect(sent[0].mission_id).toBe(id);
 expect(sent[0].content).toBe('Mes réponses au quiz :\n1. B) 56\n2. C) Apprendre');
 await expect(page.getByRole('button',{name:'Envoyer mes réponses'})).toBeDisabled();
});
