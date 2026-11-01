import { act, cleanup, renderHook } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useCopyToClipboard } from './use-copy-to-clipboard';

afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); Reflect.deleteProperty(document, 'execCommand'); });
describe('clipboard feedback and cleanup', () => {
  it('removes the fallback textarea when copying throws', async () => {
    vi.stubGlobal('navigator', {});
    Object.defineProperty(document, 'execCommand', { configurable: true, value: () => { throw new Error('Denied'); } });
    const { result } = renderHook(() => useCopyToClipboard());
    let copied: boolean | undefined;
    await act(async () => { copied = await result.current.copy('private contents'); });
    expect(copied).toBe(false);
    expect(document.querySelector('textarea')).toBeNull();
    expect(result.current.copiedId).toBeNull();
  });
  it('restarts feedback duration when the same item is copied again', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } });
    const { result } = renderHook(() => useCopyToClipboard({ resetAfterMs: 2000 }));
    await act(async () => { await result.current.copy('first', 'same'); });
    act(() => vi.advanceTimersByTime(1500));
    await act(async () => { await result.current.copy('second', 'same'); });
    act(() => vi.advanceTimersByTime(500));
    expect(result.current.copiedId).toBe('same');
    act(() => vi.advanceTimersByTime(1500));
    expect(result.current.copiedId).toBeNull();
  });
});
