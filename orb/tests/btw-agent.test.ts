vi.mock('../src/btwContext',()=>({prepareBtwContext:vi.fn(async(_s:any,context:string)=>({context,cursor:{sequence:10,visibleHash:'hash'}}))}));
import {it,expect,vi,afterEach} from 'vitest';
import {askBtwAgent,btwSession,stopBtw,btwTurnEvents} from '../src/btwAgent';
import {startLocal,localBinding} from '../src/localAgents';
vi.mock('../src/localAgents',()=>({localBinding:vi.fn(()=>undefined),restoreLocalBindings:async()=>{},localAgentForLaunch:async()=>({id:'opencode',installed:true,path:'/bin/opencode'}),refreshLocalAgents:async()=>[{id:'opencode',installed:true,path:'/bin/opencode'}],rememberBinding:vi.fn(),startLocal:vi.fn(async()=>({run_id:'run',generation:1})),followLocal:vi.fn(async()=>({text:'Read fixture',done:true,exit_code:0})),stopLocal:vi.fn(),localActivities:()=>[],reconcileLocalRun:vi.fn(async()=>{}),localLiveText:()=> 'Read fixture'}));
import {api,getMission,sendMissionMessage,cancelMission} from '../src/api';
vi.mock('../src/api',async original=>({...await original<typeof import('../src/api')>(),api:vi.fn(),getMission:vi.fn(),sendMissionMessage:vi.fn(),cancelMission:vi.fn(),appendClientTranscript:vi.fn(),setClientMissionStatus:vi.fn()}));
vi.mock('../src/stream',async original=>({...await original<typeof import('../src/stream')>(),getMissionEvents:vi.fn(async()=>[{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}])}));
afterEach(()=>{localStorage.clear();vi.clearAllMocks();});
it('creates a distinct side agent and never sends to the parent',async()=>{
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'child'});
 const events:any[]=[];
 await askBtwAgent('parent','Inspect the repo','Main context',[],new AbortController().signal,e=>events.push(e));
 expect(api).toHaveBeenCalledWith('/api/control/missions/parent/btw/agent',expect.objectContaining({body:expect.stringContaining('builtin/smart')}));
 expect(btwSession('parent')?.id).toBe('child');expect(events.at(-1).type).toBe('done');expect(sendMissionMessage).not.toHaveBeenCalled();
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValueOnce([]);
 await askBtwAgent('parent','Follow up','New context',[],new AbortController().signal,()=>{});
 expect(sendMissionMessage).toHaveBeenCalledWith('child',expect.stringContaining('New context'));
 await stopBtw('parent');expect(cancelMission).toHaveBeenCalledWith('child');
});
it('a missing agent endpoint fails without falling back to a normal fork',async()=>{
 vi.mocked(getMission).mockResolvedValue({id:'parent',status:'active',history:[],tags:[],title:null,created_at:'',updated_at:''});
 vi.mocked(api).mockRejectedValue(new Error('404'));
 await expect(askBtwAgent('parent','Q','',[],new AbortController().signal,()=>{})).rejects.toThrow('404');
 expect(api).toHaveBeenCalledTimes(1);expect(btwSession('parent')).toBeUndefined();
});

it('launches locally in the parent folder with a fresh session identity',async()=>{
 vi.mocked(localBinding).mockImplementation(id=>id==='local-parent'?{cwd:'/work/shared',harness:'claudecode',bin:'/bin/claude',sessionId:'never-reuse-parent'}:undefined);
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='local-parent'?'active':'awaiting_user',history:[],tags:id==='local-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'local-child'});
 await askBtwAgent('local-parent','Read this folder','context',[],new AbortController().signal,()=>{});
 expect(startLocal).toHaveBeenCalledWith(expect.objectContaining({id:'local-child',cwd:'/work/shared',harness:'opencode',model:'builtin/smart',sessionId:undefined}));
});

it('does not turn an empty successful exit into a fabricated answer',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([]);
 vi.mocked(getMission).mockImplementation(async(id)=>({id,status:id==='empty-parent'?'active':'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'empty-child'});
 const receive=vi.fn();
 await expect(askBtwAgent('empty-parent','Q','',[],new AbortController().signal,receive)).rejects.toThrow('No response was captured');
 expect(receive.mock.calls.some(([e])=>e.type==='done')).toBe(false);
});

it('never replays the previous answer underneath a new user question',()=>{
 const event=(sequence:number,event_type:string,content:string)=>({id:sequence,sequence,event_type,content,timestamp:''});
 const previous=event(4,'assistant_message','Previous CI answer');
 const next=event(7,'user_message','Explain Proof.lean');
 expect(btwTurnEvents([next,previous],{baseline:0})).toEqual([]);
 const answer=event(8,'assistant_message','Proof.lean is the entry point');
 expect(btwTurnEvents([answer,next,previous],{baseline:0})).toEqual([answer]);
 expect(btwTurnEvents([previous],{baseline:0,afterSequence:6})).toEqual([]);
});
it('advances the parent cursor only after an accepted send and resets it for a new model',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 const {sideQuestionKey}=await import('../src/sideQuestionStorage');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='cursor-parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'cursor-child'});
 await askBtwAgent('cursor-parent','Initial','first',[],new AbortController().signal,()=>{});
 expect(btwSession('cursor-parent')?.conversationCursor?.sequence).toBe(10);
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'delta',cursor:{sequence:20,visibleHash:'next'}});
 vi.mocked(sendMissionMessage).mockRejectedValueOnce(new Error('offline'));
 await expect(askBtwAgent('cursor-parent','Next','second',[],new AbortController().signal,()=>{})).rejects.toThrow('offline');
 expect(btwSession('cursor-parent')?.conversationCursor?.sequence).toBe(10);
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toEqual({sequence:10,visibleHash:'hash'});
 localStorage.setItem(sideQuestionKey('settings:btw'),JSON.stringify({harness:'opencode',model:'different'}));
 vi.mocked(api).mockResolvedValue({id:'new-child'});
 await askBtwAgent('cursor-parent','New model','third',[],new AbortController().signal,()=>{});
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
});

it('stages context on the committed transfer destination rather than a stale remote job',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Actual response',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='moved-parent'?'active':'awaiting_user',history:[],tags:[],title:'Main',created_at:'',updated_at:'',remote_job:{node_id:'old-node'},machine_transfer:{destination:{kind:'node',id:'new-node'}}} as any));
 vi.mocked(api).mockResolvedValue({id:'moved-child'});
 await askBtwAgent('moved-parent','Q','latest',[],new AbortController().signal,()=>{});
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[2]).toBe('new-node');
});

it('rejects generated empty-output status instead of claiming an answer',async()=>{
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:"Remote opencode job 00000000-0000-0000-0000-000000000000 on node 'old-agent' finished without assistant text (stop reason: unknown).",sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='empty-status-parent'?'active':'completed',history:[],tags:[],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'empty-status-child'});
 await expect(askBtwAgent('empty-status-parent','Q','latest',[],new AbortController().signal,()=>{})).rejects.toThrow('No response was captured');
});

it('replaces an explicitly refused side session only through the btw route and rearchives side history',async()=>{
 const {ApiError}=await import('../src/api');
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Status answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='replace-parent'?'active':'completed',history:[],tags:id==='replace-parent'?[]:['btw-parent:replace-parent'],title:'Main',created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValueOnce({id:'old-side'}).mockResolvedValueOnce({id:'new-side'});
 await askBtwAgent('replace-parent','Initial','first',[],new AbortController().signal,()=>{});
 vi.mocked(sendMissionMessage).mockRejectedValueOnce(new ApiError(409,'REMOTE_RESUME_REQUIRES_REPLACEMENT: no session'));
 const history=[{question:'Initial',answer:'Prior answer'}];
 await askBtwAgent('replace-parent','Status now?','delta',history as any,new AbortController().signal,()=>{});
 expect(btwSession('replace-parent')?.id).toBe('new-side');
 expect(vi.mocked(api).mock.calls.every(([path])=>path==='/api/control/missions/replace-parent/btw/agent')).toBe(true);
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[3]).toBeUndefined();
 expect(vi.mocked(prepareBtwContext).mock.calls.at(-1)?.[4]).toEqual(history);
 expect(JSON.parse(vi.mocked(api).mock.calls.at(-1)![1]!.body as string).side_context_mode).toBe('incremental');
});

it('finishes a local side response without waiting for Core to persist terminal status',async()=>{
 vi.mocked(localBinding).mockImplementation(id=>id==='native-parent'?{cwd:'/work/shared',harness:'opencode',bin:'/bin/opencode'}:undefined);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:'active',history:[],tags:id==='native-parent'?['placement:client']:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'native-child'});
 const receive=vi.fn();
 await askBtwAgent('native-parent','Q','context',[],new AbortController().signal,receive);
 expect(receive).toHaveBeenCalledWith({type:'done',answer:'Read fixture'});
 expect(btwSession('native-parent')?.active).toBe(false);
});


it('reconciles a restored local side run before subscribing',async()=>{
 const {reconcileLocalRun,followLocal}=await import('../src/localAgents');
 vi.mocked(localBinding).mockImplementation(id=>id==='recovery-parent'?{cwd:'/work/shared',harness:'claudecode',bin:'/bin/claude'}:undefined);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='recovery-parent'?'active':'awaiting_user',history:[],tags:id==='recovery-parent'?['placement:client']:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'recovery-child'});
 await askBtwAgent('recovery-parent','Check progress','context',[],new AbortController().signal,()=>{});
 expect(reconcileLocalRun).toHaveBeenCalledWith('recovery-child');
 expect(vi.mocked(reconcileLocalRun).mock.invocationCallOrder.at(-1)).toBeLessThan(vi.mocked(followLocal).mock.invocationCallOrder.at(-1)!);
});

it('reports remote capacity waits instead of pretending the side agent is answering', async()=>{
 const {btwQueueStatus}=await import('../src/btwAgent');
 expect(btwQueueStatus({status:'active',remote_job:{node_id:'old-agent',node_state:'queued'}} as any)).toBe('Waiting for capacity on old-agent…');
 expect(btwQueueStatus({status:'active',remote_job:{node_id:'old-agent',node_state:'running'}} as any)).toBe('');
 expect(btwQueueStatus({status:'pending'} as any)).toBe('Waiting to start…');
 expect(btwQueueStatus({status:'paused'} as any)).toBe('Side agent paused');
});

it.each(['pending','waiting_background','paused'])('does not create another side agent when a stale local flag hides a %s session',async(status)=>{
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='stale-parent'?'active':'awaiting_user',history:[],tags:[],created_at:'',updated_at:''}));
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'First answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(api).mockResolvedValue({id:'stale-child'});
 await askBtwAgent('stale-parent','First','',[],new AbortController().signal,()=>{});
 expect(btwSession('stale-parent')?.active).toBe(false);
 vi.mocked(getMission).mockImplementation(async id=>({id,status,history:[],tags:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockClear();
 await expect(askBtwAgent('stale-parent','Second','',[],new AbortController().signal,()=>{})).rejects.toThrow('still running');
 expect(api).not.toHaveBeenCalled();
});

it('replaces a deleted saved side mission without hiding other lookup errors',async()=>{
 const {ApiError}=await import('../src/api');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='deleted-parent'?'active':'awaiting_user',history:[],tags:[],created_at:'',updated_at:''}));
 vi.mocked(api).mockResolvedValue({id:'deleted-child'});
 await askBtwAgent('deleted-parent','First','',[],new AbortController().signal,()=>{});
 vi.mocked(getMission).mockRejectedValueOnce(new ApiError(503,'Unavailable'));
 await expect(askBtwAgent('deleted-parent','Next','',[],new AbortController().signal,()=>{})).rejects.toThrow('503');
 expect(btwSession('deleted-parent')?.id).toBe('deleted-child');
 vi.mocked(getMission).mockRejectedValueOnce(new ApiError(404,'Not found'));
 vi.mocked(api).mockResolvedValue({id:'replacement-child'});
 await askBtwAgent('deleted-parent','Next','',[],new AbortController().signal,()=>{});
 expect(btwSession('deleted-parent')?.id).toBe('replacement-child');
 expect(sendMissionMessage).not.toHaveBeenCalled();
});

it('rotates rejected content keys but retains uncertain launch keys',async()=>{
 const {ApiError}=await import('../src/api');
 vi.mocked(getMission).mockResolvedValue({id:'conflict-parent',status:'active',history:[],tags:[],title:null,created_at:'',updated_at:''});
 const ask=()=>askBtwAgent('conflict-parent','Q','context',[],new AbortController().signal,()=>{});
 const attempt=()=>JSON.parse(vi.mocked(api).mock.calls.at(-1)![1]!.body as string).idempotency_key;
 vi.mocked(api).mockRejectedValueOnce(new Error('network lost'));
 await expect(ask()).rejects.toThrow('network lost');
 const original=attempt();
 vi.mocked(api).mockRejectedValueOnce(new ApiError(409,'This side request key was already used for different launch content; the new question was not sent.'));
 await expect(ask()).rejects.toThrow('different launch content');
 expect(attempt()).toBe(original);
 vi.mocked(api).mockRejectedValueOnce(new Error('network lost again'));
 await expect(ask()).rejects.toThrow('network lost again');
 const fresh=attempt();expect(fresh).not.toBe(original);
 vi.mocked(api).mockRejectedValueOnce(new ApiError(503,'Unavailable'));
 await expect(ask()).rejects.toThrow('Unavailable');
 expect(attempt()).toBe(fresh);
});

it('replays the exact payload after a lost response despite fresh context paths',async()=>{
 const {prepareBtwContext}=await import('../src/btwContext');
 const {getMissionEvents}=await import('../src/stream');
 vi.mocked(getMission).mockImplementation(async id=>({id,status:id==='retry-parent'?'active':'awaiting_user',history:[],tags:[],title:null,created_at:'',updated_at:''}));
 vi.mocked(getMissionEvents).mockResolvedValue([{event_type:'assistant_message',content:'Recovered answer',sequence:1,id:1,timestamp:''}]);
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'manifest /first',cursor:{sequence:1,visibleHash:'first'}});
 vi.mocked(api).mockRejectedValueOnce(new Error('lost response'));
 await expect(askBtwAgent('retry-parent','Q','context',[],new AbortController().signal,()=>{})).rejects.toThrow('lost response');
 const original=vi.mocked(api).mock.calls.at(-1)![1]!.body;
 vi.mocked(prepareBtwContext).mockResolvedValueOnce({context:'manifest /second',cursor:{sequence:2,visibleHash:'second'}});
 vi.mocked(api).mockResolvedValueOnce({id:'recovered-child'});
 await askBtwAgent('retry-parent','Q','new context',[],new AbortController().signal,()=>{});
 expect(vi.mocked(api).mock.calls.at(-1)![1]!.body).toBe(original);
 expect(btwSession('retry-parent')?.conversationCursor).toEqual({sequence:1,visibleHash:'first'});
});
