import {test,expect,type Page} from '@playwright/test';
test.use({browserName:'webkit'});
test.setTimeout(60000);

/** Every visible error surface: alerts, error notices, red transcript rows. */
async function record(page:Page){
 await page.evaluate(()=>{
  const frames:any[]=[];(window as any).flash_=frames;
  const visible=(el:Element)=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0;};
  const sample=()=>{
   const errors=[...document.querySelectorAll('[role=alert], .error-notice, .error, .transcript-error, .error-row, .toast.error')].filter(visible).map(el=>(el.textContent??'').trim().slice(0,120));
   frames.push({t:performance.now(),errors});
  };
  // ~16 ms frames plus a 10 ms timer, so a one-frame flash is still caught.
  const tick=()=>{sample();(window as any).flashRaf=requestAnimationFrame(tick);};
  (window as any).flashTimer=setInterval(sample,10);
  tick();
 });
}
const stop=(page:Page)=>page.evaluate(()=>{cancelAnimationFrame((window as any).flashRaf);clearInterval((window as any).flashTimer);return (window as any).flash_ as {t:number;errors:string[]}[];});

const cases=[
 ...['claudecode','opencode','antigravity'].flatMap(backend=>[
  {backend,prev:'failed',remote:'1'},
  {backend,prev:'interrupted',remote:'1'},
  {backend,prev:'completed',remote:'1'},
  {backend,prev:'awaiting_user',remote:'0'},
  {backend,prev:'failed',remote:'0'},
  {backend,prev:'active',remote:'1'},
 ]),
];

for(const c of cases)test(`no error flashes when sending: ${c.backend}, previous ${c.prev}, ${c.remote==='1'?'remote':'local'}`,async({page})=>{
 await page.goto(`/tests/no-red-flash.html?backend=${c.backend}&prev=${c.prev}&remote=${c.remote}`);
 await expect(page.locator('.scroll')).toContainText('Run the steps',{timeout:20000});
 await page.waitForTimeout(300);
 const input=page.getByPlaceholder(/follow-up/i);
 await input.fill('Next step please');
 // Whatever the previous turn left on screen before the send is not a flash.
 await page.evaluate(()=>{(window as any).ready_=true;});
 await record(page);
 await input.press('Enter');
 await page.waitForTimeout(2500);
 const seen=await stop(page);
 expect(seen.length).toBeGreaterThan(50);
 // From the first frame after Enter on, no error surface may appear that was not already there.
 const before=new Set(seen[0].errors);
 if(process.env.FLASH_DEBUG){let last='';for(const f of seen){const k=JSON.stringify(f.errors);if(k!==last){console.log(Math.round(f.t-seen[0].t),k);last=k;}}}
 const flashed=[...new Set(seen.flatMap(f=>f.errors).filter(e=>!before.has(e)))];
 expect(flashed).toEqual([]);
 // A previous failure banner goes with the send and does not come back.
 const end=seen.at(-1)!.errors;
 const gone=seen.findIndex(f=>f.errors.length===0);
 if(gone>=0)expect(seen.slice(gone).every(f=>f.errors.length===0)).toBe(true);
 expect(end).toEqual([]);
 await expect(page.locator(c.prev==='active'?'.followup-queue .queue-row':'.scroll .user',{hasText:'Next step please'})).toHaveCount(1);
});
