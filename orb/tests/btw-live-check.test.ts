// Explicit opt-in only: creates a read-only side agent on the selected mission.
import {it,expect,vi} from 'vitest';
import {readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {File as NodeFile} from 'node:buffer';
import {webcrypto} from 'node:crypto';
import {setConnection,getMission} from '../src/api';
import {askBtwAgent,btwSession} from '../src/btwAgent';
import {sideQuestionKey} from '../src/sideQuestionStorage';
const live=process.env.ORB_BTW_LIVE_CHECK==='1';
const connection=live?JSON.parse(readFileSync(process.env.ORB_BTW_LIVE_CONNECTION??'/tmp/btw-test-connection.json','utf8')):null;
it.skipIf(!live)('checks actual Verity side-agent archive access and follow-up payload',async()=>{
 vi.stubGlobal('File',NodeFile);vi.stubGlobal('crypto',webcrypto);
 const requests:Array<{path:string;bytes:number;prompt:string}>=[];
 vi.stubGlobal('fetch',async(url:string,init:RequestInit={})=>{
  const args=['--max-time','90','-sS','-w','\n%{http_code}',String(url)];
  for(const [key,value] of Object.entries(init.headers??{}))args.push('-H',`${key}: ${value}`);
  if(init.method)args.push('-X',init.method);
  if(init.body){args.push('--data-binary','@-');const data=JSON.parse(String(init.body));const prompt=data.side_question??data.content;if(prompt)requests.push({path:new URL(url).pathname,bytes:Buffer.byteLength(prompt),prompt});}
  let raw:string;
  try{raw=execFileSync('curl',args,{input:init.body?String(init.body):undefined,maxBuffer:64*1024*1024,encoding:'utf8'});}
  catch{throw new Error('Live API transport failed.');}
  const split=raw.lastIndexOf('\n');return new Response(raw.slice(0,split),{status:Number(raw.slice(split+1))});
 });
 setConnection(connection.endpoint,connection.token);
 const id=process.env.ORB_BTW_LIVE_MISSION??'ebb2f1fe-8d03-4cc0-b966-68b3cb86077f';const source=await getMission(id);
 const previous=process.env.ORB_BTW_LIVE_FOLLOWUP==='1'?JSON.parse(readFileSync('/tmp/btw-live-check.json','utf8')):undefined;
 if(previous){localStorage.setItem('agent:'+sideQuestionKey(id),JSON.stringify(previous.session));requests.push(...previous.requests);}
 const visible=source.history.slice(-2).map(h=>h.role+': '+h.content).join('\n');
 const replies:string[]=previous?.replies??[];const jobs:string[]=previous?.jobs??[];const receive=(e:any)=>{if(e.type==='done')replies.push(e.answer);writeFileSync('/tmp/btw-live-check.json',JSON.stringify({session:btwSession(id),requests,replies,jobs},null,2));};
 if(previous){
  const before=previous.session.conversationCursor.sequence;
  await askBtwAgent(id,'Read-only delta test: report only the NEW main-agent events supplied since the previous snapshot, citing their sequence numbers. Is the main agent active again? Keep the answer short; do not read the full archive or change anything.',visible,[],new AbortController().signal,receive);
  expect(btwSession(id)!.id).toBe(previous.session.id);
  expect(btwSession(id)!.conversationCursor!.sequence).toBeGreaterThan(before);
  expect(requests.at(-1)!.bytes).toBeLessThan(9000);
  expect(requests.at(-1)!.prompt).toContain(`New events after ${before}`);
  const last=await getMission(btwSession(id)!.id);if(last.remote_job?.job_id)jobs.push(last.remote_job.job_id);
  writeFileSync('/tmp/btw-live-check.json',JSON.stringify({session:btwSession(id),requests,replies,jobs},null,2));
  return;
 }
 await askBtwAgent(id,'Read-only context delivery test. Do not modify files, start builds, publish, or message the main agent. Read the @conversation manifest with your tools, then inspect only a relevant tail of the transcript or event archive (do not load the full history). Identify the main objective, latest proven progress, and remaining work. Check the current status of the two existing Linux validation services/logs using read-only commands. Give a concise answer with exact file paths or event sequence numbers as evidence. Do not confuse completion of a turn with completion of the goal.',visible,[],new AbortController().signal,receive);
 const {getMissionEvents}=await import('../src/stream');
 const trace=await getMissionEvents(btwSession(id)!.id);
 expect(trace.some(e=>e.event_type==='tool_result'&&e.content.includes('transcript_parts')&&e.content.includes('through_sequence')&&!/rejected permission|\"status\":\"failed\"/.test(e.content))).toBe(true);
 expect(replies[0]).not.toContain('finished without assistant text');
 const child=await getMission(btwSession(id)!.id);if(child.remote_job?.job_id)jobs.push(child.remote_job.job_id);expect(Buffer.byteLength(child.history[0].content)).toBeLessThan(9000);
 writeFileSync('/tmp/btw-live-check.json',JSON.stringify({session:btwSession(id),requests,replies,jobs},null,2));
 await askBtwAgent(id,'Without rereading the full archive, is there any new main-agent event in this update? State the last known blocker in one sentence. Do not change anything.',visible,[],new AbortController().signal,receive);
 writeFileSync('/tmp/btw-live-check.json',JSON.stringify({session:btwSession(id),requests,replies,jobs},null,2));
 const last=await getMission(btwSession(id)!.id);if(last.remote_job?.job_id)jobs.push(last.remote_job.job_id);
 writeFileSync('/tmp/btw-live-check.json',JSON.stringify({session:btwSession(id),requests,replies,jobs},null,2));
 expect(replies).toHaveLength(2);expect(requests[1].bytes).toBeLessThan(9000);expect(requests[1].prompt).not.toContain(visible);
},600000);
