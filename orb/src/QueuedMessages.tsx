import { Portal } from "solid-js/web";
import { PopupMenu, type MenuEntry } from "./Menu";
import {For,Show,createSignal} from 'solid-js';
import {queuedLocalMessages,takeQueuedMessage,removeQueuedMessage,retryQueuedMessage,sendQueuedNow} from './localMessageQueue';
import * as Ic from './icons';
export function QueuedMessages(p:{mission:string;onEdit?:(text:string)=>void}){
 const rows=()=>queuedLocalMessages(p.mission).filter(row=>row.waiting&&row.state!=='accepted'&&row.state!=='dispatching'||!!row.error);
 const [working,setWorking]=createSignal(false);
 const [menu,setMenu]=createSignal<{x:number;y:number}|null>(null),[error,setError]=createSignal('');
 const act=async(fn:()=>Promise<unknown>)=>{if(working())return;try{setWorking(true);setError('');await fn();}catch(e){setError(String(e));}finally{setWorking(false);}};
 const options=():MenuEntry[]=>{
  if(working())return [];
  const next=rows()[0];if(!next)return [];
  const items:MenuEntry[]=[];
  if(rows().some(row=>row.state==='queued'))items.push({kind:'item',label:'Send now',onClick:()=>void act(()=>sendQueuedNow(p.mission))});
  if(next.error&&(next.state==='error'||next.state==='dispatching'||next.interrupted))items.push({kind:'item',label:'Retry saved message',onClick:()=>void act(()=>retryQueuedMessage(next.id))});
  if(p.onEdit&&next.state!=='dispatching'&&next.state!=='accepted')items.push({kind:'item',label:'Edit next message',onClick:()=>void act(async()=>{const text=await takeQueuedMessage(next.id);p.onEdit?.(text);})});
  return items;
 };
 return <Show when={rows().length}><section class="followup-queue" aria-label="Queued messages" aria-live="polite">
  <header><span>{rows().length} Queued</span><span class="queue-hint">After this turn</span><div class="queue-options"><button class="queue-action" disabled={working()||!rows().some(row=>row.state==='queued')} onClick={()=>void act(()=>sendQueuedNow(p.mission))}>Send now</button><button type="button" class="queue-menu-toggle" aria-label="Queue options" aria-haspopup="menu" aria-expanded={!!menu()} onClick={e=>{if(menu()){setMenu(null);return;}e.currentTarget.focus();const r=e.currentTarget.getBoundingClientRect();setMenu({x:r.right-240,y:r.bottom+6});}}><Ic.ChevronDown/></button><Show when={menu()}>{position=><Portal><PopupMenu x={position().x} y={position().y} onClose={()=>setMenu(null)} items={options()}><div class="queue-menu-help">{rows().some(row=>row.interrupted) ? "Retry checks that the previous agent stopped before resuming your saved message." : "Messages send after the current turn. Send now stops it first."}</div></PopupMenu></Portal>}</Show></div></header>
  <ol><For each={rows()}>{row=><li><span>{row.text}</span><Show when={p.onEdit}><button class="queue-remove queue-edit" title="Edit message" disabled={working()||row.state==='dispatching'||row.state==='accepted'} aria-label={`Edit queued message: ${row.text}`} onClick={()=>void act(async()=>{const text=await takeQueuedMessage(row.id);p.onEdit?.(text);})}><Ic.PencilIcon size={12}/></button></Show><button class="queue-remove" disabled={working()||row.state==='dispatching'||row.state==='accepted'} aria-label={`Remove queued message: ${row.text}`} onClick={()=>void act(()=>removeQueuedMessage(row.id))}><Ic.CloseIcon size={12}/></button><Show when={row.state==='dispatching'}><small>{row.error?'Needs review':'Sending…'}</small></Show><Show when={row.error}><small role="alert">{row.error}</small><Show when={row.state==='error'||row.state==='dispatching'||row.interrupted}><button onClick={()=>void act(()=>retryQueuedMessage(row.id))}>Retry</button></Show></Show></li>}</For></ol>
  <Show when={error()}><p role="alert">{error()}</p></Show>
 </section></Show>;
}
