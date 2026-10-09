import {createSignal} from 'solid-js';
import {render} from 'solid-js/web';
import {QueuedMessages} from '../src/QueuedMessages';
import {enqueueLocalMessage,queuedLocalMessages} from '../src/localMessageQueue';
import {createQueuedEdit} from '../src/queuedEdit';
import {Composer} from '../src/App';
import '../src/styles.css';
const request={id:'queue-fixture',harness:'claudecode',bin:'claude',cwd:'/work',prompt:''};
await enqueueLocalMessage({...request,prompt:'ceci est un message dans la queue'},'ceci est un message dans la queue');
await enqueueLocalMessage({...request,prompt:'et en voici un autre'},'et en voici un autre');
const [revision,setRevision]=createSignal<{text:string;append:boolean}>();
const [pendingList,setPendingList]=createSignal<{id:ReturnType<typeof crypto.randomUUID>;text:string}[]>([]);
const cancelledPending=new Set<string>();
let sendingIds:ReturnType<typeof crypto.randomUUID>[]=[];
let sendChain:Promise<void>=Promise.resolve();
Object.assign(window,{queueSettled:()=>sendChain});
render(()=>{
 // Same wiring as the conversation view in App.tsx.
 const edit=createQueuedEdit({setRevision,onError:message=>console.error(message)});
 return <main style={{padding:'32px','max-width':'760px',margin:'160px auto 0'}}>
  <QueuedMessages mission="queue-fixture" editing={edit.editing()} pending={!edit.editing()?pendingList():undefined} onCancelPending={id=>{cancelledPending.add(id);setPendingList(prev=>prev.filter(item=>item.id!==id));}} onEdit={row=>void edit.start(row)}/>
  <Composer allowConcurrentSend revision={revision()} busy placeholder="Send follow-up" onDraft={edit.trackDraft}
   editingQueued={edit.editing()?{onCancel:()=>edit.finish(true)}:undefined}
   onEmptySubmit={()=>{(window as unknown as {queueSent:number}).queueSent=((window as unknown as {queueSent?:number}).queueSent??0)+1;}}
   onEditFirstQueued={()=>{const first=queuedLocalMessages('queue-fixture').find(r=>r.waiting&&r.state==='queued'&&!r.error);if(first)void edit.start({id:first.id,text:first.text});}}
   onPending={draft=>{if(!draft)return;const nextId=crypto.randomUUID();sendingIds.push(nextId);if(!edit.editing())setPendingList(prev=>[...prev,{id:nextId,text:draft.text}]);}}
   onSend={(text)=>{const attemptId=sendingIds.shift()??crypto.randomUUID();const id=edit.editing();const run=sendChain.then(async()=>{if(cancelledPending.has(attemptId))return true;await enqueueLocalMessage({...request,prompt:text},text,id?{id:id as ReturnType<typeof crypto.randomUUID>,replace:true}:{id:attemptId});setPendingList(prev=>prev.filter(item=>item.id!==attemptId));if(id)edit.finish(false);return true;});sendChain=run.then(()=>undefined,()=>undefined);return run;}}
   onStop={()=>{}}/>
 </main>;
},document.getElementById('root')!);
