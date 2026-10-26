import '../src/styles.css';
import fixture from '../../shared/orb-spec/fixtures/approvals.json';
import {syncApprovalQueue} from '../src/approvalQueueNotices';
const reasons=['Deploy and verify the usage-limit fix on production.','Prune old docker images.','Download model weights.','Rotate the deploy token.'];
const at=(k:number,n:number)=>({id:`i${n}`,reason:reasons[n%reasons.length],created_at:'',digest:`d${n}`,...(fixture.labels[k].item as any)});
const w=window as any;
w.opened=false;
w.calls=[];
// Record what the card would send instead of reaching Core.
const realFetch=window.fetch;
window.fetch=(async(input:any,init?:any)=>{const url=String(input);if(url.includes('/api/')){w.calls.push({url,method:init?.method,body:init?.body});return new Response('{}',{status:200,headers:{'Content-Type':'application/json'}});}return realFetch(input,init);}) as any;
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
