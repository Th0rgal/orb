import { render, fireEvent, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { Providers } from '../src/Providers';
import { clearConnection, setConnection } from '../src/api';
afterEach(() => { clearConnection(); vi.useRealTimers(); vi.unstubAllGlobals(); });
const ok = (body: unknown) => new Response(JSON.stringify(body));
it('replaces a failed initial load with a retry that can recover', async () => {
  setConnection('http://core.test', 'test');
  let failed = true;
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url.endsWith('/providers') && failed ? new Response('Temporary failure', {status:503}) : ok([])));
  const ui = render(() => <Providers />);
  await waitFor(() => expect(ui.getByRole('alert').textContent).toContain('Could not load providers'));
  expect(ui.queryByRole('status')).toBeNull();
  failed = false;
  fireEvent.click(ui.getByRole('button', {name:'Try again'}));
  await waitFor(() => expect(ui.getByRole('heading', {name:'Subscriptions'})).toBeTruthy());
  expect(ui.queryByRole('alert')).toBeNull();
});
it('retains the current list when a refresh fails', async () => {
  setConnection('http://core.test', 'test');
  let failed = false;
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url.endsWith('/providers') ? failed ? new Response('Offline', {status:503}) : ok([{id:'test',name:'My account',provider_type:'openai',uses_oauth:true,status:{type:'connected'}}]) : ok([])));
  const ui = render(() => <Providers />);
  await waitFor(() => expect(ui.getByText('My account')).toBeTruthy());
  failed = true;
  fireEvent.click(ui.getByRole('button', {name:'Refresh',exact:true}));
  await waitFor(() => expect(ui.getByRole('alert').textContent).toContain('Could not refresh providers'));
  expect(ui.getByText('My account')).toBeTruthy();
});
it('aborts a stalled load after fifteen seconds and exposes retry', async () => {
  vi.useFakeTimers();
  setConnection('http://core.test', 'test');
  vi.stubGlobal('fetch', vi.fn((_url: string, options: RequestInit) => new Promise((_resolve,reject) => options.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError'))))));
  const ui = render(() => <Providers />);
  expect(ui.getByRole('status')).toBeTruthy();
  await vi.advanceTimersByTimeAsync(15_000);
  expect(ui.getByRole('alert').textContent).toContain('timed out');
  expect(ui.getByRole('button',{name:'Try again'})).toBeTruthy();
  expect(ui.queryByRole('status')).toBeNull();
});
it('ignores the previous backend response and cancels work on unmount', async () => {
  setConnection('http://old.test', 'test');
  let release!: (value: Response) => void;
  let oldSignal: AbortSignal | undefined;
  vi.stubGlobal('fetch', vi.fn((url: string, options: RequestInit) => {
    if (url === 'http://old.test/api/ai/providers') {
      oldSignal = options.signal!;
      return new Promise<Response>(resolve => { release = resolve; });
    }
    return Promise.resolve(ok(url.endsWith('/providers') ? [{id:'new',name:'New account',provider_type:'openai',uses_oauth:true,status:{type:'connected'}}] : []));
  }));
  const ui = render(() => <Providers />);
  setConnection('http://new.test', 'test');
  await waitFor(() => expect(ui.getByText('New account')).toBeTruthy());
  expect(oldSignal?.aborted).toBe(true);
  release(ok([{id:'old',name:'Old account',provider_type:'openai',uses_oauth:true,status:{type:'connected'}}]));
  await Promise.resolve();
  expect(ui.queryByText('Old account')).toBeNull();
  ui.unmount();
});
