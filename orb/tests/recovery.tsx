import {createSignal} from 'solid-js';
import {render} from 'solid-js/web';
import {LaunchStatus, MissionFailure} from '../src/missionLaunch';
import {UserTurn} from '../src/Transcript';
import type {Mission} from '../src/api';
import '../src/styles.css';
document.documentElement.dataset.theme=new URLSearchParams(location.search).get('theme') ?? 'dark';
const initial={id:'recovery',status:'interrupted',terminal_reason:'usage_limit_wait',recovery:{kind:'transient',reason:'Antigravity transient upstream error',resume_at:new Date(Date.now()+300_000).toISOString(),attempt:3,max_attempts:12}} as Mission;
function Preview(){
 const [mission,setMission]=createSignal(initial);
 return <main style={{padding:'16px','max-width':'800px',margin:'60px auto'}}>
  <LaunchStatus destination="old-agent" mission={mission()} activity onResume={()=>setMission({...initial,status:'active',remote_job:{node_state:'running'}} as Mission)} onCancelRecovery={()=>setMission({...initial,status:'paused'})}/>
  <MissionFailure mission={mission()}/>
  <UserTurn text="[Automatic recovery] Antigravity transient upstream error stopped your previous turn. Resume your work where it stopped, and check the state of anything you had started before continuing. Do not redo finished work."/>
  <p>The agent continues in the same conversation after the provider connection recovers.</p>
 </main>;
}
render(()=><Preview/>,document.getElementById('root')!);
