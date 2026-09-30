import { api, connectionVersion, getMission, type Mission } from './api';
import { machineIdentity, nativeInvoke } from './clientRuns';
import { localBinding, localDirectory, recordLocalFailure, refreshLocalAgents, rememberBinding, restoreLocalBindings } from './localAgents';
import { enqueueLocalMessage } from './localMessageQueue';

type Delivery = {id:ReturnType<typeof crypto.randomUUID>;target_mission_id?:string;content:string;scheduled?:boolean};
/** One inbox poll per computer, independent of the number of sessions.
 * Acknowledge only after saving locally; receipt tombstones prevent replays. */
export function startClientDelegations(missions: () => Mission[]) {
  if (!nativeInvoke()) return () => {};
  let stopped = false, busy = false;
  const version = connectionVersion();
  const valid = () => !stopped && version === connectionVersion();
  const tick = async () => {
    if (!valid() || busy) return;
    busy = true;
    try {
      const clientId = await machineIdentity();
      await restoreLocalBindings();
      const anchor = missions().find(mission => mission.tags?.includes('placement:client') &&
        (mission.tags.includes(`worker-client:${clientId}`) || !!localBinding(mission.id)));
      if (!anchor || !valid()) return;
      const post = <T>(id:string,body:object) => api<T>(`/api/control/missions/${id}/client-run`, {
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_id:clientId,...body}),
      });
      const inbox = await post<{messages:Delivery[]}>(anchor.id,{op:'inbox_all'});
      for (const message of inbox.messages ?? []) {
        if (!valid()) return;
        const id = message.target_mission_id ?? anchor.id;
        try {
          const mission = missions().find(m => m.id === id) ?? await getMission(id);
          if (!valid()) return;
          let binding = localBinding(id);
          if (!binding) {
            if (!mission.working_directory || !mission.backend) throw new Error('Worker needs a working directory and harness before it can start.');
            const rows = await refreshLocalAgents();
            const harness = rows.find(row => row.id === mission.backend && row.installed && row.path);
            if (!valid()) return;
            if (!harness?.path) throw new Error(`Install ${mission.backend} on this computer to start this worker.`);
            const cwd = await localDirectory(mission.working_directory);
            if (!valid()) return;
            binding = {cwd,harness:mission.backend,bin:harness.path,model:mission.model_override??undefined};
            await rememberBinding(id,binding);
            if (!valid()) return;
          }
          await enqueueLocalMessage({id,...binding,prompt:message.content},message.content,{id:message.id,delegated:true,waiting:false,scheduled:message.scheduled});
          if (!valid()) return;
          await post(id,{op:'received',message_id:message.id});
        } catch (error) { if (valid()) recordLocalFailure(id,error); }
      }
    } finally { busy = false; }
  };
  const run = () => { void tick().catch(() => {}); };
  run();
  const timer = setInterval(run, 10000);
  window.addEventListener('orb:refresh', run);
  return () => { stopped=true;clearInterval(timer);window.removeEventListener('orb:refresh',run); };
}
