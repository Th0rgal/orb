// Opt-in integration check; creates only bounded missions in orb-finder-validation.
import {it,expect,vi} from 'vitest';
import {readFileSync,writeFileSync,mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {api,setConnection,createProject,createMission} from '../src/api';
import {transferFile,uploadToken} from '../src/uploads';
const live=process.env.ORB_FINDER_LIVE==='1';
it.skipIf(!live)('reads Finder attachments from shared context on a real remote mission',async()=>{
 const connection=JSON.parse(readFileSync('/tmp/orb-finder-connection.json','utf8'));
 setConnection(connection.endpoint,connection.token);
 const project='orb-finder-validation';
 await createProject({slug:project,title:'Orb Finder validation'});
 const directory=mkdtempSync(join(tmpdir(),'orb-finder-'));
 const name='notes é sample.txt',path=join(directory,name),marker='FINDER_CONTENT_'+crypto.randomUUID();
 writeFileSync(path,marker);
 (window as any).__TAURI__={core:{invoke:async(command:string,args:any)=>{
   if(command!=='read_upload_file')throw Error('Unexpected native command');
   return readFileSync(args.path).toString('base64');
 }}};
 const local=await transferFile({name,localPath:path},'local');
 expect(local.path).toBe(path);
 const remote=await transferFile({name,localPath:path},'context:'+project);
 const manifest=await api<any>(`/api/projects/${project}/context/manifest`);
 expect(manifest.entries[remote.path.slice(8)]).toBeTruthy();
 const mission=await createMission({project,title:'Finder remote attachment validation',backend:'claudecode',model_override:'claude-sonnet-5',remote_node_id:'ashur',idempotency_key:crypto.randomUUID(),prompt:`Read the attached file ${uploadToken(remote.path)} using a file tool. Return its exact contents only. Do not edit files, run other tasks, or delegate.`,attachments:[{kind:'context',path:remote.path}]});
 writeFileSync('/tmp/orb-finder-live-result.json',JSON.stringify({id:mission.id,localPath:local.path,contextPath:remote.path,marker}));
 for(let i=0;i<60;i++){
  await new Promise(resolve=>setTimeout(resolve,2000));
  const current=await api<any>(`/api/control/missions/${mission.id}`);
  if(current.history?.some((m:any)=>m.role==='assistant'&&m.content.includes(marker))){
   writeFileSync('/tmp/orb-finder-live-result.json',JSON.stringify({id:mission.id,localPath:local.path,contextPath:remote.path,verified:true}));
   return;
  }
  if(current.status==='failed')throw Error('Test mission failed: '+current.status_message);
 }
 throw Error('Timed out waiting for file contents from test mission');
},150000);
