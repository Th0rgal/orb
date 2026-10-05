import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { SWRConfig } from 'swr';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { listAntigravityModels } from './api';
import { useAntigravityModels } from './use-antigravity-models';

vi.mock('./api', () => ({ listAntigravityModels: vi.fn() }));
const wrapper = ({ children }: { children: ReactNode }) => <SWRConfig value={{ provider: () => new Map(), shouldRetryOnError: false }}>{children}</SWRConfig>;
afterEach(cleanup);
beforeEach(() => { vi.mocked(listAntigravityModels).mockReset(); });

describe('gateway native model selection', () => {
  it('requires the selected workspace model and discards the previous workspace catalog', async () => {
    let finish!: (value: [string, string][]) => void;
    vi.mocked(listAntigravityModels).mockImplementation(workspace => workspace
      ? new Promise(resolve => { finish = resolve; })
      : Promise.resolve([['host-model', 'Host model']]));
    const { result, rerender } = renderHook(({ workspace, model }) => useAntigravityModels('antigravity', workspace, true, model), {
      wrapper, initialProps: { workspace: '', model: 'host-model' },
    });
    await waitFor(() => expect(result.current.ready).toBe(true));
    rerender({ workspace: 'container', model: 'host-model' });
    expect(result.current.ready).toBe(false);
    expect(result.current.options).toEqual([]);
    await waitFor(() => expect(listAntigravityModels).toHaveBeenCalledWith('container'));
    await act(async () => finish([['container-model', 'Container model']]));
    expect(result.current.ready).toBe(false);
    rerender({ workspace: 'container', model: 'container-model' });
    await waitFor(() => expect(result.current.ready).toBe(true));
  });
  it.each(['empty', 'failure'])('blocks saving when discovery is %s', async outcome => {
    if (outcome === 'failure') vi.mocked(listAntigravityModels).mockRejectedValue(new Error('unavailable'));
    else vi.mocked(listAntigravityModels).mockResolvedValue([]);
    const { result } = renderHook(() => useAntigravityModels('antigravity', 'container', true, 'api-model'), { wrapper });
    await waitFor(() => expect(result.current.message).not.toContain('Discovering'));
    expect(result.current.options).toEqual([]);
    expect(result.current.ready).toBe(false);
  });
  it('rejects retired saved backends without invoking native discovery', () => {
    const { result } = renderHook(() => useAntigravityModels('gemini', '', true, 'old-model'), { wrapper });
    expect(result.current.ready).toBe(false);
    expect(listAntigravityModels).not.toHaveBeenCalled();
  });
});
