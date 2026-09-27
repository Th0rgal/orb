import {api,connectionVersion} from './api';
import {contextManifest} from './projectContext';
import {encoded,type UploadSource} from './uploads';
export const CONTEXT_FILE_LIMIT=10*1024*1024;
export const CONTEXT_PROJECT_LIMIT=100*1024*1024;
/** Upload immutable bytes before publishing a conditional, versioned path. */
export async function importProjectFiles(slug:string,folder:string,sources:UploadSource[]):Promise<{paths:string[];warnings:string[]}>{
 const version=connectionVersion(),check=()=>{if(version!==connectionVersion())throw Error('Connection changed. Import stopped.');};
 if(folder.split('/').some(part=>part==='.'||part==='..')||folder.startsWith('/')||folder.includes('\\'))throw Error('Invalid destination folder.');
 const manifest=await contextManifest(slug);check();
 const paths:string[]=[],warnings:string[]=[];let size=Object.values(manifest.entries).reduce((sum,e)=>sum+e.size,0);
 const names=new Set(Object.keys(manifest.entries));
 for(const source of sources){
  check();
  try{
   if(!source.name||/[\\/\x00-\x1f]/.test(source.name)||['.','..'].includes(source.name))throw Error('Invalid file name.');
   if(source.file&&source.file.size>CONTEXT_FILE_LIMIT)throw Error('Too large to synchronize (10 MiB maximum per file).');
   const data=await encoded(source,CONTEXT_FILE_LIMIT);check();
   const bytes=Uint8Array.from(atob(data),c=>c.charCodeAt(0));
   if(bytes.length>CONTEXT_FILE_LIMIT)throw Error('Too large to synchronize (10 MiB maximum per file).');
   if(size+bytes.length>CONTEXT_PROJECT_LIMIT)throw Error('Shared context would exceed its 100 MiB project limit.');
   const dot=source.name.lastIndexOf('.'),stem=dot>0?source.name.slice(0,dot):source.name,ext=dot>0?source.name.slice(dot):'';
   const base=folder?folder.replace(/\/$/,'')+'/':'';
   let path=base+source.name,suffix=2;while(names.has(path))path=`${base}${stem} (${suffix++})${ext}`;
   const route=`/api/projects/${encodeURIComponent(slug)}/context`;
   const blob=await api<{hash:string}>(`${route}/blobs`,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:bytes});check();
   const receipt=await api<{conflict:boolean}>(`${route}/operations`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:crypto.randomUUID(),path,base:null,hash:blob.hash,directory:false,delete:false,source:'Orb file import'})});check();
   if(receipt.conflict)throw Error('Another file appeared at this path. The existing file was preserved; retry the import.');
   size+=bytes.length;names.add(path);paths.push(path);
  }catch(error){check();warnings.push(`${source.name}: ${error instanceof Error?error.message:String(error)}`);}
 }
 if(paths.length)window.dispatchEvent(new CustomEvent('orb:context-imported',{detail:{slug,paths}}));
 return {paths,warnings};
}
