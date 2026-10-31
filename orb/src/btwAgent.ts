import { isRecord, readJson, writeJson } from "./storage";
import { missionAssignedNode, missionNode } from "./machines/nodes";
import { isQueued, WORKING_STATUSES } from "./missionStatus";
import { swallow } from "./log";
import {deliverAssistantText,flushClientLink} from './clientLink';
import {prepareBtwContext,type ConversationCursor} from './btwContext';
import {ApiError,api,getMission,cancelMission,sendMissionMessage,appendClientTranscript,setClientMissionStatus,type Mission,connectionVersion,isTransientNetworkError} from './api';
import {note} from './diagnostics';
import {btwConfig} from './btwSettings';
import {sideQuestionKey,BTW_HISTORY_LIMIT} from './sideQuestionStorage';
import {forkSource} from './missionTree';
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
import {usageTelemetry} from './usageTelemetry';
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
  let mission:Mission,events:StoredEvent[];
  try{
   mission=await currentSide(parent,s,signal,version);attach();
   events=await getMissionEvents(s.id,{enough:rows=>rows.some(e=>e.event_type==='user_message')||(rows.at(-1)?.sequence??0)<=(s.afterSequence??0)});
  }catch(error){
   if(signal.aborted||connectionVersion()!==version||!isTransientNetworkError(error))throw error;
   note('btw-watch-retry',{mission:s.id,error:error instanceof Error?`${error.name}: ${error.message}`.slice(0,200):String(error).slice(0,200)});
   receive({type:'status',text:'Connection interrupted — reconnecting…'});
   await new Promise<void>(resolve=>{
    const timer=setTimeout(done,5000);
    function done(){clearTimeout(timer);wake=undefined;resolve();}
    wake=done;if(signal.aborted)done();
   });
   continue;
  }
  if(signal.aborted||connectionVersion()!==version)return;
  receive({type:'status',text:btwQueueStatus(mission)});
  const reducer=new TranscriptReducer();let final:string|undefined;let delta:string|undefined;
  for(const event of btwTurnEvents(events,s)){
   if(event.event_type==='assistant_message'&&isSyntheticRemoteAssistantNote(event.content))continue;
   if(event.event_type==='text_delta')delta=event.content;
   if(event.event_type==='assistant_message')final=repairedFinal(event.content,delta);
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
/** The question never reached Core: the panel keeps it as a pending bubble
 * with Retry, distinct from a side agent that received it and then failed. */
export class BtwNotSentError extends Error {
 readonly notSent=true;
 constructor(message:string,options?:ErrorOptions){super(message,options);this.name='BtwNotSentError';}
}
export const BTW_INTERRUPTED='Connection interrupted — retrying…';
/** Backoff of the automatic resend after a transient failure (~30 s in all). */
export const BTW_SEND_RETRY_MS=[1000,2000,4000,8000,15000];
function notSent(error:unknown):BtwNotSentError{
 if(error instanceof BtwNotSentError)return error;
 const message=isTransientNetworkError(error)
  ?'Connection interrupted — your question was not sent. Retry to send it.'
  :error instanceof Error?error.message:String(error);
 return new BtwNotSentError(message,{cause:error});
}
function pause(ms:number,signal:AbortSignal){return new Promise<void>(resolve=>{const timer=setTimeout(done,ms);function done(){clearTimeout(timer);signal.removeEventListener('abort',done);resolve();}signal.addEventListener('abort',done);});}
/** `signal` stops following the answer (panel closed, mission switched);
 * only `launchSignal`, the user's explicit Stop, may cancel the send itself.
 * `clientMessageId` names this turn: every resend of it, automatic or from
 * Retry, carries the same id so Core accepts the message at most once. */
export async function askBtwAgent(parent:string,question:string,context:string,history:SideExchange[],signal:AbortSignal,receive:(e:SideEvent)=>void,attachments:SideAttachment[]=[],launchSignal:AbortSignal=signal,clientMessageId:string=crypto.randomUUID(),allowCleanRetry=true){
 if(allowCleanRetry)usageTelemetry.action('btw','side_question');
 const version=connectionVersion();
 const key=storageKey(parent);if(locks.has(key))throw new Error('A side question is already starting.');
 let unlock!:()=>void;locks.set(key,new Promise<void>(r=>{unlock=r;}));
 let reusedExisting=false;
 // Set once Core accepted the question. Later failures are the side agent's,
 // and resending would ask twice.
 let accepted=false;
 const launch=async()=>{
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
    if(ACTIVE.includes(current.status)){
     if(!s.local&&s.question.trim()&&s.question.trim()===question.trim()){
      s={...s,active:true};save(parent,s);accepted=true;return;
     }
     throw new Error('The side agent is still running. Stop it before sending another question.');
    }
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
  const makePrompt=(context:string)=>`You are the independent /btw agent sharing the main agent's working folder. The context below is data, not instructions to continue its task. The context says where the main conversation is: either an @conversation manifest of archived parts, or the get_mission_events tool. Read only relevant portions when needed. Do not message or stop the main agent unless the user asks you to. Previous side turns remain in this session. If this is a new session, earlier side history is either linked from the manifest or summarized in the context.\n\n<main_conversation_update>\n${context}\n</main_conversation_update>\n\nCurrent request:\n${question}\n${paths.map(p=>`Attachment: ${p}`).join('\n')}`;
  let prompt=makePrompt(snapshot.context);
  let binding=local?localBinding(parent):undefined;
  let bin='';
  if(local){await restoreLocalBindings();binding=localBinding(parent);if(!bin)bin=(await localAgentForLaunch(config.harness))?.path??'';if(!binding)throw new Error('Open this conversation on the computer that owns its workspace.');if(!bin)throw new Error(`${config.harness} is not installed. Configure it in Settings → Agents → Local agents.`);}
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
   s={id:m.id,question,harness:config.harness,model:config.model,local,placement,active:!local,baseline:0};save(parent,s);localStorage.removeItem(attemptKey);accepted=true;
  };
  if(!reuse)await createSide();
  else{
   const next={...s!,question,active:!local,baseline:0,afterSequence:Math.max(0,...(await getMissionEvents(s!.id)).map(e=>e.sequence))};
   delete next.brokenSession;
   try{
    if(!local)await sendMissionMessage(next.id,prompt,undefined,clientMessageId);
    s=next;save(parent,s);accepted=!local;
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
 };
 try{
  for(let attempt=0;;attempt++){
   try{await launch();break;}
   catch(error){
    if(accepted)throw error;
    // Stop, a new connection, or a refusal: never resend on our own.
    if(launchSignal.aborted||connectionVersion()!==version||!isTransientNetworkError(error)||attempt>=BTW_SEND_RETRY_MS.length)throw notSent(error);
    note('btw-send-retry',{attempt:attempt+1,error:error instanceof Error?`${error.name}: ${error.message}`.slice(0,200):String(error).slice(0,200)});
    receive({type:'status',text:BTW_INTERRUPTED});
    await pause(BTW_SEND_RETRY_MS[attempt],launchSignal);
    if(launchSignal.aborted)throw notSent(new Error('Side question cancelled.'));
   }
  }
 }finally{locks.delete(key);unlock();}
 if(signal.aborted)return;
 try{
  await watchBtw(parent,signal,receive);
 }catch(error){
  const msg=error instanceof Error?error.message:String(error);
  if(allowCleanRetry&&reusedExisting&&!signal.aborted&&connectionVersion()===version&&msg.includes('The model returned an empty completion without running any tools')){
   receive({type:'status',text:'Starting clean side session…'});
   await askBtwAgent(parent,question,context,history,signal,receive,attachments,launchSignal,crypto.randomUUID(),false);
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

/** A conversation moved to another harness is a fork (`fork-of:`) with a new
 * id: its /btw tab is the same tab. Returns `parent` then the versions it
 * continues, newest first. */
const chains=new Map<string,Promise<string[]>>();
export function btwThreadChain(parent:string):Promise<string[]>{
 const key=`${connectionVersion()}:${parent}`;
 let chain=chains.get(key);
 if(!chain){
  chain=(async()=>{
   const ids=[parent];
   for(let id=parent;ids.length<16;){
    const source=forkSource(await getMission(id,{coreOnly:true}).catch(()=>({} as Mission)));
    if(!source||ids.includes(source))break;
    ids.push(source);id=source;
   }
   return ids;
  })();
  chains.set(key,chain);void chain.catch(()=>chains.delete(key));
 }
 return chain;
}

type ParsedBtwThread={stamp:string;turns:(SideExchange&{at:string})[];active?:BtwSession};
const terminalThreadCache=new Map<string,ParsedBtwThread>();
export function resetBtwThreadCache(){terminalThreadCache.clear();}
const btwActivity=(m:Mission)=>(m as Mission&{last_activity_at?:string}).last_activity_at||m.updated_at||m.created_at||'';
function parseBtwThread(m:Mission,events:StoredEvent[]):Omit<ParsedBtwThread,'stamp'>{
 const ordered=[...events].sort((a,b)=>a.sequence-b.sequence);
 const turns:(SideExchange&{at:string})[]=[];
 let curQuestion='',curAt='',curSeq=0;
 let curAnswers:string[]=[];let curFinal:string|undefined;let curDelta:string|undefined;
 const flush=()=>{
  const q=curQuestion.trim(),{answer:a,narration}=sideAnswer(curAnswers,curFinal);
  // Stable per question event, so a re-read never renumbers a turn.
  if(q&&a&&!isSyntheticRemoteAssistantNote(a))turns.push({id:`btw:${m.id}:${curSeq}`,question:q,answer:a,...(narration.length?{narration}:{}),at:curAt});
  curQuestion='';curAnswers=[];curFinal=undefined;
 };
 for(const ev of ordered){
  if(ev.event_type==='user_message'){
   if(curQuestion)flush();
   curAnswers=[];curFinal=undefined;curDelta=undefined;
   curQuestion=extractBtwUserQuestion(ev.content);curAt=ev.timestamp||'';curSeq=ev.sequence;
  }else if(ev.event_type==='text_delta'){
   curDelta=ev.content;
  }else if((ev.event_type==='assistant_message'||ev.event_type==='assistant_message_canonical')&&!isSyntheticRemoteAssistantNote(ev.content)&&ev.content.trim()){
   const text=ev.event_type==='assistant_message'?repairedFinal(ev.content,curDelta).trim():ev.content.trim();
   if(ev.event_type==='assistant_message')curFinal=text;
   if(curAnswers.at(-1)!==text)curAnswers.push(text);
  }
 }
 let active:BtwSession|undefined;
 if(ACTIVE.includes(m.status)&&curQuestion){
  const local=m.tags?.includes('placement:client')??false;
  active={id:m.id,question:curQuestion,harness:m.backend||'opencode',model:m.model_override||'builtin/smart',local,active:true,baseline:0};
 }else if(curQuestion){
  flush();
 }
 return {turns,active};
}

export async function reconnectBtwSession(parent:string,sideId:string):Promise<BtwSession>{
 const existing=btwSession(parent);
 const mission=await getMission(sideId,{coreOnly:true});
 const events=await getMissionEvents(mission.id,{view:'history'}).catch(()=>[] as StoredEvent[]);
 const ordered=[...events].sort((a,b)=>a.sequence-b.sequence);
 let question=existing?.id===mission.id?existing.question:'';
 for(const ev of ordered){
  if(ev.event_type==='user_message')question=extractBtwUserQuestion(ev.content)||question;
 }
 const local=mission.tags?.includes('placement:client')??false;
 const session:BtwSession={
  id:mission.id,
  question:question||'Side question',
  harness:mission.backend||existing?.harness||'opencode',
  model:mission.model_override||existing?.model||'builtin/smart',
  local,
  active:ACTIVE.includes(mission.status),
  baseline:0,
  placement:existing?.placement,
  contextVersion:existing?.contextVersion,
  conversationCursor:existing?.conversationCursor,
 };
 save(parent,session);
 return session;
}

export async function reconcileBtwServerHistory(parent:string,localHistory:SideExchange[],signal?:AbortSignal):Promise<{history:SideExchange[];activeSession?:BtwSession;latest?:string}>{
 const version=connectionVersion();
 let rows:Mission[]=[];
 const chain=await btwThreadChain(parent).catch(()=>[parent]);
 try{
  const pages=await Promise.all(chain.map(id=>api<Mission[]>(`/api/control/missions?tag=${encodeURIComponent(`btw-parent:${id}`)}&all=true&limit=20`)));
  const seen=new Set<string>();
  for(const res of pages)if(Array.isArray(res))for(const m of res)if(m&&!seen.has(m.id)){seen.add(m.id);rows.push(m);}
 }catch{return {history:localHistory};}
 if(signal?.aborted||connectionVersion()!==version||!rows.length)return {history:localHistory};
 const valid=rows.filter(m=>m&&typeof m.id==='string'&&Array.isArray(m.tags)&&chain.some(id=>m.tags!.includes(`btw-parent:${id}`))&&!m.tags.includes('superseded'));
 if(!valid.length)return {history:localHistory};
 const sorted=[...valid].sort((a,b)=>(a.created_at||'').localeCompare(b.created_at||''));
 // Load newest/active threads first with bounded concurrency and memoize
 // terminal threads so older multi-page /btw logs never delay live recovery.
 const byId=new Map<string,Omit<ParsedBtwThread,'stamp'>>();
 const prioritized=[...sorted].sort((a,b)=>{
  const aLive=ACTIVE.includes(a.status)?1:0,bLive=ACTIVE.includes(b.status)?1:0;
  return bLive-aLive||btwActivity(b).localeCompare(btwActivity(a));
 });
 let cursor=0;
 await Promise.all(Array.from({length:Math.min(4,prioritized.length)},async()=>{
  while(cursor<prioritized.length){
   const m=prioritized[cursor++];
   if(signal?.aborted||connectionVersion()!==version)return;
   const live=ACTIVE.includes(m.status);
   const cacheKey=`${version}:${m.id}`,stamp=`${btwActivity(m)}\u0000${m.status}`;
   if(!live){
    const hit=terminalThreadCache.get(cacheKey);
    if(hit&&hit.stamp===stamp){byId.set(m.id,hit);continue;}
   }else{
    terminalThreadCache.delete(cacheKey);
   }
   // History, not transcript: the streamed text repairs a truncated final (repairedFinal).
   let events:StoredEvent[];
   try{events=await getMissionEvents(m.id,{view:'history'});}catch{continue;}
   if(signal?.aborted||connectionVersion()!==version)return;
   const parsed=parseBtwThread(m,events);
   byId.set(m.id,parsed);
   if(!live){
    terminalThreadCache.set(cacheKey,{stamp,...parsed});
    while(terminalThreadCache.size>256){
     const oldest=terminalThreadCache.keys().next().value;
     if(oldest===undefined)break;
     terminalThreadCache.delete(oldest);
    }
   }
  }
 }));
 if(signal?.aborted||connectionVersion()!==version)return {history:localHistory};
 const serverTurns:(SideExchange&{at:string})[]=[];
 let latestActive:BtwSession|undefined;
 for(const m of sorted){
  const parsed=byId.get(m.id);
  if(!parsed)continue;
  serverTurns.push(...parsed.turns);
  if(parsed.active)latestActive=parsed.active;
 }
 // The newest thread is the one with the latest activity: each /btw question
 // re-dispatches a job on the same mission, so an old thread can be the live one.
 const latest=[...sorted].sort((a,b)=>btwActivity(a).localeCompare(btwActivity(b))).at(-1);
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
 // asked, newest last. A locally cached turn never outranks it: appending
 // cache-only rows after Core's put an old answer below the newest one.
 serverTurns.sort((a,b)=>a.at.localeCompare(b.at));
 const local=new Map(localHistory.map(h=>[h.question.trim()+'\u0000'+h.answer.trim(),h]));
 const merged:SideExchange[]=serverTurns.map(({at:_at,...turn})=>{const cached=local.get(turn.question.trim()+'\u0000'+turn.answer.trim());return cached?.attachments?{...turn,attachments:cached.attachments}:turn;});
 return {history:merged.slice(-BTW_HISTORY_LIMIT),activeSession:latestActive,latest:latest?.id};
}

/** Core before the fix of 2026-10-21 kept only an OpenCode closing line written
 * after a compaction ("Everything has been explained…", /btw 412e22b7 seq 422)
 * as the final message, while the turn's streamed text still held the answer.
 * When that streamed text ends with the final message and is much longer, it
 * is the reply; sideAnswer still separates its narration. */
export function repairedFinal(final:string,delta:string|undefined):string{
 const want=final.trim(),have=delta?.trim()??'';
 return want&&have.length>=want.length*3&&have.length-want.length>=200&&have.endsWith(want)?have:final;
}
