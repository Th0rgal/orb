import {createSignal,onCleanup} from 'solid-js';
import {holdQueuedMessage,releaseQueuedMessage} from './localMessageQueue';
type Revision={text:string;append:boolean};
/** Editing a queued follow-up keeps its place: the queue is held, the composer
 * shows its text, and the draft typed before is restored afterwards. */
export function createQueuedEdit(o:{setRevision:(revision:Revision)=>void;onError:(message:string)=>void}){
 const [editing,setEditing]=createSignal<string>();
 const [editingRemote,setEditingRemote]=createSignal(false);
 let draft='',before='';
 const start=async(row:{id:string;text:string;remote?:boolean})=>{
  const prev=editing(),prevRemote=editingRemote();
  if(!row.remote){
   try{await holdQueuedMessage(row.id);}catch(e){o.onError(e instanceof Error?e.message:String(e));return;}
  }
  if(prev&&!prevRemote&&prev!==row.id)void releaseQueuedMessage(prev).catch(()=>{});
  if(!prev)before=draft;
  setEditingRemote(!!row.remote);
  setEditing(row.id);o.setRevision({text:row.text,append:false});
 };
 /** `release` resumes the queue without changes (cancel); a saved edit already released it. */
 const finish=(release:boolean)=>{
  const id=editing(),wasRemote=editingRemote();setEditing(undefined);setEditingRemote(false);
  if(release&&id&&!wasRemote)void releaseQueuedMessage(id).catch(()=>{});
  o.setRevision({text:before,append:false});before='';
 };
 onCleanup(()=>{const id=editing();if(id&&!editingRemote())void releaseQueuedMessage(id).catch(()=>{});});
 return {editing,editingRemote,start,finish,trackDraft:(text:string)=>{draft=text;}};
}
