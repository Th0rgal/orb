import {For,Show,createMemo,createSignal} from 'solid-js';
import {canDiscardQueuedMessage,queuedLocalMessages,prioritizeQueuedMessage,removeQueuedMessage,retryQueuedMessage,sendQueuedNow} from './localMessageQueue';
import * as Ic from './icons';
/** Follow-ups waiting for the current turn, shown like Cursor's queue: one line per
 * message, hover actions, and the row being edited marked in place. */
export function QueuedMessages(p:{mission:string;editing?:string;onEdit?:(row:{id:string;text:string})=>void}){
 const rows=()=>queuedLocalMessages(p.mission).filter(row=>row.waiting&&row.state!=='accepted'&&row.state!=='dispatching'||!!row.error);
 const firstQueued=createMemo(()=>rows().findIndex(row=>row.state==='queued'));
 const canSendNow=()=>firstQueued()>=0;
 const attention=()=>rows().some(row=>!!row.error);
 const [working,setWorking]=createSignal(false),[collapsed,setCollapsed]=createSignal(false),[error,setError]=createSignal('');
 const act=async(fn:()=>Promise<unknown>)=>{if(working())return;try{setWorking(true);setError('');await fn();}catch(e){setError(e instanceof Error?e.message:String(e));}finally{setWorking(false);}};
 return <Show when={rows().length}><section class="followup-queue" classList={{collapsed:collapsed()}} aria-label="Queued messages" aria-live="polite">
  <header>
   <span class="queue-count">{rows().length} {attention() ? "Needs attention" : "Queued"}</span>
   <Show when={canSendNow()&&!attention()&&!p.editing}><span class="queue-hint"><Ic.ReturnIcon size={13}/> to Send</span></Show>
   <div class="queue-options">
    <Show when={canSendNow()}><button type="button" class="queue-send-now" title="Stops the current turn, then sends the next message" disabled={working()||!!p.editing} onClick={()=>void act(()=>sendQueuedNow(p.mission))}>Send now</button></Show>
    <button type="button" class="queue-collapse" aria-label={collapsed()?"Show queued messages":"Hide queued messages"} aria-expanded={!collapsed()} onClick={()=>setCollapsed(!collapsed())}><Ic.ChevronDown size={14}/></button>
   </div>
  </header>
  <Show when={!collapsed()}><ol>
   <For each={rows()}>{(row,index)=><li class="queue-row" classList={{editing:p.editing===row.id,failed:!!row.error}}>
    <div class="queue-line">
     <span class="queue-text" title={row.text}>{row.text}</span>
     <Show when={p.editing===row.id} fallback={<span class="queue-row-actions">
      <Show when={p.onEdit&&row.state==='queued'}><button type="button" title="Edit" aria-label={`Edit queued message: ${row.text}`} disabled={working()||!!p.editing} onClick={()=>p.onEdit!({id:row.id,text:row.text})}><Ic.PencilIcon size={14}/></button></Show>
      <Show when={row.state==='queued'&&index()>firstQueued()}><button type="button" title="Send next" aria-label={`Send next: ${row.text}`} disabled={working()} onClick={()=>void act(()=>prioritizeQueuedMessage(row.id))}><Ic.ArrowUpIcon size={14}/></button></Show>
      <button type="button" title="Remove" aria-label={`Remove queued message: ${row.text}`} disabled={working()||!canDiscardQueuedMessage(row)||p.editing===row.id} onClick={()=>void act(()=>removeQueuedMessage(row.id))}><Ic.TrashIcon size={14}/></button>
     </span>}><span class="queue-editing">Editing</span></Show>
    </div>
    <Show when={row.state==='dispatching'}><small>{row.error?'Needs review':'Sending…'}</small></Show>
    <Show when={row.error}><small role="alert">{row.error}</small><Show when={row.state==='error'||row.state==='dispatching'||row.interrupted}><button type="button" class="queue-send-now" disabled={working()} onClick={()=>void act(()=>retryQueuedMessage(row.id))}>Retry</button></Show></Show>
   </li>}</For>
  </ol></Show>
  <Show when={error()}><p role="alert">{error()}</p></Show>
 </section></Show>;
}
