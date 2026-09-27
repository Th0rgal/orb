import { render, screen, fireEvent, waitFor, cleanup } from '@solidjs/testing-library';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CloudAgentPage } from '../src/CloudAgents';
const fakes = vi.hoisted(() => ({ accounts: vi.fn(), launch: vi.fn() }));
vi.mock('../src/cloudAgentApi', async original => ({...await original<object>(), cloudAccounts:fakes.accounts, launchCloud:fakes.launch}));
vi.mock('../src/App', () => ({Composer: () => null, floatingDock: () => {}}));
vi.mock('../src/api', () => ({api:vi.fn(async () => ({models:{items:[]},repositories:{items:[]}}))}));
afterEach(() => {cleanup();vi.clearAllMocks();});
const capabilities = {models:false,repository:false,follow_up:false,cancel:false,artifacts:false,attachments:false,detailed_events:false};
describe('cloud creation', () => {
 it('keeps unvalidated providers disabled and offers exactly the three services', async () => {
  fakes.accounts.mockResolvedValue([{id:'grok',provider:'grok_bot',label:'Grok Bot',available:false,experimental:true,reason:'Protocol not validated',capabilities}]);
  render(() => <CloudAgentPage project="demo" path="notes" onCreated={() => {}} />);
  fireEvent.click(screen.getByLabelText('Service'));
  expect(screen.getAllByRole('menuitemradio').map(e => e.textContent?.replace('✓','').trim())).toEqual(['ChatGPT','Grok Bot','Cursor Cloud']);
  fireEvent.click(screen.getByRole('menuitemradio',{name:'Grok Bot'}));
  await screen.findByText('Protocol not validated');
  expect((screen.getByRole('button',{name:'Create cloud agent'}) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByLabelText('Repository')).toBeNull();
  expect(screen.queryByLabelText('Machine')).toBeNull();
  expect(screen.queryByRole('dialog')).toBeNull();
  expect(screen.getByRole('region', {name:'Cloud agent'}).classList.contains('new-agent')).toBe(true);
 });
 it('reuses the launch key after an uncertain response and preserves the folder', async () => {
  fakes.accounts.mockResolvedValue([{id:'profile',provider:'chatgpt',label:'Pro account',available:true,experimental:true,capabilities}]);
  fakes.launch.mockRejectedValue(new Error('Transport timeout'));
  render(() => <CloudAgentPage project="demo" path="notes" onCreated={() => {}} />);
  await screen.findByText(/Pro account/);
  fireEvent.input(screen.getByLabelText('Prompt'),{target:{value:'A bounded test'}});
  fireEvent.click(screen.getByRole('button',{name:'Create cloud agent'}));
  await screen.findByRole('alert');
  fireEvent.click(screen.getByRole('button',{name:'Create cloud agent'}));
  await waitFor(() => expect(fakes.launch).toHaveBeenCalledTimes(2));
  expect(fakes.launch.mock.calls[0][0].idempotency_key).toBe(fakes.launch.mock.calls[1][0].idempotency_key);
  expect(fakes.launch.mock.calls[0][0].tags).toEqual(['orb-folder:notes']);
  expect(fakes.launch.mock.calls[0][0]).not.toHaveProperty('working_directory');
 });
});
