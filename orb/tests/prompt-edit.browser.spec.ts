import {test,expect} from '@playwright/test';
import {eventPage} from './eventPageFixture';

test('editing grows below the text without moving a pinned conversation',async({page})=>{
 const id='e19e93c0-6942-4f16-ba04-9adfcafed915';
 const prompt='mais ça ne prend pas en compte depuis le vrai prix d’achat du coup ? Ou alors c’est parce que j’ai fait achat vente pour tax harvest?';
 const mission={id,title:'Edit stability',status:'awaiting_user',backend:'claudecode',history:[],created_at:'',updated_at:''};
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  if(path.endsWith('/events'))return route.fulfill(eventPage(route,[{id:1,sequence:1,event_type:'user_message',timestamp:'2026-10-06T08:00:00Z',content:prompt,metadata:{id:'prompt'}}]));
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'test'}]}
   :path==='/api/control/missions'?[mission]
   :path===`/api/control/missions/${id}`?mission
   :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'test',exact:true}).click();
 await page.getByRole('button',{name:/Edit stability/}).click();
 const bubble=page.locator('.user').first();
 await expect(bubble).toBeVisible();
 await bubble.evaluate(el=>{
  const scroller=el.closest('.scroll')!;
  const spacer=document.createElement('div');spacer.style.height='1200px';el.before(spacer);
  scroller.scrollTop=scroller.scrollHeight;
 });
 await page.waitForTimeout(100);
 const before=await bubble.evaluate(el=>{const r=el.getBoundingClientRect();const text=el.querySelector(':scope > span')!.getBoundingClientRect();return {top:r.top,width:r.width,bottom:r.bottom,textTop:text.top,scroll:el.closest('.scroll')!.scrollTop};});
 await bubble.dblclick();
 const editor=page.getByRole('textbox',{name:'Edit prompt text'});
 await expect(editor).toBeVisible();
 await page.waitForTimeout(100);
 const after=await bubble.evaluate(el=>{const r=el.getBoundingClientRect();return {top:r.top,width:r.width,bottom:r.bottom,textTop:el.querySelector('textarea')!.getBoundingClientRect().top,scroll:el.closest('.scroll')!.scrollTop};});
 expect(Math.abs(after.top-before.top)).toBeLessThan(2);
 // Editing adds the shared 16px content inset; the bubble and scroll anchor stay fixed.
 expect(after.textTop-after.top).toBeCloseTo(17,0);
 expect(Math.abs(after.width-before.width)).toBeLessThan(2);
 expect(Math.abs(after.scroll-before.scroll)).toBeLessThan(2);
 expect(after.bottom).toBeGreaterThan(before.bottom);
 await editor.fill(prompt+'\nAdditional line\nAnother line');
 await page.waitForTimeout(100);
 expect(Math.abs((await bubble.boundingBox())!.y-before.top)).toBeLessThan(2);
 await editor.press('Escape');
 await expect(editor).toHaveCount(0);
});
