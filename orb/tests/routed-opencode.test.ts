import {afterEach, beforeEach, expect, it, vi} from 'vitest';
import {clearConnection, listHarnessChoices, modelPickerItems, setConnection} from '../src/api';
import {withCoreEffort} from '../src/localOrigins';

beforeEach(() => { localStorage.clear(); setConnection('https://routing.test', 'test-token'); });
afterEach(() => { clearConnection(); vi.unstubAllGlobals(); });
const chains = [{id:'builtin/smart',name:'Smart',is_default:true},{id:'reviewer',name:'Reviewer'},{id:'team/custom',name:'Custom'}];
function server(routes:unknown = chains, direct = [{value:'openrouter/google/gemini',label:'OpenRouter — Gemini'}]) {
 vi.stubGlobal('fetch', vi.fn(async (url:string) => new Response(JSON.stringify(
  url.endsWith('/api/backends') ? [{id:'opencode',name:'OpenCode'},{id:'codex',name:'Codex'}] :
  url.endsWith('/api/model-routing/chains') ? routes :
  {backends:{opencode:direct,codex:[{value:'gpt',label:'GPT'}]}}
 ))));
}
it('combines routing chains first with direct configured OpenCode models, deduplicated', async () => {
 server(chains, [
  {value:'builtin/smart',label:'Routing — Smart'},
  {value:'smart',label:'Routing — Smart'},
  {value:'openrouter/google/gemini',label:'OpenRouter — Gemini'},
  {value:'xai/grok-4.6',label:'xAI — Grok 4.6'},
 ]);
 const choices = await listHarnessChoices();
 expect(choices.map(c=>c.backend.id)).toEqual(['codex','opencode']);
 expect(choices[1].models.map(m=>m.value)).toEqual([...chains.map(c=>c.id),'openrouter/google/gemini','xai/grok-4.6']);
 expect(modelPickerItems(choices[1].models)).toEqual([
  {id:'builtin/smart',label:'Smart',group:'Routing'},
  {id:'reviewer',label:'Reviewer',group:'Routing'},
  {id:'team/custom',label:'Custom',group:'Routing'},
  {id:'openrouter/google/gemini',label:'Gemini',group:'OpenRouter'},
  {id:'xai/grok-4.6',label:'Grok 4.6',group:'xAI'},
 ]);
 expect(choices[0].models).toEqual([{value:'gpt',label:'GPT'}]);
 expect(modelPickerItems(choices[0].models)).toEqual([{id:'gpt',label:'GPT'}]);
});
it('restores routed choices from the same connection cache when offline', async () => {
 server(); const choices = await listHarnessChoices();
 vi.stubGlobal('fetch',vi.fn().mockRejectedValue(new TypeError('offline')));
 expect(await listHarnessChoices()).toEqual(choices);
 setConnection('https://other.test','other-token');
 await expect(listHarnessChoices()).rejects.toThrow('offline');
});
it('rejects malformed routing responses instead of silently hiding OpenCode', async () => {
 server({}); await expect(listHarnessChoices()).rejects.toThrow('Invalid model routing catalog');
});
it('offers direct configured OpenCode models even when no routing chains exist, and hides OpenCode when neither exists', async () => {
 server([], [{value:'xai/grok-4.6',label:'xAI — Grok 4.6'}]);
 const withDirect = await listHarnessChoices();
 expect(withDirect.find(c=>c.backend.id==='opencode')?.models).toEqual([{value:'xai/grok-4.6',label:'xAI — Grok 4.6'}]);
 clearConnection(); setConnection('https://empty.test','test-token');
 server([], []);
 expect((await listHarnessChoices()).map(c=>c.backend.id)).toEqual(['codex']);
});
it('preserves Core model_override alongside effort and speed when overlaying a pending local journal', () => {
 const local = {id:'m1',title:null,status:'active',backend:'opencode',model_override:'builtin/smart',model_effort:'medium',history:[],created_at:'',updated_at:''};
 const core = {...local,model_override:'xai/grok-4.6',model_effort:'high',fast_mode:true};
 expect(withCoreEffort(local,core)).toMatchObject({model_override:'xai/grok-4.6',model_effort:'high',fast_mode:true});
});
