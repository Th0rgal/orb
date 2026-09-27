import {createEffect,createSignal,createUniqueId,onCleanup,Show} from 'solid-js';
import {subscribeProjectContext,contextConflicts} from './projectContext';
import {getApiUrl,getJwt,connectionVersion} from './api';
import {nativeInvoke} from './clientRuns';

type SyncState={initialized:boolean;pending:unknown[];error?:string|null};
export function ContextBadge(p:{slug:string}){
 const[state,setState]=createSignal<SyncState>();
 const[conflicts,setConflicts]=createSignal<string[]>([]);
 const[expanded,setExpanded]=createSignal(false),[retrying,setRetrying]=createSignal(false);
 const[retryError,setRetryError]=createSignal('');
 const id=createUniqueId();
 let retry=async()=>{};
 const error=()=>retryError()||state()?.error||'';
 const authError=()=>/HTTP 40[13]/.test(error());
 const pending=()=>state()?.pending.length??0;
 const label=()=>conflicts().length?`${conflicts().length} context conflict${conflicts().length===1?'':'s'}`:
  retrying()?'Syncing context':error()?(authError()?'Context access required':/unavailable|network|timeout/i.test(error())?'Context offline':'Context sync paused'):pending()?'Syncing context':'';
 createEffect(()=>{
  const slug=p.slug,version=connectionVersion();
  const request={endpoint:getApiUrl(),token:getJwt()??'',project:slug};
  const invoke=nativeInvoke();
  let disposed=false,busy=false;
  const valid=()=>!disposed&&version===connectionVersion();
  setState(undefined);setConflicts([]);setExpanded(false);setRetryError('');setRetrying(false);
  const refresh=async()=>{
   if(busy)return;
   busy=true;
   await Promise.allSettled([
    contextConflicts(slug,{signal:AbortSignal.timeout(8000)}).then(result=>{if(valid())setConflicts(Object.values(result).map(op=>op.path));}),
    invoke?.('project_context_status',{request}).then(result=>{if(valid()){setState((result as {state:SyncState}).state);setRetryError('');}}).catch(error=>{if(valid())setRetryError(String(error));}),
   ]);
   busy=false;
  };
  retry=async()=>{
   if(!invoke||retrying())return;
   setRetrying(true);setRetryError('');
   try{
    const result=await invoke('project_context_sync',{request}) as {state:SyncState};
    if(valid())setState(result.state);
   }catch(error){if(valid())setRetryError(String(error));}
   finally{if(valid()){setRetrying(false);void refresh();}}
  };
  const wake=()=>{void refresh();};
  const visibility=()=>{if(!document.hidden)wake();};
  void refresh();
  const stop=subscribeProjectContext(slug,wake,failure=>{if(valid())setRetryError(String(failure));});
  window.addEventListener('online',wake);window.addEventListener('focus',wake);
  document.addEventListener('visibilitychange',visibility);
  onCleanup(()=>{disposed=true;stop();window.removeEventListener('online',wake);window.removeEventListener('focus',wake);document.removeEventListener('visibilitychange',visibility);});
 });
 return <Show when={label()}><div class="context-sync-state" data-state={conflicts().length||error()?'warning':'syncing'} onKeyDown={event=>{if(event.key==='Escape'){setExpanded(false);event.stopPropagation();}}}>
  <button class="context-sync-trigger" aria-expanded={expanded()} aria-controls={id} onClick={event=>{event.stopPropagation();setExpanded(!expanded());}}>
   <span class="context-sync-dot" aria-hidden="true"/><span>{label()}</span>
  </button>
  <Show when={expanded()}><div id={id} class="context-sync-detail" role="region" aria-label="Context synchronization" onClick={event=>event.stopPropagation()}>
   <strong>{conflicts().length?'Changes need review':authError()?'Reconnect to sync context':error()?'Sync interrupted':'Synchronizing context'}</strong>
   <p>{conflicts().length?'Open file history to compare and resolve conflicting versions.':pending()?`${pending()} local change${pending()===1?'':'s'} waiting to sync.`:error()?'No queued changes. The latest server version could not be checked.':'Checking the latest changes.'}</p>
   <Show when={conflicts().length}><p>{conflicts().join('\n')}</p></Show>
   <Show when={error()}><p class="context-sync-error">{authError()?'Check your backend connection in Settings.':error()}</p></Show>
   <Show when={nativeInvoke()}><button class="s-btn" disabled={retrying()} onClick={()=>void retry()}>{retrying()?'Syncing…':'Retry sync'}</button></Show>
  </div></Show>
 </div></Show>;
}
