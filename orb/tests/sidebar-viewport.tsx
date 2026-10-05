import {render} from 'solid-js/web';
import {batch,createSignal} from 'solid-js';
import {SidebarTree} from '../src/Tree';
const nodes=(prefix:string,count:number)=>Array.from({length:count},(_,i)=>({id:`${prefix}${i}`,data:{label:`${prefix}${i}`}}));
function Fixture() {
  const [archived,setArchived]=createSignal(nodes('archive',30));
  const [projects,setProjects]=createSignal(nodes('project',60));
  const row=(r:{data:{label:string}})=><button style={{height:'32px'}}>{r.data.label}</button>;
  return <><button onClick={()=>setArchived(rows=>rows.slice(1))}>Remove archived row</button>
    <button onClick={()=>setProjects(rows=>rows.slice(1))}>Remove project row</button>
    <button onClick={()=>batch(()=>{
      const row=projects().find(row=>row.id==='project18')!;
      setProjects(rows=>rows.filter(item=>item!==row));
      setArchived(rows=>[...rows,row]);
    })}>Archive visible project</button>
    <div class="sb-scroll" style={{height:'300px',overflow:'auto'}}>
      <SidebarTree nodes={projects()} label="Projects" selected={null} render={row}/>
      <SidebarTree nodes={archived()} label="Archived" selected={null} render={row}/>
    </div></>;
}
render(()=><Fixture/>,document.getElementById('root')!);
