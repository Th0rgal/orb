import {createSignal} from 'solid-js';
import {render} from 'solid-js/web';
import {QueuedMessages} from '../src/QueuedMessages';
import {enqueueLocalMessage} from '../src/localMessageQueue';
import {createQueuedEdit} from '../src/queuedEdit';
import {Composer} from '../src/App';
import '../src/styles.css';
const request={id:'queue-fixture',harness:'claudecode',bin:'claude',cwd:'/work',prompt:''};
await enqueueLocalMessage({...request,prompt:'ceci est un message dans la queue'},'ceci est un message dans la queue');
await enqueueLocalMessage({...request,prompt:'et en voici un autre'},'et en voici un autre');
const [revision,setRevision]=createSignal<{text:string;append:boolean}>();
render(()=>{
 // Same wiring as the conversation view in App.tsx.
 const edit=createQueuedEdit({setRevision,onError:message=>console.error(message)});
 return <main style={{padding:'32px','max-width':'760px',margin:'160px auto 0'}}>
  <QueuedMessages mission="queue-fixture" editing={edit.editing()} onEdit={row=>void edit.start(row)}/>
  <Composer revision={revision()} busy placeholder="Send follow-up" onDraft={edit.trackDraft}
   editingQueued={edit.editing()?{onCancel:()=>edit.finish(true)}:undefined}
   onEmptySubmit={()=>{(window as unknown as {queueSent:number}).queueSent=((window as unknown as {queueSent?:number}).queueSent??0)+1;}}
   onSend={async(text)=>{const id=edit.editing();await enqueueLocalMessage({...request,prompt:text},text,id?{id:id as ReturnType<typeof crypto.randomUUID>,replace:true}:{});if(id)edit.finish(false);return true;}}
   onStop={()=>{}}/>
 </main>;
},document.getElementById('root')!);
