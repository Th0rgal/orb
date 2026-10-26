import { isRecord, readJson, writeJson } from "./storage";
import { SIDE_QUESTION_HARNESSES, harnessName } from "./harnesses";
import {For,createSignal} from 'solid-js';
import {Select} from './Select';
import {sideQuestionKey} from './sideQuestionStorage';
export type BtwConfig={harness:string;model:string};
export function btwConfig():BtwConfig {
 return {...{harness:'opencode',model:'builtin/smart'},...readJson<Partial<BtwConfig>>(sideQuestionKey('settings:btw'),{},isRecord)};
}
export function BtwSettings(){
 const [config,setConfig]=createSignal(btwConfig());const [message,setMessage]=createSignal('');
 const save=()=>setMessage(writeJson(sideQuestionKey('settings:btw'),config())?'Saved. Applies to the next side question.':'Could not save settings.');
 return <div class="s-body settings-body"><div class="s-inner"><h2>Quick questions (/btw)</h2><section class="s-sec"><div class="s-card">
 <div class="s-row"><div class="s-row-text"><div class="s-row-title">Harness</div><div class="s-row-desc">An independent agent in the main agent’s folder.</div></div><Select aria-label="Btw harness" value={config().harness} onChange={e=>setConfig({...config(),harness:e.currentTarget.value})}><For each={SIDE_QUESTION_HARNESSES}>{id=><option value={id}>{harnessName(id)}</option>}</For></Select></div>
 <div class="s-row"><span class="s-row-title">Model</span><input class="s-input" aria-label="Btw model" value={config().model} onInput={e=>setConfig({...config(),model:e.currentTarget.value})}/></div>
 <div class="s-row"><span class="s-row-desc">Normal harness tools and permissions. Orb adds no tool restrictions or token budget. Files are shared with the main agent.</span></div>
 <div class="s-row"><span role="status">{message()}</span><button class="s-btn" disabled={!config().model.trim()} onClick={save}>Save</button></div>
 </div></section></div></div>;
}
