import {afterEach, beforeEach, expect, it, vi} from 'vitest';
import {api, InvalidApiResponseError, isTransientNetworkError, listCompletedMissions, RequestTimeoutError, sendMissionMessage, setApiUrl, type Mission} from '../src/api';

const abort = (name: string) => Object.assign(new Error('Fetch is aborted'), {name});
beforeEach(() => { localStorage.clear(); setApiUrl('http://core.test'); });
afterEach(() => { vi.unstubAllGlobals(); });

it('reports a deadline in plain words and keeps it retryable', async () => {
 vi.stubGlobal('fetch', vi.fn(async () => { throw abort('AbortError'); }));
 const error = await api('/api/projects', {}).catch(e => e);
 expect(error).toBeInstanceOf(RequestTimeoutError);
 expect(error.message).not.toMatch(/abort/i);
 expect(isTransientNetworkError(error)).toBe(true);
});

it('leaves a caller’s own abort as an abort', async () => {
 vi.stubGlobal('fetch', vi.fn(async () => { throw abort('AbortError'); }));
 const controller = new AbortController(); controller.abort();
 const error = await api('/api/projects', {signal: controller.signal}).catch(e => e);
 expect(error).not.toBeInstanceOf(RequestTimeoutError);
 expect(error.name).toBe('AbortError');
});

it('answers null instead of an empty completed list when Core does not answer', async () => {
 vi.stubGlobal('fetch', vi.fn(async () => { throw abort('TimeoutError'); }));
 expect(await listCompletedMissions()).toBeNull();
});

it('reports a timeout while reading response body as RequestTimeoutError rather than InvalidApiResponseError', async () => {
 vi.stubGlobal('fetch', vi.fn(async () => ({
  ok: true,
  status: 200,
  text: async () => { throw abort('TimeoutError'); },
 } as unknown as Response)));
 const error = await api('/api/control/message', { method: 'POST', body: '{}' }).catch(e => e);
 expect(error).toBeInstanceOf(RequestTimeoutError);
 expect(error).not.toBeInstanceOf(InvalidApiResponseError);
 expect(isTransientNetworkError(error)).toBe(true);
});

it('skips blocking getMission when knownMission is active and recovers dropped response body from Core queue', async () => {
 const known: Mission = { id: 'm-fast', status: 'active', history: [], created_at: '', updated_at: '' };
 const calls: Array<{ url: string; method: string; body?: string }> = [];
 vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input);
  const method = (init?.method ?? 'GET').toUpperCase();
  calls.push({ url, method, body: typeof init?.body === 'string' ? init.body : undefined });
  if (url.endsWith('/api/control/message') && method === 'POST') {
   return {
    ok: true,
    status: 200,
    text: async () => { throw new TypeError('Load failed'); },
   } as unknown as Response;
  }
  if (url.includes('/api/control/queue?mission_id=m-fast') && method === 'GET') {
   return new Response(JSON.stringify([{ id: 'msg-fixed-id', content: 'Follow-up text', mission_id: 'm-fast' }]), { status: 200 });
  }
  throw new Error(`Unexpected request: ${method} ${url}`);
 }));
 const receipt = await sendMissionMessage('m-fast', 'Follow-up text', undefined, 'msg-fixed-id', known);
 expect(receipt).toEqual({ id: 'msg-fixed-id', queued: true, message_accepted: true });
 expect(calls).toHaveLength(2);
 expect(calls[0].url.endsWith('/api/control/message')).toBe(true);
 expect(calls[1].url).toContain('/api/control/queue?mission_id=m-fast');
 expect(JSON.parse(calls[0].body!).client_message_id).toBe('msg-fixed-id');
});

it('classifies 502/503/504/522/524 and truncated JSON from getMissionEventPage as transient network errors', async () => {
 const { getMissionEventPage } = await import('../src/stream');
 const { ApiError } = await import('../src/api');
 let call = 0;
 vi.stubGlobal('fetch', vi.fn(async () => {
  call++;
  return new Response('Bad Gateway', { status: 502 });
 }));
 const err502 = await getMissionEventPage('m-502').catch(e => e);
 expect(err502).toBeInstanceOf(ApiError);
 expect(err502.status).toBe(502);
 expect(isTransientNetworkError(err502)).toBe(true);
 // apiRaw automatically retried once on 502 before surfacing ApiError:
 expect(call).toBe(2);

 expect(isTransientNetworkError(new ApiError(522, 'Origin Connection Time-out'))).toBe(true);
 expect(isTransientNetworkError(new ApiError(524, 'A Timeout Occurred'))).toBe(true);
 expect(isTransientNetworkError(new ApiError(404, 'Not found'))).toBe(false);

 vi.stubGlobal('fetch', vi.fn(async () => new Response('{"truncated":', {
  status: 200,
  headers: {
   'X-Orb-Events-Protocol': '1',
   'X-Has-More': 'false',
  },
 })));
 const errJson = await getMissionEventPage('m-trunc').catch(e => e);
 expect(errJson).toBeInstanceOf(InvalidApiResponseError);
 expect(isTransientNetworkError(errJson)).toBe(true);
});



