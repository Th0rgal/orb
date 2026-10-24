import {render,screen,fireEvent,cleanup} from '@solidjs/testing-library';
import {afterEach,expect,it,vi} from 'vitest';
const mocks=vi.hoisted(()=>({accounts:vi.fn(),open:vi.fn(),usage:vi.fn().mockResolvedValue({accounts:{}})}));
vi.mock('../src/cloudAgentApi',async()=>({...await vi.importActual('../src/cloudAgentApi'),cloudAccounts:mocks.accounts}));
vi.mock('../src/api',()=>({connectionVersion:()=>1,openExternalUrl:mocks.open,api:mocks.usage}));
import {CloudProviders} from '../src/CloudProviders';
import {ProviderUsageMeter} from '../src/ProviderUsageMeter';
afterEach(()=>{cleanup();vi.clearAllMocks();});
it('groups cloud profiles, shows reconnect and never invents quotas',async()=>{
 mocks.accounts.mockResolvedValue([
 {id:'grok-1',provider:'grok_bot',label:'Grok Bot · account@example.com',available:true},
 {id:'grok-2',provider:'grok_bot',label:'Grok Bot · second',available:false,reason:'RequiresLogin'},
 {id:'cursor-default',provider:'cursor_cloud',label:'Cursor Cloud',available:true}]);
 render(()=><CloudProviders/>);
 expect(screen.getByRole('status').textContent).toContain('Loading');
 await screen.findByText('1 of 2 profiles available');
 fireEvent.click(screen.getByRole('button',{name:/Grok Bot/}));
 expect(screen.getByText('Reconnect')).toBeTruthy();
 expect(screen.getByText('second')).toBeTruthy();
 fireEvent.click(screen.getByRole('button',{name:/Cursor Cloud/}));
 expect(screen.queryByRole('progressbar')).toBeNull();
 fireEvent.click(screen.getByRole('button',{name:/View usage in Cursor/}));
 expect(mocks.open).toHaveBeenCalledWith('https://cursor.com/dashboard/usage');
});
it('shows an explicit service error and allows retry',async()=>{
 mocks.accounts.mockRejectedValueOnce(new Error('Cloud service unavailable')).mockResolvedValueOnce([]);
 render(()=><CloudProviders/>);await screen.findByRole('alert');
 fireEvent.click(screen.getByRole('button',{name:'Retry'}));
 await screen.findByText('No cloud accounts configured.');
});
it('renders measured quotas accessibly and omits unknown values',()=>{
 render(()=><><ProviderUsageMeter label="API" usedPct={38}/><ProviderUsageMeter label="Unknown" usedPct={NaN}/></>);
 const bar=screen.getByRole('progressbar');expect(bar.getAttribute('aria-valuenow')).toBe('38');
 expect(screen.queryByText('Unknown')).toBeNull();
});
