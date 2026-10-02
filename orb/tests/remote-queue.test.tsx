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
