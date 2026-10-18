import '../src/styles.css';
import {syncSecretRequestNotices} from '../src/secretRequestNotices';
const base={status:'pending',all_projects:false,created_at:''};
const write={...base,id:'w1',kind:'write',mission_id:'1f3a9c1e-0000-0000-0000-000000000000',mission_title:'DGX Spark',key:'SPARK_ROUTER_API_KEY',reason:'API key for the DGX Spark model router (spark-de79, port 8000 / Funnel URL). Required by the router for clients outside the tailnet; to rotate it, store a new value.'};
const reads=[
 {...base,id:'r1',kind:'read',mission_id:'1f3a9c1e-0000-0000-0000-000000000000',mission_title:'DGX Spark',key:'HF_TOKEN',reason:'Download Leanstral weights'},
 {...base,id:'r2',kind:'read',mission_id:'1f3a9c1e-0000-0000-0000-000000000000',mission_title:'DGX Spark',key:'VERCEL_TOKEN',reason:'List env names of the autoresearch project'},
];
const w=window as any;
w.opened=false;
w.showOne=()=>syncSecretRequestNotices([write] as any,()=>{w.opened=true;});
w.showMany=()=>syncSecretRequestNotices([write,...reads] as any,()=>{w.opened=true;});
w.showOne();
