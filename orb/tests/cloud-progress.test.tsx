import { render, screen, cleanup } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { CloudConversation } from '../src/CloudAgents';
const fakes = vi.hoisted(() => ({ execution: vi.fn() }));
vi.mock('../src/cloudAgentApi', async original => ({...await original<object>(), cloudAccounts: vi.fn(async () => []), cloudExecution: fakes.execution}));
const composerHook = vi.hoisted(() => ({ send: undefined as undefined | ((text: string) => Promise<boolean> | boolean) }));
vi.mock('../src/composer/Composer', () => ({
  Composer: (props: { onSend?: (text: string) => Promise<boolean> | boolean }) => {
    composerHook.send = props.onSend;
    return null;
  },
  floatingDock: () => {},
}));
vi.mock('../src/api', () => ({api: vi.fn(), getMission: vi.fn(async () => null), openExternalUrl: vi.fn(), connectionVersion: () => 1}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const turn = (phase: string, extra = {}) => ({key: 't1', prompt: 'Refais-moi un résumé', phase, artifacts: [], branches: [], model_params: [], ...extra});
const execution = (t: object) => ({mission_id: 'm', revision: 1, selection: {provider: 'cursor_cloud', account: 'cursor-default'}, turns: [t]});

it('shows that a Cursor Cloud turn is starting, then thinking, with elapsed time', async () => {
  fakes.execution.mockResolvedValue(execution(turn('submitting')));
  render(() => <CloudConversation id="m" />);
  // The mission Working row: the step in a status, the elapsed time beside it.
  const status = await screen.findByText('Opening Cursor Cloud…');
  expect(status.getAttribute('role')).toBe('status');
  expect(status.closest('.st-working')?.querySelector('.st-working-time')).toBeTruthy();
});

it('says Writing once a partial answer streams, and stops when the answer is complete', async () => {
  fakes.execution.mockResolvedValue(execution(turn('running', {result: 'Question 1…'})));
  const view = render(() => <CloudConversation id="m" />);
  await screen.findByText('Writing…');
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

it('keeps an optimistic "yes" follow-up across historical "yes" turns and unrelated turns until its own turn lands (SM-24)', async () => {
  const { api } = await import('../src/api');
  const { cloudAccounts } = await import('../src/cloudAgentApi');
  vi.mocked(cloudAccounts).mockResolvedValue([
    {
      id: 'paloma',
      provider: 'hermes',
      label: 'Paloma',
      status: 'connected',
      capabilities: { follow_up: true, cancel: true, attachments: false, models: false },
    } as never,
  ]);
  let state = {
    mission_id: 'm',
    revision: 1,
    selection: { provider: 'hermes' as const, account: 'paloma' },
    turns: [turn('response_complete', { key: 'hist-1', prompt: 'yes', result: 'First done' })],
  };
  fakes.execution.mockImplementation(async () => state);
  let sentBody: { client_message_id?: string; content?: string } | undefined;
  let releasePost!: () => void;
  vi.mocked(api).mockImplementation(async (url: string, opts?: RequestInit) => {
    if (url === '/api/control/message') {
      sentBody = JSON.parse(String(opts?.body ?? '{}'));
      await new Promise<void>(resolve => { releasePost = resolve; });
      return { ok: true };
    }
    return { missions: [] };
  });

  render(() => <CloudConversation id="m" />);
  await screen.findByText('First done');
  expect(composerHook.send).toBeTypeOf('function');

  const sendPromise = composerHook.send!('yes');
  await vi.waitFor(() => expect(sentBody?.client_message_id).toBeTruthy());
  // Both the historical 'yes' turn and the optimistic 'yes' bubble are rendered while in-flight.
  expect(screen.getAllByText('yes')).toHaveLength(2);

  // An unrelated concurrent turn arrives at turnSeq=2 with different prompt/key: must NOT retire our 'yes'.
  state = {
    ...state,
    revision: 2,
    turns: [
      ...state.turns,
      turn('response_complete', { key: 'other-client', prompt: 'unrelated note', result: 'Other done' }),
    ],
  };
  releasePost();
  await sendPromise;
  await screen.findByText('Other done');
  expect(screen.getAllByText('yes')).toHaveLength(2);

  // Now the provider reports our exact turn at turnSeq=3; optimistic bubble retires cleanly to 2 total ('hist-1' + 'turn-3').
  state = {
    ...state,
    revision: 3,
    turns: [
      ...state.turns,
      turn('running', { key: sentBody!.client_message_id, prompt: 'yes', result: 'Working on yes…' }),
    ],
  };
  document.dispatchEvent(new Event('visibilitychange'));
  await screen.findByText('Working on yes…');
  expect(screen.getAllByText('yes')).toHaveLength(2);
});
