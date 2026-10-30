import { describe, expect, it, vi } from 'vitest';
import { createQueueSync } from './queue-sync';

function deferred() {
  let resolve!: (value: string[]) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<string[]>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function setup() {
  const first = deferred();
  const second = deferred();
  const state = { mission: 'a', generation: 0 };
  const fetchQueue = vi.fn().mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
  const apply = vi.fn();
  const onError = vi.fn();
  const sync = createQueueSync({
    fetchQueue, apply, onError,
    getMissionId: () => state.mission,
    getMutationGeneration: () => state.generation,
  });
  return { first, second, state, fetchQueue, apply, onError, sync };
}

describe('queue snapshot synchronization', () => {
  it('runs one fresh follow-up after a mutation invalidates an in-flight response', async () => {
    const t = setup();
    const completion = t.sync('a');
    t.state.generation++;
    await t.sync('a');
    await t.sync('a');
    expect(t.fetchQueue).toHaveBeenCalledTimes(1);
    t.first.resolve(['deleted']);
    await Promise.resolve();
    expect(t.apply).not.toHaveBeenCalled();
    expect(t.fetchQueue).toHaveBeenCalledTimes(2);
    t.second.resolve(['remaining']);
    await completion;
    expect(t.apply).toHaveBeenCalledExactlyOnceWith(['remaining'], 'a');
  });

  it('does not apply the previous mission response and refreshes the newly viewed mission', async () => {
    const t = setup();
    const completion = t.sync('a');
    t.state.mission = 'b';
    await t.sync('b');
    // A late request for the old mission must not replace the pending B refresh.
    await t.sync('a');
    t.first.resolve(['a-message']);
    await Promise.resolve();
    expect(t.apply).not.toHaveBeenCalled();
    t.second.resolve(['b-message']);
    await completion;
    expect(t.apply).toHaveBeenCalledExactlyOnceWith(['b-message'], 'b');
  });

  it('does not apply a response after switching missions without a new refresh', async () => {
    const t = setup();
    const completion = t.sync('a');
    t.state.mission = 'b';
    t.first.resolve(['a-message']);
    await completion;
    expect(t.apply).not.toHaveBeenCalled();
    expect(t.fetchQueue).toHaveBeenCalledTimes(1);
  });

  it('retains the pending refresh when the active request fails', async () => {
    const t = setup();
    const completion = t.sync('a');
    await t.sync('a');
    t.first.reject(new Error('offline'));
    await Promise.resolve();
    expect(t.onError).toHaveBeenCalledTimes(1);
    t.second.resolve([]);
    await completion;
    expect(t.apply).toHaveBeenCalledExactlyOnceWith([], 'a');
  });

  it('does not retry errors indefinitely and permits a later refresh', async () => {
    const t = setup();
    const completion = t.sync('a');
    t.first.reject(new Error('offline'));
    await completion;
    expect(t.fetchQueue).toHaveBeenCalledTimes(1);
    expect(t.apply).not.toHaveBeenCalled();
    const retry = t.sync('a');
    t.second.resolve([]);
    await retry;
    expect(t.apply).toHaveBeenCalledExactlyOnceWith([], 'a');
  });
});
