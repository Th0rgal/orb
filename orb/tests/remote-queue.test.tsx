import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { createSignal } from 'solid-js';
import { RemoteQueue, type RemoteQueueHandle } from '../src/RemoteQueue';
const backend = vi.hoisted(() => ({ list: vi.fn(), api: vi.fn() }));
vi.mock('../src/api', () => ({
  listQueuedMessages: backend.list,
  api: backend.api,
  editQueuedMessage: (id: string, content: string, expectedRevision?: number) => backend.api(
    `/api/control/queue/${encodeURIComponent(id)}`,
    {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(expectedRevision !== undefined ? { content, expected_revision: expectedRevision } : { content }),
    },
  ),
  connectionVersion: () => 1,
  ApiError: class ApiError extends Error { constructor(public status: number, public detail: string) { super(`${status} ${detail}`); } },
}));
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
  // Same row layout while sending, actions disabled until Core assigns an id.
  expect((screen.getByRole('button',{name:/Remove queued message/}) as HTMLButtonElement).disabled).toBe(true);
  setConfirmed([{id:'next',content:'Continue overnight'}]);setPending(undefined);
  await screen.findByText('1 Queued');
  expect(screen.getAllByText('Continue overnight')).toHaveLength(1);
  expect(screen.getByRole('button',{name:'Remove queued message: Continue overnight'})).toBeTruthy();
});

it('edits a queued message atomically without issuing tail DELETEs and leaves trailing items intact on network failure', async () => {
  backend.list.mockResolvedValue([
    { id: 'one', content: 'First', source: 'remote-queue' },
    { id: 'two', content: 'Second', source: 'remote-queue' },
    { id: 'three', content: 'Third', source: 'host-queue:api:u' },
  ]);
  backend.api.mockResolvedValueOnce({ ok: true }).mockRejectedValueOnce(new Error('Network dropped'));
  const edit = vi.fn(), cancel = vi.fn();
  let handle!: RemoteQueueHandle;
  render(() => <RemoteQueue mission="remote" ref={h => handle = h} onEdit={edit} onRows={() => {}} onCancel={cancel}/>);
  await screen.findByText('3 Queued');
  await fireEvent.click(screen.getByRole('button', { name: 'Edit queued message: First' }));
  expect(edit).toHaveBeenCalledWith({ id: 'one', text: 'First', remote: true });
  expect(await handle.editInPlace('one', 'First, updated')).toBe('edited');
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/one', expect.objectContaining({ method: 'PATCH', body: JSON.stringify({ content: 'First, updated' }) }));
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/one', { method: 'DELETE' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/two', { method: 'DELETE' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/three', { method: 'DELETE' });
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['First, updated', 'Second', 'Third']);

  expect(await handle.editInPlace('one', 'Lost connection edit')).toBe('failed');
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['First, updated', 'Second', 'Third']);
  expect(cancel).not.toHaveBeenCalled();
  expect(backend.api.mock.calls.filter(([, init]: [string, RequestInit]) => init?.method === 'DELETE')).toEqual([]);

  const sendReplaced = vi.fn().mockResolvedValue(true);
  const replayAfter = vi.fn().mockResolvedValue(undefined);
  expect(await handle.replaceEdited('one', sendReplaced, replayAfter)).toBe(false);
  expect(sendReplaced).not.toHaveBeenCalled();
  expect(replayAfter).not.toHaveBeenCalled();
  expect(backend.api.mock.calls.filter(([, init]: [string, RequestInit]) => init?.method === 'DELETE')).toEqual([]);
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['First, updated', 'Second', 'Third']);
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
    if (path === '/api/control/queue/two/send-now?interrupt=true' && init?.method === 'POST') {
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
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/two/send-now?interrupt=true', { method: 'POST' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/one', { method: 'DELETE' });
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/two', { method: 'DELETE' });
  expect(cancel).toHaveBeenCalledWith('two');
  expect(cancel).not.toHaveBeenCalledWith('one');
  expect(screen.getByText('First')).toBeTruthy();
  // The sent row leaves in the same batch its bubble lands: no collapse step.
  expect(screen.getByText('1 Queued')).toBeTruthy();
  expect(screen.queryByText('Steer live now')).toBeNull();
});

it('removes a queued message optimistically before the DELETE request resolves and stacks multiple pending items in order', async () => {
  backend.list.mockResolvedValue([{ id: 'one', content: 'First confirmed', source: 'remote-queue' }]);
  let resolveDelete!: () => void;
  backend.api.mockImplementation(() => new Promise<unknown>(r => { resolveDelete = () => r({ ok: true }); }));
  const cancel = vi.fn();
  const { createSignal } = await import('solid-js');
  const [pending, setPending] = createSignal([
    { id: 'p1', content: 'Stacked 1' },
    { id: 'p2', content: 'Stacked 2' },
  ]);
  render(() => <RemoteQueue mission="remote" pending={pending()} onRows={() => {}} onCancel={cancel}/>);
  await screen.findByText('3 Queued');
  const items = Array.from(document.querySelectorAll('.queue-text')).map(el => el.textContent);
  expect(items).toEqual(['First confirmed', 'Stacked 1', 'Stacked 2']);

  // Click Delete on 'First confirmed' while DELETE is still pending in flight
  await fireEvent.click(screen.getByRole('button', { name: 'Remove queued message: First confirmed' }));
  // Optimistic DOM removal happens synchronously before resolveDelete() is called
  expect(screen.queryByText('First confirmed')).toBeNull();
  expect(cancel).not.toHaveBeenCalled();
  expect(screen.getByText('2 Queued')).toBeTruthy();
  resolveDelete();
  await waitFor(() => expect(cancel).toHaveBeenCalledWith('one'));
  setPending([{ id: 'p2', content: 'Stacked 2' }]);
  await screen.findByText('1 Queued');
});



it('send now leaves the queue and shows in the thread before Core answers', async () => {
  backend.list.mockResolvedValue([{ id: 'one', content: 'Go now', source: 'remote-queue' }]);
  let resolve!: (v: unknown) => void;
  backend.api.mockImplementation(() => new Promise(r => { resolve = r; }));
  const sendImmediate = vi.fn().mockResolvedValue(undefined);
  let handle!: RemoteQueueHandle;
  render(() => <RemoteQueue mission="remote" ref={h => handle = h} onSendImmediate={sendImmediate} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('Go now');
  void handle.sendNow();
  await waitFor(() => expect(screen.queryByText('Go now')).toBeNull());
  expect(sendImmediate).toHaveBeenCalledWith([], [{ id: 'one', content: 'Go now', attached: undefined }]);
  resolve({ delivered: true });
});
it('does not list a follow-up as queued once the transcript shows it delivered', async () => {
  // Core keeps the inbox row until the node accepts the job (e.g. a full node),
  // but it has already written the user message to the conversation.
  backend.list.mockResolvedValue([{id:'sent',content:'Review this plan',source:'remote-queue'},{id:'later',content:'Then continue',source:'remote-queue'}]);
  const rows=vi.fn();
  render(()=><RemoteQueue mission="remote" delivered={['sent']} onRows={rows} onCancel={()=>{}}/>);
  await screen.findByText('1 Queued');
  expect(screen.queryByText('Review this plan')).toBeNull();
  expect(rows).toHaveBeenLastCalledWith(['later']);
});
it('a lost send-now response keeps the row and its id, and never deletes or resends', async () => {
  backend.list.mockResolvedValue([{id:'one',content:'First',source:'remote-queue'},{id:'two',content:'Second',source:'remote-queue'}]);
  backend.api.mockRejectedValue(new Error('Connection interrupted'));
  const send = vi.fn().mockResolvedValue(undefined), retract = vi.fn(), cancel = vi.fn();
  render(() => <RemoteQueue mission="remote" onSendImmediate={send} onRetract={retract} onRows={()=>{}} onCancel={cancel}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button',{name:'Send now: First'}));
  expect((await screen.findByRole('alert')).textContent).toContain('Connection interrupted');
  expect(screen.getByText('First')).toBeTruthy();
  expect(backend.api).toHaveBeenCalledTimes(1);
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/one/send-now?interrupt=true',{method:'POST'});
  expect(retract).toHaveBeenCalledWith('one');
  expect(cancel).not.toHaveBeenCalled();
  expect(send).toHaveBeenCalledTimes(1); // only the optimistic injection, no stop-then-send
  expect(send).toHaveBeenCalledWith([], [{id:'one',content:'First',attached:undefined}]);
});
it('without live delivery it withdraws the optimistic copy, then stops and sends in order', async () => {
  backend.list.mockResolvedValue([{id:'one',content:'First',source:'remote-queue'},{id:'two',content:'Second',source:'remote-queue'}]);
  backend.api.mockImplementation(async (url: string) => url.endsWith('/send-now?interrupt=true') ? {ok:true,delivered:false} : {ok:true});
  const send = vi.fn().mockResolvedValue(undefined), retract = vi.fn();
  render(() => <RemoteQueue mission="remote" onSendImmediate={send} onRetract={retract} onRows={()=>{}} onCancel={()=>{}}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button',{name:'Send now: Second'}));
  await waitFor(() => expect(send).toHaveBeenLastCalledWith([{id:'two',content:'Second',attached:undefined},{id:'one',content:'First',attached:undefined}]));
  expect(retract).toHaveBeenCalledWith('two');
});
it('promoted by Core: keeps the same id, stops via Core, and never deletes or resends', async () => {
  backend.list.mockResolvedValue([{id:'one',content:'First',source:'remote-queue'},{id:'two',content:'Second',source:'remote-queue'}]);
  backend.api.mockImplementation(async (url: string) => url.includes('/send-now') ? {ok:true,delivered:false,promoted:true} : {ok:true});
  const send = vi.fn().mockResolvedValue(undefined), retract = vi.fn(), cancel = vi.fn();
  render(() => <RemoteQueue mission="remote" onSendImmediate={send} onRetract={retract} onRows={()=>{}} onCancel={cancel}/>);
  await screen.findByText('2 Queued');
  await fireEvent.click(screen.getByRole('button',{name:'Send now: Second'}));
  await waitFor(() => expect(cancel).toHaveBeenCalledWith('two'));
  expect(backend.api).toHaveBeenCalledTimes(1);
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/two/send-now?interrupt=true',{method:'POST'});
  expect(retract).not.toHaveBeenCalled();
  expect(send).toHaveBeenCalledTimes(1);
  expect(send).toHaveBeenCalledWith([], [{id:'two',content:'Second',attached:undefined}]);
  expect(screen.getByText('First')).toBeTruthy();
});

it('edits a queued message in place and reverts with a toast when Core refuses', async () => {
  backend.list.mockResolvedValue([
    { id: 'one', content: 'First', source: 'remote-queue' },
    { id: 'two', content: 'Second', source: 'remote-queue' },
  ]);
  let refuse!: (error: Error) => void;
  backend.api.mockImplementation((_path: string, init?: RequestInit) => init?.method === 'PATCH' ? new Promise((_resolve, reject) => { refuse = reject; }) : Promise.resolve({ ok: true }));
  let handle!: RemoteQueueHandle;
  render(() => <RemoteQueue mission="remote" ref={h => handle = h} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('2 Queued');
  const result = handle.editInPlace('one', 'First, edited');
  // Optimistic: same place, same count, new text.
  expect(screen.getByText('2 Queued')).toBeTruthy();
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['First, edited', 'Second']);
  expect(backend.api).toHaveBeenCalledWith('/api/control/queue/one', expect.objectContaining({ method: 'PATCH', body: JSON.stringify({ content: 'First, edited' }) }));
  const { ApiError } = await import('../src/api');
  refuse(new ApiError(409, 'This message was already sent'));
  expect(await result).toBe('failed');
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['First', 'Second']);
  expect((await screen.findByRole('alert')).textContent).toContain('already sent');
});

it('fails closed without deleting queued items when an older Core rejects PATCH with 405 or preserves attachment trailers on in-place edit', async () => {
  const attachedContent = 'Please add a markdown file inside @Context\n\n<!-- paloma:attachment:dd4b234f-6097-4d72-82c7-aae18689e1fc -->\nAttached context: read `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc/.paloma/attach.md` (paths in that manifest are relative to `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc`).';
  backend.list.mockResolvedValue([
    { id: 'one', content: attachedContent, source: 'host-queue:api:u' },
    { id: 'two', content: 'Second', source: 'host-queue:api:u' },
  ]);
  const { ApiError } = await import('../src/api');
  backend.api
    .mockImplementationOnce(() => Promise.reject(new ApiError(405, 'Method Not Allowed')))
    .mockResolvedValueOnce({ ok: true });
  let handle!: RemoteQueueHandle;
  render(() => <RemoteQueue mission="remote" ref={h => handle = h} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('2 Queued');
  expect(await handle.editInPlace('one', 'Edited')).toBe('failed');
  expect(screen.getByText('Please add a markdown file inside @Context')).toBeTruthy();
  expect((await screen.findByRole('alert')).textContent).toContain('405');
  expect(await handle.editInPlace('one', 'Updated with @Context')).toBe('edited');
  expect(backend.api).toHaveBeenLastCalledWith('/api/control/queue/one', expect.objectContaining({
    method: 'PATCH',
    body: JSON.stringify({
      content: 'Updated with @Context\n\n<!-- paloma:attachment:dd4b234f-6097-4d72-82c7-aae18689e1fc -->\nAttached context: read `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc/.paloma/attach.md` (paths in that manifest are relative to `.paloma/messages/dd4b234f-6097-4d72-82c7-aae18689e1fc`).',
    }),
  }));
  expect([...document.querySelectorAll('.queue-text span')].map(node => node.textContent)).toEqual(['Updated with @Context', 'Second']);
});

it('keeps one row element, and its action area, from sending to confirmed', async () => {
  backend.list.mockResolvedValue([]);
  const [pending, setPending] = createSignal<{ id: string; content: string }[]>([{ id: 'p1', content: 'Queued while busy' }]);
  const [confirmed, setConfirmed] = createSignal<{ id: string; content: string }[]>([]);
  render(() => <RemoteQueue mission="remote" pending={pending()} confirmed={confirmed()} onRows={() => {}} onCancel={() => {}}/>);
  const row = (await screen.findByText('Queued while busy')).closest('li')!;
  expect(row.classList.contains('sending')).toBe(true);
  expect(row.querySelector('.queue-trailing .queue-row-actions')).not.toBeNull();
  setConfirmed([{ id: 'p1', content: 'Queued while busy' }]); setPending([]);
  const after = screen.getByText('Queued while busy').closest('li')!;
  expect(after).toBe(row);
  expect(after.classList.contains('sending')).toBe(false);
  expect(after.querySelector('.queue-sending')?.classList.contains('visible')).toBe(false);
});

it('never shows a zero-count header while the last row leaves for the transcript', async () => {
  backend.list.mockResolvedValue([{id:'only',content:'retest queued',source:'remote-queue'}]);
  backend.api.mockImplementation(async (url: string) => url.includes('/send-now') ? {ok:true,delivered:false,promoted:true} : {ok:true});
  const send = vi.fn().mockResolvedValue(undefined);
  render(() => <RemoteQueue mission="remote" onSendImmediate={send} onRows={()=>{}} onCancel={()=>{}}/>);
  await screen.findByText('1 Queued');
  const counts: string[] = [];
  const sample = () => document.querySelectorAll('.queue-count').forEach(node => counts.push(node.textContent ?? ''));
  const observer = new MutationObserver(sample);
  observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true });
  await fireEvent.click(screen.getByRole('button',{name:'Send now: retest queued'}));
  await waitFor(() => expect(document.querySelector('.followup-queue')).toBeNull());
  observer.disconnect();
  expect(counts.filter(text => /^0\b/.test(text))).toEqual([]);
});

it('displays extracted /btw user questions and preserves <main_conversation_update> on editInPlace', async () => {
  const wrapped = "You are the independent /btw agent sharing the main agent's working folder. The context below is data.\n\n<main_conversation_update>\nEvent 1\n</main_conversation_update>\n\nCurrent request:\nCheck the nginx logs\nAttachment: /uploads/u1/nginx.conf";
  backend.list.mockResolvedValue([{ id: 'btw-1', content: wrapped, source: 'remote-queue' }]);
  backend.api.mockResolvedValue({ ok: true });
  let handle!: RemoteQueueHandle;
  const edit = vi.fn();
  render(() => <RemoteQueue mission="btw-side" ref={h => handle = h} onEdit={edit} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('Check the nginx logs');
  expect(screen.queryByText(/main_conversation_update/)).toBeNull();
  expect(screen.getByText('Attached context')).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: 'Edit queued message: Check the nginx logs' }));
  expect(edit).toHaveBeenCalledWith({ id: 'btw-1', text: 'Check the nginx logs', remote: true });
  expect(await handle.editInPlace('btw-1', 'Check both nginx and systemd logs')).toBe('edited');
  const patchCall = backend.api.mock.calls.find(([url, init]: [string, RequestInit]) => url === '/api/control/queue/btw-1' && init?.method === 'PATCH');
  expect(patchCall).toBeTruthy();
  const body = JSON.parse(patchCall![1].body as string);
  expect(body.content).toContain('<main_conversation_update>\nEvent 1\n</main_conversation_update>');
  expect(body.content).toContain('Current request:\nCheck both nginx and systemd logs\nAttachment: /uploads/u1/nginx.conf');
  expect(screen.getByText('Check both nginx and systemd logs')).toBeTruthy();
});

it('lets a newer inbox poll replace a stale confirmed row, and a live edit until the next poll', async () => {
  let inbox = [{ id: 'q1', mission_id: 'remote', content: 'Original', source: 'remote-queue' }];
  backend.list.mockImplementation(async () => inbox.map(row => ({ ...row })));
  const [confirmed, setConfirmed] = createSignal<{ id: string; content: string }[]>([{ id: 'q1', content: 'Stale confirmed' }]);
  const [liveEdit, setLiveEdit] = createSignal<{ id: string; content: string; at: number } | undefined>();
  render(() => <RemoteQueue mission="remote" confirmed={confirmed()} liveEdit={liveEdit()} onRows={() => {}} onCancel={() => {}}/>);
  await screen.findByText('Original');
  expect(screen.queryByText('Stale confirmed')).toBeNull();

  inbox = [{ id: 'q1', mission_id: 'remote', content: 'Edited elsewhere', source: 'remote-queue' }];
  await waitFor(() => expect(screen.getByText('Edited elsewhere')).toBeTruthy(), { timeout: 4000 });
  expect(screen.queryByText('Original')).toBeNull();

  setLiveEdit({ id: 'q1', content: 'Live edit', at: 1 });
  await screen.findByText('Live edit');
  expect(screen.queryByText('Edited elsewhere')).toBeNull();

  inbox = [{ id: 'q1', mission_id: 'remote', content: 'Polled after live', source: 'remote-queue' }];
  await waitFor(() => expect(screen.getByText('Polled after live')).toBeTruthy(), { timeout: 4000 });
  expect(screen.queryByText('Live edit')).toBeNull();

  setConfirmed([{ id: 'q2', content: 'Only confirmed' }]);
  await screen.findByText('Only confirmed');
  expect(screen.getByText('Polled after live')).toBeTruthy();
});

it('keeps a live edit that lands while a poll is in flight until a later poll', async () => {
  let release!: (rows: { id: string; mission_id: string; content: string; source: string }[]) => void;
  backend.list.mockImplementation(() => new Promise(resolve => { release = resolve; }));
  const [liveEdit, setLiveEdit] = createSignal<{ id: string; content: string; at: number } | undefined>();
  render(() => <RemoteQueue mission="remote" liveEdit={liveEdit()} onRows={() => {}} onCancel={() => {}}/>);
  await vi.waitFor(() => expect(backend.list).toHaveBeenCalled());
  setLiveEdit({ id: 'q1', content: 'Live during poll', at: 1 });
  release([{ id: 'q1', mission_id: 'remote', content: 'Stale poll', source: 'remote-queue' }]);
  await screen.findByText('Live during poll');
  expect(screen.queryByText('Stale poll')).toBeNull();
  backend.list.mockResolvedValue([{ id: 'q1', mission_id: 'remote', content: 'Later poll', source: 'remote-queue' }]);
  await waitFor(() => expect(screen.getByText('Later poll')).toBeTruthy(), { timeout: 4000 });
  expect(screen.queryByText('Live during poll')).toBeNull();
});

it('refuses to CAS-edit a delivered queue row and refreshes on a typed 409 revision conflict (SM-24)', async () => {
  backend.list.mockResolvedValue([{ id: 'q1', mission_id: 'remote', content: 'Original', source: 'remote-queue', revision: 4 }]);
  const { ApiError } = await import('../src/api');
  let conflicted = false;
  backend.api.mockImplementation(async (url: string) => {
    if (String(url).endsWith('/q1') && !conflicted) {
      conflicted = true;
      throw new ApiError(409, JSON.stringify({ code: 'revision_conflict', current_revision: 7 }));
    }
    return { ok: true };
  });
  let handle!: RemoteQueueHandle;
  const [delivered, setDelivered] = createSignal<string[]>([]);
  render(() => <RemoteQueue mission="remote" delivered={delivered()} ref={value => { handle = value; }} onRows={() => {}} onCancel={() => {}} />);
  await screen.findByText('Original');
  expect(await handle.editInPlace('q1', 'Edited text')).toBe('failed');
  const patch = backend.api.mock.calls.find(([url, init]: [string, RequestInit]) => String(url).endsWith('/q1') && init?.method === 'PATCH');
  expect(patch).toBeTruthy();
  expect(JSON.parse(patch![1].body as string)).toEqual({ content: 'Edited text', expected_revision: 4 });
  expect((await screen.findByRole('alert')).textContent).toMatch(/Queue changed on another client/);
  await waitFor(() => expect(backend.list.mock.calls.length).toBeGreaterThan(1));
  expect(screen.getByText('Original')).toBeTruthy();
  setDelivered(['q1']);
  expect(await handle.editInPlace('q1', 'too late')).toBe('failed');
  expect(backend.api.mock.calls.filter(([url, init]: [string, RequestInit]) => String(url).endsWith('/q1') && init?.method === 'PATCH')).toHaveLength(1);
});

it('treats DELETE 404 as gone only when the body says "message not in queue" and rolls back on route-missing 404', async () => {
  backend.list.mockResolvedValue([
    { id: 'route-404', content: 'Route missing', source: 'remote-queue' },
    { id: 'gone-404', content: 'Already gone', source: 'remote-queue' },
  ]);
  const { ApiError } = await import('../src/api');
  backend.api
    .mockImplementationOnce(async () => {
      throw new ApiError(404, JSON.stringify({ error: 'not_found', path: '/api/control/queue/route-404' }));
    })
    .mockImplementationOnce(async () => {
      throw new ApiError(404, JSON.stringify({ error: 'message not in queue' }));
    });
  const cancel = vi.fn(), remove = vi.fn(), rows = vi.fn();
  render(() => <RemoteQueue mission="remote" onRows={rows} onRemove={remove} onCancel={cancel}/>);
  await screen.findByText('2 Queued');

  await fireEvent.click(screen.getByRole('button', { name: 'Remove queued message: Route missing' }));
  expect((await screen.findByRole('alert')).textContent).toContain('not_found');
  expect(screen.getByText('Route missing')).toBeTruthy();
  expect(cancel).not.toHaveBeenCalledWith('route-404');
  expect(remove).not.toHaveBeenCalledWith('route-404');
  expect(rows).toHaveBeenLastCalledWith(['route-404', 'gone-404']);

  await fireEvent.click(screen.getByRole('button', { name: 'Remove queued message: Already gone' }));
  await waitFor(() => expect(cancel).toHaveBeenCalledWith('gone-404'));
  expect(remove).toHaveBeenCalledWith('gone-404');
  expect(screen.queryByText('Already gone')).toBeNull();
  expect(rows).toHaveBeenLastCalledWith(['route-404']);
});

it('on a terminal mission labels listed rows as not delivered and sends via delete-then-send only after DELETE 200 or "message not in queue"', async () => {
  backend.list.mockResolvedValue([
    { id: 'q1', content: 'Please stop and summarize', source: 'remote-queue' },
    { id: 'q2', content: 'Follow-up two', source: 'remote-queue' },
  ]);
  const { ApiError } = await import('../src/api');
  // First attempt: DELETE returns route-missing 404 -> must NOT call onSendImmediate(payload).
  backend.api.mockImplementationOnce(async () => {
    throw new ApiError(404, JSON.stringify({ error: 'not_found', path: '/api/control/queue/q1' }));
  });
  const send = vi.fn().mockResolvedValue(undefined), retract = vi.fn(), cancel = vi.fn();
  render(() => <RemoteQueue mission="remote" terminal={true} onSendImmediate={send} onRetract={retract} onRows={() => {}} onCancel={cancel}/>);
  await screen.findByText('2 Not delivered');
  expect(screen.getAllByText(/Not delivered · mission ended before delivery/)).toHaveLength(2);

  await fireEvent.click(screen.getByRole('button', { name: 'Send now: Please stop and summarize' }));
  expect((await screen.findByRole('alert')).textContent).toContain('not_found');
  // Never called /send-now on a terminal mission, and did not dispatch payload after failed DELETE:
  expect(backend.api).not.toHaveBeenCalledWith('/api/control/queue/q1/send-now?interrupt=true', expect.anything());
  expect(send).toHaveBeenCalledTimes(1); // only the optimistic liveInjected preview before retract
  expect(retract).toHaveBeenCalledWith('q1');
  expect(cancel).not.toHaveBeenCalled();
  expect(screen.getByText('Please stop and summarize')).toBeTruthy();

  // Second attempt: q1 DELETE returns 200, q2 DELETE returns 404 "message not in queue" -> sends both in order.
  send.mockClear();
  backend.api.mockImplementation(async (url: string, init?: RequestInit) => {
    if (url === '/api/control/queue/q1' && init?.method === 'DELETE') return { ok: true, id: 'q1', mission_id: 'remote' };
    if (url === '/api/control/queue/q2' && init?.method === 'DELETE') {
      throw new ApiError(404, JSON.stringify({ error: 'message not in queue' }));
    }
    throw new Error(`unexpected call ${url}`);
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Send now: Please stop and summarize' }));
  await waitFor(() => expect(send).toHaveBeenLastCalledWith([
    { id: 'q1', content: 'Please stop and summarize', attached: undefined },
    { id: 'q2', content: 'Follow-up two', attached: undefined },
  ]));
  expect(cancel).toHaveBeenCalledWith('q1');
  expect(cancel).toHaveBeenCalledWith('q2');
});
