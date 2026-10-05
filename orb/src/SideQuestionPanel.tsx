import {createStore, reconcile} from "solid-js/store";
import {NativeInteraction} from "./NativeInteraction";
import {askBtwAgent,watchBtw,stopBtw,btwSession,btwActivities,btwItems,btwThoughts} from "./btwAgent";
import {btwConfig} from "./btwSettings";
import {AgentActivity} from "./AgentActivity";
import { Composer } from "./App";
import type { DraftImage } from "./imageAttachments";
import { uploadToken, type UploadedFile } from "./uploads";
import { Portal } from 'solid-js/web';
import { useSidePanel } from './FilePanel';
import { createEffect, createSignal, For, on, onCleanup, onMount, Show } from 'solid-js';
import { connectionVersion } from './api';
import { readSideQuestion, writeSideQuestion, sideQuestionKey, type QueuedSideQuestion } from './sideQuestionStorage';
import { UserTurn, ThinkBlock } from "./Transcript";
import { MdView } from './Markdown';
import { askSide, sideContext, sideAttachments, type SideAttachment, type SideExchange } from './sideQuestionClient';
import type { StreamItem } from './transcriptModel';
import * as Ic from './icons';
export type SideQuestionsHandle={ask:(question:string,images?:DraftImage[],files?:UploadedFile[])=>Promise<boolean>;open:()=>void};
// Local side history stays separate from mission events and the main draft.
export function SideQuestions(p:{mission:string;items:StreamItem[];ref:(handle:SideQuestionsHandle)=>void;onTransfer:(text:string)=>void;onOpenSession?:(id:string)=>void|Promise<void>}) {
 const side=useSidePanel();
 const [docked,setDocked]=createSignal(false);
 const key=()=>{connectionVersion();return sideQuestionKey(p.mission);};
 const [history,setHistory]=createSignal<SideExchange[]>([]),[open,setOpen]=createSignal(false),[busy,setBusy]=createSignal(false);
 const [turnId,setTurnId]=createSignal(crypto.randomUUID());
 const [preparing,setPreparing]=createSignal(false);
 const [runStatus,setRunStatus]=createSignal('');
 const [question,setQuestion]=createSignal(''),[answer,setAnswer]=createSignal(''),[draft,setDraft]=createSignal(''),[error,setError]=createSignal(''),[model,setModel]=createSignal('');
 let abort:AbortController|undefined;
 let scroll:HTMLDivElement|undefined;
 // Sending explicitly returns to the latest turn, even after reading older replies.
 const revealSentQuestion=()=>{
  const current=key();
  requestAnimationFrame(()=>{if(current===key()&&scroll)scroll.scrollTop=scroll.scrollHeight;});
 };
 // The thread opens at its end, like the conversation, and follows new
 // text only while the reader is near the end.
 let shown='';
 createEffect(()=>{answer();history();const now=open()?loadedKey():'';const opened=now!==shown;shown=now;
  if(!scroll)return;const toEnd=()=>{if(scroll)scroll.scrollTop=scroll.scrollHeight;};
  if(opened)requestAnimationFrame(toEnd);
  else if(scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<120)queueMicrotask(toEnd);});
 const [storageError,setStorageError]=createSignal(false);
 const [pendingAttachments,setPendingAttachments]=createSignal<SideAttachment[]>([]);
 // Questions asked while the side agent answers wait here and are sent in
 // order, one per finished answer. An error keeps them until the retry.
 const [queue,setQueue]=createSignal<QueuedSideQuestion[]>([]);
 const sendNext=()=>{
  if(busy()||error())return;
  const next=queue()[0];if(!next)return;
  setQueue(rows=>rows.slice(1));
  void ask(next.question,[],[],next.attachments??[]);
 };
 const [loadedKey,setLoadedKey]=createSignal('');
 let ready:Promise<void>=Promise.resolve();
 createEffect(on(key,current=>{
  abort?.abort();setLoadedKey('');setBusy(false);setHistory([]);setError('');setQueue([]);
  let stale=false;onCleanup(()=>{stale=true;});
  ready=readSideQuestion(current).then(saved=>{
  if(stale)return;
  setHistory((saved?.history??[]).map(row=>({...row,id:row.id??crypto.randomUUID()})));setBusy(false);setOpen(saved?.open??false);
  setDocked(saved?.docked??false);setQuestion(saved?.pending?.question??'');
  setAnswer(saved?.pending?.answer??'');
  setError(saved?.pending ? saved.pending.error || 'Side question interrupted. Retry to request a complete answer.' : '');
  setPendingAttachments(saved?.pending?.attachments??[]);setDraft(saved?.draft??'');setModel(saved?.model??'');setStorageError(false);
  setQueue(saved?.queue??[]);
  setLoadedKey(current);
  const agent=btwSession(p.mission);
  const lastAnswer=saved?.history.at(-1)?.answer;
  const emptyReply=lastAnswer!==undefined&&(lastAnswer==='The side agent finished without a text response.'||!lastAnswer.replace(/[.\s…]/g,''));
  if(emptyReply){setHistory(rows=>rows.slice(0,-1));setQuestion(saved!.history.at(-1)!.question);setAnswer('');}
  if(agent&&(agent.active||emptyReply||saved?.pending)){
   const controller=new AbortController();abort=controller;setBusy(true);setQuestion(agent.question);setError('');
   void watchBtw(p.mission,controller.signal,event=>{
    if(stale||controller.signal.aborted)return;
    if(event.type==='start'){setModel(event.model);setRunStatus('Starting side agent…');}
    if(event.type==='status')setRunStatus(event.text);
    if(event.type==='snapshot')setAnswer(event.text);
    if(event.type==='done'){setHistory(rows=>[...rows,{id:turnId(),question:agent.question,answer:event.answer}].slice(-20));setBusy(false);queueMicrotask(sendNext);}
   }).catch(e=>{if(!stale&&!controller.signal.aborted){setError(String(e));setBusy(false);}});
  }
  if(saved?.open&&saved.docked)queueMicrotask(()=>{if(loadedKey()===current)side?.show();});
  });
 }));
 createEffect(()=>{
  const current=key();
  const snapshot={history:history(),draft:draft(),model:model(),open:docked()&&side?side.visible():open(),docked:docked(),
    pending:(busy()||error())?{question:question(),answer:answer(),error:error(),attachments:pendingAttachments()}:undefined,
    queue:queue()};
  if(loadedKey()===current)void writeSideQuestion(current,snapshot).then(saved=>{if(key()===current)setStorageError(!saved);});
 });
 side?.register(()=>{setDocked(true);setOpen(true);});
 onCleanup(()=>{abort?.abort();side?.register(undefined);});
 const ask=async(text:string,images:DraftImage[]=[],files:UploadedFile[]=[],retryAttachments?:SideAttachment[],retryTurn=false)=>{
  text=text.trim();if(!text)return false;
  const selected=key();await ready;if(selected!==key())return false;
  if(busy()){
   // The draft is accepted: it waits for the answer in progress.
   const attachments=retryAttachments??await sideAttachments(images,files);
   if(selected!==key())return false;
   for(const file of files)text=text.replaceAll(uploadToken(file.path),`[File: ${file.source.name}]`);
   setQueue(rows=>[...rows,{id:crypto.randomUUID(),question:text,attachments}].slice(0,20));
   setOpen(true);if(docked())side?.show();setDraft('');
   revealSentQuestion();
   return true;
  }
  if(!preparing()&&!retryTurn)setTurnId(crypto.randomUUID());
  const current=key(),context=sideContext(p.items,true),controller=new AbortController();abort=controller;
  let attachments:SideAttachment[];
  setBusy(true);
  try { attachments=retryAttachments??await sideAttachments(images,files); }
  catch(e){setBusy(false);throw e;}
  if(controller.signal.aborted||current!==key())return false;
  for(const file of files)text=text.replaceAll(uploadToken(file.path),`[File: ${file.source.name}]`);
  setPendingAttachments(attachments);
  setOpen(true);if(docked())side?.show();setBusy(true);setQuestion(text);setAnswer('');setError('');setDraft('');
  revealSentQuestion();
  void askBtwAgent(p.mission,text,context,history(),controller.signal,event=>{
   if(current!==key()||controller.signal.aborted)return;
   if(event.type==='start'){setModel(event.model);setRunStatus('Starting side agent…');}
    if(event.type==='status')setRunStatus(event.text);
   if(event.type==='snapshot')setAnswer(event.text);
   if(event.type==='delta')setAnswer(value=>value+event.text);
   if(event.type==='done'){
    setAnswer(event.answer);
    const next=[...history(),{id:turnId(),question:text,answer:event.answer,attachments}].slice(-20);
    setHistory(next);setBusy(false);
   }
  },attachments).catch(e=>{if(current===key()&&!controller.signal.aborted)setError(e instanceof Error?e.message:String(e));})
  .finally(()=>{if(current===key()&&abort===controller){setBusy(false);queueMicrotask(sendNext);}});
  return true;
 };
 const reveal=()=>{setOpen(true);if(docked())side?.show();};
 p.ref({ask,open:reveal});
 const escape=(event:KeyboardEvent)=>{
  if(event.key==='Escape'&&!event.defaultPrevented&&open()&&!docked()){
   event.preventDefault();setOpen(false);
  }
 };
 onMount(()=>window.addEventListener('keydown',escape));
 onCleanup(()=>window.removeEventListener('keydown',escape));
 const cancel=()=>{void stopBtw(p.mission).then(()=>{abort?.abort();setBusy(false);setError('Side agent stopped.');}).catch(e=>setError(String(e)));};
 const retry=()=>{const asked=question(),files=pendingAttachments();void ask(asked,[],[],files,true);};
 // Reconcile the same turn through preparation, streaming and persistence.
 const [turns,setTurns]=createStore<Array<SideExchange & {id:string;pending?:boolean;error?:string}>>([]);
 createEffect(()=>{
  const rows=history().map((row,index)=>({...row,id:row.id??`saved:${loadedKey()}:${index}`}));
  if((preparing()||busy()||error())&&!rows.some(row=>row.id===turnId()))rows.push({id:turnId(),question:question(),answer:answer(),attachments:pendingAttachments(),pending:preparing()||busy(),error:error()} as typeof rows[number]);
  setTurns(reconcile(rows,{key:'id'}));
 });
 const prepareSend=(draft:{text:string}|null)=>{
  if(!draft){setPreparing(false);return;}
  if(busy())return;
  setTurnId(crypto.randomUUID());setQuestion(draft.text);setAnswer('');setError('');setPreparing(true);
  setOpen(true);if(docked())side?.show();revealSentQuestion();
 };
 let inline!:HTMLDivElement;
 return <>
  <div ref={inline}/>
  <Show when={!side&&!open()&&(history().length||busy()||error())}><button class="btw-reopen" onClick={reveal}>Side questions {busy()?'· Answering…':`· ${history().length}`}</button></Show>
  <Show when={open()}><Portal mount={docked() ? side?.target() : inline}><section class="btw-panel" aria-label="Side questions">
   <header><div><strong>Side question</strong></div><div class="btw-actions"><Show when={side}><button class="icon-btn" aria-label={docked()?"Move side question below conversation":"Move side question to right panel"} title={docked()?"Move below conversation":"Move to right panel"} onClick={()=>{if(docked()){setDocked(false);side?.hide();}else{setDocked(true);side?.show();}}}><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/><path d={docked()?"m11 9-3 3 3 3":"m8 9 3 3-3 3"}/></svg></button></Show><button class="icon-btn" aria-label="Close side questions" onClick={()=>{setOpen(false);if(docked())side?.hide();}}><Ic.CloseIcon size={16}/></button></div></header>
   <div class="btw-thread" ref={scroll}>
    <For each={turns}>{exchange=><article data-side-turn={exchange.id}>
     <UserTurn text={exchange.question} pending={exchange.pending&&!exchange.answer} onSend={text=>ask(text,[],[],exchange.attachments??[])}/>
     <Show when={exchange.pending}><For each={btwThoughts(p.mission)}>{thought=><ThinkBlock item={thought}/>}</For></Show>
     <Show when={exchange.answer}><MdView compact text={exchange.answer}/></Show>
     <Show when={exchange.pending}><p class="sr-only" role="status">{preparing()?'Sending…':'Side agent is working…'}</p></Show>
     <Show when={exchange.error}><p role="alert" class="error">{exchange.error}</p><button onClick={retry} disabled={busy()}>Retry</button><Show when={p.onOpenSession&&exchange.error?.match(/A side agent is already queued or running for this conversation \(([0-9a-f-]{36})\)/)?.[1]}>{id=><button onClick={()=>{void Promise.resolve(p.onOpenSession?.(id())).catch(e=>setError(String(e)));}}>Open existing side agent</button>}</Show></Show>
     <Show when={!exchange.pending&&!exchange.error}><button class="btw-transfer" onClick={()=>p.onTransfer(`About this side question: ${exchange.question}\n\n${exchange.answer}`)}>Use in agent draft ↗</button></Show>
    </article>}</For>
    <Show when={queue().length}><section class="followup-queue btw-queue" aria-label="Queued side questions" aria-live="polite">
     <header><span class="queue-count">{queue().length} Queued</span></header>
     <ol><For each={queue()}>{row=><li class="queue-row"><div class="queue-line"><span class="queue-text" title={row.question}>{row.question}</span><span class="queue-row-actions"><button type="button" title="Remove" aria-label={`Remove queued side question: ${row.question}`} onClick={()=>setQueue(rows=>rows.filter(other=>other.id!==row.id))}><Ic.TrashIcon size={14}/></button></span></div></li>}</For></ol>
    </section></Show>
    <Show when={!history().length&&!question()}><p class="dim">Ask a question or give the side agent a task. It shares the main agent’s workspace.</p></Show>
    <Show when={busy() && runStatus()}><p class="dim" role="status">{runStatus()}</p></Show>
    <AgentActivity items={btwActivities(p.mission)} running={busy()}/>
    <Show when={btwSession(p.mission) && busy()}><NativeInteraction mission={btwSession(p.mission)!.id} active={busy()} remote={!btwSession(p.mission)!.local} items={btwItems(p.mission)}/></Show>
   </div>
   <Show when={storageError()}><p class="dim" role="status">Local storage is unavailable. This side conversation may be lost on refresh.</p></Show>
   <div class="btw-composer-dock"><Composer sideQuestion onPending={prepareSend} picker={false} placeholder={busy()?"Queue a side question…":"Ask a side question…"} busy={busy()} scope={key()} uploadTarget="side" onDraft={setDraft} onSend={(text,images,files)=>ask(text,images,files)} onStop={cancel}/><div class="btw-footer"><span>/btw</span><span aria-hidden="true">·</span><span title="Independent agent sharing the main workspace">{model()||`${btwConfig().harness} · ${btwConfig().model}`}</span></div></div>
  </section></Portal></Show>
 </>;
}
