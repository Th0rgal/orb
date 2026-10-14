import { Popover } from "./Popover";
import {createEffect,createMemo,createSignal,createUniqueId,onCleanup,Show} from 'solid-js';
import {subscribeProjectContext,contextConflicts} from './projectContext';
import {getApiUrl,getJwt,connectionVersion} from './api';
import {nativeInvoke} from './clientRuns';

// Backoff for automatic retries; after the last step the badge settles on "offline"
// and waits for focus, reconnect, or a manual retry.
const RETRY_DELAYS=[10,20,40,80,160];
type SyncState={initialized:boolean;pending:unknown[];error?:string|null};
export function ContextBadge(p:{slug:string;compact?:boolean}){
 const[state,setState]=createSignal<SyncState>();
 const[conflicts,setConflicts]=createSignal<string[]>([]);
 const[expanded,setExpanded]=createSignal(false),[retrying,setRetrying]=createSignal(false);
 const[retryError,setRetryError]=createSignal('');
 const[lastSynced,setLastSynced]=createSignal<number>();
 const[attempt,setAttempt]=createSignal(0),[retryAt,setRetryAt]=createSignal(0),[now,setNow]=createSignal(Date.now());
 const[showDetails,setShowDetails]=createSignal(false);
 const id=createUniqueId();
 let retry=async()=>{};
 // Memoized so a refresh returning the same failure doesn't restart the retry countdown.
 const error=createMemo(()=>retryError()||state()?.error||'');
 const authError=()=>/HTTP 40[13]/.test(error());
 const pending=()=>state()?.pending.length??0;
 const gaveUp=()=>attempt()>=RETRY_DELAYS.length;
 const countdown=()=>Math.max(0,Math.ceil((retryAt()-now())/1000));
 const failure=()=>gaveUp()?'Sync offline':'Sync failed';
 const label=()=>conflicts().length?`${conflicts().length} context conflict${conflicts().length===1?'':'s'}`:
  retrying()?'Syncing context':error()?(authError()?'Context access required':retryAt()&&countdown()?`${failure()} · retrying in ${countdown()}s`:failure()):pending()?'Syncing context':'';
 const ago=(t:number)=>{const m=Math.floor((now()-t)/60000);return m<1?'just now':m<60?`${m} min ago`:`${Math.floor(m/60)} h ago`;};
 const errorDetail=()=>{const m=/\((\d{3})\)|HTTP (\d{3})/.exec(error());const code=m?.[1]??m?.[2];return code?`Server error ${code}`:'Connection error';};
 createEffect(()=>{
  const slug=p.slug,version=connectionVersion();
  const request={endpoint:getApiUrl(),token:getJwt()??'',project:slug};
  const invoke=nativeInvoke();
  let disposed=false,busy=false;
  const valid=()=>!disposed&&version===connectionVersion();
  setState(undefined);setConflicts([]);setExpanded(false);setRetryError('');setRetrying(false);
  setLastSynced(undefined);setAttempt(0);setRetryAt(0);setShowDetails(false);
  let timer:ReturnType<typeof setTimeout>|undefined;
  const ok=(next:SyncState)=>{setState(next);if(!next.error){setLastSynced(Date.now());setAttempt(0);setRetryAt(0);}};
  const refresh=async()=>{
   if(busy)return;
   busy=true;
   await Promise.allSettled([
    contextConflicts(slug,{signal:AbortSignal.timeout(8000)}).then(result=>{if(valid())setConflicts(Object.values(result).map(op=>op.path));}),
    invoke?.('project_context_status',{request}).then(result=>{if(valid()){ok((result as {state:SyncState}).state);setRetryError('');}}).catch(error=>{if(valid())setRetryError(String(error));}),
   ]);
   busy=false;
  };
  retry=async()=>{
   if(!invoke||retrying())return;
   setRetrying(true);setRetryError('');
   try{
    const result=await invoke('project_context_sync',{request}) as {state:SyncState};
    if(valid())ok(result.state);
   }catch(error){if(valid())setRetryError(String(error));}
   finally{if(valid()){setRetrying(false);void refresh();}}
  };
  const wake=()=>{setAttempt(0);void refresh();};
  const visibility=()=>{if(!document.hidden)wake();};
  void refresh();
  const stop=subscribeProjectContext(slug,wake,failure=>{if(valid())setRetryError(String(failure));});
  window.addEventListener('online',wake);window.addEventListener('focus',wake);
  document.addEventListener('visibilitychange',visibility);
  // Schedule the next automatic retry whenever a (non-auth) failure is showing.
  createEffect(()=>{
   clearTimeout(timer);
   if(!invoke||!error()||authError()||retrying()||gaveUp()){setRetryAt(0);return;}
   const n=attempt();
   setRetryAt(Date.now()+RETRY_DELAYS[n]*1000);
   timer=setTimeout(()=>{setAttempt(n+1);void retry();},RETRY_DELAYS[n]*1000);
  });
  const tick=setInterval(()=>setNow(Date.now()),1000);
  onCleanup(()=>{clearTimeout(timer);clearInterval(tick);disposed=true;stop();window.removeEventListener('online',wake);window.removeEventListener('focus',wake);document.removeEventListener('visibilitychange',visibility);});
 });
 const title=()=>conflicts().length?'Changes need review':authError()?'Reconnect to sync context':error()?(gaveUp()?'Sync offline':"Couldn't reach the server"):'Synchronizing context';
 const body=()=>conflicts().length?'Open file history to compare and resolve conflicting versions.':
  pending()?`${pending()} local change${pending()===1?'':'s'} waiting to sync.`:
  error()?'Your local changes are safe — nothing is waiting to upload.':'Checking the latest changes.';
 return <Show when={label()}><div class="context-sync-state" classList={{compact:!!p.compact}} data-state={conflicts().length||(error()&&pending())?'warning':error()?'failed':'syncing'} >
  <button class="context-sync-trigger" aria-label={label()} title={p.compact?label():undefined} aria-expanded={expanded()} aria-controls={id} onClick={event=>{event.stopPropagation();setExpanded(!expanded());}}>
   <span class="context-sync-dot" aria-hidden="true"/><Show when={!p.compact}><span>{label()}</span></Show>
  </button>
  <Show when={expanded()}><Popover id={id} class="context-sync-detail" label="Context synchronization" onClose={() => setExpanded(false)}>
   <strong>{title()}</strong>
   <p>{body()}</p>
   <Show when={conflicts().length}><p>{conflicts().join('\n')}</p></Show>
   <Show when={error()}>
    <div class="context-sync-meta">
     <Show when={lastSynced()}>{t=><span>Last synced {ago(t())}</span>}</Show>
     <Show when={authError()} fallback={<>
      <button type="button" class="context-sync-more" aria-expanded={showDetails()} onClick={()=>setShowDetails(!showDetails())}>{errorDetail()} · Details {showDetails()?'▾':'▸'}</button>
      <Show when={showDetails()}><code class="context-sync-raw">{error()}</code></Show>
     </>}><span>Check your backend connection in Settings.</span></Show>
    </div>
   </Show>
   <div class="context-sync-actions">
    <Show when={nativeInvoke()}><button class="s-btn primary" disabled={retrying()} onClick={()=>{setAttempt(0);void retry();}}>{retrying()?'Syncing…':'Retry now'}</button></Show>
    <button class="s-btn ghost" onClick={()=>setExpanded(false)}>Dismiss</button>
   </div>
  </Popover></Show>
 </div></Show>;
}
