import {createSignal,onCleanup} from 'solid-js';
import {holdQueuedMessage,releaseQueuedMessage} from './localMessageQueue';
type Revision={text:string;append:boolean};
/** Editing a queued follow-up keeps its place: the queue is held, the composer
 * shows its text, and the draft typed before is restored afterwards. */
export function createQueuedEdit(o:{setRevision:(revision:Revision)=>void;onError:(message:string)=>void}){
 const [editing,setEditing]=createSignal<string>();
 let draft='',before='';
 const start=async(row:{id:string;text:string})=>{
  try{await holdQueuedMessage(row.id);}catch(e){o.onError(e instanceof Error?e.message:String(e));return;}
  before=draft;setEditing(row.id);o.setRevision({text:row.text,append:false});
 };
 /** `release` resumes the queue without changes (cancel); a saved edit already released it. */
 const finish=(release:boolean)=>{
  const id=editing();setEditing(undefined);
  if(release&&id)void releaseQueuedMessage(id).catch(()=>{});
  o.setRevision({text:before,append:false});before='';
 };
 onCleanup(()=>{const id=editing();if(id)void releaseQueuedMessage(id).catch(()=>{});});
 return {editing,start,finish,trackDraft:(text:string)=>{draft=text;}};
}
