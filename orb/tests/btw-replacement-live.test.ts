// Explicit opt-in only: creates a read-only side agent on the selected mission.
import {it,expect,vi} from 'vitest';
import {readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {File as NodeFile} from 'node:buffer';
import {webcrypto} from 'node:crypto';
import {setConnection,getMission} from '../src/api';
import {askBtwAgent,btwSession} from '../src/btwAgent';
import {sideQuestionKey} from '../src/sideQuestionStorage';
const live=process.env.ORB_BTW_REPAIR_LIVE==='1';
const connection=live?JSON.parse(readFileSync(process.env.ORB_BTW_LIVE_CONNECTION??'/tmp/btw-test-connection.json','utf8')):null;
it.skipIf(!live)('recovers the refused Verity btw session without an ordinary mission',async()=>{
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

 const original='1c06471d-1443-4e5d-848e-cd895cc8338d';
 const {btwConfig}=await import('../src/btwSettings');const config=btwConfig();
 const machine=source.machine_transfer?.destination;
 const node=machine?.kind==='node'?machine.id:source.remote_node_id??source.remote_job?.node_id;
 localStorage.setItem('agent:'+sideQuestionKey(id),JSON.stringify({id:original,question:'Previous side turn',harness:config.harness,model:config.model,local:false,active:false,baseline:0,placement:JSON.stringify([false,node,source.working_directory,source.workspace_id]),contextVersion:2,conversationCursor:{sequence:0,visibleHash:''}}));
 const replies:string[]=[];
 await askBtwAgent(id,"Quel est le statut actuellement de ? L'avancée sur Verity par rapport à la roadmap initiale. Réponds en lecture seule avec les preuves disponibles, sans modifier le travail ni envoyer de message à l’agent principal.",source.history.slice(-2).map(h=>h.content).join('\n'),[],new AbortController().signal,(event)=>{
  if(event.type==='done')replies.push(event.answer);
  writeFileSync('/tmp/btw-repair-live-result.json',JSON.stringify({session:btwSession(id),requests:requests.map(r=>({path:r.path,bytes:r.bytes})),replies},null,2));
 });
 const child=await getMission(btwSession(id)!.id);
 expect(child.id).not.toBe(original);
 expect(child.tags).toContain('btw-parent:'+id);
 expect(child.tags).toContain('fork-workspace:'+id);
 expect(Buffer.byteLength(child.history[0].content)).toBeLessThan(12000);
 expect(requests.every(r=>r.path.endsWith('/message')||r.path.endsWith('/btw/agent'))).toBe(true);
 expect(replies.length).toBe(1);expect(replies[0].length).toBeGreaterThan(80);
 writeFileSync('/tmp/btw-repair-live-result.json',JSON.stringify({session:btwSession(id),requests:requests.map(r=>({path:r.path,bytes:r.bytes})),replies,child:{id:child.id,status:child.status,tags:child.tags,remote_job:child.remote_job}},null,2));
},600000);
