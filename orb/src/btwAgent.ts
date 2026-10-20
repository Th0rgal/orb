import { isRecord, readJson, writeJson } from "./storage";
import { missionAssignedNode, missionNode } from "./machines/nodes";
import { isQueued, WORKING_STATUSES } from "./missionStatus";
import { swallow } from "./log";
import {deliverAssistantText,flushClientLink} from './clientLink';
import {prepareBtwContext,type ConversationCursor} from './btwContext';
import {ApiError,api,getMission,cancelMission,sendMissionMessage,appendClientTranscript,setClientMissionStatus,type Mission,connectionVersion} from './api';
import {btwConfig} from './btwSettings';
import {sideQuestionKey} from './sideQuestionStorage';
import {localBinding,restoreLocalBindings,localAgentForLaunch,rememberBinding,startLocal,followLocal,stopLocal,localActivities,reconcileLocalRun,recoverLocalLaunch} from './localAgents';
import {getMissionEvents,storedToStream,streamMission,type StoredEvent} from './stream';
import {TranscriptReducer,type StreamItem} from './transcriptModel';
const [agentItems,setAgentItems]=createSignal<Record<string,StreamItem[]>>({});
export function btwItems(parent:string){const s=btwSession(parent);return s?agentItems()[s.id]??[]:[];}
type Thought=Extract<StreamItem,{kind:'think'}>;
const [liveThoughts,setLiveThoughts]=createSignal<Record<string,Thought[]>>({});
const thoughtsOf=(items:StreamItem[])=>items.filter((item):item is Thought=>item.kind==='think');
/** Thoughts of the current side turn. Stored events only hold finished
 * thoughts, so while the agent is answering the live stream is ahead. */
export function btwThoughts(parent:string):Thought[]{
 const s=btwSession(parent);if(!s)return [];
 const stored=thoughtsOf(agentItems()[s.id]??[]),live=liveThoughts()[s.id]??[];
 return live.length>stored.length||(live.length===stored.length&&live.some(item=>!item.done))?live:stored;
}
import type {SideAttachment,SideEvent,SideExchange} from './sideQuestionClient';
import {transferFile} from './uploads';
import {createSignal} from 'solid-js';
import type {LocalActivity} from './localAgents';
const [remoteActivities,setRemoteActivities]=createSignal<Record<string,LocalActivity[]>>({});
export type BtwSession={id:string;question:string;harness:string;model:string;local:boolean;active:boolean;baseline:number;afterSequence?:number;placement?:string;conversationCursor?:ConversationCursor;pendingCursor?:ConversationCursor;contextBytes?:number;contextVersion?:number;launchPending?:boolean;brokenSession?:boolean};
const storageKey=(parent:string)=>'agent:'+sideQuestionKey(parent);
export function btwSession(parent:string):BtwSession|undefined{const s=readJson<BtwSession|undefined>(storageKey(parent),undefined,isRecord);return s?{...s}:undefined;}
function save(parent:string,s:BtwSession){writeJson(storageKey(parent),s);}

// A turn is delimited by its latest user event, not an array offset: late
// persistence or a resumed session can otherwise replay the previous answer.
export function btwTurnEvents(events:StoredEvent[],session:Pick<BtwSession,'baseline'|'afterSequence'>):StoredEvent[]{
 const ordered=[...events].sort((a,b)=>a.sequence-b.sequence);
 const latestUser=ordered.reduce((sequence,event)=>event.event_type==='user_message'?event.sequence:sequence,0);
 const boundary=Math.max(session.afterSequence??0,latestUser);
 return ordered.filter(event=>event.sequence>boundary);
}

export function btwQueueStatus(mission: Mission): string {
 const node = missionNode(mission);
 if (mission.remote_job?.node_state === 'queued') return `Waiting for capacity${node ? ` on ${node}` : ''}…`;
 if (mission.status === 'paused') return 'Side agent paused';
 if (mission.status === 'waiting_background') return 'Waiting for background work…';
 if (isQueued(mission.status) || mission.status === 'starting' || mission.status === 'resuming') return 'Waiting to start…';
 return '';
}
export function isSyntheticRemoteAssistantNote(text: string): boolean {
 return (
  /^Remote (?:node '[^']+'|\w+) job [0-9a-f-]{36} (?:on node '[^']+' )?(?:finished with(?:out assistant text| state)|reached state) /.test(text) ||
  /^Native Codex goal stopped with status /.test(text)
 );
}
// OpenCode auto-compaction writes a summary turn and a synthetic "Continue…"
// prompt. Older Core builds recorded both inside the side agent's answer.
const COMPACTION_SUMMARY=/(?:^|\n)## Objective\n[\s\S]*?\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed\.[^\S\n]*(?:\n|$)/g;
export function stripCompactionSummary(text:string):string{
 return text.replace(COMPACTION_SUMMARY,'\n\n').replace(/\n{3,}/g,'\n\n').trim();
}
export type SideAnswer={answer:string;narration:string[]};
/** The side turn's answer is its final message; earlier text is progress
 * narration, shown folded rather than glued in front of the answer. */
export function sideAnswer(texts:string[],final?:string):SideAnswer{
 const meaningful=(t:string)=>!!t.replace(/[.\s…]/g,'');
 const clean:string[]=[];
 for(const raw of texts){const t=stripCompactionSummary(raw);if(meaningful(t)&&clean.at(-1)!==t)clean.push(t);}
 const recorded=final!==undefined?stripCompactionSummary(final):'';
 if(meaningful(recorded)){
  const at=clean.lastIndexOf(recorded);
  return {answer:recorded,narration:(at>=0?clean.slice(0,at):clean).filter(t=>t!==recorded)};
 }
 return {answer:clean.at(-1)??'',narration:clean.slice(0,-1)};
}
const ACTIVE=[...WORKING_STATUSES,'paused'];
const RESUMABLE=['awaiting_user','completed','interrupted'];
// Event sequences belong to one mission. Resolve the entire replacement chain
// before changing the saved session, and never carry its predecessor's boundary.
async function currentSide(parent:string,s:BtwSession,signal?:AbortSignal,version=connectionVersion()):Promise<Mission>{
 const seen=new Set<string>();
 const check=()=>{if(version!==connectionVersion())throw new Error('Connection changed.');if(signal?.aborted)throw new Error('Side question cancelled.');};
 check();
 let mission=await getMission(s.id);check();
 for(let hop=0;hop<16;hop++){
  seen.add(mission.id);
  const next=mission.tags?.find(tag=>tag.startsWith('superseded_by:'))?.slice('superseded_by:'.length);
  if(!next){
   if(mission.id!==s.id){s.id=mission.id;s.baseline=0;delete s.afterSequence;delete s.brokenSession;s.active=ACTIVE.includes(mission.status);save(parent,s);}
   return mission;
  }
  if(seen.has(next))throw new Error('Side session recovery contains a cycle.');
  mission=await getMission(next).catch(error=>{
   // A missing replacement is not proof that the saved side session was deleted.
   if(error instanceof ApiError&&error.status===404)throw new Error('Recovered side session is unavailable (404). Retry after recovery finishes.');
   throw error;
  });check();
 }
 throw new Error('Side session recovery chain is too long.');
}
const locks=new Map<string,Promise<void>>();
export function btwLaunchPending(parent:string):Promise<void>|undefined{return locks.get(storageKey(parent));}
export async function stopBtw(parent:string){const s=btwSession(parent);if(!s)return;if(s.local){await stopLocal(s.id);await flushClientLink(s.id);await setClientMissionStatus(s.id,'interrupted');}else{await currentSide(parent,s);await cancelMission(s.id);}}
export function btwActivities(parent:string){const s=btwSession(parent);return s?.local?localActivities(s.id):s?remoteActivities()[s.id]??[]:[];}
async function upload(attachments:SideAttachment[],destination:string){
 const paths:string[]=[];
 for(const a of attachments){const bytes=Uint8Array.from(atob(a.data_base64),c=>c.charCodeAt(0));const file=new File([bytes],a.name,{type:a.media_type});const item=await transferFile({name:a.name,file},destination);paths.push(item.path);}
 return paths;
}
const NOT_LOCAL='This conversation no longer runs on this computer';
const finishing=new Map<string,Promise<unknown>>();
function follow(id:string,receipt?:import('./clientRuns').ClientRunReceipt){
 if(finishing.has(id))return;
 const version=connectionVersion();
 const task=followLocal(id,()=>{}).then(async state=>{if(version!==connectionVersion())return;await deliverAssistantText(id,state.text,receipt);await setClientMissionStatus(id,state.exit_code||state.error||!state.text.trim()?'failed':'awaiting_user',receipt);}).finally(()=>finishing.delete(id));
 finishing.set(id,task);void task.catch(swallow("btw.followLocal", { mission: id }));
}
export async function watchBtw(parent:string,signal:AbortSignal,receive:(e:SideEvent)=>void){
 const s=btwSession(parent);if(!s)throw new Error('Side session not found.');const version=connectionVersion();
 receive({type:'start',model:s.harness+' · '+s.model});
 if(s.local){
  receive({type:'status',text:''});
  await restoreLocalBindings();
  await reconcileLocalRun(s.id);
  if(signal.aborted||connectionVersion()!==version)return;
  await getMission(s.id).then(m=>{if(connectionVersion()===version&&ACTIVE.includes(m.status))follow(s.id);}).catch(swallow("btw.watchStatus", { mission: s.id }));
  // The native receipt owns completion; Core synchronization must not keep the UI busy.
  const state=await followLocal(s.id,text=>{if(!signal.aborted&&connectionVersion()===version)receive({type:'snapshot',text});});
  if(signal.aborted||connectionVersion()!==version)return;
  s.active=false;
  if(state.error||state.exit_code||!state.text.trim()){s.brokenSession=true;delete s.pendingCursor;save(parent,s);throw new Error(state.error||'The side agent stopped without a response.');}
  if(s.pendingCursor){s.conversationCursor=s.pendingCursor;delete s.pendingCursor;}
  delete s.brokenSession;save(parent,s);
  receive({type:'done',answer:state.text});return;
 }
 let previous:string|undefined;
 let streamed:SideAnswer={answer:'',narration:[]};
 let wake:(()=>void)|undefined;
 const size=(a:SideAnswer)=>a.answer.length+a.narration.reduce((n,t)=>n+t.length,0);
 const publish=(a:SideAnswer)=>{const key=JSON.stringify(a);if(!signal.aborted&&connectionVersion()===version&&key!==previous){previous=key;receive({type:'snapshot',text:a.answer,narration:a.narration});}};
 const textsOf=(items:StreamItem[])=>items.flatMap(i=>i.kind==='text'?[i.text]:[]);
 // Unfinished thoughts are never stored: only the live stream carries them.
 let live=new TranscriptReducer(),streamId:string|undefined,stopStream:(()=>void)|undefined;
 const attach=()=>{
  if(streamId===s.id)return;
  stopStream?.();live=new TranscriptReducer();streamed={answer:'',narration:[]};
  if(streamId!==undefined)publish(streamed);
  const id=s.id;streamId=id;
  setLiveThoughts(all=>({...all,[id]:[]}));
  stopStream=streamMission(id,event=>{
   if(id!==s.id||signal.aborted||connectionVersion()!==version)return;
   live.apply(event);
   streamed=sideAnswer(textsOf(live.items));
   if(streamed.answer)publish(streamed);
   if(event.type==='mission_status_changed'||event.type==='status')wake?.();
   setLiveThoughts(all=>({...all,[id]:thoughtsOf(live.items).map(item=>({...item}))}));
  },()=>{});
 };
 const abortWake=()=>wake?.();signal.addEventListener('abort',abortWake);
 try{
 while(!signal.aborted){
  if(version!==connectionVersion())throw new Error('Connection changed.');
  const mission=await currentSide(parent,s,signal,version);attach();
  const events=await getMissionEvents(s.id);
  if(signal.aborted||connectionVersion()!==version)return;
  receive({type:'status',text:btwQueueStatus(mission)});
  const reducer=new TranscriptReducer();let final:string|undefined;
  for(const event of btwTurnEvents(events,s)){
   if(event.event_type==='assistant_message'&&isSyntheticRemoteAssistantNote(event.content))continue;
   if(event.event_type==='assistant_message')final=event.content;
   const e=storedToStream(event);if(e)reducer.apply(e);}
  setAgentItems(all=>({...all,[s.id]:reducer.items}));
  const toolItems=reducer.items.filter((i):i is Extract<StreamItem,{kind:'tool'}>=>i.kind==='tool');
  setRemoteActivities(all=>({...all,[s.id]:toolItems.map(i=>({id:i.callId,label:i.name,done:i.done,failed:false,detail:JSON.stringify({args:i.args,result:i.result})}))}));
  const active=ACTIVE.includes(mission.status);
  let result=sideAnswer(textsOf(reducer.items),final);
  // A terminal persisted response is authoritative, even if shorter than a streamed draft.
  if((active||!result.answer)&&size(streamed)>size(result))result=streamed;
  const text=result.answer;
  publish(result);
  if(!active){
   s.active=false;
   if(['failed','interrupted','cancelled'].includes(mission.status)){
    s.brokenSession=true;delete s.pendingCursor;save(parent,s);
    throw new Error(mission.remote_job?.error||mission.status_message||`Side agent ${mission.status}.`);
   }
   if(!text.trim()){
    s.brokenSession=true;delete s.pendingCursor;save(parent,s);
    const reason=mission.remote_job?.error||mission.status_message;
    const hint=toolItems.length>0
     ?'Check its activity for tool errors, then retry.'
     :'The model returned an empty completion without running any tools; retry to start a clean side session.';
    throw new Error(`No response was captured from the side agent (${mission.status}${reason?`: ${reason}`:''}). ${hint}`);
   }
   if(s.pendingCursor){s.conversationCursor=s.pendingCursor;delete s.pendingCursor;}
   delete s.brokenSession;save(parent,s);
   receive({type:'done',answer:text,...(result.narration.length?{narration:result.narration}:{})});return;
  }
  await new Promise<void>(resolve=>{
   const timer=setTimeout(done,5000);
   function done(){clearTimeout(timer);wake=undefined;resolve();}
   wake=done;if(signal.aborted)done();
  });
 }
 }finally{stopStream?.();signal.removeEventListener('abort',abortWake);wake?.();}
}
export async function askBtwAgent(parent:string,question:string,context:string,history:SideExchange[],signal:AbortSignal,receive:(e:SideEvent)=>void,attachments:SideAttachment[]=[],launchSignal:AbortSignal=signal,allowCleanRetry=true){
 const version=connectionVersion();
 const key=storageKey(parent);if(locks.has(key))throw new Error('A side question is already starting.');
 let unlock!:()=>void;locks.set(key,new Promise<void>(r=>{unlock=r;}));
 let reusedExisting=false;
 try{
  let s=btwSession(parent);
  let current:Mission|undefined;
  if(s){
   // Native completion can precede its transcript/status update to Core.
   // A queued local follow-up must observe that update before the status guard.
   if(s.local&&!s.active)await finishing.get(s.id);
   if(s.local&&s.launchPending){
    // Native recovery proves the prior attempt stopped before releasing Core.
    // Transport failures and live processes retain the fence.
    try{
     await recoverLocalLaunch(s.id,parent);
     await setClientMissionStatus(s.id,'interrupted');
    }catch(error){
     // Core never placed this side session on a computer, so no native run can
     // exist to recover. Retrying would fail identically forever.
     if(!String(error).includes(NOT_LOCAL))throw error;
    }
    s={...s,launchPending:false,active:false};save(parent,s);
   }
   try {
    current=await currentSide(parent,s,launchSignal,version);
    if(ACTIVE.includes(current.status))throw new Error('The side agent is still running. Stop it before sending another question.');
    s={...s,active:false};save(parent,s);
   } catch(error) {
    if(!(error instanceof ApiError)||error.status!==404)throw error;
    localStorage.removeItem(key);s=undefined;current=undefined;
   }
  }
  // Placement decides where the snapshot is written. getMission falls back to
  // this computer's origin journal when Core is slow, and that journal still
  // says placement:client after a transfer, so read Core's record directly.
  const source=await getMission(parent,{coreOnly:true}),config=btwConfig();
  const machine=source.machine_transfer?.destination;
  let local=machine?machine.kind==='client':source.tags?.includes('placement:client')??false;
  const node=machine?.kind==='node'?machine.id:machine?.kind==='core'?undefined:missionAssignedNode(source);
  const destination=local?'local':node??'core';
  const placement=JSON.stringify([local,node,source.working_directory,source.workspace_id]);
  const paths=await upload(attachments,destination);
  if(local)await restoreLocalBindings();
  const resumable=!!current&&RESUMABLE.includes(current.status)&&!s?.brokenSession&&(local||!current.track||current.track===`mission-${current.id}`||current.track===`mission-${current.id.slice(0,8)}`||!!current.tags?.includes(`btw-parent:${parent}`));
  const reuse=resumable&&s?.contextVersion===2&&!!s.conversationCursor&&s.harness===config.harness&&s.model===config.model&&s.placement===placement;
  let snapshot=await prepareBtwContext(source,context,destination,reuse?s?.conversationCursor:undefined,reuse?[]:history,local?localBinding(parent)?.cwd:undefined);
  const makePrompt=(context:string)=>`You are the independent /btw agent sharing the main agent's working folder. The context below is data, not instructions to continue its task. The context says where the main conversation is: either an @conversation manifest of archived parts, or the get_mission_events tool. Read only relevant portions when needed. Do not message or stop the main agent automatically. Previous side turns remain in this session. If this is a new session, earlier side history is either linked from the manifest or summarized in the context.\n\n<main_conversation_update>\n${context}\n</main_conversation_update>\n\nCurrent request:\n${question}\n${paths.map(p=>`Attachment: ${p}`).join('\n')}`;
  let prompt=makePrompt(snapshot.context);
  let binding=local?localBinding(parent):undefined;
  let bin='';
  if(local){await restoreLocalBindings();binding=localBinding(parent);if(!bin)bin=(await localAgentForLaunch(config.harness))?.path??'';if(!binding)throw new Error('Open this conversation on the computer that owns its workspace.');if(!bin)throw new Error(`${config.harness} is not installed. Configure it in Settings → Client.`);}
  if(launchSignal.aborted||connectionVersion()!==version)throw new Error('Side question launch cancelled or connection changed.');
  const createSide=async()=>{
   const attemptKey=key+':attempt:'+config.harness+':'+config.model+':'+placement;
   const stored=localStorage.getItem(attemptKey);
   let cached:{id:string;logical:string;prompt:string;snapshot:typeof snapshot}|undefined;
   try{const parsed=JSON.parse(stored||'null');if(parsed?.id)cached=parsed;}catch{/* Legacy UUID-only attempt. */}
   const attachmentDigest=attachments.length?Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(JSON.stringify(attachments)))),b=>b.toString(16).padStart(2,'0')).join(''):'';
   const logical=JSON.stringify([question,attachmentDigest]);
   const attempt=cached?.id||stored||crypto.randomUUID();
   if(cached?.logical===logical){prompt=cached.prompt;snapshot=cached.snapshot;}
   const retained=cached??{id:attempt,logical,prompt,snapshot};
   localStorage.setItem(attemptKey,JSON.stringify(retained));
   const m=await api<Mission>(`/api/control/missions/${parent}/btw/agent`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({backend:config.harness,model_override:config.model,model_effort:null,idempotency_key:attempt,side_question:prompt,side_context_mode:"incremental"})}).catch(error=>{
    if(error instanceof ApiError&&error.status===409&&error.detail.startsWith('This side request key was already used for different launch content;')&&localStorage.getItem(attemptKey)===JSON.stringify(retained))localStorage.removeItem(attemptKey);
    throw error;
   });
   // Core owns placement. A stale local view must not launch a native run for
   // a side session Core already started elsewhere.
   if(local&&!m.tags?.includes('placement:client'))local=false;
   s={id:m.id,question,harness:config.harness,model:config.model,local,placement,active:!local,baseline:0};save(parent,s);localStorage.removeItem(attemptKey);
  };
  if(!reuse)await createSide();
  else{
   const next={...s!,question,active:!local,baseline:0,afterSequence:Math.max(0,...(await getMissionEvents(s!.id)).map(e=>e.sequence))};
   delete next.brokenSession;
   try{
    if(!local)await sendMissionMessage(next.id,prompt);
    s=next;save(parent,s);
    reusedExisting=true;
   }catch(error){
    if(!(error instanceof ApiError)||error.status!==409||!error.detail.startsWith('REMOTE_RESUME_REQUIRES_REPLACEMENT:'))throw error;
    // Only an explicit pre-submit refusal permits a fresh native side session.
    // Keep previous side turns in its archive, never in the process argv.
    snapshot=await prepareBtwContext(source,context,destination,undefined,history);
    prompt=makePrompt(snapshot.context);
    if(launchSignal.aborted||connectionVersion()!==version)throw new Error('Side question launch cancelled or connection changed.');
    await createSide();
   }
  }
  if(local&&binding){const old=localBinding(s!.id);await rememberBinding(s!.id,{harness:config.harness,bin,cwd:binding.cwd,model:config.model,sessionId:old?.sessionId});s!.launchPending=true;save(parent,s!);const receipt=await startLocal({id:s!.id,harness:config.harness,bin,cwd:binding.cwd,model:config.model,prompt,sessionId:old?.sessionId,sharedCwdWith:parent,imagePaths:paths.filter((_,i)=>attachments[i].media_type.startsWith('image/'))});s!.launchPending=false;s!.active=true;save(parent,s!);follow(s!.id,receipt);await appendClientTranscript(s!.id,'user',question,undefined,receipt);}
  s!.contextVersion=2;
  if(!reuse||!s!.conversationCursor)s!.conversationCursor=snapshot.cursor;
  else s!.pendingCursor=snapshot.cursor;
  s!.contextBytes=new TextEncoder().encode(snapshot.context).length;save(parent,s!);
 }finally{locks.delete(key);unlock();}
 if(signal.aborted)return;
 try{
  await watchBtw(parent,signal,receive);
 }catch(error){
  const msg=error instanceof Error?error.message:String(error);
  if(allowCleanRetry&&reusedExisting&&!signal.aborted&&connectionVersion()===version&&msg.includes('The model returned an empty completion without running any tools')){
   receive({type:'status',text:'Starting clean side session…'});
   await askBtwAgent(parent,question,context,history,signal,receive,attachments,launchSignal,false);
   return;
  }
  throw error;
 }
}

export function extractBtwUserQuestion(content:string):string{
 const marker='\nCurrent request:\n';
 const idx=content.lastIndexOf(marker);
 const raw=idx>=0?content.slice(idx+marker.length):content;
 return raw.replace(/(?:\nAttachment: [^\n]+)+\s*$/,'').trim();
}

export async function reconcileBtwServerHistory(parent:string,localHistory:SideExchange[],signal?:AbortSignal):Promise<{history:SideExchange[];activeSession?:BtwSession;latest?:string}>{
 const version=connectionVersion();
 let rows:Mission[]=[];
 try{
  const res=await api<Mission[]>(`/api/control/missions?tag=${encodeURIComponent(`btw-parent:${parent}`)}&all=true&limit=20`);
  if(Array.isArray(res))rows=res;
 }catch{return {history:localHistory};}
 if(signal?.aborted||connectionVersion()!==version||!rows.length)return {history:localHistory};
 const valid=rows.filter(m=>m&&typeof m.id==='string'&&Array.isArray(m.tags)&&m.tags.includes(`btw-parent:${parent}`)&&!m.tags.includes('superseded'));
 if(!valid.length)return {history:localHistory};
 const sorted=[...valid].sort((a,b)=>(a.created_at||'').localeCompare(b.created_at||''));
 const serverTurns:(SideExchange&{at:string})[]=[];
 let latestActive:BtwSession|undefined;
 for(const m of sorted){
  if(signal?.aborted||connectionVersion()!==version)return {history:localHistory};
  let events:StoredEvent[]=[];
  try{events=await getMissionEvents(m.id);}catch{continue;}
  if(signal?.aborted||connectionVersion()!==version)return {history:localHistory};
  const ordered=[...events].sort((a,b)=>a.sequence-b.sequence);
  let curQuestion='',curAt='',curSeq=0;
  let curAnswers:string[]=[];let curFinal:string|undefined;
  const flush=()=>{
   const q=curQuestion.trim(),{answer:a,narration}=sideAnswer(curAnswers,curFinal);
   // Stable per question event, so a re-read never renumbers a turn.
   if(q&&a&&!isSyntheticRemoteAssistantNote(a))serverTurns.push({id:`btw:${m.id}:${curSeq}`,question:q,answer:a,...(narration.length?{narration}:{}),at:curAt});
   curQuestion='';curAnswers=[];curFinal=undefined;
  };
  for(const ev of ordered){
   if(ev.event_type==='user_message'){
    if(curQuestion)flush();
    curQuestion=extractBtwUserQuestion(ev.content);curAt=ev.timestamp||'';curSeq=ev.sequence;
   }else if((ev.event_type==='assistant_message'||ev.event_type==='assistant_message_canonical')&&!isSyntheticRemoteAssistantNote(ev.content)&&ev.content.trim()){
    const text=ev.content.trim();
    if(ev.event_type==='assistant_message')curFinal=text;
    if(curAnswers.at(-1)!==text)curAnswers.push(text);
   }
  }
  const isActive=ACTIVE.includes(m.status);
  if(isActive&&curQuestion){
   const local=m.tags?.includes('placement:client')??false;
   latestActive={id:m.id,question:curQuestion,harness:m.backend||'opencode',model:m.model_override||'builtin/smart',local,active:true,baseline:0};
  }else if(curQuestion){
   flush();
  }
 }
 // The newest thread is the one with the latest activity: each /btw question
 // re-dispatches a job on the same mission, so an old thread can be the live one.
 const activity=(m:Mission)=>(m as Mission&{last_activity_at?:string}).last_activity_at||m.updated_at||m.created_at||'';
 const latest=[...sorted].sort((a,b)=>activity(a).localeCompare(activity(b))).at(-1);
 let existing=btwSession(parent);
 // A session saved as running whose thread Core reports finished (or that is
 // no longer listed) is stale: it must not pin the tab to an old thread.
 if(existing?.active&&!valid.some(m=>m.id===existing!.id&&ACTIVE.includes(m.status)))existing={...existing,active:false};
 if(latestActive&&(!existing||!existing.active||existing.id!==latestActive.id)){
  save(parent,latestActive);
 }else if(latest&&RESUMABLE.includes(latest.status)&&!existing?.active){
  const local=latest.tags?.includes('placement:client')??false;
  const lastTurn=serverTurns.at(-1);
  if(lastTurn&&(!existing||existing.id!==latest.id||existing.question!==lastTurn.question)){
   save(parent,{id:latest.id,question:lastTurn.question,harness:latest.backend||existing?.harness||'opencode',model:latest.model_override||existing?.model||'builtin/smart',local,active:false,baseline:0,placement:existing?.placement,contextVersion:existing?.contextVersion,conversationCursor:existing?.conversationCursor});
  }
 }
 if(!serverTurns.length)return {history:localHistory,activeSession:latestActive,latest:latest?.id};
 // Core is the record: its turns across every thread, in the order they were
 // asked. Local turns stay only when Core has no answer for that question yet.
 serverTurns.sort((a,b)=>a.at.localeCompare(b.at));
 const onServer=new Set(serverTurns.map(t=>t.question.trim()));
 const merged:SideExchange[]=[...serverTurns.map(({at:_at,...turn})=>turn),...localHistory.filter(h=>!onServer.has(h.question.trim()))];
 return {history:merged.slice(-20),activeSession:latestActive,latest:latest?.id};
}
