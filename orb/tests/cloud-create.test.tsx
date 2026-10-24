import { render, screen, fireEvent, waitFor, cleanup } from '@solidjs/testing-library';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CloudAgentPage } from '../src/CloudAgents';
import { CLOUD_PROVIDER_KEY, defaultCloudProvider } from '../src/cloudAgentApi';
const fakes = vi.hoisted(() => ({ accounts: vi.fn(), launch: vi.fn() }));
vi.mock('../src/cloudAgentApi', async original => ({...await original<object>(), cloudAccounts:fakes.accounts, launchCloud:fakes.launch}));
// A thin stand-in for the shared composer: the field, "+" and send as it wires them.
vi.mock('../src/composer/Composer', () => ({floatingDock: () => {}, Composer: (p: any) => {
 let value = '';
 return <div class="composer">
  {p.textOnly ? (p.attachDisabledReason ? <button class="plus" disabled title={p.attachDisabledReason} aria-label="Attach file or image" /> : null) : <button class="plus" aria-label="Attach file or image" />}
  <textarea aria-label={p.inputLabel} onInput={e => { value = e.currentTarget.value; }} />
  {p.controls}
  <button aria-label={p.sendLabel} disabled={p.disabled} onClick={() => { const text = value; value = ''; void Promise.resolve(p.onSend(text, [])).then(ok => { if (ok === false) value = text; }); }} />
 </div>;
}}));
vi.mock('../src/api', () => ({api:vi.fn(async () => ({models:{items:[]},repositories:{items:[]}}))}));
afterEach(() => {cleanup();vi.clearAllMocks();});
const capabilities = {models:false,repository:false,follow_up:false,cancel:false,artifacts:false,attachments:false,detailed_events:false};
describe('cloud creation', () => {
 it('keeps unvalidated providers disabled and offers exactly the three services', async () => {
  fakes.accounts.mockResolvedValue([{id:'grok',provider:'grok_bot',label:'Grok Bot',available:false,experimental:true,reason:'Protocol not validated',capabilities}]);
  render(() => <CloudAgentPage project="demo" path="notes" onCreated={() => {}} />);
  fireEvent.click(screen.getByLabelText('Service'));
  expect(screen.getAllByRole('option').map(e => e.textContent?.replace('✓','').trim())).toEqual(['Grok Bot','Cursor Cloud','Hermes']);
  fireEvent.click(screen.getByRole('option',{name:'Grok Bot'}));
  await screen.findByText('Protocol not validated');
  expect((screen.getByRole('button',{name:'Attach file or image'}) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByRole('button',{name:'Attach file or image'}).title).toMatch(/Grok Bot doesn’t accept attachments/);
  expect((screen.getByRole('button',{name:'Create cloud agent'}) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByLabelText('Repository')).toBeNull();
  expect(screen.queryByLabelText('Machine')).toBeNull();
  expect(screen.queryByRole('dialog')).toBeNull();
  expect(screen.getByRole('region', {name:'Cloud agent'}).classList.contains('new-agent')).toBe(true);
 });
 it('reuses the launch key after an uncertain response and preserves the folder', async () => {
  fakes.accounts.mockResolvedValue([{id:'profile',provider:'cursor_cloud',label:'Pro account',available:true,experimental:true,capabilities}]);
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
 it('shows the provider mark once, in the account chip, not inside the composer', async () => {
  fakes.accounts.mockResolvedValue([{id:'profile',provider:'cursor_cloud',label:'Pro account',available:true,experimental:false,capabilities}]);
  const { container } = render(() => <CloudAgentPage project="demo" onCreated={() => {}} />);
  await screen.findByText(/Pro account/);
  expect(container.querySelectorAll('.provider-logo')).toHaveLength(1);
  expect(container.querySelector('.composer .provider-logo')).toBeNull();
 });
});

describe('default cloud provider', () => {
 const acct = (provider: string, available = true) => ({id:provider, provider, label:provider, available, experimental:false, capabilities}) as any;
 it('prefers Hermes when it is available', () => {
  expect(defaultCloudProvider([acct('grok_bot'), acct('cursor_cloud'), acct('hermes')])).toBe('hermes');
 });
 it('falls back to the first available provider', () => {
  expect(defaultCloudProvider([acct('grok_bot', false), acct('hermes', false), acct('cursor_cloud')])).toBe('cursor_cloud');
  expect(defaultCloudProvider([acct('grok_bot', false)])).toBe('grok_bot');
  expect(defaultCloudProvider([])).toBe('hermes');
 });
 it('keeps the last explicit choice while that provider has an account', () => {
  expect(defaultCloudProvider([acct('cursor_cloud'), acct('hermes')], 'cursor_cloud')).toBe('cursor_cloud');
  expect(defaultCloudProvider([acct('hermes')], 'cursor_cloud')).toBe('hermes');
  expect(defaultCloudProvider([acct('hermes')], 'not-a-provider')).toBe('hermes');
 });
 it('opens the new-task page on Hermes, and on a persisted choice', async () => {
  fakes.accounts.mockResolvedValue([acct('cursor_cloud'), {...acct('hermes'), label:'Paloma'}]);
  const first = render(() => <CloudAgentPage project="demo" onCreated={() => {}} />);
  await screen.findByText('Paloma');
  first.unmount();
  localStorage.setItem(CLOUD_PROVIDER_KEY, 'cursor_cloud');
  render(() => <CloudAgentPage project="demo" onCreated={() => {}} />);
  await waitFor(() => expect(screen.getByLabelText('Service').textContent).toContain('Cursor Cloud'));
  localStorage.removeItem(CLOUD_PROVIDER_KEY);
 });
});
