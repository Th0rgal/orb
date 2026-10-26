import {Show} from 'solid-js';
import './providerUsage.css';
import {quotaLevel} from './providerUsage';

/** Shared quota presentation. Missing/invalid usage is never rendered as zero. */
export function ProviderUsageMeter(p:{label:string;usedPct:number;reset?:string}) {
 const valid=()=>Number.isFinite(p.usedPct);
 const pct=()=>Math.max(0,Math.min(100,Math.round(p.usedPct)));
 const level=()=>quotaLevel(p.usedPct/100);
 return <Show when={valid()}><div class="provider-usage-meter">
  <div class={`provider-usage-heading ${level()}`}><span>{p.label==='7d'?'Weekly':p.label}</span><span>{pct()}%</span></div>
  <div class="p-bar" role="progressbar" aria-label={`${p.label} usage`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct()} aria-valuetext={`${pct()}% used${level()==='exhausted'?', exhausted':level()==='warning'?', almost used':''}`}>
   <div class={`p-bar-fill ${level()}`} style={{width:`${pct()}%`}}/>
  </div>
  <Show when={p.reset}><div class="provider-usage-reset">Resets {p.reset!.replace(/^reset\s+/i,'')}</div></Show>
 </div></Show>;
}

/** One window on a pool's single row: "5h ▬ 7% 2h". The reset is a short
 * inline hint; its full text is the tooltip. */
export function ProviderUsageChip(p:{label:string;usedPct:number;reset?:string}) {
 const pct=()=>Math.max(0,Math.min(100,Math.round(p.usedPct)));
 const level=()=>quotaLevel(p.usedPct/100);
 const label=()=>p.label==='7d'?'Weekly':p.label;
 const reset=()=>p.reset?.replace(/^reset\s+/i,'').replace(/^in\s+/,'');
 return <Show when={Number.isFinite(p.usedPct)}><span class={`provider-usage-chip ${level()}`} title={p.reset?`${label()}: ${pct()}% used · resets ${p.reset.replace(/^reset\s+/i,'')}`:`${label()}: ${pct()}% used`}>
  <span class="provider-usage-chip-label">{label()}</span>
  <span class="p-bar" role="progressbar" aria-label={`${p.label} usage`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct()} aria-valuetext={`${pct()}% used${level()==='exhausted'?', exhausted':level()==='warning'?', almost used':''}`}><span class={`p-bar-fill ${level()}`} style={{width:`${pct()}%`}}/></span>
  <span class="provider-usage-chip-pct">{pct()}%</span>
  <Show when={reset()}><span class="provider-usage-chip-reset">{reset()}</span></Show>
 </span></Show>;
}
