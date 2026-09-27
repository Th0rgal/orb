/** One ordered native snapshot followed by changes, without idle IPC traffic. */
export function followInteraction<T>(
  id: string,
  publish: (request: T | null) => void,
  fail: (error: unknown) => void,
): () => void {
  const host = window as unknown as {
    __TAURI_INTERNALS__?: { invoke: (command: string, args: Record<string, unknown>) => Promise<unknown> };
    __TAURI__?: { core?: { Channel?: new () => { onmessage: (value: T | null) => void } } };
  };
  const invoke = host.__TAURI_INTERNALS__?.invoke;
  let stopped = false, token: number | undefined, timer: ReturnType<typeof setTimeout> | undefined;
  const unsubscribe = (value: number) => void invoke?.('local_interaction_unsubscribe', { id, token: value }).catch(() => {});
  // Only older native builds use this ladder. Sequential timeouts cannot overlap
  // reads, and disposal prevents late responses from reaching a new mission.
  const poll = async () => {
    if (stopped || !invoke) return;
    try {
      const value = await invoke('local_interaction', { id }) as T | null;
      if (!stopped) publish(value);
    } catch (error) { if (!stopped) fail(error); }
    finally { if (!stopped) timer = setTimeout(() => void poll(), 1500); }
  };
  const Channel = host.__TAURI__?.core?.Channel;
  if (invoke && Channel) {
    const channel = new Channel();
    channel.onmessage = value => { if (!stopped) publish(value); };
    void invoke('local_interaction_subscribe', { id, onEvent: channel }).then(value => {
      token = value as number;
      if (stopped) unsubscribe(token);
    }).catch(error => {
      if (stopped) return;
      if (/unknown command|command .*not found/i.test(String(error))) void poll();
      else fail(error);
    });
  } else if (invoke) void poll();
  return () => { stopped = true; clearTimeout(timer); if (token !== undefined) unsubscribe(token); };
}
