import { render, screen, cleanup } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { CloudConversation } from '../src/CloudAgents';
const fakes = vi.hoisted(() => ({ execution: vi.fn() }));
vi.mock('../src/cloudAgentApi', async original => ({...await original<object>(), cloudAccounts: vi.fn(async () => []), cloudExecution: fakes.execution}));
vi.mock('../src/App', () => ({Composer: () => null, floatingDock: () => {}}));
vi.mock('../src/api', () => ({api: vi.fn(), getMission: vi.fn(async () => null), openExternalUrl: vi.fn()}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const turn = (phase: string, extra = {}) => ({key: 't1', prompt: 'Refais-moi un quiz', phase, artifacts: [], branches: [], model_params: [], ...extra});
const execution = (t: object) => ({mission_id: 'm', revision: 1, selection: {provider: 'chatgpt', account: 'chatgpt-profile'}, turns: [t]});

it('shows that a ChatGPT turn is starting, then thinking, with elapsed time', async () => {
  fakes.execution.mockResolvedValue(execution(turn('submitting')));
  render(() => <CloudConversation id="m" />);
  expect((await screen.findByText(/Opening ChatGPT… · 0:0\d/)).getAttribute('role')).toBe('status');
});

it('says Writing once a partial answer streams, and stops when the answer is complete', async () => {
  fakes.execution.mockResolvedValue(execution(turn('running', {result: 'Question 1…'})));
  const view = render(() => <CloudConversation id="m" />);
  await screen.findByText(/Writing… · /);
  expect(screen.getByText('Question 1…')).toBeTruthy();
  view.unmount();
  fakes.execution.mockResolvedValue(execution(turn('response_complete', {result: 'Question 1 ?'})));
  render(() => <CloudConversation id="m" />);
  await screen.findByText('Question 1 ?');
  expect(screen.queryByText(/Writing…|Thinking…/)).toBeNull();
});

it('requires an explicit choice for the exact Hermes approval and displays child attempts', async () => {
  const {api}=await import('../src/api');
  vi.mocked(api).mockResolvedValue({missions:[{id:'child',title:'Delegated check',status:'completed'}]});
  fakes.execution.mockResolvedValue({mission_id:'m',revision:1,selection:{provider:'hermes',account:'paloma'},turns:[turn('waiting_user',{
    external_id:'run_one',artifacts:[{kind:'hermes_approval',run_id:'run_one',request:{request_id:'approval_one',command:'Perform requested action',choices:['once','deny']}}]
  })]});
  render(()=><CloudConversation id="m"/>);
  await screen.findByText('Delegated check');
  const approve=await screen.findByRole('button',{name:'Approve once'});
  expect(screen.queryByRole('button',{name:'always'})).toBeNull();
  expect(vi.mocked(api).mock.calls.filter(([,opts])=>opts?.method==='POST')).toHaveLength(0);
  approve.click();
  await vi.waitFor(()=>expect(vi.mocked(api).mock.calls.some(([url,opts])=>url.endsWith('/cloud/approval')&&opts?.body===JSON.stringify({run_id:'run_one',request_id:'approval_one',choice:'once'}))).toBe(true));
});
