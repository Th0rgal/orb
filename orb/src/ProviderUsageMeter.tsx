import {Show} from 'solid-js';
import './providerUsage.css';

/** Shared quota presentation. Missing/invalid usage is never rendered as zero. */
export function ProviderUsageMeter(p:{label:string;usedPct:number;reset?:string}) {
 const valid=()=>Number.isFinite(p.usedPct);
 const pct=()=>Math.max(0,Math.min(100,Math.round(p.usedPct)));
 return <Show when={valid()}><div class="provider-usage-meter">
  <div class="provider-usage-heading"><span>{p.label==='7d'?'Weekly':p.label}</span><span>{pct()}%</span></div>
  <div class="p-bar" role="progressbar" aria-label={`${p.label} usage`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct()} aria-valuetext={`${pct()}% used`}>
   <div class={`p-bar-fill ${pct()>=100?'hot':pct()>=90?'warm':''}`} style={{width:`${pct()}%`}}/>
  </div>
  <Show when={p.reset}><div class="provider-usage-reset">Resets {p.reset!.replace(/^reset\s+/i,'')}</div></Show>
 </div></Show>;
}
