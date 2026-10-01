import {render} from 'solid-js/web';
import {LiveProjectsSection} from '../src/ProjectFiles';
import {setConnection} from '../src/api';
import '../src/styles.css';
setConnection(location.origin,'fixture');
render(()=><aside style={{width:'280px'}}><LiveProjectsSection harnessChoices={[]} onFork={()=>{}} selected={()=>null} open={()=>{}} onNewAgent={()=>{}} onNewProject={()=>{}} /></aside>,document.getElementById('root')!);
