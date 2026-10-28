import {afterEach, beforeEach, expect, it, vi} from 'vitest';
import {api, isTransientNetworkError, listCompletedMissions, RequestTimeoutError, setApiUrl} from '../src/api';

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

