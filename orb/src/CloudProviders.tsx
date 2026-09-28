import {For,Show,createSignal,createEffect,on,onCleanup,onMount} from 'solid-js';
import {cloudAccounts,cloudAccountLabel,cloudNames,type CloudAccount,type CloudProvider} from './cloudAgentApi';
import {api,connectionVersion,openExternalUrl} from './api';
import {ProviderUsageMeter} from './ProviderUsageMeter';
import {FlaskIcon} from './icons';
import {ProviderLogo} from './ProviderLogo';
import {mergeById,pollWhileVisible} from './poll';
import './providerUsage.css';

type AccountUsage={windows:{label:string;used_percent:number}[];details:{label:string;used_percent:number}[];reset_at?:string;reset_at_ms?:string;source:string};
const services:CloudProvider[]=['chatgpt','cursor_cloud','grok_bot'];
const dashboards:Record<CloudProvider,string>={chatgpt:'https://chatgpt.com/',cursor_cloud:'https://cursor.com/dashboard/usage',grok_bot:'https://grok.com/'};
export function cloudAccountStatus(account:CloudAccount):string {
 if(account.available)return 'Available';
 if(/RequiresLogin|reconnect|login|sign.?in/i.test(account.reason??''))return 'Reconnect';
 return 'Unavailable';
}
export function CloudProviders() {
 const [accounts,setAccounts]=createSignal<CloudAccount[]>([]);
 const [usage,setUsage]=createSignal<Record<string,AccountUsage>>({});
 let usageGeneration=0;
 const refreshUsage=async()=>{const generation=++usageGeneration,version=connectionVersion();try{const data=await api<{accounts?:Record<string,AccountUsage>}>('/api/cloud/usage');if(!disposed&&generation===usageGeneration&&version===connectionVersion())setUsage(data.accounts??{});}catch{if(!disposed&&generation===usageGeneration)setUsage({});}};
 const [loaded,setLoaded]=createSignal(false),[error,setError]=createSignal('');
 let disposed=false,busy=false;
 const refresh=async()=>{
  if(busy)return;busy=true;const version=connectionVersion();void refreshUsage();
  try {const next=await cloudAccounts();if(!Array.isArray(next))throw new Error('Cloud accounts could not be read. Refresh to retry.');if(!disposed&&version===connectionVersion()){setAccounts(previous=>mergeById(previous,next));setError('');setLoaded(true);}}
  catch(e){if(!disposed&&version===connectionVersion()){setError(e instanceof Error?e.message:String(e));setLoaded(true);}}
  finally{busy=false;if(!disposed&&version!==connectionVersion())void refresh();}
 };
 createEffect(on(connectionVersion,()=>{setAccounts([]);setUsage({});setLoaded(false);setError('');void refresh();}));
 onMount(()=>{const stop=pollWhileVisible(refresh,60000);window.addEventListener('orb:providers-refresh',refresh);onCleanup(()=>{disposed=true;stop();window.removeEventListener('orb:providers-refresh',refresh);});});
 return <section class="s-sec" aria-label="Cloud agents"><h3>Cloud agents</h3><div class="s-card">
  <Show when={loaded()} fallback={<div class="s-row" role="status">Loading cloud accounts…</div>}>
   <Show when={error()}><div class="s-row cloud-provider-error"><span class="s-row-desc" role="alert">{error()}</span><button class="s-btn sm" onClick={()=>void refresh()}>Retry</button></div></Show>
   <For each={services.filter(service=>accounts().some(a=>a.provider===service))}>{service=><CloudProviderRow provider={service} accounts={accounts().filter(a=>a.provider===service)} usage={usage()[accounts().find(a=>a.provider===service)?.id??'']}/>}</For>
   <Show when={!error()&&!accounts().length}><div class="s-row"><span class="s-row-desc">No cloud accounts configured.</span></div></Show>
  </Show>
 </div></section>;
}
function CloudProviderRow(p:{provider:CloudProvider;accounts:CloudAccount[];usage?:AccountUsage}) {
 const [open,setOpen]=createSignal(false),[error,setError]=createSignal('');
 const available=()=>p.accounts.filter(a=>a.available).length;
 const label=()=>p.accounts.length>1?`${available()} of ${p.accounts.length} profiles available`:cloudAccountStatus(p.accounts[0]);
 const visit=async()=>{try{await openExternalUrl(dashboards[p.provider]);setError('');}catch(e){setError(String(e));}};
 return <div class="p-acc-wrap"><button class="s-row p-acc p-acc-btn" aria-expanded={open()} onClick={()=>setOpen(!open())}>
  <ProviderLogo type={p.provider}/><div class="s-row-text"><div class="s-row-title cloud-provider-title">{cloudNames[p.provider]}<Show when={p.accounts.some(a=>a.experimental)}><span class="cloud-experimental-icon" title="Experimental connector" aria-label="Experimental connector"><FlaskIcon size={14}/></span></Show></div><div class="s-row-desc"><span class={`p-st ${available()?'connected':'needs_reauth'}`}>{label()}</span></div></div><span class={`chev p-acc-chev ${open()?'open':''}`}>›</span>
 </button><Show when={open()}><div class="p-acc-body">
  <Show when={p.accounts.length>1}><div class="cloud-provider-profiles"><For each={p.accounts}>{account=><div class="cloud-provider-profile"><span>{cloudAccountLabel(account)}<Show when={account.label.match(/[^\s·]+@[^\s·]+/)?.[0]}> · {account.label.match(/[^\s·]+@[^\s·]+/)?.[0]}</Show></span><span class={`p-st ${account.available?'connected':'needs_reauth'}`} title={account.reason}>{cloudAccountStatus(account)}</span></div>}</For></div></Show>
  <Show when={p.accounts.length===1&&!p.accounts[0].available}><p class="cloud-provider-note">{p.accounts[0].reason}</p></Show>
  <Show when={p.usage?.windows?.length} fallback={<p class="cloud-provider-note">{p.provider==='cursor_cloud'?'Subscription usage is available in your Cursor dashboard. Account quotas are not shared by this connector.':'Subscription usage is not reported by this connector.'}</p>}>
   <For each={p.usage?.windows}>{w=><ProviderUsageMeter label={w.label} usedPct={w.used_percent}/>}</For>
   <Show when={p.usage?.details?.length}><details class="cloud-usage-breakdown"><summary>Usage breakdown</summary><For each={p.usage?.details}>{w=><ProviderUsageMeter label={w.label} usedPct={w.used_percent}/>}</For></details></Show>
   <Show when={p.usage?.reset_at||p.usage?.reset_at_ms}>{reset=><p class="cloud-provider-note">Resets {new Date(p.usage?.reset_at??Number(reset())).toLocaleDateString()}</p>}</Show>
  </Show>
  <div class="p-acc-actions"><button class="s-btn" onClick={()=>void visit()}>{p.provider==='cursor_cloud'?'View usage in Cursor':`Open ${cloudNames[p.provider]}`} ↗</button></div>
  <Show when={error()}><p class="s-row-desc c-red" role="alert">{error()}</p></Show>
 </div></Show></div>;
}
