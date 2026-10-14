import {afterEach,expect,it,vi} from 'vitest';
import {cleanup,fireEvent,render,screen,waitFor} from '@solidjs/testing-library';
import {createSignal} from 'solid-js';
import {ContextBadge} from '../src/ContextBadge';
const mocks=vi.hoisted(()=>({invoke:vi.fn(),conflicts:vi.fn()}));
vi.mock('../src/clientRuns',()=>({nativeInvoke:()=>mocks.invoke}));
vi.mock('../src/projectContext',()=>({subscribeProjectContext:()=>()=>{},contextConflicts:mocks.conflicts}));
vi.mock('../src/api',()=>({getApiUrl:()=> 'https://example.test',getJwt:()=> 'token',connectionVersion:()=>0}));
afterEach(()=>{cleanup();vi.resetAllMocks();});
it('reads native status without waiting for the server and retries an offline cache',async()=>{
 mocks.conflicts.mockReturnValue(new Promise(()=>{}));
 mocks.invoke.mockResolvedValue({state:{initialized:true,pending:[],error:'Context server unavailable'}});
 render(()=><ContextBadge slug="test"/>);
 await fireEvent.click(await screen.findByRole('button',{name:/^Sync failed/}));
 expect(screen.getByText(/nothing is waiting to upload/)).toBeTruthy();
 mocks.invoke.mockResolvedValue({state:{initialized:true,pending:[],error:null}});
 await fireEvent.click(screen.getByRole('button',{name:'Retry now'}));
 await waitFor(()=>expect(mocks.invoke).toHaveBeenCalledWith('project_context_sync',{request:{endpoint:'https://example.test',token:'token',project:'test'}}));
 await waitFor(()=>expect(screen.queryByRole('button',{name:/^Sync failed/})).toBeNull());
});
it('ignores responses from the previous project',async()=>{
 let resolveOld!:(v:unknown)=>void;
 mocks.conflicts.mockResolvedValue({});
 mocks.invoke.mockImplementation((_command,{request})=>request.project==='old'?new Promise(resolve=>{resolveOld=resolve;}):Promise.resolve({state:{initialized:true,pending:[],error:null}}));
 const[slug,setSlug]=createSignal('old');
 render(()=><ContextBadge slug={slug()}/>);
 setSlug('new');
 resolveOld({state:{initialized:true,pending:[],error:'stale error'}});
 await waitFor(()=>expect(mocks.invoke).toHaveBeenCalledWith('project_context_status',expect.objectContaining({request:expect.objectContaining({project:'new'})})));
 expect(screen.queryByRole('button')).toBeNull();
});
it('exposes authorization failures and supports Escape',async()=>{
 mocks.conflicts.mockResolvedValue({});
 mocks.invoke.mockResolvedValue({state:{initialized:true,pending:[{}],error:'Context sync returned HTTP 401'}});
 render(()=><ContextBadge slug="test"/>);
 const button=await screen.findByRole('button',{name:'Context access required'});
 await fireEvent.click(button);
 expect(screen.getByText('1 local change waiting to sync.')).toBeTruthy();
 expect(screen.getByText('Check your backend connection in Settings.')).toBeTruthy();
 await fireEvent.keyDown(button,{key:'Escape'});
 expect(screen.queryByRole('region')).toBeNull();
});
it('retries automatically with a visible countdown',async()=>{
 vi.useFakeTimers({shouldAdvanceTime:true});
 try{
  mocks.conflicts.mockResolvedValue({});
  mocks.invoke.mockImplementation(async(command:string)=>({state:{initialized:true,pending:[],error:command==='project_context_sync'?null:'Context stream failed (500)'}}));
  render(()=><ContextBadge slug="test"/>);
  expect(await screen.findByRole('button',{name:/Sync failed · retrying in 10s/})).toBeTruthy();
  await vi.advanceTimersByTimeAsync(10_000);
  await waitFor(()=>expect(mocks.invoke).toHaveBeenCalledWith('project_context_sync',expect.anything()));
 }finally{vi.useRealTimers();}
});
