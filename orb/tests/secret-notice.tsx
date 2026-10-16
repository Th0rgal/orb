import '../src/styles.css';
import {syncSecretRequestNotices} from '../src/secretRequestNotices';
syncSecretRequestNotices([{id:'r1',kind:'read',status:'pending',mission_id:'0f3a9c1e-0000-0000-0000-000000000000',mission_title:"Je veux que tu regardes le repository d'autoresearch et que tu vérifies tout",key:'VERCEL_TOKEN',all_projects:false,reason:"Lister (noms seulement) les variables d'environnement du projet Vercel autoresearch pour vérifier qu'il ne manque aucun secret, puis comparer avec le fichier .env.example du dépôt",created_at:''}],()=>{(window as any).opened=true;});
