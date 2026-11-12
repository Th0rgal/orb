import { Suspense, lazy } from 'solid-js';
import { render, fireEvent, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, expect, it, vi } from 'vitest';
import { Providers } from '../src/Providers';
import { ProvidersPageSkeleton } from '../src/ProvidersSkeleton';
import { clearConnection, peekCachedProviders, setConnection } from '../src/api';
import { cachePut, cacheReset } from '../src/pageCache';
afterEach(() => { clearConnection(); vi.useRealTimers(); vi.unstubAllGlobals(); });
const ok = (body: unknown) => new Response(JSON.stringify(body));
it('replaces a failed initial load with a retry that can recover', async () => {
  setConnection('http://core.test', 'test');
  let failed = true;
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url.endsWith('/providers') && failed ? new Response('Temporary failure', {status:503}) : ok([])));
  const ui = render(() => <Providers />);
  await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Could not load providers'));
  expect(ui.queryByRole('status')).toBeNull();
  failed = false;
  fireEvent.click(screen.getByRole('button', {name:'Try again'}));
  await waitFor(() => expect(ui.getByRole('heading', {name:'Subscriptions'})).toBeTruthy());
  expect(screen.queryByRole('alert')).toBeNull();
});
it('retains the current list when a refresh fails', async () => {
  setConnection('http://core.test', 'test');
  let failed = false;
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url.endsWith('/providers') ? failed ? new Response('Offline', {status:503}) : ok([{id:'test',name:'My account',provider_type:'openai',uses_oauth:true,status:{type:'connected'}}]) : ok([])));
  const ui = render(() => <Providers />);
  await waitFor(() => expect(ui.getByText('My account')).toBeTruthy());
  failed = true;
  fireEvent.click(ui.getByRole('button', {name:'Refresh',exact:true}));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Could not refresh providers'));
  expect(ui.getByText('My account')).toBeTruthy();
});
it('aborts a stalled load after fifteen seconds and exposes retry', async () => {
  vi.useFakeTimers();
  setConnection('http://core.test', 'test');
  vi.stubGlobal('fetch', vi.fn((_url: string, options: RequestInit) => new Promise((_resolve,reject) => options.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError'))))));
  const ui = render(() => <Providers />);
  expect(ui.getByRole('status')).toBeTruthy();
  await vi.advanceTimersByTimeAsync(15_000);
  expect(screen.getByRole('alert').textContent).toContain('timed out');
  expect(screen.getByRole('button',{name:'Try again'})).toBeTruthy();
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
it('renders cached providers immediately on remount without flashing the loading skeleton', async () => {
  setConnection('http://core.test', 'test');
  let holdSecondFetch = false;
  vi.stubGlobal('fetch', vi.fn((url: string) => {
    if (holdSecondFetch) {
      return new Promise<Response>(() => {});
    }
    return Promise.resolve(ok(url.endsWith('/providers') ? [{id:'cached',name:'Cached Claude',provider_type:'anthropic',uses_oauth:true,status:{type:'connected'}}] : []));
  }));
  const first = render(() => <Providers />);
  await waitFor(() => expect(first.getByText('Cached Claude')).toBeTruthy());
  await waitFor(() => expect(first.queryByRole('status')).toBeNull());
  first.unmount();

  // Remounting (e.g. returning from Settings) renders cached accounts & cloud connectors
  // synchronously even while all background refreshes are still in flight, with zero skeleton flash.
  holdSecondFetch = true;
  const second = render(() => <Providers />);
  expect(second.getByText('Cached Claude')).toBeTruthy();
  expect(second.queryByRole('status')).toBeNull();
  second.unmount();
});
it('survives non-array cloud-accounts payloads without wedging on the loading skeleton', async () => {
  setConnection('http://core.test', 'test');
  cachePut('settings:cloud-accounts', { job: null, runs: [] } as unknown);
  vi.stubGlobal('fetch', vi.fn((url: string) =>
    Promise.resolve(ok(url.endsWith('/api/ai/providers')
      ? [{id:'claude',name:'Claude (work)',provider_type:'anthropic',uses_oauth:true,status:{type:'connected'}}]
      : { job: null, runs: [] })),
  ));
  const ui = render(() => <Providers />);
  await waitFor(() => expect(ui.getByRole('button', { name: 'Usage history' })).toBeTruthy());
  expect(ui.getByText(/Claude/)).toBeTruthy();
  ui.unmount();
});
it('paints the Inference heading and skeleton synchronously while the lazy Providers chunk loads', async () => {
  setConnection('http://core.test', 'test');
  vi.stubGlobal('fetch', vi.fn(async (url: string) =>
    ok(url.endsWith('/api/ai/providers')
      ? [{ id: 'lazy-acc', name: 'Lazy OpenAI', provider_type: 'openai', uses_oauth: true, status: { type: 'connected' } }]
      : []),
  ));
  let resolveChunk!: (mod: { default: typeof Providers }) => void;
  const LazyProviders = lazy(() => new Promise<{ default: typeof Providers }>((resolve) => {
    resolveChunk = resolve;
  }));
  const ui = render(() => (
    <Suspense fallback={<ProvidersPageSkeleton />}>
      <LazyProviders />
    </Suspense>
  ));
  // Synchronous first frame: Inference heading and 3-row skeleton card are visible immediately (never blank).
  expect(ui.getByRole('heading', { name: 'Inference' })).toBeTruthy();
  expect(ui.getByRole('status', { name: 'Loading inference accounts' })).toBeTruthy();

  resolveChunk({ default: Providers });
  await waitFor(() => expect(ui.getByText('Lazy OpenAI')).toBeTruthy());
  expect(ui.queryByRole('status', { name: 'Loading inference accounts' })).toBeNull();
  ui.unmount();
});
it('hydrates persisted provider catalog on cold launch and wipes it on clearConnection', async () => {
  setConnection('http://core.test', 'tok-a');
  const requestedPaths: string[] = [];
  let holdReload = false;
  vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
    const url = String(input);
    requestedPaths.push(new URL(url).pathname);
    if (holdReload) return new Promise<Response>(() => {});
    if (url.endsWith('/api/ai/providers')) {
      return Promise.resolve(ok([{ id: 'persisted', name: 'Persisted Anthropic', provider_type: 'anthropic', uses_oauth: true, status: { type: 'connected' } }]));
    }
    if (url.endsWith('/api/ai/providers/usage')) {
      return Promise.resolve(ok({ entries: {} }));
    }
    return Promise.resolve(ok([]));
  }));

  const first = render(() => <Providers />);
  await waitFor(() => expect(first.getByText('Persisted Anthropic')).toBeTruthy());
  // Cold load fires usage, health, login options, and cloud accounts in parallel without waiting for /api/ai/providers.
  expect(requestedPaths).toContain('/api/ai/providers');
  expect(requestedPaths).toContain('/api/model-routing/health');
  expect(requestedPaths).toContain('/api/ai/providers/usage');
  first.unmount();

  // Simulate cold app restart: clear in-memory pageCache while keeping persisted storage.
  cacheReset();
  expect(peekCachedProviders()?.map((p) => p.name)).toEqual(['Persisted Anthropic']);
  holdReload = true;
  const cold = render(() => <Providers />);
  expect(cold.getByText('Persisted Anthropic')).toBeTruthy();
  expect(cold.queryByRole('status', { name: 'Loading inference accounts' })).toBeNull();
  cold.unmount();

  // Sign-out / clearConnection wipes persisted orb.catalog:* entries across storage and memory.
  clearConnection();
  expect(peekCachedProviders()).toBeNull();
  setConnection('http://core.test', 'tok-a');
  expect(peekCachedProviders()).toBeNull();
});
