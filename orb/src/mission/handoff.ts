/**
 * When a Send now handoff is over. The handoff starts at the click while the
 * old turn may still be running; it ends once the mission has been seen
 * stopped and then running again (the new turn), or once a different remote
 * job runs. A failure ends it at once so the real state shows.
 */
import { isFailedStatus, isLive, remoteJobEnded, type Handoff } from "../missionStatus";

type Observed = {
  status?: string | null;
  remote_job?: { job_id?: string | null; phase?: string | null; node_state?: string | null; lease_state?: string | null; terminal_reason?: string | null; finished_at?: string | null } | null;
} | null | undefined;

export function createHandoffTracker() {
  let current: string | undefined, stopSeen = false, oldJob: string | null | undefined;
  return {
    reset() { current = undefined; stopSeen = false; oldJob = undefined; },
    /** Feed the latest mission snapshot; true when the handoff is over. */
    observe(handoff: Handoff, mission: Observed): boolean {
      const job = mission?.remote_job;
      if (current !== handoff.id) {
        current = handoff.id; stopSeen = false;
        oldJob = job && !remoteJobEnded(job) ? job.job_id ?? null : null;
      }
      if (!mission) return false;
      if (isFailedStatus(mission.status)) return true;
      const running = isLive(mission.status) && !(job && remoteJobEnded(job));
      if (!running) { stopSeen = true; return false; }
      const newJob = !!job?.job_id && oldJob !== undefined && oldJob !== null && job.job_id !== oldJob;
      return stopSeen || newJob;
    },
  };
}
