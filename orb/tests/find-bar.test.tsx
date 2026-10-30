import { fireEvent, render, screen, waitFor } from '@solidjs/testing-library';
import { afterEach, describe, expect, it } from 'vitest';
import { FindBar } from '../src/FindBar';
import { Transcript, type StreamItem } from '../src/Transcript';

describe('FindBar in-conversation message-only search', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('searches only final user and agent messages while ignoring thoughts, work narration, tool calls, and automatic wakes', async () => {
    const items: StreamItem[] = [
      {
        kind: 'user',
        key: 'u-1',
        text: 'Please audit Fallback behavior in Orb.',
        sequence: 1,
      },
      {
        kind: 'think',
        key: 'th-1',
        text: 'Thinking about Fallback edge cases and Fallback internals.',
        done: true,
        sequence: 2,
      },
      {
        kind: 'text',
        key: 'narration-1',
        text: 'Let me inspect the Fallback module before answering.',
        live: false,
        sequence: 3,
      },
      {
        kind: 'tool',
        key: 'tool-1',
        callId: 'c-1',
        name: 'read_file',
        args: { path: 'src/FallbackSecretToolArg.ts' },
        result: 'FallbackToolOutputOnly_999',
        done: true,
        sequence: 4,
      },
      {
        kind: 'tool',
        key: 'orch-1',
        callId: 'c-2',
        name: 'mcp__sandboxed__start_mission',
        args: { title: 'Fallback Subagent Worker' },
        result: { mission_id: '00000000-0000-4000-8000-000000000099', status: 'running' },
        done: true,
        sequence: 5,
      },
      {
        kind: 'text',
        key: 'final-1',
        text: 'The final Fallback fix is ready, and fallback tests pass.',
        live: false,
        sequence: 6,
      },
      {
        kind: 'user',
        key: 'u-auto',
        text: 'Automatic coordinator Fallback wakeup',
        source: 'background-task',
        sequence: 7,
      },
      {
        kind: 'user',
        key: 'u-rec',
        text: '[Automatic recovery] Fallback transport retry',
        sequence: 8,
      },
    ];

    const { container } = render(() => (
      <div>
        <div class="scroll">
          <Transcript items={items} needsPrepareSearch={() => false} />
        </div>
        <FindBar />
      </div>
    ));

    const scroller = container.querySelector('.scroll') as HTMLElement;
    fireEvent.pointerDown(scroller);
    window.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'f', code: 'KeyF', metaKey: true, bubbles: true }),
    );

    const input = await screen.findByRole('textbox', { name: 'Find in conversation' });
    const count = container.querySelector('.find-count') as HTMLElement;
    // Empty query never displays "Searching history…"
    expect(count.textContent).toBe('');

    // Search case-insensitively: matches 1 in user prompt + 2 in final agent message = 3 total!
    fireEvent.input(input, { target: { value: 'Fallback' } });
    await waitFor(() => expect(count.textContent).toBe('1 / 3'));

    // Toggle Match Case: only "Fallback" (capitalized) matches => 1 in user + 1 in final agent = 2 total!
    fireEvent.click(screen.getByRole('button', { name: 'Match case' }));
    await waitFor(() => expect(count.textContent).toBe('1 / 2'));

    // Step forward and wrap around
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(count.textContent).toBe('2 / 2'));
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(count.textContent).toBe('1 / 2'));

    // Collapsed WorkFold must remain collapsed (`aria-expanded="false"`)
    const workToggle = container.querySelector('.st-work-head');
    expect(workToggle?.getAttribute('aria-expanded')).toBe('false');

    // Tokens present ONLY in thoughts, intermediate narration, tool args/results, orchestration, or auto wakes must return "No results"
    fireEvent.click(screen.getByRole('button', { name: 'Match case' }));
    for (const nonMessageToken of [
      'internals',
      'before answering',
      'FallbackSecretToolArg',
      'FallbackToolOutputOnly_999',
      'Subagent Worker',
      'coordinator',
      'transport retry',
    ]) {
      fireEvent.input(input, { target: { value: nonMessageToken } });
      await waitFor(() => expect(count.textContent).toBe('No results'));
    }

    // Escape closes FindBar cleanly
    fireEvent.keyDown(input, { key: 'Escape', bubbles: true });
    expect(screen.queryByRole('search')).toBeNull();
  });
});
