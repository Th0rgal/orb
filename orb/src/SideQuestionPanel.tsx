import { swallow } from "./log";
import {createStore, reconcile} from "solid-js/store";
import {NativeInteraction} from "./NativeInteraction";
import * as btwMod from "./btwAgent";
import {askBtwAgent,watchBtw,stopBtw,btwSession,btwActivities,btwItems,btwThoughts,isSyntheticRemoteAssistantNote,dropBtwQueuedCursor} from "./btwAgent";
import {streamMission} from "./stream";
import {btwConfig} from "./btwSettings";
import {AgentActivity} from "./AgentActivity";
import { Composer } from "./composer/Composer";
import type { DraftImage } from "./imageAttachments";
import { uploadToken, type UploadedFile } from "./uploads";
import { Portal } from 'solid-js/web';
import { useSidePanel } from './FilePanel';
import { createPinnedScroll } from './mission/pinnedScroll';
import { createEffect, createSignal, For, on, onCleanup, onMount, Show } from 'solid-js';
import { connectionVersion, sendMissionMessage, type QueuedMessage } from './api';
import { consumeSideQuestionOpenHint, readSideQuestion, peekSideQuestionOpen, writeSideQuestion, sideQuestionKey, BTW_HISTORY_LIMIT, type QueuedSideQuestion } from './sideQuestionStorage';
import { RemoteQueue, type PendingRemoteQueueItem, type RemoteQueueHandle } from './RemoteQueue';
import { QueuedMessages } from './QueuedMessages';
import { createQueuedEdit } from './queuedEdit';
import { queuedLocalMessages, sendQueuedNow } from './localMessageQueue';
import { messagePresentation } from './messagePresentation';
import { ErrorToast } from './toast';
import { usageTelemetry } from './usageTelemetry';
import { UserTurn, ThoughtSequence } from "./Transcript";
import { MdView } from './Markdown';
import { ErrorNotice } from './ErrorNotice';
import { remoteLog } from './remoteLog';
import { sideContext, sideAttachments, type SideAttachment, type SideExchange } from './sideQuestionClient';
import type { StreamItem } from './transcriptModel';
import * as Ic from './icons';
// A finished answer may already be in Core's history (a reconcile ran first).
function appendTurn(rows:SideExchange[],turn:SideExchange):SideExchange[]{
 const last=rows.at(-1);
 if(last&&last.question.trim()===turn.question.trim()&&last.answer.trim()===turn.answer.trim())return rows;
 return [...rows,turn].slice(-BTW_HISTORY_LIMIT);
}
export type SideQuestionsHandle={ask:(question:string,images?:DraftImage[],files?:UploadedFile[])=>Promise<boolean>;open:()=>void};
// Local side history stays separate from mission events and the main draft.
/** A conversation moved to another harness keeps its /btw tab: a new version
 * with no tab of its own starts from the nearest earlier version's. */
async function inheritSideQuestion(mission:string){
 let chain=[mission];
 try{if('btwThreadChain' in btwMod&&typeof btwMod.btwThreadChain==='function')chain=await btwMod.btwThreadChain(mission);}catch{}
 for(const id of chain.slice(1)){
  const saved=await readSideQuestion(sideQuestionKey(id));
  // Its pending turn belongs to that version's side agent.
  if(saved)return {...saved,pending:undefined};
 }
 return undefined;
}
export function SideQuestions(p:{mission:string;items:StreamItem[];ref:(handle:SideQuestionsHandle)=>void;onTransfer:(text:string)=>void;onOpenSession?:(id:string)=>void|Promise<void>}) {
 const side=useSidePanel();
 const key=()=>{connectionVersion();return sideQuestionKey(p.mission);};
 const [history,setHistory]=createSignal<SideExchange[]>([]),[open,setOpen]=createSignal(false),[busy,setBusy]=createSignal(false);
 const [turnId,setTurnId]=createSignal(crypto.randomUUID());
 const [preparing,setPreparing]=createSignal(false);
 const [runStatus,setRunStatus]=createSignal('');
 const [notSent,setNotSent]=createSignal(false);
 const [draftRevision,setDraftRevision]=createSignal<{text:string;append?:boolean}|undefined>();
 const [question,setQuestion]=createSignal(''),[answer,setAnswer]=createSignal(''),[narration,setNarration]=createSignal<string[]>([]),[draft,setDraft]=createSignal(''),[error,setError]=createSignal(''),[model,setModel]=createSignal('');
 let abort:AbortController|undefined;
 // Set while this panel itself is launching/answering a question.
 let asking=false;
 let launchAbort:AbortController|undefined;
 const pin=createPinnedScroll({key:()=>(open()?loadedKey():'')});
 // Sending explicitly returns to the latest turn, even after reading older replies.
 const revealSentQuestion=()=>pin.pin();
 // The thread opens at its end, like the main conversation, and follows
 // streaming and resizes through the shared pinned-scroll owner.
 let shown='';
 createEffect(()=>{answer();history();busy();btwActivities(p.mission).length;const now=open()?loadedKey():'';const opened=now!==shown;shown=now;
  if(!now)return;
  if(opened)pin.pin();
  else queueMicrotask(pin.scrollIfPinned);});
 const [storageError,setStorageError]=createSignal(false);
 const [queueToast,setQueueToast]=createSignal('');
 const [pendingAttachments,setPendingAttachments]=createSignal<SideAttachment[]>([]);
 // Fallback browser queue when `queueBtwFollowUp` is unavailable (legacy `/btw` SSE)
 // or when legacy entries from older builds are awaiting initial server reconciliation.
 const [queue,setQueue]=createSignal<QueuedSideQuestion[]>([]);
 const [sideSessionId,setSideSessionId]=createSignal('');
 const [sideSessionLocal,setSideSessionLocal]=createSignal(false);
 const [pendingQueued,setPendingQueued]=createSignal<PendingRemoteQueueItem[]>([]);
 const [confirmedQueued,setConfirmedQueued]=createSignal<(QueuedMessage&{attached?:boolean})[]>([]);
 const [deliveredQueuedIds,setDeliveredQueuedIds]=createSignal<string[]>([]);
 const [remoteQueuedIds,setRemoteQueuedIds]=createSignal<string[]>([]);
 const [handoffId,setHandoffId]=createSignal<string>();
 let remoteQueue:RemoteQueueHandle|undefined;
 const refreshSideSession=(missionId=p.mission,fallback?:ReturnType<typeof btwSession>)=>{
  const s=btwSession(missionId)??fallback;
  setSideSessionId(s?.id??'');
  setSideSessionLocal(Boolean(s?.local));
  return s;
 };
 const queuedEdit=createQueuedEdit({
  setRevision:rev=>setDraftRevision(rev),
  onError:msg=>setQueueToast(msg),
 });
 const editingQueued=()=>queuedEdit.editing();
 const hasQueueFollowUp=()=>{
  try{return 'queueBtwFollowUp' in btwMod&&typeof btwMod.queueBtwFollowUp==='function';}catch{return false;}
 };
 const sendNext=()=>{
  if(hasQueueFollowUp()||busy()||error())return;
  const next=queue()[0];if(!next)return;
  setQueue(rows=>rows.slice(1));
  void ask(next.question,[],[],next.attachments??[]);
 };
 const [loadedKey,setLoadedKey]=createSignal('');
 let ready:Promise<void>=Promise.resolve();
 let reconnectSession:(sideId:string)=>Promise<void>=async sideId=>{await p.onOpenSession?.(sideId);};
 let watchActiveSession:((agent:NonNullable<ReturnType<typeof btwSession>>,initialAttachments?:SideAttachment[])=>void)|undefined;
 createEffect(on(key,current=>{
  abort?.abort();queuedEdit.finish(true);
  setLoadedKey('');setBusy(false);setHistory([]);setError('');setQueue([]);setQueueToast('');
  setSideSessionId('');setSideSessionLocal(false);
  setPendingQueued([]);setConfirmedQueued([]);setDeliveredQueuedIds([]);setRemoteQueuedIds([]);setHandoffId(undefined);
  let stale=false;onCleanup(()=>{stale=true;});
  const missionId=p.mission;
  let resync:(()=>void)|undefined;
  let migratingLegacyQueue=false;
  let unmigratedLegacyQueue:QueuedSideQuestion[]=[];
  const markDelivered=(id?:string)=>{
   if(!id)return;
   setDeliveredQueuedIds(prev=>prev.includes(id)?prev:[...prev,id]);
   setPendingQueued(prev=>prev.filter(item=>item.id!==id));
   if(handoffId()===id)setHandoffId(undefined);
  };
  const watchActive=(agent:NonNullable<ReturnType<typeof btwSession>>,initialAttachments?:SideAttachment[])=>{
   refreshSideSession(missionId,agent);
   abort?.abort();
   const controller=new AbortController();abort=controller;setBusy(true);setQuestion(agent.question);setAnswer('');setNarration([]);setError('');setNotSent(false);
   if(initialAttachments)setPendingAttachments(initialAttachments);
   let currentQuestion=agent.question;
   let currentAttachments=initialAttachments;
   void watchBtw(missionId,controller.signal,event=>{
    if(stale||controller.signal.aborted)return;
    if(event.type==='start'){setModel(event.model);setRunStatus('Starting side agent…');}
    if(event.type==='status')setRunStatus(event.text);
    if(event.type==='snapshot'){setAnswer(event.text);setNarration(event.narration??[]);}
    if(event.type==='turn'){
     if(event.completed){
      const doneTurn=event.completed;
      setHistory(rows=>rows.some(row=>row.answer.trim()===doneTurn.answer.trim()&&row.question.trim()===doneTurn.question.trim())?rows:appendTurn(rows,{id:turnId(),question:doneTurn.question,answer:doneTurn.answer,...(doneTurn.narration?.length?{narration:doneTurn.narration}:{}),...(currentAttachments?.length?{attachments:currentAttachments}:{})}));
     }
     currentQuestion=event.question;
     currentAttachments=undefined;
     markDelivered(event.messageId);
     setTurnId((event.messageId as ReturnType<typeof crypto.randomUUID>)??crypto.randomUUID());
     setQuestion(event.question);setAnswer('');setNarration([]);setError('');setNotSent(false);setPendingAttachments([]);
     setRunStatus('Starting side agent…');
     refreshSideSession(missionId);
    }
    if(event.type==='done'){
     // A restored session can name an older question than the answer Core
     // finished; never pair them, and let Core's history settle the turn.
     const narrated=event.narration?.length?{narration:event.narration}:{};
     const attached=currentAttachments?.length?{attachments:currentAttachments}:{};
     setHistory(rows=>rows.some(row=>row.answer.trim()===event.answer.trim()&&row.question.trim()===currentQuestion.trim())?rows:appendTurn(rows,{id:turnId(),question:currentQuestion,answer:event.answer,...narrated,...attached}));
     setBusy(false);setRunStatus('');setQuestion('');setAnswer('');setNarration([]);setPendingAttachments([]);setTurnId(crypto.randomUUID());resync?.();
     if(remoteQueuedIds().length){setTimeout(()=>{if(!stale)resync?.();},350);}
     queueMicrotask(sendNext);}
   }).catch(e=>{
    if(stale||controller.signal.aborted)return;
    if(handoffId()){
     // Send-now interrupted the active turn to promote a queued follow-up;
     // re-sync immediately instead of surfacing a transient interruption banner.
     setBusy(true);setRunStatus('Starting side agent…');setError('');
     setTimeout(()=>{if(!stale)resync?.();},250);
     return;
    }
    setError(e instanceof Error?e.message:String(e));setBusy(false);
   });
  };
  watchActiveSession=watchActive;
  reconnectSession=async(sideId:string)=>{
   if(p.onOpenSession){await p.onOpenSession(sideId);return;}
   const unsent=question().trim();
   let reconnectFn:typeof btwMod.reconnectBtwSession|undefined;
   try{if('reconnectBtwSession' in btwMod)reconnectFn=btwMod.reconnectBtwSession;}catch{}
   const session=typeof reconnectFn==='function'?await reconnectFn(missionId,sideId):undefined;
   if(stale||key()!==current)return;
   setError('');setNotSent(false);setQuestion('');setAnswer('');setNarration([]);setPendingAttachments([]);
   if(unsent&&!draft().trim())setDraftRevision({text:unsent});
   if(session?.active)watchActive(session);
   resync?.();
  };
  if(peekSideQuestionOpen(current)){setOpen(true);side?.show();}
  ready=readSideQuestion(current).then(saved=>{
  if(stale)return;
  const shouldOpen=consumeSideQuestionOpenHint(current)||Boolean(saved?.open);
  const cleanHistory=(saved?.history??[]).filter(row=>!isSyntheticRemoteAssistantNote(row.answer)).map(row=>({...row,id:row.id??crypto.randomUUID()}));
  setHistory(cleanHistory);setBusy(false);setOpen(shouldOpen);
  setQuestion(saved?.pending?.question??'');
  setAnswer(saved?.pending?.answer&&!isSyntheticRemoteAssistantNote(saved.pending.answer)?saved.pending.answer:'');
  let launching:Promise<void>|undefined;
  try{if('btwLaunchPending' in btwMod&&typeof btwMod.btwLaunchPending==='function')launching=btwMod.btwLaunchPending(missionId);}catch{}
  let reconcileServer:typeof btwMod.reconcileBtwServerHistory|undefined;
  try{if('reconcileBtwServerHistory' in btwMod)reconcileServer=btwMod.reconcileBtwServerHistory;}catch{}
  const hasReconcile=typeof reconcileServer==='function';
  const interruptedError='Side question interrupted. Retry to request a complete answer.';
  const rawSavedError=saved?.pending?.error||'';
  const normalizedSavedError=rawSavedError.includes('Check its activity for tool errors')&&btwActivities(missionId).length===0
   ? rawSavedError.replace('Check its activity for tool errors, then retry.','The model returned an empty completion without running any tools; retry to start a clean side session.')
   : rawSavedError;
  setError(saved?.pending&&!launching?(normalizedSavedError||(hasReconcile?'':interruptedError)):'');
  setNotSent(!!saved?.pending?.notSent&&!launching);
  // Retry after a restart resends under the same id, so Core can drop a copy.
  if(saved?.pending?.turnId)setTurnId(saved.pending.turnId as ReturnType<typeof crypto.randomUUID>);
  setPendingAttachments(saved?.pending?.attachments??[]);setDraft(saved?.draft??'');setModel(saved?.model??'');setStorageError(false);
  const legacySavedQueue=saved?.queue??[];
  unmigratedLegacyQueue=hasReconcile&&hasQueueFollowUp()?[...legacySavedQueue]:[];
  setQueue(legacySavedQueue);
  const agent=refreshSideSession(missionId);
  const lastSaved=saved?.history.at(-1);
  const lastAnswer=lastSaved?.answer;
  const emptyReply=lastAnswer!==undefined&&(lastAnswer==='The side agent finished without a text response.'||!lastAnswer.replace(/[.\s…]/g,''));
  const syntheticReply=lastAnswer!==undefined&&isSyntheticRemoteAssistantNote(lastAnswer)&&!saved?.pending;
  if(emptyReply){setHistory(rows=>rows.slice(0,-1));setQuestion(lastSaved!.question);setAnswer('');setNarration([]);}
  if(syntheticReply){setQuestion(lastSaved!.question);setAnswer('');setNarration([]);if(!agent?.active)setError('Side question was interrupted before the agent answered. Retry to request a complete answer.');}
  let awaitingServerPending=false;
  if(launching){
   setBusy(true);setRunStatus('Starting side agent…');
   void launching.then(()=>{
    if(stale||key()!==current)return;
    const launched=btwSession(missionId);
    if(launched?.active)watchActive(launched);
    else{setBusy(false);setError(interruptedError);}
   });
  }else if(agent&&(agent.active||emptyReply)){
   watchActive(agent);
  }else if(saved?.pending&&!normalizedSavedError&&hasReconcile){
   // An in-flight side turn runs on Core across panel unmounts and mission switches;
   // reconcile with Core before claiming the answer was interrupted.
   awaitingServerPending=true;
   setBusy(true);setRunStatus('Reconnecting…');
  }
  setLoadedKey(current);
  // Never delay the tab for it: a fork's earlier history fills an empty tab when it arrives.
  if(!saved)void inheritSideQuestion(missionId).then(earlier=>{if(!stale&&key()===current&&earlier&&!history().length&&!busy())setHistory(earlier.history.filter(row=>!isSyntheticRemoteAssistantNote(row.answer)).map(row=>({...row,id:row.id??crypto.randomUUID()})));});
  if(shouldOpen)queueMicrotask(()=>{if(loadedKey()===current)side?.show();});
  if(hasReconcile){
   const reconcile=reconcileServer!;
   // The newest thread stays live while the tab is open: a question asked on
   // a completed thread (another device, a restart) re-dispatches a job on
   // that same mission, and its answer must show without reopening the tab.
   let following='',stopFollow:(()=>void)|undefined,again:ReturnType<typeof setTimeout>|undefined;
   let inFlight=0;
   // The live stream can sit on a dead cursor (sleep, proxy, reconnect):
   // re-read Core periodically so the newest turns always arrive without overlapping slow reads.
   const poll=setInterval(()=>{if(!stale&&inFlight===0&&document.visibilityState!=='hidden')sync(history());},15000);
   onCleanup(()=>{stopFollow?.();clearTimeout(again);clearInterval(poll);});
   const follow=(id:string|undefined)=>{
    if(!id||id===following||stale)return;
    stopFollow?.();following=id;
    stopFollow=streamMission(id,event=>{
     if(!['user_message','assistant_message','assistant_message_canonical','mission_status_changed'].includes(event.type))return;
     clearTimeout(again);again=setTimeout(()=>{if(!stale)sync(history());},300);
    },()=>{if(!stale)sync(history());});
   };
   let generation=0;
   // Only the newest read applies: an older, slower one never rolls back history.
   const sync=(local:Parameters<typeof reconcile>[1])=>{
    const mine=++generation;inFlight++;
    void reconcile(missionId,local).then(reconciled=>{
     if(stale||key()!==current||mine!==generation)return;
     if(reconciled.latest)setSideSessionId(prev=>prev||reconciled.latest!);
     refreshSideSession(missionId,reconciled.activeSession);
     follow(reconciled.latest);
     const changed=reconciled.history.length!==history().length||reconciled.history.some((row,i)=>row.question!==history()[i]?.question||row.answer!==history()[i]?.answer);
     if(changed)setHistory(reconciled.history);
     if(!migratingLegacyQueue&&unmigratedLegacyQueue.length&&hasQueueFollowUp()){
      const answered=new Set(reconciled.history.map(h=>h.question.trim()));
      if(reconciled.activeSession?.question)answered.add(reconciled.activeSession.question.trim());
      unmigratedLegacyQueue=unmigratedLegacyQueue.filter(item=>item.question.trim()&&!answered.has(item.question.trim()));
      const remainingIds=new Set(unmigratedLegacyQueue.map(item=>item.id));
      setQueue(rows=>rows.filter(r=>remainingIds.has(r.id)));
      if(unmigratedLegacyQueue.length){
       migratingLegacyQueue=true;
       const batch=[...unmigratedLegacyQueue];
       void (async()=>{
        try{
         for(const item of batch){
          if(stale||key()!==current)break;
          const ok=await ask(item.question,[],[],item.attachments??[],false,item.id as ReturnType<typeof crypto.randomUUID>).catch(()=>false);
          if(ok){
           unmigratedLegacyQueue=unmigratedLegacyQueue.filter(r=>r.id!==item.id);
           setQueue(rows=>rows.filter(r=>r.id!==item.id));
          }
         }
        }finally{
         migratingLegacyQueue=false;
        }
       })();
      }
     }
     const pendingQ=question().trim();
     if(pendingQ&&error()&&reconciled.history.some(h=>h.question.trim()===pendingQ)){
      setError('');setNotSent(false);setQuestion('');setAnswer('');setNarration([]);
     }
     // A restored pending turn ("Starting side agent…" or "Reconnecting…") that
     // Core has since answered is finished: show Core's answer instead of a stale spinner.
     if(pendingQ&&busy()&&!asking&&!reconciled.activeSession&&reconciled.history.some(h=>h.question.trim()===pendingQ)){
      awaitingServerPending=false;
      abort?.abort();setBusy(false);setRunStatus('');setQuestion('');setAnswer('');setNarration([]);setTurnId(crypto.randomUUID());
      queueMicrotask(sendNext);
     }
     if(reconciled.activeSession&&(!busy()||(awaitingServerPending&&!asking)||handoffId())){
      awaitingServerPending=false;
      setHandoffId(undefined);
      watchActive(reconciled.activeSession);
     }else if(awaitingServerPending&&!asking&&!reconciled.activeSession){
      awaitingServerPending=false;
      setBusy(false);setRunStatus('');setError(interruptedError);
     }
    }).catch(e=>{
     if(!stale&&key()===current&&mine===generation&&awaitingServerPending&&!asking){
      awaitingServerPending=false;
      setBusy(false);setRunStatus('');setError(interruptedError);
     }
     swallow("sideQuestions.reconcile")(e);
    }).finally(()=>{inFlight=Math.max(0,inFlight-1);});
   };
   resync=()=>{if(!stale)sync(history());};
   sync(cleanHistory);
  }
  });
 }));
 createEffect(()=>{
  const current=key();
  const snapshot={history:history(),draft:draft(),model:model(),open:side?side.visible():open(),docked:true,
    pending:(busy()||error())?{question:question(),answer:answer(),error:error(),attachments:pendingAttachments(),turnId:turnId(),...(notSent()?{notSent:true}:{})}:undefined,
    queue:queue()};
  if(loadedKey()===current)void writeSideQuestion(current,snapshot).then(saved=>{if(key()===current)setStorageError(!saved);});
 });
 side?.register(()=>setOpen(true));
 onCleanup(()=>{abort?.abort();side?.register(undefined);});
 function observeBtwDock(el:HTMLDivElement){
  const update=()=>{
   const h=el.getBoundingClientRect().height;
   if(h>0)el.parentElement?.style.setProperty('--btw-dock-height',`${Math.ceil(h)}px`);
  };
  if(typeof ResizeObserver==='undefined'){queueMicrotask(update);return;}
  const observer=new ResizeObserver(update);
  queueMicrotask(()=>{update();observer.observe(el);});
  onCleanup(()=>{observer.disconnect();el.parentElement?.style.removeProperty('--btw-dock-height');});
 }
 const submitQueuedFollowUp=async(
  text:string,
  images:DraftImage[],
  files:UploadedFile[],
  retryAttachments:SideAttachment[]|undefined,
  clientMessageId:ReturnType<typeof crypto.randomUUID>=crypto.randomUUID(),
  replace=false,
 )=>{
  const selected=key(),missionId=p.mission;
  const attachments=retryAttachments??await sideAttachments(images,files);
  if(selected!==key())return false;
  for(const file of files)text=text.replaceAll(uploadToken(file.path),`[File: ${file.source.name}]`);
  if(!hasQueueFollowUp()){
   setQueue(rows=>[...rows,{id:clientMessageId,question:text,attachments}].slice(0,20));
   setOpen(true);side?.show();setDraft('');
   revealSentQuestion();
   return true;
  }
  const queueFn=btwMod.queueBtwFollowUp;
  if(!replace){
   setPendingQueued(rows=>[...rows,{id:clientMessageId,content:text,attached:attachments.length>0||undefined}]);
  }
  setOpen(true);side?.show();setDraft('');
  revealSentQuestion();
  try{
   const res=await queueFn(missionId,text,sideContext(p.items,true),history(),attachments,clientMessageId,replace);
   if(selected!==key())return true;
   setSideSessionId(res.missionId);
   setSideSessionLocal(res.local);
   setPendingQueued(rows=>rows.filter(r=>r.id!==clientMessageId));
   if(!res.local){
    if(res.queued){
     setConfirmedQueued(rows=>[...rows.filter(r=>r.id!==res.id),{id:res.id,content:res.prompt,attached:attachments.length>0||undefined}]);
    }else{
     // The running turn finished right before Core admitted our message, so Core started this turn immediately.
     setDeliveredQueuedIds(rows=>rows.includes(res.id)?rows:[...rows,res.id]);
     const active={...(refreshSideSession(missionId)??{id:res.missionId,question:text,harness:btwConfig().harness,model:btwConfig().model,local:false,active:true,baseline:0}),question:text,active:true};
     setTurnId(res.id as ReturnType<typeof crypto.randomUUID>);
     watchActiveSession?.(active,attachments);
    }
   }
   return true;
  }catch(e){
   setPendingQueued(rows=>rows.filter(r=>r.id!==clientMessageId));
   if(selected===key())setQueueToast(e instanceof Error?e.message:String(e));
   return false;
  }
 };
 const ask=async(text:string,images:DraftImage[]=[],files:UploadedFile[]=[],retryAttachments?:SideAttachment[],retryTurn=false,clientMessageId?:ReturnType<typeof crypto.randomUUID>)=>{
  text=text.trim();if(!text)return false;
  const selected=key();await ready;if(selected!==key())return false;
  if(busy()){
   return submitQueuedFollowUp(text,images,files,retryAttachments,clientMessageId);
  }
  if(clientMessageId)setTurnId(clientMessageId);
  else if(!preparing()&&!retryTurn)setTurnId(crypto.randomUUID());
  setPreparing(false);
  const current=key(),missionId=p.mission,activeTurnId=turnId(),context=sideContext(p.items,true),controller=new AbortController(),launchController=new AbortController();abort=controller;launchAbort=launchController;
  let attachments:SideAttachment[];
  setBusy(true);setRunStatus('Sending…');
  try { attachments=retryAttachments??await sideAttachments(images,files); }
  catch(e){setBusy(false);setRunStatus('');throw e;}
  if(launchController.signal.aborted)return false;
  for(const file of files)text=text.replaceAll(uploadToken(file.path),`[File: ${file.source.name}]`);
  if(current===key()){
   setPendingAttachments(attachments);
   setOpen(true);side?.show();setBusy(true);setQuestion(text);setAnswer('');setNarration([]);setError('');setNotSent(false);setDraft('');
   revealSentQuestion();
  }
  asking=true;
  let currentQuestion=text;
  void askBtwAgent(missionId,text,context,history(),controller.signal,event=>{
   if(current!==key()||controller.signal.aborted)return;
   refreshSideSession(missionId);
   if(event.type==='start'){setModel(event.model);setRunStatus('Starting side agent…');}
   if(event.type==='status')setRunStatus(event.text);
   if(event.type==='snapshot'){setAnswer(event.text);setNarration(event.narration??[]);}
   if(event.type==='delta')setAnswer(value=>value+event.text);
   if(event.type==='turn'){
    if(event.completed){
     const doneTurn=event.completed;
     setHistory(rows=>rows.some(row=>row.answer.trim()===doneTurn.answer.trim()&&row.question.trim()===doneTurn.question.trim())?rows:appendTurn(rows,{id:turnId(),question:doneTurn.question,answer:doneTurn.answer,...(doneTurn.narration?.length?{narration:doneTurn.narration}:{})}));
    }
    currentQuestion=event.question;
    if(event.messageId){
     setDeliveredQueuedIds(prev=>prev.includes(event.messageId!)?prev:[...prev,event.messageId!]);
     setPendingQueued(prev=>prev.filter(item=>item.id!==event.messageId));
     if(handoffId()===event.messageId)setHandoffId(undefined);
     setTurnId(event.messageId as ReturnType<typeof crypto.randomUUID>);
    }else setTurnId(crypto.randomUUID());
    setQuestion(event.question);setAnswer('');setNarration([]);setError('');setNotSent(false);setPendingAttachments([]);
    setRunStatus('Starting side agent…');
   }
   if(event.type==='done'){
    setAnswer(event.answer);setNarration(event.narration??[]);
    const next=appendTurn(history(),{id:turnId(),question:currentQuestion,answer:event.answer,...(event.narration?.length?{narration:event.narration}:{}),...(currentQuestion===text?{attachments}:{})});
    setHistory(next);setBusy(false);setRunStatus('');
   }
  },attachments,launchController.signal,activeTurnId).catch(e=>{
   if(current!==key()||controller.signal.aborted)return;
   if(handoffId())return;
   setNotSent((e as {notSent?:unknown})?.notSent===true);setError(e instanceof Error?e.message:String(e));
  })
  .finally(()=>{
   if(abort===controller)asking=false;
   refreshSideSession(missionId);
   if(current===key()&&abort===controller&&!handoffId()){setBusy(false);setRunStatus('');queueMicrotask(sendNext);}
  });
  return true;
 };
 const sendSideImmediate=async(
  ordered:{id:string;content:string;attached?:boolean}[],
  liveInjected?:{id:string;content:string;attached?:boolean}[],
 )=>{
  const targetId=sideSessionId()||btwSession(p.mission)?.id;
  if(!targetId)return;
  if(liveInjected?.length){
   const first=liveInjected[0];
   setHandoffId(first.id);
   setConfirmedQueued(rows=>rows.filter(r=>r.id!==first.id));
   return;
  }
  if(!ordered.length)return;
  const first=ordered[0];
  setHandoffId(first.id);
  abort?.abort();
  await stopBtw(p.mission).catch(swallow("sideQuestions.stopForSendNow"));
  for(const row of ordered){
   await sendMissionMessage(targetId,row.content,undefined,row.id).catch(e=>setQueueToast(e instanceof Error?e.message:String(e)));
  }
  const presented=messagePresentation(first.content).text;
  setTurnId(first.id as ReturnType<typeof crypto.randomUUID>);
  setBusy(true);setQuestion(presented);setAnswer('');setNarration([]);setError('');setNotSent(false);setRunStatus('Starting side agent…');
 };
 const sendQueueFromSideComposer=()=>{
  if(editingQueued())return;
  if(sideSessionLocal()){
   const id=sideSessionId();
   const next=id?queuedLocalMessages(id).find(row=>row.waiting&&row.state==='queued'):undefined;
   if(next&&id)void sendQueuedNow(id,next.id).catch(e=>setQueueToast(e instanceof Error?e.message:String(e)));
   return;
  }
  if(remoteQueue?.hasQueued())void remoteQueue.sendNow();
 };
 const editFirstSideQueued=()=>{
  if(editingQueued())return;
  if(sideSessionLocal()){
   const id=sideSessionId();
   const first=id?queuedLocalMessages(id).find(row=>row.waiting&&row.state==='queued'):undefined;
   if(first)void queuedEdit.start({id:first.id,text:first.text});
   return;
  }
  remoteQueue?.editFirst();
 };
 const reveal=()=>{setOpen(true);side?.show({focus:true});};
 p.ref({ask,open:reveal});
 const escape=(event:KeyboardEvent)=>{
  if(event.key==='Escape'&&!event.defaultPrevented&&open()&&!side){
   event.preventDefault();setOpen(false);
  }
 };
 onMount(()=>window.addEventListener('keydown',escape));
 onCleanup(()=>window.removeEventListener('keydown',escape));
 const cancel=()=>{launchAbort?.abort();void stopBtw(p.mission).then(()=>{abort?.abort();setConfirmedQueued([]);setPendingQueued([]);setBusy(false);setRunStatus('');setError('Side agent stopped.');}).catch(e=>setError(String(e)));};
 const retry=()=>{const asked=question(),files=pendingAttachments();void ask(asked,[],[],files,true);};
 const dismiss=()=>{setError('');setNotSent(false);setQuestion('');setAnswer('');setNarration([]);setPendingAttachments([]);queueMicrotask(sendNext);};
 // Reconcile the same turn through preparation, streaming and persistence.
 const [turns,setTurns]=createStore<Array<SideExchange & {id:string;pending?:boolean;error?:string}>>([]);
 createEffect(()=>{
  const rows=history().map((row,index)=>({...row,id:row.id??`saved:${loadedKey()}:${index}`}));
  if((preparing()||busy()||error())&&!rows.some(row=>row.id===turnId()))rows.push({id:turnId(),question:question(),answer:answer(),narration:narration(),attachments:pendingAttachments(),pending:preparing()||busy(),error:error()} as typeof rows[number]);
  setTurns(reconcile(rows,{key:'id'}));
 });
 const prepareSend=(draft:{text:string}|null)=>{
  if(!draft){setPreparing(false);return;}
  if(busy()||editingQueued())return;
  setTurnId(crypto.randomUUID());setQuestion(draft.text);setAnswer('');setNarration([]);setError('');setPreparing(true);
  setOpen(true);side?.show();revealSentQuestion();
 };
 let inline!:HTMLDivElement;
 // Keep a live stage and elapsed time visible throughout an active turn, even after partial text streams.
 const [elapsed,setElapsed]=createSignal(0);
 createEffect(on(busy,b=>{setElapsed(0);if(!b)return;const started=Date.now(),t=setInterval(()=>setElapsed(Math.floor((Date.now()-started)/1000)),1000);onCleanup(()=>clearInterval(t));}));
 return <>
  <div ref={inline}/>
  <Show when={!side&&!open()&&(history().length||busy()||error())}><button class="btw-reopen" onClick={reveal}>Side questions {busy()?'· Answering…':`· ${history().length}`}</button></Show>
  <Show when={open()}><Portal mount={side ? side.target() : inline}><section class="btw-panel" aria-label="Side questions">
   <header><div><strong>Side question</strong></div><div class="btw-actions"><button class="icon-btn" aria-label="Close side questions" onClick={()=>{setOpen(false);side?.hide();}}><Ic.CloseIcon size={16}/></button></div></header>
   <div class="btw-thread" ref={pin.ref} onScroll={pin.onScroll}>
    <For each={turns}>{exchange=>{
     const content=()=>remoteLog(exchange.answer);
     return <article data-side-turn={exchange.id}>
     <UserTurn text={exchange.question} pending={exchange.pending&&!exchange.answer} onSend={text=>ask(text,[],[],exchange.attachments??[])}/>
     <Show when={exchange.pending}><ThoughtSequence items={btwThoughts(p.mission)}/></Show>
     <Show when={exchange.narration?.length}><details class="btw-narration"><summary>{exchange.narration!.length===1?'1 progress update':`${exchange.narration!.length} progress updates`}</summary><For each={exchange.narration}>{note=><MdView compact text={note}/>}</For></details></Show>
     <Show when={content().text}><MdView compact searchable text={content().text}/></Show>
     <Show when={content().details}><details class="legacy-log"><summary>Original execution log</summary><pre>{content().details}</pre></details></Show>
     <Show when={exchange.pending}><p class="sr-only" role="status">{preparing()?'Sending…':'Side agent is working…'}</p></Show>
     <Show when={exchange.error}><ErrorNotice error={exchange.error!} title={notSent()?"Question not sent":"Couldn’t complete side question"}><button type="button" class="error-notice-link" onClick={retry} disabled={busy()}>Retry</button><button type="button" class="error-notice-link" onClick={dismiss} disabled={busy()}>Dismiss</button><Show when={exchange.error?.match(/A side agent is already queued or running for this conversation \(([0-9a-f-]{36})\)/)?.[1]}>{id=><button type="button" class="error-notice-link" onClick={()=>{void Promise.resolve(reconnectSession(id())).catch(e=>setError(String(e)));}}>Open existing side agent</button>}</Show></ErrorNotice></Show>
     <Show when={!exchange.pending&&!exchange.error}><button class="btw-transfer" onClick={()=>p.onTransfer(`About this side question: ${exchange.question}\n\n${content().text||exchange.answer}`)}>Use in agent draft ↗</button></Show>
    </article>;}}</For>
    <Show when={queue().length&&!hasQueueFollowUp()}><section class="followup-queue btw-queue" aria-label="Queued side questions" aria-live="polite">
     <header><span class="queue-count">{queue().length} Queued</span></header>
     <ol><For each={queue()}>{row=><li class="queue-row"><div class="queue-line"><span class="queue-text" title={row.question}>{row.question}</span><span class="queue-row-actions"><button type="button" title="Remove" aria-label={`Remove queued side question: ${row.question}`} onClick={()=>setQueue(rows=>rows.filter(other=>other.id!==row.id))}><Ic.TrashIcon size={14}/></button></span></div></li>}</For></ol>
    </section></Show>
    <Show when={!history().length&&!question()}><p class="dim">Ask a question or give the side agent a task. It shares the main agent’s workspace.</p></Show>
    <Show when={busy()}><p class="dim btw-progress" role="status">{
      // Queue states ("Waiting to start…") are stale once the side agent has acted.
      btwActivities(p.mission).some(a => a.kind !== "status" && a.id !== "antigravity:status") || answer() || narration().length ? "Working…" : runStatus() || "Thinking…"
    }<Show when={elapsed() >= 3}> · {elapsed()} s</Show></p></Show>
    <AgentActivity items={btwActivities(p.mission)} running={busy()} completed={!busy() && !error()}/>
    <Show when={btwSession(p.mission) && busy()}><NativeInteraction mission={btwSession(p.mission)!.id} active={busy()} remote={!btwSession(p.mission)!.local} items={btwItems(p.mission)}/></Show>
   </div>
   <Show when={storageError()}><p class="dim" role="status">Local storage is unavailable. This side conversation may be lost on refresh.</p></Show>
   <div class="btw-composer-dock" ref={observeBtwDock}>
    <Show when={hasQueueFollowUp()&&(sideSessionId()||pendingQueued().length)}>
     <Show when={!sideSessionLocal()} fallback={
      <QueuedMessages
       mission={sideSessionId()}
       editing={editingQueued()}
       pending={!editingQueued()?pendingQueued().map(item=>({id:item.id,text:item.content})):undefined}
       onCancel={id=>dropBtwQueuedCursor(p.mission,id)}
       onCancelPending={id=>{dropBtwQueuedCursor(p.mission,id);setPendingQueued(rows=>rows.filter(r=>r.id!==id));}}
       onEdit={row=>void queuedEdit.start(row)}
      />
     }>
      <RemoteQueue
       mission={sideSessionId()}
       ref={handle=>remoteQueue=handle}
       editing={editingQueued()}
       onEdit={row=>void queuedEdit.start(row)}
       onSendImmediate={sendSideImmediate}
       pending={!editingQueued()?pendingQueued():undefined}
       confirmed={confirmedQueued()}
       delivered={deliveredQueuedIds()}
       onRetract={id=>{if(handoffId()===id)setHandoffId(undefined);}}
       onSendNowAccepted={(id,live)=>{if(live&&handoffId()===id)setHandoffId(undefined);}}
       onEdited={(id,content)=>setConfirmedQueued(rows=>rows.map(r=>r.id===id?{...r,content}:r))}
       onRows={setRemoteQueuedIds}
       onRemove={id=>dropBtwQueuedCursor(p.mission,id)}
       onCancel={id=>{
        setConfirmedQueued(rows=>rows.filter(r=>r.id!==id));
        setPendingQueued(rows=>rows.filter(r=>r.id!==id));
       }}
      />
     </Show>
    </Show>
    <Composer
     allowConcurrentSend
     sideQuestion
     revision={draftRevision()}
     onPending={prepareSend}
     picker={false}
     placeholder={busy()?"Queue a side question…":"Ask a side question…"}
     busy={busy()}
     scope={key()}
     uploadTarget="side"
     editingQueued={editingQueued()?{onCancel:()=>queuedEdit.finish(true)}:undefined}
     onEmptySubmit={sendQueueFromSideComposer}
     onEditFirstQueued={editFirstSideQueued}
     onDraft={val=>{setDraft(val);queuedEdit.trackDraft(val);}}
     onSend={async(text,images,files)=>{
      const id=editingQueued();
      if(!id)return ask(text,images,files);
      usageTelemetry.action('message_edit','queue');
      if(queuedEdit.editingRemote()&&remoteQueue){
       const queueRef=remoteQueue;
       const edit=(images.length||files?.length)?Promise.resolve('unsupported' as const):queueRef.editInPlace(id,text);
       queuedEdit.finish(false);
       const result=await edit;
       if(result!=='unsupported')return true;
       return queueRef.replaceEdited(
        id,
        ()=>submitQueuedFollowUp(text,images,files??[],undefined),
        async after=>{
         for(const r of after){
          const target=sideSessionId()||btwSession(p.mission)?.id;
          if(target)await sendMissionMessage(target,r.content,undefined,crypto.randomUUID());
         }
        },
       );
      }
      const saved=await submitQueuedFollowUp(text,images,files??[],undefined,id as ReturnType<typeof crypto.randomUUID>,true);
      if(saved)queuedEdit.finish(false);
      return saved;
     }}
     onStop={cancel}
    />
    <ErrorToast error={queueToast()} title="Couldn’t queue side question" onDismiss={()=>setQueueToast('')} />
    <div class="btw-footer"><span class="btw-footer-tag">/btw</span><span class="under-sep" aria-hidden="true">·</span><span class="btw-footer-model" title="Independent agent sharing the main workspace">{model()||`${btwConfig().harness} · ${btwConfig().model}`}</span></div>
   </div>
  </section></Portal></Show>
 </>;
}
