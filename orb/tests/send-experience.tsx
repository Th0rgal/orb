// Offline visual fixture: no model call or production mutation.
import {render} from 'solid-js/web';
import '../src/styles.css';

localStorage.setItem('orb.selectedConversation','');
localStorage.setItem('orb.apiUrl',location.origin);
localStorage.setItem('orb.jwt','test');
localStorage.setItem('orb.machine','core');
localStorage.setItem('orb.harnessPick',JSON.stringify({backend:'codex',model:'gpt-6.1-sol'}));
let mission:any;
let eventController:ReadableStreamDefaultController<Uint8Array>|undefined;
let prompt='';let started=0;let first:Element|undefined;let firstY=0;
const report=document.createElement('output');report.id='send-measurement';report.style.cssText='position:fixed;top:0;left:300px;z-index:99999;background:#222;color:white;padding:6px';document.body.append(report);
let firstPaint=0,removed=0,maxShift=0;
new MutationObserver(()=>{
 if(!started)return;
 const row=Array.from(document.querySelectorAll('.main .scroll .user')).find(el=>el.textContent?.includes(prompt));
 if(row&&!first){first=row;firstY=row.getBoundingClientRect().y;firstPaint=performance.now()-started;}
 if(first){if(!first.isConnected)removed++;else maxShift=Math.max(maxShift,Math.abs(first.getBoundingClientRect().y-firstY));}
 const text=`First DOM: ${firstPaint.toFixed(1)} ms; removed: ${removed}; vertical shift: ${maxShift.toFixed(1)} px`;
 if(report.textContent!==text)report.textContent=text;
}).observe(document.getElementById('root')!,{childList:true,subtree:true});
document.addEventListener('click',e=>{if((e.target as Element).closest('button[title="Send"]')&&!started){prompt=(document.querySelector('textarea') as HTMLTextAreaElement)?.value;started=performance.now();}},true);
window.fetch=async(input,init)=>{
 const url=new URL(String(input),location.origin),path=url.pathname;
 if(path==='/api/control/missions'&&init?.method==='POST'){
  const body=JSON.parse(String(init.body));await new Promise(r=>setTimeout(r,1500));
  mission={id:'fixture-mission',title:'Send continuity',backend:'codex',status:'active',history:[{role:'user',content:body.prompt}],created_at:'',updated_at:'',project:'default'};
  setTimeout(()=>{eventController?.enqueue(new TextEncoder().encode(`event: user_message\ndata: ${JSON.stringify({id:'canonical',content:body.prompt})}\n\n`));},1000);
  return Response.json(mission);
 }
 if(path==='/api/control/stream')return new Response(new ReadableStream({start(c){eventController=c;}}),{headers:{'Content-Type':'text/event-stream'}});
 if(path.endsWith('/events'))return Response.json([],{headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':'0'}});
 if(path.endsWith('/conflicts'))return Response.json({});
 if(path==='/api/control/missions/fixture-mission')return Response.json(mission);
 if(path==='/api/control/missions')return Response.json(mission?[mission]:[]);
 if(path==='/api/control/queue')return Response.json([]);
 if(path==='/api/projects')return Response.json({projects:[{slug:'default',title:'Default'}]});
 if(path==='/api/backends')return Response.json([{id:'codex',name:'Codex'}]);
 if(path==='/api/providers/backend-models')return Response.json({backends:{codex:[{value:'gpt-6.1-sol',label:'GPT-6.1 Sol'}]}});
 if(path==='/api/remote-nodes')return Response.json({enabled:true,nodes:[]});
 if(path==='/api/model-routing/chains')return Response.json([]);
 if(path.endsWith('/files'))return Response.json({entries:[]});
 return Response.json({jobs:[],runs:[],nodes:[],projects:[]});
};
report.textContent='Loading fixture…';
void import('../src/App').then(({default:App})=>{report.textContent='Ready';render(()=><App/>,document.getElementById('root')!);}).catch(e=>{report.textContent=String(e);});
