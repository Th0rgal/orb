import { api, type Mission } from './api';
import type { StoredEvent } from './stream';
import type { SideExchange } from './sideQuestionClient';
import { transferFile, encoded } from './uploads';

export type ConversationCursor = { sequence:number; visibleHash:string; archive?:string };
const encoder = new TextEncoder();
export function byteTail(text:string, max:number):string {
 const bytes=encoder.encode(text);if(bytes.length<=max)return text;
 let start=bytes.length-max;while((bytes[start]&0xc0)===0x80)start++;
 return '[Earlier content omitted; read the archive.]\n'+new TextDecoder().decode(bytes.slice(start));
}
// Explicit public transcript types: never export private thinking or arbitrary metadata.
export function publicEvents(events:StoredEvent[]):StoredEvent[] {
 const allowed=new Set(['user_message','assistant_message','assistant_message_canonical','text_delta','text_op','tool_call','tool_result','error']);
 return events.filter(e=>allowed.has(e.event_type)&&e.metadata?.queued!==true).map(e=>({id:e.id,sequence:e.sequence,event_type:e.event_type,timestamp:e.timestamp,tool_call_id:e.tool_call_id,tool_name:e.tool_name,content:e.content}));
}
export async function conversationEvents(parent:string):Promise<StoredEvent[]> {
 const result:StoredEvent[]=[];let before:number|undefined;
 // Backwards pagination freezes the upper boundary even while the mission runs.
 while(true){
  const page=await api<StoredEvent[]|{events?:StoredEvent[]}>(`/api/control/missions/${encodeURIComponent(parent)}/events?view=all&limit=1000${before===undefined?'':`&before_seq=${before}`}`);
  const rows=Array.isArray(page)?page:page.events??[];
  if(!rows.length)break;
  const next=Math.min(...rows.map(e=>e.sequence));
  if(before!==undefined&&next>=before)throw new Error('Conversation pagination did not advance.');
  result.push(...rows);before=next;
 }
 return [...new Map(result.map(e=>[e.sequence,e])).values()].sort((a,b)=>a.sequence-b.sequence);
}
async function digest(text:string){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(text))),b=>b.toString(16).padStart(2,'0')).join('');}
export async function contextSnapshot(source:Mission,events:StoredEvent[],visible:string,previous?:ConversationCursor){
 const sequence=events.reduce((n,e)=>Math.max(n,e.sequence),0),visibleHash=await digest(visible);
 // A reset event log cannot inherit the old cursor.
 const cursor=previous&&previous.sequence<=sequence?previous:undefined;
 const safe=publicEvents(events),fresh=safe.filter(e=>e.sequence>(cursor?.sequence??0));
 const overview=fresh.map(e=>`[${e.sequence}] ${e.event_type}${e.tool_name?` ${e.tool_name}`:''}: ${byteTail(e.content,500)}`).join('\n');
 const initial=!cursor;
 const recent=initial?`${byteTail(visible||source.history.filter(h=>h.role==='user'||h.role==='assistant').map(h=>`${h.role}: ${h.content}`).join('\n'),1500)}\nRecent public events:\n${byteTail(overview,3000)}`:byteTail(overview,4500);
 const live=!initial&&!fresh.length&&visibleHash!==cursor.visibleHash?`\nLatest visible snapshot (may be unfinished):\n${byteTail(visible,1500)}`:'';
 return {cursor:{sequence,visibleHash},safe,summary:`${initial?'Initial recent context':`New events after ${cursor.sequence} through ${sequence}`}\n${recent||'No new public events.'}${live}`};
}
async function archiveFile(name:string,text:string,destination:string){return (await transferFile({name,file:new File([text],name,{type:'text/plain'})},destination)).path;}
export async function archiveParts(name:string,rows:string[],write:(name:string,text:string)=>Promise<string>){
 const paths:string[]=[];let chunk:string[]=[],chunkBytes=0;
 const flush=async()=>{paths.push(await write(`${name}.${paths.length}`,chunk.join('')));chunk=[];chunkBytes=0;};
 // Bound each upload, including a single unusually large tool result. The
 // size of the chunk is kept as a count: re-encoding it for every row froze
 // the page for a minute on a long conversation.
 for(const row of rows){let bytes=encoder.encode(row+'\n');while(bytes.length){
  let end=Math.min(bytes.length,4*1024*1024);while(end<bytes.length&&(bytes[end]&0xc0)===0x80)end--;
  const part=bytes.slice(0,end);bytes=bytes.slice(end);
  if(chunkBytes+part.length>8*1024*1024)await flush();
  chunk.push(new TextDecoder().decode(part));chunkBytes+=part.length;
 }}
 if(chunk.length||!paths.length)await flush();return paths;
}
export async function prepareBtwContext(source:Mission,visible:string,destination:string,previous?:ConversationCursor,sideHistory:SideExchange[]=[],localRoot?:string){
 const events=await conversationEvents(source.id),snapshot=await contextSnapshot(source,events,visible,previous);
 const unchanged=previous?.archive?.startsWith('.paloma/conversation/')&&previous.sequence===snapshot.cursor.sequence&&previous.visibleHash===snapshot.cursor.visibleHash;
 let manifest=unchanged?previous!.archive:undefined;
 if(!manifest){
 const localId=crypto.randomUUID();
 const write=async(name:string,text:string)=>{
  if(destination!=='local')return archiveFile(name,text,destination);
  if(!localRoot)throw new Error('The owning computer workspace is unavailable.');
  const rel=`.paloma/conversation/${localId}/${name}`;
  const {writeLocalFiles}=await import('./localAgents');
  await writeLocalFiles(localRoot,[{rel,encoding:'base64',content:await encoded({name,file:new File([text],name)})}]);
  return rel;
 };
 const transcript=source.history.filter(h=>h.role==='user'||h.role==='assistant').map(h=>`## ${h.role}\n\n${h.content}\n`);
 transcript.push('## Latest visible transcript (snapshot; may be unfinished)\n'+visible);
 const transcripts=await archiveParts('transcript.md',transcript,write);
 const traces=await archiveParts('events.jsonl',snapshot.safe.map(e=>JSON.stringify(e)),write);
 const sides=sideHistory.length?await archiveParts('side-history.md',sideHistory.map(e=>`## Question\n${e.question}\n## Answer\n${e.answer}`),write):[];
 manifest=await write('conversation.json',JSON.stringify({mission:source.id,captured_at:new Date().toISOString(),through_sequence:snapshot.cursor.sequence,transcript_parts:transcripts,event_parts:traces,previous_side_history_parts:sides,instructions:'Read parts in order. Parts may split a long line. Events contain public messages and tool details, without private reasoning. This is a snapshot refreshed on each /btw send.'},null,2));
 if(destination!=='local'){
  const id=manifest.match(/\/uploads\/([0-9a-f-]{36})\/conversation\.json$/)?.[1];
  if(!id)throw new Error('Invalid conversation upload receipt.');
  manifest=`.paloma/conversation/${id}/conversation.json`;
  if(destination==='core')await api(`/api/control/missions/${source.id}/btw/context`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({manifest_id:id})});
 }
 }
 return {cursor:{...snapshot.cursor,archive:manifest},context:`Mission: ${source.id}\nTitle: ${source.title??''}\nStatus: ${source.status}\n@conversation: ${manifest}\nThis manifest points to the full available conversation and tool-event archive on this machine. Search/read only relevant passages; do not load the whole archive by default.\n${snapshot.summary}`};
}
