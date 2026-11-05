import type {DraftImage} from "./imageAttachments";
import type { UploadedFile } from "./uploads";
export interface ComposerDraft { mode?: "goal" | "plan" | "btw" | null; text:string; images:DraftImage[]; uploads?: UploadedFile[]; }
let database: Promise<IDBDatabase> | undefined;
// Closing and reopening a composer can beat IndexedDB. Keep the latest write
// visible synchronously, including while an older disk read is in flight.
const currentDrafts = new Map<string, ComposerDraft>();
function db(): Promise<IDBDatabase> {
 return database ??= new Promise((resolve,reject)=>{
  const request=indexedDB.open('orb-composer-drafts',1);
  request.onupgradeneeded=()=>request.result.createObjectStore('drafts');
  request.onsuccess=()=>resolve(request.result);
  request.onerror=()=>reject(request.error);
 });
}
export async function readComposerDraft(scope:string):Promise<ComposerDraft | undefined> {
 if (currentDrafts.has(scope)) return currentDrafts.get(scope);
 const database=await db();
 const stored = await new Promise<ComposerDraft | undefined>((resolve,reject)=>{
  const request=database.transaction('drafts').objectStore('drafts').get(scope);
  request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);
 });
 return currentDrafts.get(scope) ?? stored;
}
export async function saveComposerDraft(scope:string,draft:ComposerDraft):Promise<void> {
 currentDrafts.set(scope, draft);
 const database=await db();
 return new Promise((resolve,reject)=>{
  const transaction=database.transaction('drafts','readwrite');
  const store=transaction.objectStore('drafts');
  if (!draft.text && !draft.images.length && !draft.mode) store.delete(scope);else store.put(draft,scope);
  transaction.oncomplete=()=>resolve();transaction.onerror=()=>reject(transaction.error);
 });
}
/** Large side transcripts may include image bytes; keep them out of localStorage. */
export async function readSideThread<T>(scope:string):Promise<T|undefined> {
 const database=await db();
 return new Promise((resolve,reject)=>{const request=database.transaction('drafts').objectStore('drafts').get(`thread:${scope}`);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
}
export async function saveSideThread<T>(scope:string,value:T):Promise<void> {
 const database=await db();
 return new Promise((resolve,reject)=>{const tx=database.transaction('drafts','readwrite');tx.objectStore('drafts').put(value,`thread:${scope}`);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error);});
}
export async function updateSideThread<T>(
 scope: string,
 updater: (current: T | undefined) => T | undefined,
): Promise<{ updated: boolean; value: T | undefined }> {
 const database = await db();
 return new Promise((resolve, reject) => {
  const tx = database.transaction('drafts', 'readwrite');
  const store = tx.objectStore('drafts');
  const key = `thread:${scope}`;
  const req = store.get(key);
  let updated = false;
  let next: T | undefined;
  req.onsuccess = () => {
   try {
    next = updater(req.result as T | undefined);
    if (next !== undefined) {
     updated = true;
     store.put(next, key);
    }
   } catch (err) {
    tx.abort();
    reject(err);
   }
  };
  req.onerror = () => reject(req.error);
  tx.oncomplete = () => resolve({ updated, value: next });
  tx.onerror = () => reject(tx.error);
 });
}
