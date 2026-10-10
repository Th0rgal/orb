import {render,screen,fireEvent,cleanup,waitFor} from '@solidjs/testing-library';
import {afterEach,describe,it,expect,vi} from 'vitest';
import {CyberPicker,MissionCyber,cyberCompatibility,draftCyber,setDraftCyber,requireCyberSupport} from '../src/cyberAccess';
import {describeError} from '../src/ErrorNotice';
vi.mock('../src/api',()=>({api:vi.fn(),connectionVersion:()=>0}));
import {api} from '../src/api';
afterEach(()=>{vi.mocked(api).mockReset();cleanup();setDraftCyber('standard');});
describe('cyber selection',()=>{
 it('refuses unsupported remote selections before creating a mission without changing the requested mode',async()=>{
  vi.mocked(api).mockResolvedValue({version:2,route_supported:false,refusal:'unsupported_access_program: Choose Automatic explicitly.'});
  await expect(requireCyberSupport({model:'gpt-6.1-sol',mode:'standard',remote:true})).rejects.toThrow('Choose Automatic');
  expect(draftCyber()).toBe('standard');
  expect(vi.mocked(api).mock.calls[0][0]).toContain('remote=true');
  await expect(requireCyberSupport({model:'gpt-6.1-sol',mode:'automatic',remote:true})).resolves.toBeUndefined();
  vi.mocked(api).mockResolvedValue({version:2});
  await expect(requireCyberSupport({model:'gpt-6.1-sol',mode:'standard',remote:true})).rejects.toThrow('cannot confirm');
 });
 it('disables unsupported remote programs while keeping Automatic an explicit choice',async()=>{
  vi.mocked(api).mockResolvedValue({version:2,route_supported:false});
  let selected='';render(()=><CyberPicker value="standard" model="gpt-6.1-sol" remote onChange={v=>selected=v}/>);
  await fireEvent.click(screen.getByRole('button',{name:'Cyber program: Standard'}));
  await waitFor(()=>expect((screen.getByRole('menuitemradio',{name:/Standard/}) as HTMLButtonElement).title).toContain('cannot guarantee'));
  expect((screen.getByRole('menuitemradio',{name:/Standard/}) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).disabled).toBe(true);
  await fireEvent.click(screen.getByRole('menuitemradio',{name:/Automatic/}));
  expect(selected).toBe('automatic');
 });
 it('checks Daybreak independently for models requiring that program',async()=>{
  vi.mocked(api).mockImplementation(async path=>({version:2,route_supported:String(path).includes('mode=daybreak')}));
  let selected='';render(()=><CyberPicker value="standard" model="gpt-daybreak-blue-latest" remote onChange={v=>selected=v}/>);
  await fireEvent.click(screen.getByRole('button',{name:'Cyber program: Standard'}));
  await waitFor(()=>expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).disabled).toBe(false));
  expect((screen.getByRole('menuitemradio',{name:/Standard/}) as HTMLButtonElement).disabled).toBe(true);
  await fireEvent.click(screen.getByRole('menuitemradio',{name:/Daybreak/}));
  expect(selected).toBe('daybreak');
 });
 it('retries a failed remote capability check when the menu reopens',async()=>{
  vi.mocked(api).mockRejectedValue(Error('network'));
  render(()=><CyberPicker value="standard" model="gpt-6.1-sol" remote onChange={()=>{}}/>);
  const trigger=screen.getByRole('button',{name:'Cyber program: Standard'});
  await fireEvent.click(trigger);
  await waitFor(()=>expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).title).toContain('Reopen'));
  await fireEvent.click(trigger);
  vi.mocked(api).mockResolvedValue({version:2,route_supported:true});
  await fireEvent.click(trigger);
  await waitFor(()=>expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).disabled).toBe(false));
 });
 it('applies route gating when editing an existing remote mission',async()=>{
  vi.mocked(api).mockImplementation(async path=>String(path).endsWith('/cyber')
   ?{mode:'standard',status:'requested',revision:'saved'}:{version:2,route_supported:false});
  render(()=><MissionCyber mission={{id:'remote-mission',status:'paused',title:'Existing',history:[],backend:'codex',model_override:'gpt-6.1-sol',remote_node_id:'ashur'}}/>);
  await fireEvent.click(await screen.findByRole('button',{name:'Cyber program: Standard'}));
  await waitFor(()=>expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).title).toContain('cannot guarantee'));
  expect((screen.getByRole('menuitemradio',{name:/Standard/}) as HTMLButtonElement).disabled).toBe(true);
 });
 it('keeps client-owned sessions editable despite historical remote placement',async()=>{
  vi.mocked(api).mockImplementation(async path=>String(path).endsWith('/cyber')
   ?{mode:'standard',status:'requested',revision:'saved'}:{version:2,route_supported:false});
  render(()=><MissionCyber mission={{id:'client-mission',status:'paused',title:'Client',history:[],tags:['placement:client'],backend:'codex',model_override:'gpt-6.1-sol',remote_node_id:'ashur'}}/>);
  await fireEvent.click(await screen.findByRole('button',{name:'Cyber program: Standard'}));
  expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).disabled).toBe(false);
  expect(vi.mocked(api).mock.calls.some(([path])=>String(path).includes('remote=true'))).toBe(false);
 });
 it('starts Standard and never calls a pending selection active',()=>{
  expect(draftCyber()).toBe('standard');
  render(()=><CyberPicker value="daybreak" model="gpt-6.1-sol" onChange={()=>{}}/>);
  expect(screen.getByRole('button',{name:'Cyber program: Daybreak'}).title).toContain('requested');
  expect(screen.queryByText('active')).toBeNull();
 });
 it('keeps the model and requires an explicit selection',async()=>{
  let selected='';render(()=><CyberPicker value="standard" model="gpt-6.1-sol" onChange={v=>selected=v}/>);
  await fireEvent.click(screen.getByRole('button',{name:'Cyber program: Standard'}));
  await fireEvent.click(screen.getByRole('menuitemradio',{name:/Daybreak/}));
  expect(selected).toBe('daybreak');
 });
 it('opens locked settings for inspection without allowing changes',async()=>{
  render(()=><CyberPicker value="standard" model="gpt-6.1-sol" disabled note="Saving selection…" onChange={()=>{}}/>);
  await fireEvent.click(screen.getByRole('button',{name:'Cyber program: Standard'}));
  expect(screen.getByRole('menu',{name:'Cyber program'})).toBeTruthy();
  expect((screen.getByRole('menuitemradio',{name:/Daybreak/}) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByRole('button',{name:'Cyber program: Standard'}).title).toContain('Saving selection');
  expect(screen.getByRole('menu').querySelector('small, p')).toBeNull();
 });
 it('disables incompatible choices and explains why',()=>{
  expect(cyberCompatibility('daybreak','unknown-model')).toContain('not been established');
  expect(cyberCompatibility('standard','gpt-daybreak-blue-latest')).toContain('requires Daybreak');
  expect(cyberCompatibility('daybreak','gpt-6-astra')).toBeUndefined();
 });
 it('preserves access denial and cyber policy as distinct errors',()=>{
  expect(describeError('403 access_program_not_enabled').title).toBe('Cyber access is not enabled');
  expect(describeError("unexpected status 403 Forbidden: Daybreak isn't available for this model. Turn off Daybreak or choose another model.").title).toBe('Daybreak is unavailable for this account or model');
  expect(describeError('cyberPolicy').title).toContain('policy');
  expect(describeError('unsupported_access_program').title).toContain('unsupported');
 });
});
