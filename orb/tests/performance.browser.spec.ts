import {test,expect,type Page} from '@playwright/test';
// Scroll the transcript one viewport at a time, waiting for each scroll event
// and a frame, so virtualization mounts turns as it would for a user.
async function scrollToBottom(page:Page){
 for(let i=0;i<200;i++){
  const done=await page.evaluate(()=>new Promise<boolean>(resolve=>{
   const el=document.querySelector('.scroll') as HTMLElement;
   const max=el.scrollHeight-el.clientHeight;
   if(el.scrollTop>=max-1)return resolve(true);
   el.addEventListener('scroll',()=>requestAnimationFrame(()=>resolve(false)),{once:true});
   el.scrollTop=Math.min(max,el.scrollTop+el.clientHeight);
  }));
  if(done)return;
 }
}
test('long histories stay bounded and preserve live text',async({page})=>{
 const errors:string[]=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto('/tests/performance-native.html');
 await page.waitForFunction(()=>!!(window as any).perfHarness);
 const samples=[];
 for(let i=0;i<5;i++)samples.push(await page.evaluate(()=>(window as any).perfHarness.transcript(1000,100)));
 console.log('VIRTUAL_TRANSCRIPT',JSON.stringify(samples));
 expect(samples.every(sample=>sample.nodes<5000)).toBe(true);
 expect(errors).toEqual([]);
 await scrollToBottom(page);
 await expect(page.locator('.st-text').last()).toContainText('A streamed fragment.');
});
test('focus survives repeated native-shaped question snapshots',async({page})=>{
 await page.goto('/tests/performance-native.html');
 await page.waitForFunction(()=>!!(window as any).perfHarness);
 const result=await page.evaluate(()=>(window as any).perfHarness.stableQuestion());
 expect(result).toMatchObject({same:true,focused:true,value:'A draft',selection:[2,5]});
});

test('finds an unmounted turn and preserves an edited prompt while scrolling',async({page})=>{
 await page.goto('/tests/performance-native.html');await page.waitForFunction(()=>!!(window as any).perfHarness);
 await page.evaluate(()=>(window as any).perfHarness.transcript(1000,1));
 await page.locator('.user').first().dblclick();
 const editor=page.getByRole('textbox',{name:'Edit prompt text'});await editor.fill('Keep this draft');
 await scrollToBottom(page);
 await expect(editor).toHaveValue('Keep this draft');
 await page.keyboard.press('Escape');
 await page.keyboard.press('Meta+f');
 await page.getByRole('textbox',{name:'Find in conversation'}).fill('Inspect module 123');
 await expect(page.locator('.find-count')).toHaveText('1 / 1');
 await expect(page.locator('.user').filter({hasText:'Inspect module 123'})).toBeVisible();
});
