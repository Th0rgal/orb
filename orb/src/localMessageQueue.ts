import {createSignal,batch} from 'solid-js';
import {mergeById} from './poll';
import {connectionVersion,getMission,reopenMission,appendClientTranscript,setClientMissionStatus} from './api';
import type {ClientRunReceipt} from './clientRuns';
import {readSideThread,saveSideThread} from './composerDrafts';
import {sideQuestionKey} from './sideQuestionStorage';
import {recoverLocalLaunch,recordLocalFailure,restoreLocalBindings,localBinding,pollLocal,reconcileLocalRun,startLocal,followLocal,stopLocal,type StartLocal,type PollLocal} from './localAgents';

export type QueuedLocalMessage={id:ReturnType<typeof crypto.randomUUID>;mission:string;text:string;request:StartLocal;state:'queued'|'dispatching'|'accepted'|'error';error?:string;interrupted?:boolean;autoResumed?:boolean;waiting?:boolean;receipt?:ClientRunReceipt;claimedAt?:number;userSynced?:boolean;result?:PollLocal;resultStatus?:'interrupted'|'failed'|'awaiting_user';resultId?:ReturnType<typeof crypto.randomUUID>};
const [entries,publishEntries]=createSignal<QueuedLocalMessage[]>([]);
// IndexedDB clones every read. Keep unchanged rows stable so the 1s worker
// heartbeat does not invalidate every mounted conversation and its markdown.
const setEntries=(rows:QueuedLocalMessage[])=>publishEntries(previous=>mergeById(previous,rows));
const [accepted,setAccepted]=createSignal<QueuedLocalMessage[]>([]);
export const queuedLocalMessages=(mission:string)=>entries().filter(row=>row.mission===mission);
export const acceptedLocalMessages=(mission:string)=>accepted().filter(row=>row.mission===mission);
export function forgetAcceptedLocalMessages(ids:Set<string>){setAccepted(rows=>rows.filter(row=>!ids.has(row.id)));}
const storageKey=()=>`followups:${sideQuestionKey('queue')}`;
const wakeEvent='orb:queue-wake';
const lostRun='Orb lost the local run. Your message is saved. Retry to resume it.';
/** The agent keeps its session: it is told what happened instead of being handed the request as new work. */
export const resumedPrompt=(prompt:string)=>`Orb restarted while you were working on the request below, so your previous turn was cut short. Check what is already done, then continue from there. Do not redo finished work.\n\n${prompt}`;
const wake=()=>window.dispatchEvent(new Event(wakeEvent));
async function locked<T>(key:string,action:()=>Promise<T>):Promise<T>{
 if(!navigator.locks)throw new Error('Update Orb to queue messages safely on this computer.');
 return navigator.locks.request(key,action);
}
async function read(key:string){return await readSideThread<QueuedLocalMessage[]>(key)??[];}
async function write(key:string,rows:QueuedLocalMessage[]){await saveSideThread(key,rows);if(key===storageKey())setEntries(rows);}
async function update(key:string,id:string,change:(row:QueuedLocalMessage)=>void){await locked(key,async()=>{const rows=await read(key);const row=rows.find(r=>r.id===id);if(row){change(row);await write(key,rows);}});}
export async function enqueueLocalMessage(request:StartLocal,text:string,options:{id?:ReturnType<typeof crypto.randomUUID>;waiting?:boolean}={}){
 const key=storageKey(),id=options.id??crypto.randomUUID();
 await locked(key,async()=>{const rows=await read(key);if(!rows.some(row=>row.id===id))rows.push({id,mission:request.id,text,request,state:'queued',waiting:options.waiting??true});await write(key,rows);});
 wake();return id;
}
export const canDiscardQueuedMessage=(row:QueuedLocalMessage)=>!['dispatching','accepted'].includes(row.state)||!!row.interrupted||(row.state==='dispatching'&&!!row.error);
/** An interrupted send is removable only after native recovery confirms it stopped.
 * Keep its receipt/output in the recovery archive; never discard a newer attempt. */
async function discardQueuedMessage(id:string):Promise<string|undefined>{
 const key=storageKey(),snapshot=(await read(key)).find(row=>row.id===id);
 if(!snapshot)return;
 if(!canDiscardQueuedMessage(snapshot))throw Error('This message has already been sent.');
 if(snapshot.interrupted||snapshot.state==='dispatching')await recoverLocalLaunch(snapshot.mission);
 const text=await locked(key,async()=>{
  if(key!==storageKey())throw Error('Connection changed. The message is still saved.');
  const rows=await read(key),row=rows.find(row=>row.id===id);
  if(!row)return;
  if(JSON.stringify(row)!==JSON.stringify(snapshot))throw Error('This message changed while checking the previous run. Try again.');
  if(row.receipt||row.result)await saveSideThread(`${key}:recovered:${row.id}:${row.receipt?.run_id??'unknown'}`,row);
  await write(key,rows.filter(row=>row.id!==id));
  return row.text;
 });
 wake();return text;
}
export async function removeQueuedMessage(id:string){await discardQueuedMessage(id);}
export async function takeQueuedMessage(id:string){
 const text=await discardQueuedMessage(id);
 if(text===undefined)throw Error('This message is no longer queued.');
 return text;
}
export async function retryQueuedMessage(id:string){
 const key=storageKey(),row=(await read(key)).find(row=>row.id===id);
 if(!row)return;
 if(row.interrupted||(row.state==='dispatching'&&row.error))await recoverLocalLaunch(row.mission);
 // Keep the previous attempt, including unsynced output, before a deliberate retry.
 if(row.receipt||row.result)await saveSideThread(`${key}:recovered:${row.id}:${row.receipt?.run_id??'unknown'}`,row);
 if(key!==storageKey())return;
 await update(key,id,stored=>{
  if(stored.state==='error'||(stored.state==='dispatching'&&stored.error)||(stored.state==='accepted'&&stored.interrupted)){
   stored.state='queued';delete stored.error;delete stored.interrupted;
   delete stored.receipt;delete stored.result;delete stored.resultId;delete stored.resultStatus;delete stored.userSynced;delete stored.claimedAt;
  }
 });
 wake();
}
const settling=new Map<string,Promise<void>>();
const stopping=new Set<string>();
export async function sendQueuedNow(mission:string){
 const key=storageKey(),runKey=`${key}:${mission}`;
 if(stopping.has(runKey))return;
 stopping.add(runKey);
 try {
  if(!(await read(key)).some(row=>row.mission===mission&&row.state==='queued'))return;
  // An idle/recovered conversation has nothing to stop. Only an explicit
  // missing-run response grants recovery; transport failures remain failures.
  let running = false;
  try { running = !(await pollLocal(mission)).done; }
  catch (error) { if (!/no local run/i.test(String(error))) throw error; }
  if (running) await stopLocal(mission);
  // The follower saves the partial answer before closing its run receipt.
  const follower=settling.get(runKey);
  if(follower)await follower;else await recoverLocalLaunch(mission);
 }finally{stopping.delete(runKey);wake();}
}
export function startLocalQueueWorker(){
 const key=storageKey(),version=connectionVersion();let stopped=false,busy=false,again=false;
 batch(()=>{setEntries([]);setAccepted([]);});
 const valid=()=>!stopped&&connectionVersion()===version&&storageKey()===key;
 async function persistResult(row:QueuedLocalMessage){
  if(!row.receipt)return;
  if(!row.userSynced){
   await appendClientTranscript(row.mission,'user',row.text,row.id,row.receipt);
   row.userSynced=true;
   await update(key,row.id,stored=>{stored.userSynced=true;});
  }
  if(row.result){
   if(row.result.text.trim())await appendClientTranscript(row.mission,'assistant',row.result.text,row.resultId,row.receipt);
   const failed=(row.result.exit_code!=null&&row.result.exit_code!==0)||!!row.result.error;
   recordLocalFailure(row.mission,failed?(row.result.error||`Local process exited with code ${row.result.exit_code}`):null);
   await setClientMissionStatus(row.mission,row.resultStatus??(failed?'failed':'awaiting_user'),row.receipt);
   if(!valid())return;
   await locked(key,async()=>{const rows=await read(key);const next=rows.filter(r=>r.id!==row.id);await saveSideThread(key,next);if(valid())batch(()=>{setAccepted(prev=>[...prev.filter(r=>r.id!==row.id),row]);setEntries(next);});});
   window.dispatchEvent(new Event('orb:refresh'));
  }
 }
 async function syncFailed(row:QueuedLocalMessage,error:unknown){
  if(!valid())return;
  // A closed receipt cannot become writable again. Keep its output and draft,
  // but require an explicit retry instead of looping or silently replaying work.
  const closed=/409.*Local execution (already ended or moved|receipt is stale)/i.test(String(error));
  await update(key,row.id,stored=>{
   if(closed){stored.state='error';stored.interrupted=true;stored.error='The previous run ended before syncing finished. Your message and any response are saved on this computer. Retry to continue the conversation.';}
   else stored.error=`Saved locally; could not finish syncing: ${String(error)}`;
  });
 }
 function follow(row:QueuedLocalMessage){
  const runKey=`${key}:${row.mission}`;if(settling.has(runKey))return;
  // Set once the run is settled or confirmed stopped: the queue may then look at this mission again.
  let finished=false;
  const promise=navigator.locks.request(`${runKey}:follow`,{ifAvailable:true},async lock=>{
   if(!lock)return;
   try {
    // Begin observing output immediately. A slow transcript write must not hide it.
    const output=followLocal(row.mission,()=>{});
    const userSync=Promise.resolve(appendClientTranscript(row.mission,'user',row.text,row.id,row.receipt)).then(async()=>{
     row.userSynced=true;
     await update(key,row.id,stored=>{stored.userSynced=true;});
    }).catch(()=>{});
    const result=await output;await userSync;if(!valid())return;
    row={...row,result,resultId:crypto.randomUUID(),resultStatus:stopping.has(runKey)?'interrupted':undefined};
    await update(key,row.id,stored=>{stored.result=result;stored.resultId=row.resultId;stored.resultStatus=row.resultStatus;});
    await persistResult(row);finished=true;
   }catch(error){
    if(!valid())return;
    if(/no local run/i.test(String(error))){
     let recovered=false;
     let detail=lostRun;
     try{await recoverLocalLaunch(row.mission);recovered=true;}
     catch(recovery){detail=`Orb lost the local run. Retry will check that the previous agent stopped. ${String(recovery)}`;}
     if(!valid())return;
     // A missing attachment or a held recovery lock is not evidence of mission failure.
     recordLocalFailure(row.mission,null);
     await update(key,row.id,stored=>{stored.interrupted=true;stored.error=detail;if(recovered)stored.state='error';});
     window.dispatchEvent(new Event('orb:refresh'));
     finished=recovered;
    }else await syncFailed(row,error);
   }
  }).then(()=>{}).finally(()=>{settling.delete(runKey);if(finished)wake();});settling.set(runKey,promise);
 }
 const tick=async()=>{
  if(!valid())return;if(busy){again=true;return;}busy=true;
  try {
   const rows=await read(key);if(!valid())return;setEntries(rows);if(!rows.length)return;
   await restoreLocalBindings();const seen=new Set<string>();
   for(const row of rows){
    if(!valid())return;if(seen.has(row.mission))continue;seen.add(row.mission);
    const runKey=`${key}:${row.mission}`;
    if(settling.has(runKey)||stopping.has(runKey))continue;
    if(row.interrupted){
     // The app restarted under a running turn and recovery confirmed that agent stopped.
     // Continue its session once without asking; a second loss waits for the user.
     if(row.state==='error'&&row.error===lostRun&&!row.autoResumed){
      if(row.receipt||row.result)await saveSideThread(`${key}:recovered:${row.id}:${row.receipt?.run_id??'unknown'}`,row);
      await update(key,row.id,stored=>{
       if(stored.state!=='error'||stored.error!==lostRun||stored.autoResumed)return;
       stored.state='queued';stored.autoResumed=true;delete stored.error;delete stored.interrupted;
       delete stored.receipt;delete stored.result;delete stored.resultId;delete stored.resultStatus;delete stored.userSynced;delete stored.claimedAt;
      });
      again=true;
     }
     continue;
    }
    if(row.state==='accepted'){
     if(row.result)await persistResult(row).catch(error=>syncFailed(row,error));else follow(row);
     continue;
    }
    if(row.state==='dispatching'&&!row.error&&Date.now()-(row.claimedAt??0)>30_000){
     await update(key,row.id,stored=>{
      if(stored.state==='dispatching'&&!stored.error)stored.error='Launch confirmation was lost. Check the previous run before retrying; this message will not be sent again automatically.';
     });
     continue;
    }
    if(row.state!=='queued')continue;
    const binding=localBinding(row.mission);if(!binding)continue;
    try {
     try{const native=await pollLocal(row.mission);if(!native.done){await reconcileLocalRun(row.mission);continue;}}catch(error){if(!/no local run/i.test(String(error)))throw error;}
     await reconcileLocalRun(row.mission);if(!valid())return;
     const mission=await getMission(row.mission);
     if(!mission.tags?.includes('placement:client')||binding.cwd!==row.request.cwd)throw Error('This conversation changed machines or folders. Remove this message and send it again.');
     if(['active','running','pending','starting','resuming'].includes(mission.status))continue;
     if(!valid())return;
     // Only the durable claim is locked: enqueue/cancel never waits for the network.
     const claimed=await locked(key,async()=>{const current=await read(key);const first=current.find(r=>r.mission===row.mission);if(first?.id!==row.id||first.state!=='queued'||!valid()||stopping.has(runKey))return false;first.state='dispatching';first.claimedAt=Date.now();await write(key,current);return true;});
     if(!claimed)continue;
     row.state='dispatching';
     // Sending a saved follow-up explicitly reopens an archived conversation.
     // Do this after claiming it so another window cannot dispatch the same draft.
     if(mission.status==='acknowledged'){
      try{await reopenMission(row.mission);}catch(error){
       await update(key,row.id,stored=>{stored.state='error';stored.error=String(error);});
       continue;
      }
      if(!valid())return;
     }
     const receipt=await startLocal({...row.request,prompt:row.autoResumed?resumedPrompt(row.request.prompt):row.request.prompt,sessionId:localBinding(row.mission)?.sessionId});
     row.state='accepted';row.receipt=receipt;
     await update(key,row.id,stored=>{stored.state='accepted';stored.receipt=receipt;delete stored.error;});
     follow(row);
    }catch(error){if(valid())await update(key,row.id,stored=>{if(stored.state==='queued'||/^Local launch rejected:/.test(error instanceof Error?error.message:String(error)))stored.state='error';stored.error=stored.state==='dispatching'?`Launch outcome uncertain. Retry will check that the previous run stopped. ${String(error)}`:String(error);});}
   }
  }catch{/* Durable entries stay available for the next attempt. */}
  finally{busy=false;if(again&&valid()){again=false;queueMicrotask(()=>void tick());}}
 };
 const onWake=()=>void tick();window.addEventListener(wakeEvent,onWake);void tick();// A queued row waits on a turn this window may not be following: look again on its own.
 const timer=setInterval(()=>{if(entries().some(row=>row.state==='queued'||row.state==='dispatching'||!!row.error))onWake();},30000);window.addEventListener('online',onWake);
 return ()=>{stopped=true;clearInterval(timer);window.removeEventListener(wakeEvent,onWake);window.removeEventListener('online',onWake);};
}
