import { StrictMode } from 'react';
import { act, cleanup, fireEvent, render, renderHook, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AsyncButton, useAsyncAction } from './async-button';
afterEach(() => { cleanup(); vi.useRealTimers(); });
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}
describe('async controls in Strict Mode', () => {
  it('releases button busy state after completion and allows another click', async () => {
    const task = deferred(); const handler = vi.fn().mockReturnValue(task.promise);
    render(<StrictMode><AsyncButton onClick={handler}>Save fixture</AsyncButton></StrictMode>);
    const button = screen.getByRole('button', { name: 'Save fixture' });
    fireEvent.click(button); expect(button).toBeDisabled();
    await act(async () => task.resolve());
    expect(button).toBeEnabled(); expect(button).not.toHaveAttribute('aria-busy');
    fireEvent.click(button); expect(handler).toHaveBeenCalledTimes(2);
  });
  it('tracks slow operations and clears pending and slow state on completion', async () => {
    vi.useFakeTimers(); const task = deferred();
    const { result } = renderHook(() => useAsyncAction(() => task.promise, { slowAfterMs: 100 }), { wrapper: StrictMode });
    let running!: Promise<void>;
    act(() => { running = result.current.run(); });
    expect(result.current.pending).toBe(true);
    act(() => vi.advanceTimersByTime(100)); expect(result.current.isSlow).toBe(true);
    await act(async () => { task.resolve(); await running; });
    expect(result.current.pending).toBe(false); expect(result.current.isSlow).toBe(false);
  });
});
