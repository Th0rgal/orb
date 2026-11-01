import { act, cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(() => {
  cleanup(); vi.doUnmock('react-syntax-highlighter');
  vi.doUnmock('react-syntax-highlighter/dist/esm/styles/prism'); vi.resetModules();
});

describe('JSON highlighting load recovery', () => {
  it('retains readable JSON after import failure and retries on a later mount', async () => {
    vi.resetModules();
    const failedLoad = vi.fn(() => { throw new Error('Chunk unavailable'); });
    vi.doMock('react-syntax-highlighter', failedLoad);
    vi.doMock('react-syntax-highlighter/dist/esm/styles/prism', () => ({ oneDark: {}, oneLight: {} }));
    const { LazyJsonHighlighter } = await import('./lazy-json-highlighter');
    const view = render(<LazyJsonHighlighter>{'{"first":true}'}</LazyJsonHighlighter>);
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
    await waitFor(() => expect(failedLoad).toHaveBeenCalled());
    expect(view.container.querySelector('pre')).toHaveTextContent('{"first":true}');
    expect(view.container.querySelector('[data-testid="highlighted"]')).toBeNull();
    view.unmount();
    const recoveredLoad = vi.fn(() => ({ Prism: ({ children }: { children: string }) => <pre data-testid="highlighted">{children}</pre> }));
    vi.doMock('react-syntax-highlighter', recoveredLoad);
    const next = render(<LazyJsonHighlighter>{'{"second":true}'}</LazyJsonHighlighter>);
    await waitFor(() => expect(next.container.querySelector('[data-testid="highlighted"]')).toHaveTextContent('{"second":true}'));
    expect(recoveredLoad).toHaveBeenCalledTimes(1);
  });
});
