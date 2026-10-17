import '../src/styles.css';
import {syncSecretRequestNotices} from '../src/secretRequestNotices';
syncSecretRequestNotices([
 {id:'r1',kind:'read',status:'pending',mission_id:'0f3a9c1e-0000-0000-0000-000000000000',mission_title:"Je veux que tu regardes le repository d'autoresearch et que tu vérifies tout",key:'VERCEL_TOKEN',all_projects:false,reason:"Lister (noms seulement) les variables d'environnement du projet Vercel autoresearch pour vérifier qu'il ne manque aucun secret, puis comparer avec le fichier .env.example du dépôt",created_at:''},
 {id:'w1',kind:'write',status:'pending',mission_id:'1f3a9c1e-0000-0000-0000-000000000000',mission_title:'DGX Spark',key:'SPARK_ROUTER_API_KEY',all_projects:false,reason:'API key for the DGX Spark model router (spark-de79, port 8000 / Funnel URL). Required by the router for clients outside the tailnet.',created_at:''},
] as any,()=>{(window as any).opened=true;});
