import {test,expect,webkit} from '@playwright/test';

test('context counter preserves results without reserializing historical tools',async({},testInfo)=>{
 const browser=await webkit.launch();
 try {
  const page=await browser.newPage();
  await page.route('**/perf.html',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><title>Orb performance</title>'}));
  await page.goto('http://127.0.0.1:1431/perf.html');
  const result=await page.evaluate(async()=>{
   const url='/src/missionContext.ts';
   const {estimateTokens}=await import(/* @vite-ignore */ url);
   let serializations=0;
   const items=Array.from({length:150},(_,i)=>({kind:'tool',key:`t${i}`,callId:`t${i}`,name:'Read',done:true,args:{path:`/workspace/${i}`},result:{toJSON(){serializations++;return {text:'x'.repeat(20000)};}}}));
   const oldEstimate=(rows:typeof items)=>Math.ceil(rows.reduce((chars,item)=>chars+item.name.length+Math.min(JSON.stringify(item.args).length,400)+Math.min(JSON.stringify(item.result).length,400),0)/4);
   const measure=(fn:typeof oldEstimate)=>{serializations=0;const start=performance.now();let count=0;for(let n=0;n<60;n++)count=fn([...items]);return {ms:performance.now()-start,serializations,count};};
   return {baseline:measure(oldEstimate),optimized:measure(estimateTokens),tools:items.length,updates:60};
  });
  expect(result.optimized.count).toBe(result.baseline.count);
  expect(result.baseline.serializations).toBe(9000);
  expect(result.optimized.serializations).toBe(150);
  console.log(JSON.stringify(result));
  await testInfo.attach('context-performance.json',{body:JSON.stringify(result,null,2),contentType:'application/json'});
 } finally {await browser.close();}
});
