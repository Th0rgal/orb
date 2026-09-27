import type {Route} from '@playwright/test';
/** In-memory event endpoint implementing the same exclusive cursors as the backend. */
export function eventPage<T extends {sequence?:number}>(route:Route,events:readonly T[]) {
 const query=new URL(route.request().url()).searchParams;
 const since=query.get('since_seq'),before=query.get('before_seq');
 const page=events.filter(event=>(since===null||(event.sequence??0)>Number(since))&&(before===null||(event.sequence??0)<Number(before)));
 const sequence=page.flatMap(event=>typeof event.sequence==='number'?[event.sequence]:[]);
 const all=events.flatMap(event=>typeof event.sequence==='number'?[event.sequence]:[]);
 const headers:Record<string,string>={'Access-Control-Expose-Headers':'X-Orb-Events-Protocol, X-Has-More, X-Max-Sequence, X-Next-Cursor, X-Page-Max-Sequence','X-Orb-Events-Protocol':'1','X-Has-More':'false','X-Max-Sequence':String(all.length?Math.max(...all):0)};
 if(sequence.length){headers['X-Page-Max-Sequence']=String(Math.max(...sequence));headers['X-Next-Cursor']=String(since===null?Math.min(...sequence):Math.max(...sequence));}
 return {json:page,headers};
}
