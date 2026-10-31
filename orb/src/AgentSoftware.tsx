import { ago, useNow } from "./time";
import { For, Show, createSignal, onMount } from "solid-js";
import {availableSoftwareUpdates,canInstallSoftware,matchesSoftwareJob,softwareAttentionSummary,updateAllSoftware,softwareMachines,softwareRefreshing,refreshSoftware,updateSoftware,cancelSoftware,newer,softwareVersion,type SoftwareMachine,type SoftwareComponent} from './softwareInventory';
function ComponentRow(p:{machine:SoftwareMachine;row:SoftwareComponent}){
 const [busy,setBusy]=createSignal(false),[error,setError]=createSignal('');
 const job=()=>p.machine.inventory?.jobs.filter(j=>matchesSoftwareJob(j,p.row)).at(-1);
 const pending=()=>['queued','installing'].includes(job()?.state??'');
 const installable=()=>canInstallSoftware(p.row);
 const available=()=>p.row.installed&&newer(p.row.latest,p.row.version);
 const needsSetup=()=>p.row.installed&&p.row.ready===false;
 const status=()=>job()?.state==='queued'?`Waiting for ${p.row.name} sessions`:job()?.state==='installing'?(p.row.installed?'Updating…':'Installing…'):job()?.state==='failed'?(p.row.installed?'Update failed':'Install failed'):!p.row.installed?(installable()?`Not installed · ${p.row.latest}`:'Not installed'):p.row.release_error?'Version check unavailable':!softwareVersion(p.row.version)?'Version unknown':available()?`→ ${p.row.latest}`:needsSetup()?'Setup required':!p.row.latest?(p.row.ready===true?'Ready':'Release unknown'):'Up to date';
 const perform=async(action:()=>Promise<void>)=>{setBusy(true);setError('');try{await action();}catch(e){setError(String(e));}finally{setBusy(false);}};
 return <div class="software-entry"><details><summary><span class="software-name">{p.row.name}</span><span class="software-version" title={p.row.version??''}>{softwareVersion(p.row.version)?.join('.')??p.row.version??'—'}</span><span class="software-owner">{p.row.owner}</span><span class={`software-status ${job()?.state==='failed'?'failed':available()||installable()||needsSetup()?'attention':''}`}>{status()}</span></summary>
 <div class="software-details"><Show when={p.row.path}><code>{p.row.path}</code></Show><span>{p.row.owner}{p.row.update_supported?' · Updates managed by Orb':' · Managed externally'}</span><Show when={p.row.ready_detail}><p>{p.row.ready_detail}</p></Show><p>{p.row.instructions}</p>
 <For each={p.row.running}>{r=><p>Session {r.session.slice(0,8)} · Started with {r.version??'version unknown'} · Runner {r.runner}</p>}</For>
 <Show when={job()?.error}><p class="inline-error">{job()!.error}</p></Show></div></details>
 <Show when={p.machine.online&&!p.machine.error}><div class="software-actions"><Show when={job()?.state==='queued'}><button class="s-btn sm quiet" disabled={busy()} onClick={()=>void perform(()=>cancelSoftware(p.machine.id,job()!.id))}>Cancel</button></Show>
 <Show when={!pending()&&p.row.update_supported&&(available()||installable())}><button class="s-btn sm quiet" disabled={busy()} onClick={()=>void perform(()=>updateSoftware(p.machine.id,p.row))}>{busy()?'Queuing…':job()?.state==='failed'?'Retry':p.row.installed?'Update':'Install'}</button></Show></div></Show>
 <Show when={error()}><p class="inline-error" role="alert">{error()}</p></Show></div>;
}
export function AgentSoftware(p:{external?:{id:string;name:string}[]}){
 const [open,setOpen]=createSignal(false);
 const [updatingAll,setUpdatingAll]=createSignal(false),[updateError,setUpdateError]=createSignal('');
 const updateAll=async()=>{setUpdatingAll(true);setUpdateError('');try{await updateAllSoftware();}catch(e){setUpdateError(String(e));}finally{setUpdatingAll(false);}};
 const clock=useNow(60000);onMount(()=>{void refreshSoftware();});
 const summary=()=>softwareAttentionSummary(softwareMachines());
 const hasInstalls=()=>availableSoftwareUpdates().some(x=>!x.row.installed);
 return <section class="s-card agent-software" aria-label="Agent software"><button class="s-row p-acc-btn" aria-expanded={open()} onClick={()=>setOpen(!open())}><div class="s-row-text"><div class="s-row-title">Agent software</div></div><span class="s-row-desc">{summary()}</span><span class={`chev p-acc-chev ${open()?'open':''}`}>›</span></button>
 <Show when={open()}><div class="software-body"><div class="software-toolbar"><span>Versions and installers</span><button class="s-btn sm quiet" disabled={updatingAll()||softwareRefreshing()||!availableSoftwareUpdates().length} onClick={()=>void updateAll()}>{updatingAll()?'Queuing…':hasInstalls()?'Install & update all':'Update all'}</button><button class="icon-btn" aria-label="Refresh software versions" title="Check versions" disabled={softwareRefreshing()} onClick={()=>void refreshSoftware(true)}><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M20 7v5h-5M4 17v-5h5M6 6a8 8 0 0 1 13 3M18 18A8 8 0 0 1 5 15"/></svg></button></div>
 <Show when={updateError()}><p class="inline-error" role="alert">{updateError()}</p></Show>
 <Show when={!softwareMachines().length}><p class="software-empty">{softwareRefreshing()?'Checking software…':'No inventory available'}</p></Show>
 <For each={softwareMachines().filter(m=>m.inventory)}>{m=><div class="software-machine"><div class="software-machine-heading"><span>{m.name}</span><small>{[m.error||(!m.online?'Offline':''),m.inventory?(clock(),`Checked ${ago(m.inventory.checked_at*1000,clock())}`):''].filter(Boolean).join(' · ')||'Checking…'}</small></div>
 <Show when={m.inventory}>{inv=><><For each={inv().components}>{r=><ComponentRow machine={m} row={r}/>}</For><details class="software-runtime"><summary><span class="software-name">{inv().runtime.name}</span><span class="software-version">{inv().runtime.version}</span><span class="software-owner">App</span><span class={inv().runtime.restart_required?'software-status attention':'software-status'}>{inv().runtime.restart_required?'Restart required':'Managed externally'}</span></summary><div class="software-details"><span>Running build · {inv().runtime.build}</span><code>{inv().runtime.path}</code><For each={inv().runtime.running}>{r=><p>Session {r.session.slice(0,8)} · {r.harness} · {r.version??'Harness version not reported'} · Runner {r.runner}</p>}</For><p>{m.id==='local'?'Rebuild or update Orb, then restart when agents finish.':'Update through the guarded deployment process when agents finish.'}</p></div></details></>}</Show>
 </div>}</For>
 <Show when={softwareMachines().some(m=>!m.inventory)}><details class="software-unavailable"><summary>{softwareMachines().filter(m=>!m.inventory).length} machines without inventory</summary><For each={softwareMachines().filter(m=>!m.inventory)}>{m=><div class="software-machine-heading"><span>{m.name}</span><small>{m.error||(!m.online?'Offline':'Checking…')}</small></div>}</For></details></Show>
 <For each={p.external?.filter(m=>!softwareMachines().some(s=>s.id===m.id))}>{m=><div class="software-machine-heading"><span>{m.name}</span><small>Inventory unavailable · SSH only</small></div>}</For>
 </div></Show></section>;
}
