import {render} from 'solid-js/web';
import {Composer} from '../src/App';
import {CronForm} from '../src/ControllerSettings';
import {getProjectCronFromJob} from '../src/cronSchema';
import fixtures from './fixtures/hermes-jobs.json';
import '../src/styles.css';
import {ensureVoiceProbe} from '../src/VoiceButton';
if (location.search.includes('voice')) ensureVoiceProbe({
 capability: async () => ({supported: true, reason: null, platform: 'macos', arch: 'aarch64',
   python: '/test/python', python_ready: true, model_repo: 'test', model_revision: 'test',
   model_dir: '/test/model', model_ready: true, worker: 'off', languages: ['en', 'fr'],
   max_seconds: 120, idle_seconds: 600}),
 prewarm: async () => {}, transcribe: async () => {throw new Error('Not recording in this fixture');}, cancel: async () => true,
});
document.documentElement.dataset.theme='dark';
const view=getProjectCronFromJob('notes',fixtures.hourly);
render(()=><main style={{padding:'30px','max-width':'800px',margin:'auto',height:'100vh',overflow:'auto'}}>{location.search.includes('cron')?<CronForm draftKey="feedback" view={view} save={async()=>view} onSaved={()=>{}}/>:<Composer placeholder="Send follow-up" busy={false} onSend={()=>new Promise<boolean>(resolve=>{(window as any).finish=resolve;})} onStop={()=>{}}/>}</main>,document.getElementById('root')!);
