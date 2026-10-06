import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { RemoteQueue, type RemoteQueueHandle } from '../src/RemoteQueue';
const backend = vi.hoisted(() => ({ list: vi.fn(), api: vi.fn() }));
vi.mock('../src/api', () => ({ listQueuedMessages: backend.list, api: backend.api, connectionVersion: () => 1 }));
afterEach(() => { cleanup(); vi.resetAllMocks(); });
it('shows durable remote messages in order and removes only the selected entry', async () => {
  backend.list.mockResolvedValue([{ id: 'one', content: 'First', source: 'remote-queue' },{ id: 'two', content: 'Second', source: 'remote-queue' },{ id: 'local', content: 'Local', source: 'api' }]);
  backend.api.mockResolvedValue({ ok: true });
  const cancel = vi.fn(), rows = vi.fn();
  render(() => <RemoteQueue mission="remote" onRows={rows} onCancel={cancel}/>);
  await screen.findByText('2 Queued');
  expect(rows).toHaveBeenLastCalledWith(['one', 'two']);
  expect(screen.queryByText('Local')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Remove queued message: First' }));
  await waitFor(() => expect(cancel).toHaveBeenCalledWith('one'));
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/one', { method: 'DELETE' });
  expect(screen.queryByText('First')).toBeNull();
  expect(screen.getByText('Second')).toBeTruthy();
});
it('keeps the queue visible if cancellation fails', async () => {
  backend.list.mockResolvedValue([{ id: 'next', content: 'Try again', source: 'remote-queue' }]);
  backend.api.mockRejectedValue(new Error('Connection unavailable'));
  const cancel = vi.fn();
  render(() => <RemoteQueue mission="remote" onRows={() => {}} onCancel={cancel}/>);
  await screen.findByText('Try again');
  await fireEvent.click(screen.getByRole('button', { name: 'Remove queued message: Try again' }));
  await screen.findByRole('alert');
  expect(screen.getByText('Try again')).toBeTruthy();
  expect(cancel).not.toHaveBeenCalled();
});
it('reconciles delivery or cancellation from another client without reopening', async () => {
  backend.list.mockResolvedValueOnce([{id:'next',content:'Queued',source:'remote-queue'}]).mockResolvedValue([]);
  const rows=vi.fn();
  render(()=><RemoteQueue mission="remote" onRows={rows} onCancel={()=>{}}/>);
  await screen.findByText('Queued');
  await waitFor(()=>expect(rows).toHaveBeenLastCalledWith([]),{timeout:4000});
  expect(screen.queryByText('Queued')).toBeNull();
});

it('shows host follow-ups with the blocking writer and cancellation', async () => {
  backend.list.mockResolvedValue([{id:'host',content:'Follow up',source:'host-queue:api:u',queue_error:'Waiting for PR writer blocker'}, {id:'done',content:'Consumed',source:'host-queue:api:u',inflight:true}]);
  backend.api.mockResolvedValue({ok:true});
  const cancel=vi.fn();
  render(()=><RemoteQueue mission="host" onRows={()=>{}} onCancel={cancel}/>);
  await screen.findByText('1 Queued');
  expect(screen.getByText(/Waiting for PR writer blocker/)).toBeTruthy();
  expect(screen.queryByText('Consumed')).toBeNull();
  await fireEvent.click(screen.getByRole('button',{name:'Remove queued message: Follow up'}));
  await waitFor(()=>expect(cancel).toHaveBeenCalledWith('host'));
});

it('shows sending and confirmed receipts without waiting for a slow queue poll', async () => {
  backend.list.mockReturnValue(new Promise(()=>{}));
  const {createSignal} = await import('solid-js');
  const [pending,setPending]=createSignal<{id:string;content:string}|undefined>({id:'next',content:'Continue overnight'});
  const [confirmed,setConfirmed]=createSignal<{id:string;content:string}[]>([]);
  render(()=><RemoteQueue mission="remote" pending={pending()} confirmed={confirmed()} onRows={()=>{}} onCancel={()=>{}}/>);
  expect(screen.getByText('Continue overnight')).toBeTruthy();
  expect(screen.queryByRole('button',{name:/Remove queued message/})).toBeNull();
  setConfirmed([{id:'next',content:'Continue overnight'}]);setPending(undefined);
  await screen.findByText('1 Queued');
  expect(screen.getAllByText('Continue overnight')).toHaveLength(1);
  expect(screen.getByRole('button',{name:'Remove queued message: Continue overnight'})).toBeTruthy();
});

it('supports editing, replacing in order, and sending a queued remote message immediately', async () => {
  backend.list.mockResolvedValue([{ id: 'one', content: 'First', source: 'remote-queue' }, { id: 'two', content: 'Second', source: 'remote-queue' }]);
  backend.api.mockResolvedValue({ ok: true });
  const edit = vi.fn(), sendImmediate = vi.fn().mockResolvedValue(undefined);
  let handle!: RemoteQueueHandle;
  render(() => <RemoteQueue mission="remote" ref={h => handle = h} onEdit={edit} onSendImmediate={sendImmediate} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button', { name: 'Edit queued message: First' }));
  expect(edit).toHaveBeenCalledWith({ id: 'one', text: 'First', remote: true });
  const sendReplaced = vi.fn().mockResolvedValue(true);
  const replayAfter = vi.fn().mockResolvedValue(undefined);
  expect(await handle.replaceEdited('one', sendReplaced, replayAfter)).toBe(true);
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/one', { method: 'DELETE' });
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/two', { method: 'DELETE' });
  expect(sendReplaced).toHaveBeenCalledTimes(1);
  expect(replayAfter).toHaveBeenCalledWith([{ content: 'Second', attached: undefined }]);
});

it('sends the selected remote queued message immediately ahead of earlier rows and strips attachment trailers', async () => {
  const attachedContent = 'Please add a markdown file inside @Context\n\n<!-- paloma:attachment:dd4b234f-6097-4d72-82c7-aae18689e1fc -->\nAttached context: read `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc/.paloma/attach.md` (paths in that manifest are relative to `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc`).';
  backend.list.mockResolvedValue([{ id: 'one', content: 'First', source: 'remote-queue' }, { id: 'two', content: attachedContent, source: 'remote-queue' }]);
  backend.api.mockResolvedValue({ ok: true });
  const sendImmediate = vi.fn().mockResolvedValue(undefined);
  render(() => <RemoteQueue mission="remote" onSendImmediate={sendImmediate} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button', { name: 'Send now: Please add a markdown file inside @Context' }));
  await waitFor(() => expect(sendImmediate).toHaveBeenCalledWith([
    { id: 'two', content: 'Please add a markdown file inside @Context', attached: true },
    { id: 'one', content: 'First', attached: undefined },
  ]));
});

it('keeps the error alert visible when sendNow fails after clearing the queue', async () => {
  backend.list.mockResolvedValue([{ id: 'one', content: 'First', source: 'remote-queue' }]);
  backend.api.mockResolvedValue({ ok: true });
  const sendImmediate = vi.fn().mockRejectedValue(new Error('Immediate dispatch failed'));
  render(() => <RemoteQueue mission="remote" onSendImmediate={sendImmediate} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('1 Queued');
  await fireEvent.click(screen.getByRole('button', { name: 'Send now: First' }));
  const alert = await screen.findByRole('alert');
  expect(alert.textContent).toContain('Immediate dispatch failed');
});

it('injects the selected queued message live without deleting remaining queued messages when the harness accepts mid-turn input', async () => {
  backend.list.mockResolvedValue([
    { id: 'one', content: 'First', source: 'remote-queue' },
    { id: 'two', content: 'Steer live now', source: 'remote-queue' },
  ]);
  backend.api.mockImplementation((path: string, init?: RequestInit) => {
    if (path === '/api/control/queue/two/send-now' && init?.method === 'POST') {
      return Promise.resolve({ ok: true, delivered: true });
    }
    return Promise.resolve({ ok: true });
  });
  const sendImmediate = vi.fn().mockResolvedValue(undefined);
  const cancel = vi.fn();
  const rows = vi.fn();
  render(() => <RemoteQueue mission="remote" onSendImmediate={sendImmediate} onRows={rows} onCancel={cancel}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button', { name: 'Send now: Steer live now' }));
  await waitFor(() => expect(sendImmediate).toHaveBeenCalledWith(
    [],
    [{ id: 'two', content: 'Steer live now', attached: undefined }],
  ));
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/two/send-now', { method: 'POST' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/one', { method: 'DELETE' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/two', { method: 'DELETE' });
  expect(cancel).toHaveBeenCalledWith('two');
  expect(cancel).not.toHaveBeenCalledWith('one');
  expect(screen.getByText('First')).toBeTruthy();
  expect(screen.queryByText('Steer live now')).toBeNull();
});
