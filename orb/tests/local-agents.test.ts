import { describe, expect, it, vi } from "vitest";
import { isSecretPath, quotePath, rewritePrompt, materializeMentions } from "../src/localAgents";
import type { AttachChip } from "../src/attach";

vi.mock('../src/cyberAccess', async importOriginal => ({
  ...await importOriginal<typeof import('../src/cyberAccess')>(),
  getCyber: vi.fn(async () => ({mode:'automatic',status:'requested',revision:'legacy'})),
}));

describe("local mention rewrite", () => {
  it("leaves unknown @words and rewrites a copied file", () => {
    const text = "see @notes/foo.md and email me @home";
    const out = rewritePrompt(text, [{ raw: "@notes/foo.md", absolute: "/tmp/orb/notes/foo.md" }]);
    expect(out).toBe("see /tmp/orb/notes/foo.md and email me @home");
  });

  it("quotes paths that contain spaces", () => {
    expect(quotePath("/tmp/my files/a.md")).toBe('"/tmp/my files/a.md"');
  });

  it("refuses secrets and unreadable files, and copies a readable one", async () => {
    expect(isSecretPath("notes/.env")).toBe(true);
    expect(isSecretPath("notes/foo.md")).toBe(false);
    const chips: AttachChip[] = [
      { id: "f", kind: "file", path: "notes/foo.md", label: "foo" },
      { id: "s", kind: "file", path: ".env", label: "env" },
    ];
    const ok = await materializeMentions(
      "demo",
      "read @notes/foo.md",
      chips,
      async () => "hello",
      async () => [],
    );
    expect(ok.files).toEqual([{ rel: ".paloma/attach/notes/foo.md", content: "hello" }]);
    expect(ok.prompt).toContain("__ROOT__/.paloma/attach/notes/foo.md");
    await expect(materializeMentions("demo", "read @.env", chips, async () => "", async () => [])).rejects.toThrow(/not copied/);
    await expect(
      materializeMentions("demo", "read @notes/foo.md", chips, async () => {
        throw new Error("missing");
      }, async () => []),
    ).rejects.toThrow(/could not be read/);
  });
});

it("restores native session bindings across webview origins", async () => {
  vi.resetModules();
  const { restoreLocalBindings, localBinding } = await import('../src/localAgents');
  const binding = {harness:'codex',bin:'/bin/codex',cwd:'/work',sessionId:'original-session'};
  const host = window as unknown as {__TAURI_INTERNALS__?: {invoke: () => Promise<unknown>}};
  const previous = host.__TAURI_INTERNALS__;
  localStorage.removeItem('orb.localBindings');
  const priorTauri=(window as any).__TAURI__;
  (window as any).__TAURI__={core:{Channel:class {onmessage=(_value:any)=>{};}}};
  host.__TAURI_INTERNALS__ = {invoke: async (...args:any[]) => {if(args[0]==='local_bindings_subscribe')args[1].onEvent.onmessage({revision:0,bindings:{mission:binding}});return 1;}};
  try {
    await restoreLocalBindings();
    expect(localBinding('mission')).toEqual(binding);
  } finally {
    window.dispatchEvent(new Event('pagehide'));
    host.__TAURI_INTERNALS__ = previous;(window as any).__TAURI__=priorTauri;
    localStorage.removeItem('orb.localBindings');
  }
});

it("restores native bindings even when the webview cache is corrupt", async () => {
  vi.resetModules();
  const { restoreLocalBindings, localBinding } = await import('../src/localAgents');
  const binding = {harness:'codex',bin:'/bin/codex',cwd:'/work',sessionId:'original-session'};
  const host = window as unknown as {__TAURI_INTERNALS__?: {invoke: () => Promise<unknown>}};
  const previous = host.__TAURI_INTERNALS__;
  localStorage.setItem('orb.localBindings', '{broken');
  const priorTauri=(window as any).__TAURI__;
  (window as any).__TAURI__={core:{Channel:class {onmessage=(_value:any)=>{};}}};
  host.__TAURI_INTERNALS__ = {invoke: async (...args:any[]) => {if(args[0]==='local_bindings_subscribe')args[1].onEvent.onmessage({revision:0,bindings:{mission:binding}});return 1;}};
  try {
    await restoreLocalBindings();
    expect(localBinding('mission')).toEqual(binding);
  } finally {
    window.dispatchEvent(new Event('pagehide'));
    host.__TAURI_INTERNALS__ = previous;(window as any).__TAURI__=priorTauri;
    localStorage.removeItem('orb.localBindings');
  }
});


it("serializes local sends through native recovery and retains the exact receipt", async () => {
  const { startLocal, reconcileLocalRun } = await import('../src/localAgents');
  const { clientRunReceipt } = await import('../src/clientRuns');
  const host = window as any, previous=host.__TAURI_INTERNALS__;
  let release!: (value: unknown) => void;
  const pending=new Promise(resolve=>release=resolve);
  const invoke=vi.fn((command:string)=>command==='local_agents_cyber_capabilities'?Promise.resolve(1):command==='local_run_launch'?pending:Promise.resolve({done:true,text:'',resumed:false}));
  host.__TAURI_INTERNALS__={invoke};
  const request={id:'recovery-send',harness:'codex',bin:'/bin/codex',cwd:'/work',prompt:'/plan test'};
  try {
    const first=startLocal(request);
    await reconcileLocalRun(request.id);
    await expect(startLocal(request)).rejects.toThrow('still running locally');
    const receipt={run_id:'new-generation',generation:6,prompt:'test'};release(receipt);
    expect(await first).toEqual(receipt);
    expect(await clientRunReceipt(request.id)).toEqual(receipt);
    expect(invoke.mock.calls.filter(c=>c[0]==='local_run_launch')).toHaveLength(1);
    await reconcileLocalRun(request.id);
  } finally {host.__TAURI_INTERNALS__=previous;}
});

it("resolves context at the cursor token without consuming punctuation or copying snapshots", async()=>{
 const host=window as unknown as {__TAURI_INTERNALS__?:{invoke:ReturnType<typeof vi.fn>}};
 const previous=host.__TAURI_INTERNALS__;
 const invoke=vi.fn().mockResolvedValue({root:"/local/shared context",state:{},resolved_paths:["context/notes.md","context/a b.md","context"]});host.__TAURI_INTERNALS__={invoke};
 try{
  const result=await materializeMentions("demo",'Read @context/notes.md. Then @"context/a b.md" and @context.', ['context/notes.md','context/a b.md','context'].map(path=>({id:path,kind:'context' as const,path,label:path,project:'demo'})));
  expect(result.prompt).toBe('Read "/local/shared context/context/notes.md". Then "/local/shared context/context/a b.md" and "/local/shared context/context".');
  expect(result.files).toEqual([]);
  expect(invoke.mock.calls[0][1].request.paths).toEqual(['context/notes.md','context/a b.md','context']);
 }finally{host.__TAURI_INTERNALS__=previous;}
});

it("links mentioned project folders to the live context so the agent's writes sync back", async()=>{
 const host=window as unknown as {__TAURI_INTERNALS__?:{invoke:ReturnType<typeof vi.fn>}};
 const previous=host.__TAURI_INTERNALS__;
 const chips: AttachChip[]=[{id:"c",kind:"folder",path:"Context",label:"Context"},{id:"f",kind:"file",path:"notes/foo.md",label:"foo"},{id:"s",kind:"file",path:".env",label:"env"}];
 const read=vi.fn(async()=>"copied");
 try{
  host.__TAURI_INTERNALS__={invoke:vi.fn().mockResolvedValue({root:"/local/ctx",state:{},resolved_paths:["Context","notes/foo.md"]})};
  const live=await materializeMentions("minecraft","Write the handover files in @Context and read @notes/foo.md",chips,read,async()=>[]);
  expect(live.prompt).toBe("Write the handover files in /local/ctx/Context and read /local/ctx/notes/foo.md");
  expect(live.files).toEqual([]);
  expect(read).not.toHaveBeenCalled();
  expect(host.__TAURI_INTERNALS__!.invoke.mock.calls[0][1].request.paths).toEqual(["Context","notes/foo.md"]);
  await expect(materializeMentions("minecraft","read @.env",chips,read,async()=>[])).rejects.toThrow(/not copied/);
  // Without the live replica the old file copy still works; unknown mentions remain text.
  host.__TAURI_INTERNALS__={invoke:vi.fn().mockRejectedValue(new Error("Context is not available on this computer"))};
  const copied=await materializeMentions("minecraft","read @notes/foo.md",chips,read,async()=>[]);
  expect(copied.files).toEqual([{rel:".paloma/attach/notes/foo.md",content:"copied"}]);
  await expect(materializeMentions("minecraft","read @context",chips,read,async()=>[])).rejects.toThrow("Context is not available");
 }finally{host.__TAURI_INTERNALS__=previous;}
});

it('waits for this window’s recovery before launching instead of racing its native lock', async () => {
  const {recoverLocalLaunch,startLocal} = await import('../src/localAgents');
  const host=window as unknown as {__TAURI_INTERNALS__?:{invoke:(command:string)=>Promise<unknown>}};
  const previous=host.__TAURI_INTERNALS__;
  let release!:()=>void;
  const recovering=new Promise<void>(resolve=>release=resolve);
  const invoke=vi.fn(async(command:string)=>{
    if(command==='local_agents_cyber_capabilities')return 1;
    if(command==='local_run_reconcile')return recovering;
    if(command==='local_agents_poll')return {done:true,text:''};
    if(command==='local_run_launch')return {run_id:'test-run',generation:1};
    return {};
  });
  host.__TAURI_INTERNALS__={invoke};
  try {
    const recovery=recoverLocalLaunch('recovery-race');
    const launch=startLocal({id:'recovery-race',harness:'codex',bin:'codex',cwd:'/work',prompt:'/goal test'});
    await Promise.resolve();
    expect(invoke.mock.calls.some(c=>c[0]==='local_run_launch')).toBe(false);
    release();await recovery;await launch;
    expect(invoke.mock.calls.filter(c=>c[0]==='local_run_reconcile')).toHaveLength(1);
    expect(invoke.mock.calls.filter(c=>c[0]==='local_run_launch')).toHaveLength(1);
  } finally {host.__TAURI_INTERNALS__=previous;}
});


it("keeps a discovered CLI available when an older native version probe fails", async () => {
  const {refreshLocalAgents, installedIds} = await import("../src/localAgents");
  const previous = (window as any).__TAURI__;
  (window as any).__TAURI__ = {core:{invoke:vi.fn().mockResolvedValue([
    {id:"opencode",bin:"opencode",path:"/opt/homebrew/bin/opencode",installed:false,version:null},
    {id:"grok",bin:"grok",path:null,installed:false,version:null},
  ])}};
  try {
    await refreshLocalAgents();
    expect(installedIds()).toEqual(["opencode"]);
  } finally { (window as any).__TAURI__ = previous; }
});

it('Stop drains an already invoked launch before reporting the mission stopped',async()=>{
 const {startLocal,stopLocal}=await import('../src/localAgents');
 const host=window as any,previous=host.__TAURI_INTERNALS__;
 let release!:(value:unknown)=>void;
 const pending=new Promise(resolve=>release=resolve);let running=false;
 const invoke=vi.fn(async(command:string)=>{
    if(command==='local_agents_cyber_capabilities')return 1;
  if(command==='local_run_launch'){const receipt=await pending;running=true;return receipt;}
  if(command==='local_agents_stop'){running=false;return;}
  if(command==='local_agents_poll')return {done:!running,text:''};
  return {};
 });host.__TAURI_INTERNALS__={invoke};
 try{
  const launch=startLocal({id:'stop-launch-race',harness:'codex',bin:'codex',cwd:'/work',prompt:'wake'});
  await vi.waitFor(()=>expect(invoke.mock.calls.some(c=>c[0]==='local_run_launch')).toBe(true));let stopped=false;
  const stop=stopLocal('stop-launch-race',{cancelWakeups:false}).then(()=>{stopped=true;});
  await Promise.resolve();await Promise.resolve();expect(stopped).toBe(false);
  release({run_id:'late-run',generation:1});await launch;await stop;
  expect(running).toBe(false);expect(invoke.mock.calls.filter(c=>c[0]==='local_agents_stop')).toHaveLength(2);
 }finally{host.__TAURI_INTERNALS__=previous;}
});

it('Stop prevents a launch waiting for native recovery from reaching IPC',async()=>{
 const {recoverLocalLaunch,startLocal,stopLocal}=await import('../src/localAgents');
 const host=window as any,previous=host.__TAURI_INTERNALS__;
 let release!:()=>void;const pending=new Promise<void>(resolve=>release=resolve);
 const invoke=vi.fn(async(command:string)=>command==='local_run_reconcile'?pending:command==='local_agents_poll'?{done:true,text:''}:{});
 host.__TAURI_INTERNALS__={invoke};
 try{
  const recovery=recoverLocalLaunch('stop-recovery-race');
  const launch=startLocal({id:'stop-recovery-race',harness:'codex',bin:'codex',cwd:'/work',prompt:'wake'});
  const rejected=expect(launch).rejects.toThrow('stopped before launch');
  await stopLocal('stop-recovery-race',{cancelWakeups:false});release();await recovery;await rejected;
  expect(invoke.mock.calls.some(c=>c[0]==='local_run_launch')).toBe(false);
 }finally{host.__TAURI_INTERNALS__=previous;}
});

it('new native launches wait for persisted Stop recovery',async()=>{
 const wakeups=await import('../src/localWakeups');
 let release!:()=>void;const recovery=new Promise<void>(resolve=>release=resolve);
 const replay=vi.spyOn(wakeups,'replayLocalWakeupStops').mockReturnValue(recovery);
 const {startLocal}=await import('../src/localAgents');
 const host=window as any,previous=host.__TAURI_INTERNALS__;
 const invoke=vi.fn(async(command:string)=>command==='local_agents_cyber_capabilities'?Promise.resolve(1):command==='local_run_launch'?{run_id:'fresh',generation:2}:{done:true,text:''});host.__TAURI_INTERNALS__={invoke};
 try{
  const launch=startLocal({id:'startup-stop-replay',harness:'codex',bin:'codex',cwd:'/work',prompt:'new turn'});
  await vi.waitFor(()=>expect(replay).toHaveBeenCalled());
  expect(invoke.mock.calls.some(c=>c[0]==='local_run_launch')).toBe(false);
  release();await launch;expect(invoke.mock.calls.some(c=>c[0]==='local_run_launch')).toBe(true);
 }finally{replay.mockRestore();host.__TAURI_INTERNALS__=previous;}
});


it('project skill preflight runs without mentions and preserves actionable failures', async () => {
 const { prepareProjectSkills } = await import('../src/localAgents');
 const host = window as any, previous = host.__TAURI_INTERNALS__;
 const invoke = vi.fn(async () => { throw new Error('Skill name collision at /work/.agents/skills/review. Your draft is kept.'); });
 host.__TAURI_INTERNALS__ = { invoke };
 try {
  await expect(prepareProjectSkills('orb-project-skills-test', '/work', 'codex')).rejects.toThrow('Skill name collision');
  expect(invoke).toHaveBeenCalledWith('project_skills_prepare', expect.objectContaining({
   request: expect.objectContaining({ project: 'orb-project-skills-test', paths: [] }), cwd: '/work', harness: 'codex',
  }));
 } finally { host.__TAURI_INTERNALS__ = previous; }
});


it('typed @context/skills and @context/Context resolve to originals without attachment chips', async () => {
 const host = window as any, previous = host.__TAURI_INTERNALS__;
 const invoke = vi.fn().mockResolvedValue({root:'/synced/original',state:{},resolved_paths:['skills/review/SKILL.md','Context']});
 host.__TAURI_INTERNALS__ = {invoke};
 try {
  const result = await materializeMentions('project', 'Edit @context/skills/review/SKILL.md and read @context/Context.', []);
  expect(result.prompt).toBe('Edit /synced/original/skills/review/SKILL.md and read /synced/original/Context.');
  expect(result.files).toEqual([]);
  expect(invoke.mock.calls[0][1].request.paths).toEqual(['context/skills/review/SKILL.md','context/Context']);
 } finally {host.__TAURI_INTERNALS__ = previous;}
});

it('rejects an old native binary before invoking a Codex launch',async()=>{
 const {startLocal}=await import('../src/localAgents');
 const host=window as any,previous=host.__TAURI_INTERNALS__;
 const invoke=vi.fn(async(..._args:any[])=>({done:true,text:''}));host.__TAURI_INTERNALS__={invoke};
 try{
  await expect(startLocal({id:'old-cyber-native',harness:'codex',bin:'codex',cwd:'/work',prompt:'test'})).rejects.toThrow('Update Orb desktop');
  expect(invoke.mock.calls.some((c:any)=>c[0]==='local_run_launch')).toBe(false);
 }finally{host.__TAURI_INTERNALS__=previous;}
});
