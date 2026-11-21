import { expect, test } from '@playwright/test';

test.use({ browserName: 'webkit' });

test('batch replay retains every streamed fragment in order', async ({ page }, info) => {
  await page.goto('/tests/transcript.html');
  const result = await page.evaluate(async () => {
    const url = '/src/transcriptModel.ts';
    const { buildTranscript, applyStreamEvent, applyStreamEvents } = await import(/* @vite-ignore */ url);
    // End on a user turn so the deltas start a fresh reply.
    const history = Array.from({ length: 2001 }, (_, i) => ({
      type: i % 2 ? 'assistant_message' : 'user_message',
      eventId: `h${i}`,
      data: { id: `h${i}`, content: `Message ${i}` },
    }));
    const events = Array.from({ length: 128 }, (_, i) => ({
      type: 'text_delta',
      eventId: `live${i}`,
      data: { mode: 'delta', content: `[${i}]` },
    }));
    let sequential = buildTranscript(history);
    const start = performance.now();
    for (const event of events) sequential = applyStreamEvent(sequential, event);
    const sequentialMs = performance.now() - start;

    const baseline = buildTranscript(history);
    const begin = performance.now();
    const batch = applyStreamEvents(baseline, events);
    const batchMs = performance.now() - begin;
    return {
      historyEvents: history.length,
      fragments: events.length,
      sequentialMs,
      batchMs,
      equal: JSON.stringify(sequential) === JSON.stringify(batch),
      prefixRetained: batch[0] === baseline[0],
      text: batch.at(-1)?.text,
    };
  });

  const { text, ...metrics } = result;
  expect(text).toBe(Array.from({ length: 128 }, (_, i) => `[${i}]`).join(''));
  expect(result.equal).toBe(true);
  expect(result.prefixRetained).toBe(true);
  await info.attach('batch-performance.json', { body: JSON.stringify(metrics, null, 2), contentType: 'application/json' });
  console.log('BATCH_BENCHMARK', JSON.stringify(metrics));
});
