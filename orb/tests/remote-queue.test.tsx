import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { RemoteQueue } from '../src/RemoteQueue';
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
  await fireEvent.click(screen.getAllByRole('button', { name: 'Cancel' })[0]);
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
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
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
  await fireEvent.click(screen.getByRole('button',{name:'Cancel'}));
  await waitFor(()=>expect(cancel).toHaveBeenCalledWith('host'));
});

it('shows sending and confirmed receipts without waiting for a slow queue poll', async () => {
  backend.list.mockReturnValue(new Promise(()=>{}));
  const {createSignal} = await import('solid-js');
  const [pending,setPending]=createSignal<{id:string;content:string}|undefined>({id:'next',content:'Continue overnight'});
  const [confirmed,setConfirmed]=createSignal<{id:string;content:string}[]>([]);
  render(()=><RemoteQueue mission="remote" pending={pending()} confirmed={confirmed()} onRows={()=>{}} onCancel={()=>{}}/>);
  expect(screen.getByText('Continue overnight')).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Cancel'})).toBeNull();
  setConfirmed([{id:'next',content:'Continue overnight'}]);setPending(undefined);
  await screen.findByText('1 Queued');
  expect(screen.getAllByText('Continue overnight')).toHaveLength(1);
  expect(screen.getByRole('button',{name:'Cancel'})).toBeTruthy();
});
