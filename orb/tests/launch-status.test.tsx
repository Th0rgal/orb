import { createSignal } from "solid-js";
import { render } from "@solidjs/testing-library";
import { expect, it } from "vitest";
import { LaunchStatus, MissionFailure, missionPhase } from "../src/missionLaunch";
import type { Mission } from "../src/api";

const remote = (job: Record<string, unknown> = {}) => ({
  id: "mission", status: "active", remote_job: { job_id: "job", phase: "observed", ...job },
  execution: { state: "waiting_remote_job" },
}) as Mission;

it("removes accepted startup feedback when transcript activity arrives without inferring Running", () => {
  const [activity, setActivity] = createSignal(false);
  const [mission, setMission] = createSignal(remote());
  const { container } = render(() => <><LaunchStatus destination="Spark" mission={mission()} activity={activity()} /><MissionFailure mission={mission()}/></>);
  expect(container.textContent).toContain("Waiting for the remote node to confirm execution");
  setActivity(true);
  expect(container.querySelector(".launch-status")).toBeNull();
  expect(missionPhase(mission(), true).label).toBe("Remote job accepted");
  setMission(remote({ node_state: "failed", exit_code: 1 }));
  expect(container.textContent).toContain("Remote job failed");
  expect(container.querySelector(".error-notice")).not.toBeNull();
});

it.each([
  [{ node_state: "queued" }, "Queued"],
  [{ phase: "unobserved" }, "Checking remote job"],
  [{ phase: "submit_ambiguous" }, "Checking submission"],
  [{ phase: "unobserved", exit_code: 1 }, "Remote job stopped"],
  [{ phase: "finished" }, "Remote job finished"],
] as const)("keeps actionable remote states visible despite old output: %j", (job, label) => {
  const { container } = render(() => <><LaunchStatus destination="Spark" mission={remote(job)} activity /><MissionFailure mission={remote(job)}/></>);
  if (missionPhase(remote(job), true).failed) expect(container.querySelector(".error-notice")).not.toBeNull();
  else expect(container.textContent).toContain(label);
});

it("does not allocate a routine running banner above an active transcript", () => {
  const { container } = render(() => <LaunchStatus destination="Spark" mission={remote({ node_state: "running" })} activity />);
  expect(container.querySelector(".launch-status")).toBeNull();
});


it("uses the transcript failure as the sole error, using a red notice when no error arrived", () => {
  const [inTranscript, setInTranscript] = createSignal(false);
  const mission = { id: "failed", status: "failed", terminal_reason: "harness exited" } as Mission;
  const { container } = render(() => <><LaunchStatus destination="Core" mission={mission} failureInTranscript={inTranscript()} /><MissionFailure mission={mission} failureInTranscript={inTranscript()}/></>);
  expect(container.textContent).toContain("Mission failed");
  expect(container.querySelector(".error-notice")).not.toBeNull();
  setInTranscript(true);
  expect(container.querySelector(".launch-status")).toBeNull();
});

it.each(['awaiting_user','waiting_user'])('keeps a normal completed response quiet in %s',status=>{
 const mission={id:'local',status} as Mission;
 const [activity,setActivity]=createSignal(false);
 const {container}=render(()=><LaunchStatus destination="This computer" mission={mission} activity={activity()}/>);
 expect(container.textContent).toContain('Ready for a follow-up');
 setActivity(true);
 expect(container.querySelector('.launch-status')).toBeNull();
});
it('does not claim a native run is idle based on stale backend status',()=>{
 const mission={id:'local',status:'awaiting_user'} as Mission;
 const {container}=render(()=><LaunchStatus destination="This computer" mission={mission} activity submitting/>);
 expect(container.querySelector('.launch-status')).toBeNull();
});


it("shows waiting for first output instead of a silent prompt-only active mission", () => {
  const [activity, setActivity] = createSignal(false);
  const mission = { id: "stalled", status: "active" } as Mission;
  const { container } = render(() => <LaunchStatus destination="Core" mission={mission} activity={activity()} />);
  expect(container.textContent).toContain("Waiting for the first output");
  setActivity(true);
  expect(container.querySelector(".launch-status")).toBeNull();
});

it("describes a Core restart as an interruption, not a failed native task", () => {
  const [mission, setMission] = createSignal({ id: "native", status: "interrupted", terminal_reason: "service_restart", tags: ["placement:client"] } as Mission);
  const { container } = render(() => <MissionFailure mission={mission()} />);
  expect(container.textContent).toContain("Mission interrupted");
  expect(container.textContent).toContain("does not confirm that the agent on your computer stopped");
  expect(container.textContent).not.toContain("Mission failed");
  setMission({ ...mission(), status: "completed", terminal_reason: "client_runner" });
  expect(container.querySelector(".error-notice")).toBeNull();
});

it('shows a scheduled recovery as waiting, offers actions, and clears it on Stop or Resume', async () => {
 const {vi}=await import('vitest');
 const resume=vi.fn(), cancel=vi.fn();
 const waiting={id:'retry',status:'interrupted',terminal_reason:'usage_limit_wait',recovery:{kind:'transient',reason:'Antigravity transient upstream error',resume_at:'2026-10-09T19:00:00Z',attempt:3,max_attempts:12}} as Mission;
 const [mission,setMission]=createSignal(waiting);
 const [pending,setPending]=createSignal(false);
 const {container,getByRole}=render(()=><><LaunchStatus destination="old-agent" mission={mission()} activity onResume={resume} onCancelRecovery={cancel} recoveryPending={pending()}/><MissionFailure mission={mission()}/></>);
 expect(container.textContent).toContain('Recovery scheduled');
 expect(container.textContent).toContain('attempt 3/12');
 expect(container.querySelector('.error-notice')).toBeNull();
 getByRole('button',{name:'Resume now'}).click();expect(resume).toHaveBeenCalledTimes(1);
 getByRole('button',{name:'Cancel recovery'}).click();expect(cancel).toHaveBeenCalledTimes(1);
 setPending(true);
 getByRole('button',{name:'Resume now'}).click();
 getByRole('button',{name:'Cancel recovery'}).click();
 expect(resume).toHaveBeenCalledTimes(1);expect(cancel).toHaveBeenCalledTimes(1);
 setMission({...waiting,status:'paused'});
 expect(container.textContent).not.toContain('Recovery scheduled');
 setMission({...waiting,status:'active',remote_job:{node_state:'running'}} as Mission);
 expect(container.querySelector('.launch-status')).toBeNull();
});

it('explains a provider response length limit without calling it a quota or connection failure', () => {
 const mission={id:'length',status:'interrupted',terminal_reason:'usage_limit_wait',recovery:{kind:'output_limit',resume_at:'2026-10-09T19:00:00Z',attempt:1,max_attempts:12}} as Mission;
 const phase=missionPhase(mission,false);
 expect(phase.label).toBe('Recovery scheduled');
 expect(phase.detail).toContain('shorter responses');
 expect(phase.detail).not.toContain('connection');
});
