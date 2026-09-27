import { LiveProjectsSection } from "../src/ProjectFiles";
import { render } from 'solid-js/web';
import { ProjectSettings } from '../src/ProjectSettings';
import { setConnection } from '../src/api';
import '../src/styles.css';
setConnection(location.origin, 'fixture');
window.fetch = async input => {
  const path = String(input);
  const value = path.endsWith('/grant') ? {grant:{parallel_missions:3,autonomy_level:'act_full',budget_per_tick:'1 planner/reviewer + up to 2 writers on distinct PRs; one build at a time',merge_authority:'repo:example/project'}} : path.includes('missions') ? [] : path.endsWith('/files') ? {entries:[]} : path.endsWith('/crons') ? {jobs:[]} : path.endsWith('/controller') ? {job:null,runs:[]} : {projects:[{slug:'sample',title:'Sample project'}]};
  return new Response(JSON.stringify(value), {headers:{'Content-Type':'application/json'}});
};
render(() => <><aside><LiveProjectsSection harnessChoices={[]} onFork={()=>{}} selected={()=>null} open={()=>{}} onNewAgent={()=>{}} onNewProject={()=>{}} /></aside><ProjectSettings slug="sample" onOpenPage={()=>{}} onOpenMission={()=>{}} /></>, document.getElementById('root')!);
