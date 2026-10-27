import '../src/styles.css';
import fixture from '../../shared/orb-spec/fixtures/approvals.json';
import {syncApprovalQueue} from '../src/approvalQueueNotices';
import {getApprovalQueue} from '../src/approvalQueue';
const reasons=['Deploy and verify the usage-limit fix on production.','Prune old docker images.','Download model weights.','Rotate the deploy token.'];
const at=(k:number,n:number)=>({id:`i${n}`,reason:reasons[n%reasons.length],created_at:'',digest:`d${n}`,...(fixture.labels[k].item as any)});
const w=window as any;
w.opened=false;
w.calls=[];
// Record what the card would send instead of reaching Core.
const realFetch=window.fetch;
// A Core that predates /api/approvals: the queue is 404, the per-kind lists answer.
w.legacyCore=false;
const legacyPrivilege={id:'p9',state:'pending',scope:'service_deploy',target_host:'agent-core',requester_mission_id:'7c1d2e3f-0000-4000-8000-000000000001',requester_title:'Ship usage fix',reason:'Deploy the approval queue to prod.',ttl_minutes:240,session_scoped:true,created_at:'2026-10-27T10:00:00Z'};
const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers:{'Content-Type':'application/json'}});
window.fetch=(async(input:any,init?:any)=>{const url=String(input);if(url.includes('/api/')){w.calls.push({url,method:init?.method??'GET',body:init?.body});const path=new URL(url,location.origin).pathname;
 if(w.legacyCore&&path==='/api/approvals/queue')return new Response('Not Found',{status:404});
 if(w.legacyCore&&path==='/api/privilege-access')return json({bunker_state:0,requests:[legacyPrivilege],audit:[],command_audit:[]});
 if(w.legacyCore&&path==='/api/bitwarden/broker')return json({requests:[],grants:[],audit:[]});
 if(w.legacyCore&&path==='/api/mission-access')return json({requests:[],audit:[]});
 return json({});}return realFetch(input,init);}) as any;
w.loadFromLegacyCore=async()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');w.legacyCore=true;const {items}=await getApprovalQueue();syncApprovalQueue(items,()=>{w.opened=true;});};
// deploy, root, secret read, secret write, mission access
w.items={one:[at(0,0)],many:[at(0,0),at(1,1),at(2,2),at(3,3),at(7,4)]};
w.show=(k:'one'|'many')=>syncApprovalQueue(w.items[k],()=>{w.opened=true;});
w.addDock=()=>{
 const dock=document.createElement('div');dock.className='dock';dock.style.cssText='position:fixed;left:300px;right:40px;bottom:0;margin:0;padding:10px 34px 16px';
 dock.innerHTML='<div class="col"><div class="composer" style="height:80px"></div></div>';document.body.appendChild(dock);
 const side=document.createElement('div');side.style.cssText='position:fixed;right:0;bottom:0;width:200px';
 side.innerHTML='<div class="composer" style="height:40px"></div>';document.body.appendChild(side);
};
w.show('one');
