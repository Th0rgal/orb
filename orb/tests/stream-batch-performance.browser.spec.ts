import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('batch replay reduces immutable array copies without changing results',async({page},info)=>{
 await page.goto('/tests/transcript.html');
 const result=await page.evaluate(async()=>{
  const url='/src/transcriptModel.ts';const {buildTranscript,applyStreamEvent,applyStreamEvents}=await import(/* @vite-ignore */url);
  const history=Array.from({length:2000},(_,i)=>({type:i%2?'assistant_message':'user_message',eventId:`h${i}`,data:{id:`h${i}`,content:`Message ${i}`}}));
  const events=Array.from({length:128},(_,i)=>({type:'text_delta',eventId:`live${i}`,data:{content:'x'}}));
  const before=buildTranscript(history);const start=performance.now();let sequential=before;
  for(const event of events)sequential=applyStreamEvent(sequential,event);
  const sequentialMs=performance.now()-start;
  const baseline=buildTranscript(history);const begin=performance.now();const batch=applyStreamEvents(baseline,events);const batchMs=performance.now()-begin;
  return {historyEvents:history.length,fragments:events.length,sequentialMs,batchMs,equal:JSON.stringify(sequential)===JSON.stringify(batch),prefixRetained:batch[0]===baseline[0]};
 });
 expect(result.equal).toBe(true);expect(result.prefixRetained).toBe(true);
 await info.attach('batch-performance.json',{body:JSON.stringify(result,null,2),contentType:'application/json'});
 console.log('BATCH_BENCHMARK',JSON.stringify(result));
});
